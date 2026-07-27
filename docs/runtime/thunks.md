# Thunks & the `Future` primitive

*The lazily-computed value that doubles as a one-shot concurrent cell — the claim/wait mechanism every subsystem forces through.*

A **thunk** is a suspended computation that yields a Nix [value](values.md) when forced. `fix` evaluates to weak head normal form (WHNF): forcing a thunk drives it far enough to expose the outermost constructor (an int, a list *spine*, an attrset *keyset*, a lambda) — element/field bodies stay thunked until forced in turn. Forcing is idempotent and memoized: the first force computes, all later forces return the stored result.

In parallel mode the same object is also a **`Future`** — a one-shot concurrent cell. Exactly one fiber *claims* a thunk and runs its body; any other fiber that reaches an in-flight thunk *blocks* on it and observes the claimer's result. There is no duplicate execution and no lock held across evaluation. This single primitive underpins three subsystems: laziness (memoized suspension), parallelism (fibers hand each other results through resolved thunks — see [scheduler](../parallel/scheduler.md), [speculation](../parallel/speculation.md)), and [imports](../parallel/imports.md) (an `ImportEntry` embeds the same `Future`). Wherever you see claim → run → publish → wake, it is this machine.

Correctness oracle: byte-identical `.drv`. Speculation and fan-out are *scheduling* decisions; they never change which value a thunk resolves to.

## Representation

Millions of thunks are live at once on a real eval, so thunk-only metadata stays on `Thunk` while the reusable synchronization primitive remains small. A normal `Future` is 24 bytes; a production `Thunk` is at most 56 bytes, while safety builds retain an active-union tag and allow up to 80. Tests enforce those bounds. Two ideas keep unrelated future users from paying for evaluator state and keep the thunk payload bounded:

