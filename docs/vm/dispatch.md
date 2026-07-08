# VM Dispatch

*The threaded bytecode interpreter and the chunk format it runs.*

The interpreter is the canonical evaluator: the bytecode loop is what every correctness claim rests on (byte-identical `.drv`).

## Mental model

A chunk is a compiled function or thunk body: a flat byte stream of opcodes plus a constant pool. The VM holds one **operand stack** and a stack of **call frames**. Executing a chunk = pushing a frame over its locals and running its opcodes; each op mutates the operand stack, and control ops (`call`, `ret`) push/pop frames. There is no expression tree at runtime — only bytes, a stack, and frames.

Dispatch is **threaded**: each opcode is its own small handler function, and each handler ends by tail-jumping to the next. A dispatch step reads the next opcode byte and indexes a static `handlers` table (opcode byte → handler pointer, `handlers[op]`), then `@call(.always_tail)`s it. There is no central `switch`, no per-op `call`/`return`. The whole run of a chunk is one long chain of `jmp`s sharing a single machine stack frame.

## The dispatch chain

Every handler has the identical signature:

```
fn (vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void
```

A handler reads its inline operands from `code[ip..]`, does its work, **pushes any result onto `vm.stack`** (it does not *return* the value), then tail-calls `dispatch`, which reads the next opcode and tail-calls its handler:

```
dispatch(vm, frame, code, ip, stop_depth):
    if ip >= code.len: return endOfCode(vm)     # ran off the end → ensure ≥1 stack value
    op = code[ip]
    @call(.always_tail, handlers[op], {vm, frame, code, ip + 1, stop_depth})
```

`dispatch` is `inline`, so it is spliced into each handler's epilogue — the epilogue *is* the tail jump to the next handler. `ip + 1` is passed so the handler sees `ip` pointing at its first **operand** byte; the handler advances `ip` past its operands before its own dispatch.

Entry funnels through `run → runUntil(stop_depth) → dispatchEntry → dispatch → first handler`. `runUntil` kicks off the chain, then pops and returns the single value the chain left on the stack. `dispatchEntry` is a thin non-inline trampoline whose signature matches the handler signature, so `runUntil` (a different signature) can legally start an `always_tail` chain.

### Why return `void`, not the value

Handlers return `anyerror!void`. `anyerror!Value` is 24 bytes on x86-64 SysV, which forces return-by-sret-pointer; the sret slot would not match across handlers, and `@call(.always_tail)` requires matching signatures. So handlers communicate results through `vm.stack`, and only leave the chain via a plain return when a frame is popped down to the watermark (below).

### Why LLVM is mandatory

`@call(.always_tail, …)` compiles to `jmp`, not `call`. Only the LLVM backend implements it. With it, the entire dispatch chain reuses the *one* stack frame that `runUntil` established — handler-to-handler transitions push nothing. Without it (e.g. a debug/self-hosted backend that lowers the tail call to an ordinary call), the chain would recurse one machine frame per opcode and blow the native stack on any non-trivial program. LLVM is not an optimization here; it is a correctness precondition.

### Why many small handlers, not one switch

An equivalent monolithic ~70-arm `switch` compiles to a single ~32 KB function. At that size LLVM's register allocator abandons aggressive stack-slot coloring, so every arm spills conservatively and adding a single case grew the frame by 16 bytes for *every* arm. Splitting each opcode into a standalone function restores local, per-handler register allocation, removes the shared-spill tax, and makes adding an opcode genuinely free at the codegen level. The static `handlers` table (indexed by opcode byte) is the only thing tying them together.

## Value stack and frames

**Operand stack** — `vm.stack[0..sp)`, capacity `VM_STACK_CAP` (65 536). `push`/`pushFrame` bounds-check against the cap and raise `error.StackOverflow`; `pop` is unchecked (it only decrements `sp`). `sp_high_water` tracks the peak for diagnostics.

**Frames** — `vm.frames[0..frames_len)`, capacity `MAX_FRAMES` (512). A `Frame` is:

| field | meaning |
|---|---|
| `chunk_ptr` | the running `*const Chunk` |
| `chunk_id` | its registry id (for trace/error anchoring) |
| `ip` | byte offset into `code` (written back before any op that can re-enter or fault) |
| `frame_base` | index in `vm.stack` where this frame's locals begin |
| `local_count` | slots reserved for locals |
| `upvalues` | the closure's captured values (`null` for a bare chunk run) |

`pushFrame(ch, chunk_id, arg_count, upvalues)`: the top `arg_count` operands are the frame's first locals (they stay on the stack; `frame_base = sp - arg_count`), the remaining `local_count - arg_count` slots are reserved and `@memset` to `null`, `ip = 0`. Overflow is checked on both frame count (`FrameOverflow`) and slot reservation (`StackOverflow`); `arg_count > local_count` is `InvalidCallFrame`. Locals live *in the operand stack* at `[frame_base .. frame_base + local_count)` — there is no separate locals array.

Local access is force-vs-capture split, matching the recursive-`let` cell discipline (see [runtime/thunks.md](../runtime/thunks.md)): `get_local` forces the slot on read; `capture_local` / `capture_upvalue` read it raw (so an unresolved cell can be captured without triggering evaluation).

### The stop-depth watermark

`stop_depth` threads unchanged through the whole chain. It is the `frames_len` value at which the *current* `runUntil` invocation should stop and hand its result back — not a nesting-limit guard. On `ret`, `retEpilogue`:

