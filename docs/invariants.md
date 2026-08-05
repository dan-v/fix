# Invariants

*The cross-cutting rules a change must not break. Each links to the doc that explains it.*

These span subsystems, so they're collected here. Violating one usually shows up as a wrong `.drv`, a data race under `--workers>1`, or a GC use-after-free — rarely as an obvious local bug.

## Compatibility boundaries

- **Compatible derivations.** For supported inputs, `fix` is intended to produce
  the same ATerm derivation text and store paths as `nix-instantiate`. Focused
  tests cover ordering, escaping, `hashModuloInputs`, nixBase32, and
  fixed-output `r:` handling; benchmark-fixture tests compare resulting
  strict JSON values, including `drvPath`s from NixOS and Home Manager
  evaluations. See
  [derivation/hashing](derivation/hashing.md).
- **Instrumentation and collection are not language semantics.** The [GC](gc.md)
  and [probes](perf/probes.md) must preserve successful values, errors, and
  derivation output. A diagnostic path must not become load-bearing.
- **Determinism.** Everything that feeds a hash is canonically sorted (attrset entries, drv outputs/inputs/srcs/env, path refs). [String context](derivation/context.md) must propagate through every string op, or a derivation loses inputs.

## Values & memory

- **Ownership is tagged, never inferred from a boolean.** Use `TextRef` (or a
  domain-specific tagged union) when a field may be borrowed or owned. A
  pointer `deinit` releases the owned case; transferring ownership uses
  `take`. Do not reintroduce `owned: bool` beside an untyped slice.
- **Owned replacements are transactional.** Allocate and validate a
  replacement before freeing the current value. On allocation or parse failure,
  the observable state and its ownership remain unchanged.
- **Canonical-NaN scrub.** Every `f64` entering a `Value` goes through `float()`, which scrubs any NaN to one canonical positive NaN. Never hand-construct a NaN into a `Value`, and never assume an arbitrary NaN bit pattern is a float — a stray sign=1 NaN aliases the tagged-value prefix. → [runtime/values](runtime/values.md)
- **Boxed integers.** i64 outside i48 range lives in a heap `boxed_int`. Use `isAnyInt`/`int.get`, never branch on `isInt` alone where a big integer is possible. → [runtime/values](runtime/values.md)
- **IDs never move; a *reachable* object's ID stays valid.** `ObjectId` and `InternId` index stores whose backing pages are never relocated, so a value copied by bits keeps addressing the same slot. The [GC](gc.md) is non-moving; moving objects would require locating and rewriting IDs in parked fiber state. `InternId`s are append-only and never reclaimed. But a swept object's slot is reclaimed onto a free list and reused for a later allocation, so a stale (unrooted) `ObjectId` can silently alias a *different* object — which is exactly why rooting (below) is load-bearing. → [runtime/heap](runtime/heap.md)
- **Attrsets are sorted by `InternId`.** Construction sorts and rejects duplicates; lookup binary-searches. Don't build an attrset object out of order. → [runtime/heap](runtime/heap.md)

## Thunks & the `Future` protocol

- **Claim is per-fiber, not per-worker.** `ClaimerId` is globally unique per fiber and survives worker migration; blackhole detection compares it. Never key claim/recursion decisions on the OS thread. → [runtime/thunks](runtime/thunks.md)
- **`reset()` is transient-only.** It is used only for `OutOfMemory`,
  `StackOverflow`, and `SpeculativeBail`, which never wrote a result. It is not
  a general retry path. Deterministic failures go sticky via `.errored`. →
  [runtime/thunks](runtime/thunks.md)
- **Terminal states never revert** — the one exception is a binding cell's deliberate `.evaluating → .unresolved` publish. Recursive `let` cells are **born `.evaluating`/claimed** so a racing fiber parks instead of freezing the binding to a placeholder. → [runtime/thunks](runtime/thunks.md)
- **Publish ordering.** Write the result (plain) *before* the release-store of the terminal state; readers acquire-load the state to observe it. Re-check waiter state under the packed waiter-word lock on enroll; call wake callbacks *outside* the lock. → [runtime/thunks](runtime/thunks.md)

