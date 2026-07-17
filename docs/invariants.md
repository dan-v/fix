# Invariants

*The cross-cutting rules a change must not break. Each links to the doc that explains it.*

These span subsystems, so they're collected here. Violating one usually shows up as a wrong `.drv`, a data race under `--workers>1`, or a GC use-after-free — rarely as an obvious local bug.

## Correctness oracle

- **Byte-identical `.drv`.** Evaluation must produce the exact store paths `nix-instantiate` does. It's the ground-truth test for every change — a perf win that alters a store path is a bug. What must match exactly (ATerm ordering & escaping, `hashModuloInputs`, nixBase32, fixed-output `r:` logic) is enumerated in [derivation/hashing](derivation/hashing.md).
- **The interpreter is the sole engine and is canonical.** The [GC](gc.md) and the [probes](perf/probes.md) must never change output or behavior — only speed, memory, or measurement. Output is byte-identical whether the collector is dormant or collecting; a diagnostic path must never become load-bearing.
- **Determinism.** Everything that feeds a hash is canonically sorted (attrset entries, drv outputs/inputs/srcs/env, path refs). [String context](derivation/context.md) must propagate through every string op, or a derivation loses inputs.

## Values & memory

- **Canonical-NaN scrub.** Every `f64` entering a `Value` goes through `float()`, which scrubs any NaN to one canonical positive NaN. Never hand-construct a NaN into a `Value`, and never assume an arbitrary NaN bit pattern is a float — a stray sign=1 NaN aliases the tagged-value prefix. → [runtime/values](runtime/values.md)
- **Boxed integers.** i64 outside i48 range lives in a heap `boxed_int`. Use `isAnyInt`/`int.get`, never branch on `isInt` alone where a big integer is possible. → [runtime/values](runtime/values.md)
- **IDs never move; a *reachable* object's ID stays valid.** `ObjectId` and `InternId` index segmented stores whose backing pages are never relocated, so a value copied by bits keeps addressing the same slot — the [GC](gc.md) is non-moving *because* suspended fibers hold `ObjectId`s that can't be rewritten. `InternId`s are append-only and never reclaimed. But a swept object's slot is reclaimed onto a free list and reused for a later allocation, so a stale (unrooted) `ObjectId` can silently alias a *different* object — which is exactly why rooting (below) is load-bearing. → [runtime/heap](runtime/heap.md)
- **Attrsets are sorted by `InternId`.** Construction sorts and rejects duplicates; lookup binary-searches. Don't build an attrset object out of order. → [runtime/heap](runtime/heap.md)

## Thunks & the `Future` protocol

- **Claim is per-fiber, not per-worker.** `ClaimerId` is globally unique per fiber and survives worker migration; blackhole detection compares it. Never key claim/recursion decisions on the OS thread. → [runtime/thunks](runtime/thunks.md)
- **`reset()` is transient-only.** It's used only for `OutOfMemory` / `StackOverflow` / `SpeculativeBail`, which never wrote a result. It is **not** a safe general retry — re-running a body can yield a different value. Deterministic failures go sticky via `.errored`. → [runtime/thunks](runtime/thunks.md)
- **Terminal states never revert** — the one exception is a binding cell's deliberate `.evaluating → .unresolved` publish. Recursive `let` cells are **born `.evaluating`/claimed** so a racing fiber parks instead of freezing the binding to a placeholder. → [runtime/thunks](runtime/thunks.md)
- **Publish ordering.** Write the result (plain) *before* the release-store of the terminal state; readers acquire-load the state to observe it. Re-check waiter state under `waiters_mu` on enroll; call wake callbacks *outside* the lock. → [runtime/thunks](runtime/thunks.md)

## GC rooting

- **The operand stack is a precise root; force in place.** Ops force with `forceAt`/`forceTop` and write back — never pop-then-force — so a value stays rooted across a possibly-collecting force. → [runtime/thunks](runtime/thunks.md), [vm/dispatch](vm/dispatch.md)
- **In-flight thunks are rooted by the force chain.** An `.evaluating` thunk is off the stack; `vm.gc_force_chain` roots its target/upvalues for the body's duration. Loop-based builtins root accumulators via `gc_temp_roots`. → [gc](gc.md)
- **`heap_token` invalidates caches.** It bumps on every collection (and per `Evaluator`); the attr inline cache and the [thunk-result memo](runtime/thunks.md) key on it so stale entries auto-miss. Any new cross-eval cache must key on it too. → [gc](gc.md)
- **Single-owner ranges.** Every `ValueRange`/`AttrRange` belongs to exactly one object; the GC marks objects, not ranges. Don't alias a range into two objects. → [gc](gc.md)
- **Collections fire only at `native_depth == 0`** (a `forceThunk` safepoint), never mid-builtin. → [gc](gc.md)

## Concurrency

- **Fiber resumption is deduplicated and serialized.** `ReadyNode.queued` (0→1 CAS) keeps a fiber on the ready queue at most once; a per-fiber `run_mu` serializes concurrent `resume_` from different threads. Both are load-bearing against real crashes. → [parallel/fibers](parallel/fibers.md)
- **Stolen fibers return home.** A finished fiber goes back to its *allocator*-worker's free list, not the stealer's, so teardown ownership is unambiguous. → [parallel/workers](parallel/workers.md)
- **Speculation stays one layer deep and bails only after demand.** `in_speculation` stops a speculative force from cascading more speculation; `SpeculativeBail` only triggers once the demanded result already exists — so byte-identity is preserved and there's nothing to tune. → [parallel/speculation](parallel/speculation.md)
- **Progress stage emission is demand-only, structurally.** The progress protocol is split into two types: the stage-stack half (`StageSink` — a single-writer LIFO `active[]` in the CLI, not thread-safe) exists only on the demand fiber's `ExecutionContext` (`eval/workers/context.zig`), installed by `Worker.runTopLevel` alongside `is_demand` and reset when the fiber recycles; every VM on that fiber — including nested import/render VMs — reads it through `vm.ctx`, and every other fiber's ctx holds null, so an off-demand stage or wait emit has no handle to call through. The concurrent-span half (`SpanSink`, on every VM as `progress_spans`) is the **only** progress channel available off-demand — don't add a bypass; a stray off-demand stage emit corrupts `active[]` (historically an intermittent TTY-only `--workers>1` SIGSEGV/hang). Every emit gates on its handle being installed, so a run with progress disabled pays nothing.

## Observability

- **Progress reports work boundaries, not scheduler quanta.** Stage and wait events come only from the demand fiber; off-demand work uses independent concurrent spans. Keep all progress writes gated on an installed sink, and never add per-quantum progress updates to the evaluation hot path. → [cli](cli.md)

## Build & structure

- **LLVM is forced** (`use_llvm=true`) because the threaded dispatcher relies on `@call(.always_tail)`; other backends would unbounded-recurse. → [build](build.md), [vm/dispatch](vm/dispatch.md)
- **Module-boundary hygiene.** Import the durable groups (`base`, `syntax`, `runtime`, `store`, `fetchers`, `expr`, `cli`) by name. Inside a durable module, use ordinary relative imports so each type has one canonical instance. → [build](build.md)
- **Chunks are immutable after registration**, and their constants are permanent GC roots (never swept). Per-thread inline caches/memos are guarded by `heap_token`. → [vm/dispatch](vm/dispatch.md)