1. pops the finished frame, sets `sp = frame_base`, pushes `result`;
2. if `frames_len == stop_depth`, **returns** (leaving the chain) — `runUntil` pops `result` and returns it to its caller;
3. otherwise dispatches into the resumed caller frame (`ret_frame.ip` already points past the call site).

This is what makes the interpreter **re-entrant**. `runIsolatedFrame(ch, chunk_id, arg_count, upvalues)` records `stop_depth = frames_len`, pushes one frame over the pre-staged args, then `runUntil(stop_depth)`; the nested chain runs until exactly that frame rets, yielding its single value. On error it unwinds `frames_len`/`sp` back to the mark and captures a trace. Isolated frames are the universal "run this body and give me the value" primitive — used by thunk forcing ([runtime/thunks.md](../runtime/thunks.md)) and by `callValue`/PAP saturation ([calls.md](calls.md)).

`halt` (chunk sentinel) and running off the end of `code` both terminate the chain, ensuring at least one value is on the stack for the caller.

## Instruction encoding

- 1-byte opcode + **0…N operand bytes**, opcode-dependent. There is **no uniform instruction width**; each handler knows its own operand layout and advances `ip` accordingly.
- Multi-byte operands are **little-endian**: `u8`, `u16`, `u32`, `InternId` (2- or 4-byte "wide" variants where a narrow id might overflow), and repeated 3-byte capture descriptors `(kind:1, index:2)`.
- Many opcodes come in narrow/`_long` pairs (2- vs 4-byte id) and in **fused super-op** forms that collapse common pairs into one dispatch — e.g. `get_upvalue_attr`, `get_local_attr`, and the value-returning `constant_ret` / `get_local_ret` / `get_upvalue_ret` (see [access.md](access.md), [calls.md](calls.md)). Fusion is an emit-time decision in the [compiler](../compiler/pipeline.md); the `fusion_savings` counter keeps fusion from perturbing the speculation size threshold.

## Chunk and registry

A `Chunk` is **immutable after construction**. Key fields (compiler-stamped; see [compiler/scopes.md](../compiler/scopes.md) and [compiler/strictness.md](../compiler/strictness.md)):

| field | role |
|---|---|
| `code`, `constants` | the byte stream and constant pool |
| `local_count` | frame slot count (thunk bodies: `0`; lambda bodies: `≥1`) |
| `arity` | params consumed before the body runs — `1` for curried/attrset lambdas and thunk bodies, `N` for an *uncurried* merged value-lambda chain (see [calls.md](calls.md)) |
| `strict_params` | per-param must-force bitmask for uncurried chunks |
| `scheduling` | `SchedulingHints`: `body_is_substantial` (≥ `SPECULATION_MIN_CODE_BYTES` = 256 → worth speculative forcing, see [parallel/speculation.md](../parallel/speculation.md)), `strictness` bitmasks, `trivial` body classification (trivial thunk bodies skip thunk allocation — see [runtime/thunks.md](../runtime/thunks.md)), `strict_param`, `strict_via_upvalue` |
| `function_args`, `source_map` | `builtins.functionArgs` metadata; cold-path error spans |
| `body_span` | representative source span of the whole body node — labels a thunk quantum / demand wait in the timeline (`null` for chunks that skip it) |

`ChunkRegistry` is the "program": chunks are stored once and referenced by `ChunkId` across threads. Chunks accumulate at runtime, not just at load — the deferred-attr force path compiles fresh bodies on demand, and speculative-import helpers compile `.nix` files ahead of the demand fiber, so many worker threads register concurrently.

- `get(id)` is **lock-free** (bounds-checked index into stable segments).
- `register(chunk)` is **lock-free** too: it heap-allocates the immutable `Chunk`, then `appendAtomic`-CAS-bumps the segment cursor to publish a `ChunkSlot`. Alongside the `*Chunk` pointer, the slot inlines a copy of the hot scheduling metadata (`trivial`, `body_is_substantial`, `strict_param`, `strict_via_upvalue`) so the thunk-creation and speculation-gate paths read them from a dense, cache-friendly array instead of chasing the heap-scattered `Chunk`. Once registered, a chunk never changes, so cross-thread `*const Chunk` sharing needs no further synchronization.

Two **well-known stub chunks** (`genlist_apply`, `mapattrs_apply`) are registered eagerly at `ChunkRegistry.init` so builtins can materialize lazy elements by reusing a shared stub-chunk body instead of allocating a per-element `builtin_closure` object (see [access.md](access.md)).

## Invariants

- **Operand stack is a precise GC root.** Values are forced *in place* on the stack, never after popping into a local — forcing is a GC safepoint, and a popped-then-forced value could be swept. Binary ops read via `binTop`, force in place, and `dropBin` only after. (See [gc.md](../gc.md).)
- **Single reused machine frame.** The `always_tail` chain never grows the native stack; growth is bounded by `MAX_FRAMES` VM frames, not by opcode count.
- **Registered chunks are immutable**; a chunk is fully built before its `ChunkSlot` is published, so any thread that resolves the id observes a complete, unchanging `Chunk`.
- **`frame.ip` is written back** before any op that can fault, re-enter the interpreter, or push a frame, so error traces and resumed callers see a consistent ip.

Code: `src/vm/`, `src/bytecode/`
