# VM Calls

*The calling convention: closures, currying/uncurrying, partial application, and per-call strictness.*

Function application is the hot path of Nix evaluation. This is where closures become frames, where multi-arg lambdas avoid intermediate allocation, and where the compiler's strictness analysis ([compiler/strictness.md](../compiler/strictness.md)) turns into eager-vs-lazy argument decisions at runtime.

## Callable values

A call applies a **callee** value to arguments. Five callee kinds:

| kind | apply behavior |
|---|---|
| **closure** | `ObjectId → { chunk_id, upvalues }` (see [runtime/heap.md](../runtime/heap.md)). Runs the chunk body in a frame. |
| **PartialApp** | an under-applied uncurried closure: `{ func, accumulated_args }`. Extended or saturated by the next arg. |
| **builtin** | a primop id; `applyBuiltin(id, args)` (see [builtins.md](builtins.md)). |
| **builtin_closure** | a primop pre-bound to leading args (`{ builtin_id, args }`); appends the new arg and applies. |
| **attrs with `__functor`** | callable attrset: fetch `.__functor`, then apply *it* to the attrset itself, then apply the original arg (one extra call level). |

Closures are **immutable**: `closure`/`closure_captures` snapshot the upvalue *values* at creation. There is no re-readable reference to an outer slot — a later shadow of a captured name cannot change what the closure sees (Nix has no mutation; "rebind" is scope shadowing).

## Currying and uncurrying

Nix lambdas are curried (`a: b: c: …`). Naively each `:` is its own one-arg closure, so `f 1 2 3` allocates two intermediate closures. The compiler instead **merges an adjacent value-lambda chain into one uncurried chunk** with `arity = N` (capped at `max_uncurry_arity` = 4; see [compiler/scopes.md](../compiler/scopes.md)). Such a chunk consumes N params in a **single frame**.

Application against an uncurried chunk has three cases:

- **Saturated** (args supplied `== arity`): stage the N args as the frame's first locals and run the body in one frame — zero intermediate closure/PAP allocation. This is the uncurrying win.
- **Under-applied** (`< arity`): build a `PartialApp { func, args }` value and return it. It stays callable; the next application folds one more arg in, saturating when the count reaches `arity`.
- **Over-applied** / **non-closure callee** / **curried (arity 1)**: fall back to applying **one argument at a time** (a normal frame per arg, or the PAP fold).

`arity == 1` (curried lambdas, attrset-pattern lambdas, and all thunk bodies) is the overwhelmingly common path; `doCall` short-circuits it directly and stays branch-cheap, treating `arity != 1` as the rare uncurried/PAP case.

## The call opcodes

| op | position | shape |
|---|---|---|
| `call` | normal | `[closure, arg] → [result]`; pushes a frame (closure) or a result value (builtin/PAP). |
| `call_tail` | tail | closure callee **reuses the current frame** (`replaceCurrentFrame`); other callees behave like `call` followed by `ret`. |
| `call_n` | normal | `[callee, arg1…argN] → [result]`, 1-byte N. Saturated uncurried closure → single frame; otherwise folds one arg at a time. |
| `call_tail_n` | tail | saturated closure reuses the frame (`replaceCurrentFrameMulti`) — deep multi-arg tail recursion does not grow the stack; else folds to a value the following `ret` returns. |

`call`/`call_n` push a frame and then continue dispatch on `currentFrame` — whether the callee transferred control (new frame) or produced a value (builtin/fold), the same resume path handles both. `call_n` is semantically N sequential `call`s; its only reason to exist is the saturated single-frame path.

Two application "flavors" back these:

- **Control-transfer** (`doCall`/`doTailCall`/`doCallN`/`doTailCallN`): pushes/reuses a VM frame, result lands on the caller's stack. Used by the `call*` opcodes.
- **Run-to-completion** (`callValue`/`callValuePartial`): runs the body via `runIsolatedFrame` ([dispatch.md](dispatch.md)) and *returns* a Value. Used by builtins and by the `call_n` fold, which need a value in hand mid-operation.

## Per-parameter strictness at the call boundary

A lazy language thunks arguments by default. But if the callee *unconditionally forces* an argument, thunking it is pure overhead (and, in accumulator recursion, builds unbounded thunk chains). The compiler's must-force analysis feeds three runtime decisions:

- **`strict_param`** (single-param chunk whose body must-forces its parameter). At a `thunk_arg` site the VM checks the runtime callee: if it is such a closure, the argument expression is **evaluated eagerly to a value — no thunk**; otherwise it thunks exactly like `thunk`. This catches dynamically-dispatched strict calls the compiler cannot resolve statically.
- **`strict_params`** (bitmask, uncurried chunks). Before a **saturated** `call_n`/`call_tail_n` pushes the frame, `forceStrictArgs` forces the must-force arg positions in place on the stack. Value-preserving (the body forces them anyway); it recovers the eager-arg win for the multi-param case and kills lazy-thunk buildup.
- **`strict_via_upvalue`** (forwarding: body is exactly `f param` for a captured `f`). The lambda forces its arg iff `f` does. `calleeForcesArg` resolves this at the call site (it holds the closure's upvalues), following one level into `f`'s own `strict_param`.

`calleeForcesArg` is conservative — false for builtins, builtin-closures, and callable attrsets (they keep the lazy thunk). See [compiler/strictness.md](../compiler/strictness.md) for how these bits are derived, and [runtime/thunks.md](../runtime/thunks.md) for the thunk they elide.

## `__functor` protocol

Applying an attrset dispatches through `__functor`: read `attrs.__functor`, apply it to the attrset itself (yielding a callable), then apply the pending argument. In tail position this loops (`current = callAttrFunctor(current)`) so chained functors don't grow the frame stack. `NotCallable` if `__functor` is absent.

## Inline caches

Two thread-local, `heap_token`-guarded caches. `chunk_id`s and `obj_id`s are not unique across evaluator instances and the caches are per-thread, so a mismatched `heap_token` invalidates the slot when the evaluator changes.

- **Call IC** (256 slots) — keyed by the caller's `(chunk_id, ip)`, storing the `(callee_chunk_id → *const Chunk)` it last resolved. On hit, `closureChunkViaIC` skips the registry index lookup at every `call`/`call_tail`/`call_n` site; on miss it records the observed callee. The slot index mixes `chunk_id` and `ip` so distinct call sites collide rarely.
- **Attr IC** (8192 slots) — keyed by `(heap_token, obj_id, name_id) → Value` (pre-force). Backs attribute reads; detailed in [access.md](access.md).

## Invariants

- **Callee and args are GC-rooted across a call.** They arrive in Zig locals (popped off the operand stack), so a force *inside* the call would otherwise sweep them; `doCall`/`callValue` root them for the call's duration. Where args stay on the stack (`call_n` fold, saturated frame), the on-stack slot is the root. (See [gc.md](../gc.md).)
- **Upvalues snapshot at closure creation** and never change.
- **Saturated uncurried calls run in one frame** with no intermediate closure/PAP; under-application produces a callable PAP; over-application folds.
- **Caches are per-thread and `heap_token`-guarded**; a stale entry from a prior evaluator is never used.

Code: `src/nix/vm/`, `src/nix/bytecode/`