## GC rooting

- **The operand stack is a precise root; force in place.** Ops force with `forceAt`/`forceTop` and write back — never pop-then-force — so a value stays rooted across a possibly-collecting force. → [runtime/thunks](runtime/thunks.md), [vm/dispatch](vm/dispatch.md)
- **In-flight thunks are rooted by the force chain.** An `.evaluating` thunk is off the stack; `vm.gc_roots.force_chain` roots its target/upvalues for the body's duration. Loop-based builtins use `vm.gc_roots.temporary`. → [gc](gc.md)
- **`heap_token` invalidates caches.** It bumps on every collection (and per `Engine`); the attr inline cache and the [thunk-result memo](runtime/thunks.md) key on it so stale entries auto-miss. Any new cross-eval cache must key on it too. → [gc](gc.md)
- **Single-owner ranges.** Every `ValueRange`/`AttrRange` belongs to exactly one object; the GC marks objects, not ranges. Don't alias a range into two objects. → [gc](gc.md)
- **Collection starts at a demand `forceThunk` boundary.** The coordinating fiber may collect at any native depth because builtin arguments and fresh intermediates are explicitly rooted; peer fibers park only at `native_depth == 0`. → [gc](gc.md)

## Concurrency

- **Fiber resumption is deduplicated and serialized.** `ReadyNode.queued` (0→1 CAS) keeps a fiber on the ready queue at most once; a per-fiber `run_mu` serializes concurrent `resume_` from different threads. Both are load-bearing against real crashes. → [parallel/fibers](parallel/fibers.md)
- **Stolen fibers return home.** A finished fiber goes back to its *allocator*-worker's free list, not the stealer's, so teardown ownership is unambiguous. → [parallel/workers](parallel/workers.md)
- **External completion outlives publication.** Blocking and daemon callbacks
  copy stack-cell fields before publishing their future, then drop the
  scheduler's `external_jobs` count only after the callback no longer touches
  them. Worker teardown must drain that count even when there are no helper
  threads. → [parallel/workers](parallel/workers.md)
- **Speculative cascades are bounded.** `speculation.active` blocks recursive creation-time speculation and sibling sweeps; queue caps and task budgets bound recursive fan-out and map-style submissions. `SpeculativeBail` triggers after demand completes or a task budget expires. → [parallel/speculation](parallel/speculation.md)
- **Observation state is evaluator-scoped.** An evaluator owns a cheap, copyable `Observer` capability and passes it to its VMs and realization store. There is no process-global recorder and no single-writer stage stack: concurrent evaluators and helper fibers may emit spans independently, while the selected sink owns any synchronization. A disabled or verbosity-filtered span returns before a clock read, subject copy, lock, or indirect call.

## Observability

- **One observation describes one work boundary.** Producers declare a local static `SpanSpec` (or event/counter/flow spec); terminal progress and Perfetto consume that same record. Success completion is explicit, so an error unwind must cancel rather than print a misleading completed record. Worker quanta and demand waits are profile-only and never become terminal chatter. → [cli](cli.md)

## Build & structure

- **LLVM is forced** (`use_llvm=true`) because the threaded dispatcher relies on `@call(.always_tail)`; other backends would unbounded-recurse. → [build](build.md), [vm/dispatch](vm/dispatch.md)
- **Module-boundary hygiene.** Import the durable groups (`base`, `syntax`, `runtime`, `store`, `fetchers`, `expr`, `cli`) by name. Inside a durable module, use ordinary relative imports so each type has one canonical instance. Durable implementation belongs in responsibility-named subdirectories, not the `src/` root or catch-all `util`/`common`/`helpers` files. `zig build structure-check` enforces this shape, tagged ownership, and removal of the legacy `Evaluator` API. → [build](build.md)
- **Registered chunks are immutable after publication.** Their constants are
  permanent GC roots. Source breakpoints patch private `BreakpointTable` code
  overlays selected by debug dispatch; the canonical registry bytes remain
  authoritative. Per-thread inline caches and memos are guarded by
  `heap_token`. → [vm/dispatch](vm/dispatch.md), [cli](cli.md)