- **Separated responsibilities.** `Future` owns only state, claimer identity, and waiters. `Thunk` adds `demanded`, the `TargetKind` discriminant, and optional profiling fields. Imports, realization claims, and I/O futures therefore do not carry thunk scheduling metadata.
- **`target` XOR `result` overlap.** The `Payload` is a bare 24-byte union: `.target` (what to evaluate) is the live arm while unresolved/evaluating; `.result` (the resolved `Value`, or an `*ErrorInfo`'s bits) is live once terminal. They are *never both live* — the body reads `target`, then the resolver overwrites the same bytes with `result`. So resolving costs no growth. `future.state` is the discriminant that says which arm is live.

```
Thunk
  future: Future
    state:        atomic u32   // FutureState FSM (the discriminant)
    claimer:      atomic u32   // ClaimerId of the evaluating fiber
    waiters_head: ?*Waiter     // parked fibers (null when uncontended)
    waiters_mu:   SpinMutex
  demanded:       atomic u8    // observed by a real caller? (vs speculation)
  target_kind:    TargetKind
  profiling:      zero-sized unless its build probe is enabled
  payload: union {             // bare union — state selects the arm
    target: ThunkTarget,       //   live while unresolved/evaluating
    result: Value,             //   live once resolved/errored
  }
```

`ErrorInfo` (`{err, message}`) is stored out-of-band and pointed at from the `result` slot only in the errored state, so uncommon failures do not widen every thunk.

## `ThunkTarget` kinds

| Kind | Body | Notes |
|---|---|---|
| `closure` | Call a `Value` (user closure → run its chunk; builtin/builtin-closure → apply) | The general case. |
| `bytecode` | Run `chunk_id` with captured upvalues | Up to `inline_capacity` = 2 upvalues live **inline** in the thunk (one alloc, one cache line on the force path); wider captures spill to a slice in the [heap's `values` store](heap.md). `upvalue_count` *is* the discriminant — no tag word, struct stays 24B. |
| `pass_through` | Force a wrapped `Value`, memoize its result | How the compiler models recursive let cells; also `deepSeq`-style memo. |
| `attr_access` | `getAttrValue(base, name)` directly | **Frameless, O(1)**: no frame push, no bytecode dispatch. Serves the overwhelmingly common `someUpvalue.attr` shape (`config.foo`, `lib.bar`, attrset-pattern params) directly; a `bytecode` thunk over a tiny `up_get_attr; ret` chunk would instead run a whole isolated frame, and `run_isolated_frame` is the biggest machinery bucket on the serial critical path. |
| `deferred` | Compile an AST node on first force, then run like `bytecode` | Lazy per-attr compilation of huge generated attrsets (e.g. nixpkgs hackage-packages). The compiled `ChunkId` is cached on the shared `DeferredTable` entry; see [lazy-compile](../compiler/lazy-compile.md). |

Inline-vs-spill storage is mirrored in `deferred` so that arm doesn't widen the union either.

## State machine

```
                    tryClaim (CAS unresolved→evaluating)
  unresolved ─────────────────────────────────────────► evaluating (claimed by ClaimerId)
      ▲                                                        │
      │ reset()  (transient failure only)                      │ run the target …
      │                                                        ├─ resolve()         ─► resolved   (terminal)
      └────────────────────────────────────────────────────── ├─ markErrored()     ─► errored    (terminal, sticky)
                                                               └─ blackhole()       ─► blackhole  (terminal)
```

`tryClaim(claimer)` is the one method every caller enters through. It loops on an acquire-load of `state`:

- **unresolved** → CAS to `evaluating`. Win → store claimer (release) → `.claimed` (you run the body). Lose → retry the loop.
- **evaluating**, claimer == *mine* → `.blackhole`. Same fiber re-entered its own in-flight evaluation = genuine infinite recursion (`let x = x`).
- **evaluating**, claimer == *other* → `.busy`. A different fiber is running it; enroll and park.
- **resolved / errored** → `.already_resolved` / `.errored`; read the embedder's `result` slot.

**`ClaimerId` is per-fiber, globally unique, allocated at fiber creation, and does *not* encode the worker.** So blackhole detection is exact: a fiber that migrates across workers keeps its identity, and two *distinct* fibers touching the same thunk always see `.busy`, never a false blackhole. This is the invariant that makes concurrent forking safe.

## Waiter list & wake

A `.busy` caller enrolls a `Waiter` and yields its worker (so the worker runs other fibers meanwhile). `enrollWaiter` takes `waiters_mu` and **re-checks state under the lock**: if the thunk already left `.evaluating`, it returns `false` and the caller re-loops `tryClaim` instead of parking (closing the enroll-vs-resolve race). Otherwise it prepends to `waiters_head`.

The resolver (`publish` / `publishErrored` / `reset` / `blackhole`) writes the result, release-stores the terminal state, then re-takes the lock, drains the list to a local, releases, and calls each `wake_fn` **outside** the lock (a slow wake must not block other resolvers draining unrelated futures). Each `wake_fn` recovers its fiber via `@fieldParentPtr` and enqueues it on its home-worker ready queue (ready fibers are then stealable by any worker — see [workers](../parallel/workers.md)).

```
memory model
  resolver:  store result (plain)              // payload write
             claimer.store(INVALID, release)
             state.store(terminal, release)     // publishes the result write
             ── re-lock waiters_mu, drain, unlock, wake_fn each (outside lock)
  claimer:   state.load(acquire) == terminal    // observes the result write
             read payload.result
  blackhole: claimer.store(release) / load(acquire)  // pairs for the id compare
```

The result store *happens-before* the state release-store; a reader that acquire-loads the terminal state is guaranteed to see the published payload. The `claimer` store/load are their own release/acquire pair so the blackhole id-compare never reads a stale claimer.

## Forcing — the hot path

`forceValue(v)` is inlined at every call site and handles the common cases without a call frame:

1. **not a thunk** → return `v` unchanged.
2. **thunk, `resolved`** → mark demanded, return `payload.result` (the steady-state case — workers/fan-out tend to resolve hot thunks early).
3. **anything else** → cold `forceThunkImpl`.

`forceThunkImpl`: hit the [GC](../gc.md) safepoint, `tryClaim`, then on `.claimed` check the [memo](#thread-local-thunk-result-memo) and `evalThunkTarget`:

- `bytecode` / `deferred` → `runBytecodeChunk`, which runs the chunk on a fresh interpreter frame (`runIsolatedFrame` — the interpreter is the sole execution engine)
- `closure` → `evalThunkClosure`: run a user closure's chunk on a fresh frame, or `applyBuiltin` for a builtin/builtin-closure
- `attr_access` → frameless `getAttrValue`
- `pass_through` → recurse `forceValueImpl` on the wrapped value

The safepoint sits at this force boundary, never mid-allocation. The fiber that wins collection coordination may request a collection at any native builtin depth; soundness rests on the precise-root discipline (operand stack, call/arg rooting, the in-flight force chain, and container temp-roots). At multiple workers, peers park only at native-depth-zero boundaries, then assist the minor mark and sweep before resuming.

On `.busy`, spin a bounded `busy_spin_before_enroll` (1024) times in case the owner is about to publish, then enroll + yield, and retry the loop on resume. On `.blackhole` → `error.RecursiveThunk`; on `.errored` → replay the cached error.

**In-place forcing.** Ops force operands with `forceAt(depth)` / `forceTop` — the value is forced *while it stays in its stack slot* and written back, never popped first. This keeps the operand stack a precise GC root across the (possibly collecting) force. The in-flight thunk itself is rooted by pushing its id onto `vm.gc_roots.force_chain` for the duration of its body (it's `.evaluating` and off the stack). See [gc](../gc.md).

## Thread-local thunk-result memo

nixpkgs can re-evaluate pure `lib` helpers with identical arguments across many modules, producing distinct thunk objects that per-object memoization cannot share.

The memo is a bounded **per-worker, zero-contention** table (`memo_size = 1 << 14` = 16384 slots) keyed by `(heap_token, chunk_id, upvalue count, ≤2 upvalue Value-bits) → Value`:

- Only `bytecode` thunks with ≤2 upvalues (the inline-storage majority) — the key compares exactly with no allocation.
- **Sound for pure executions** — same chunk + same upvalues ⇒ same value. A
  per-VM effect epoch detects `trace`/`warn`, debugger callbacks, and effects
  returned through nested imports; such executions are not inserted into the
  memo.
- Keyed by `heap_token`, which **bumps on every GC collection**, auto-invalidating stale entries across heap generations / `Engine` instances (same trick as the attr inline cache).
- **Does not cross workers** (thread-local). Each worker publishes its memo's address into a registry so the STW collector can mark current-token entries (a memo slot can be the momentary sole reference to a shared result). The heap token is bumped after collection, invalidating those old slots before ObjectIds can be reused.

Checked on the freshly-claimed path before running the body; a hit resolves the thunk to the cached value and skips execution.

## Special thunks

- **Lazy shell** (`initLazyShell`): born **`.resolved`** with `demanded = 0` and `result` already live. Forces in O(1) (resolved fast path). Used when the compiler has an eager-buildable shape (list/attrset/lambda) sitting in an observably-lazy position — it wraps the already-built shell instead of registering a chunk and dispatching bytecode. Lazy renderers (XML lazy mode) see *resolved but undemanded* and print `<unevaluated />` until a real consumer marks it demanded — this is how speculation stays invisible.
- **Binding cell** (`initBindingCell`): created for recursive `let` bindings *before* the RHS is computed, born **`.evaluating` claimed** by the creating fiber. A concurrent force therefore sees `.busy` and parks, rather than CAS-claiming a placeholder. The creator later calls `publishCellBinding(val)`, which writes `target = pass_through(val)` and transitions back to **`.unresolved`** (keeping laziness — the cell forces `val` only when actually forced). Without the born-claimed guard, a racing fiber could claim the cell while it still wrapped the placeholder null and freeze the binding to null before the creator published — a real race that this fixes.
- **Demand-effect group** (`effect_group`): a claiming speculative fiber freezes
  its effect-journal suffix before release-publishing `.resolved` or `.errored`.
  Acquire readers either propagate that immutable group while speculating or
  atomically emit it on genuine demand. The raw group id fits the thunk's
  existing alignment hole; records themselves are evaluator-owned.

## Invariants & gotchas

- **`reset()` is transient-only.** It drops to `.unresolved` and wakes waiters to retry — used *only* for `error.OutOfMemory`, `error.StackOverflow`, `error.SpeculativeBail` (the target arm is untouched; a transient failure never wrote a result). **It is NOT a safe general retry:** re-running a body after `StackOverflow` can yield a *different* value (a shrunk VM stack changes what the body computes). Deterministic failures instead go **sticky** via `.errored`, replaying the cached `ErrorInfo` on every later force.
- **Terminal states never revert** — except the binding-cell's deliberate `.evaluating → .unresolved` publish.
- **Claim is per-fiber**, not per-worker. Never key blackhole/claim decisions on the OS thread.
- **Thunks are GC-rooted through the in-flight force chain** (`vm.gc_roots.force_chain` roots the `.evaluating` thunk's target closure / upvalues / attr-access base). See [gc](../gc.md).
- **Speculative forcing** (`forceValueSpeculative`) resolves without setting `demanded` and raises `speculation.active`, which (a) stops new thunks from cascading further speculation and (b) lets big builtin loops `error.SpeculativeBail` (a transient reset) once the demanded result is already in hand — bounding one wrong guess. See [speculation](../parallel/speculation.md).
- **Single-owner ranges.** Every `ValueRange` / `AttrRange` a thunk's upvalues spill into is single-owner (a structural invariant), so the GC marks objects not ranges.

Code: `src/runtime/thunk.zig`, `src/expr/vm/force.zig`
