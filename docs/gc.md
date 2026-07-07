# GC

*A non-moving precise generational collector (`-Dgc`), off by default, zero-cost when off. STATUS: works and is byte-identical at ALL worker counts (serial minor at w=1; parallel STW mark + evac at w>1, per-worker sharded lock-free free lists). Collection is governed by a single **memory budget** (`--max-memory` / `FIX_MAX_MEMORY`, default half of MemAvailable): a run that never crosses half the budget pays only the mutator rooting tax (~2-2.5% wall, measured), because reclaim tracking is armed lazily at the first budget/2 STW safepoint. Experimental; interpreter canonical.*

**Zero-cost when off.** `-Dgc` is a comptime `build_options.gc` flag; every root-enumeration, safepoint, and bitmap path is guarded and compiles to nothing when disabled. Enabling it never changes output — the [interpreter](vm/dispatch.md) is canonical and evaluation is byte-identical with the collector on or off.

## Memory budget (the collection policy)

One number decides when the collector runs: a heap-reserved-bytes budget.

- Resolution order: `--max-memory=N` (MiB, or `Nk`/`Nm`/`Ng`) → `FIX_MAX_MEMORY` (same format) → **half of `/proc/meminfo` MemAvailable** (fallbacks: half MemTotal, then 2 GiB). `0` = never collect (reclaim machinery never enabled — bump-only, like `FIX_GC_OFF`).
- **Lazy arming**: below budget/2 the heap only compares the reserved-bytes cursor against the threshold once per TLAB refill — no young-slot tracking, no write barrier, no free-list probes. The first budget/2 crossing runs an arming STW safepoint (everything allocated so far becomes untracked/old — the unreclaimable floor); real collections start at the budget, re-armed at `max(budget, reserved + clamp(budget/8, 64MB, 1GB))` after each.
- Consequence: on a 128 GB machine the default budget dwarfs any eval → **zero collections, zero arming**; on a small-RAM device collections start well before OOM and peak reserved is bounded near the budget (measured: `--max-memory=512m` holds nixos_toplevel at 850 MB reserved vs ~1.4 GB unbounded, byte-identical).

## Why non-moving + precise

- **Non-moving.** [ObjectIds](runtime/heap.md) are dense indices baked into thunks, [values](runtime/values.md), and range headers across many *suspended [fibers](parallel/fibers.md)*. A moving collector would have to rewrite every ObjectId in every parked fiber's state — infeasible. So objects stay put; fragmentation is accepted as the price.
- **Precise.** No C-stack / register scan. The collector walks *exact heap edges* from an enumerated root set via the heap's trace map. This is why roots must be enumerated explicitly and completely (below) — a missed root is a use-after-free, not a conservative over-retention.

## Root set

Marking starts from every place a live ObjectId can be reached without going through the heap:

```
Root set (all must be enumerated — precise):
  • Every worker VM:
      – operand stack + all Frames        (vm/dispatch.md)
      – Frame.upvalues                     (runtime/thunks.md)
      – builtins + native_upvalues
  • In-flight force chain    vm.gc_force_chain   (the suspended
        forceThunk stack — roots on the force chain, runtime/thunks.md)
  • Native temp roots        vm.gc_temp_roots    (loop-based builtins
        holding transient objects across allocations)
  • Scheduler-queued task targets            (parallel/scheduler.md)
  • Thread-local thunk-memo entries (token-keyed; auto-invalidated
        on heap_token bump — see below)
  • Transient import VMs                      (parallel/imports.md)
  • Chunk constants — pinned, never swept
```

## Mark

- Precise **bitmap**: one bit per ObjectId (allocated/live).
- Explicit **worklist**, no recursion (heap graphs are deep).
- From each root, follow exact heap edges via the trace map; mark reached objects and account live bytes / objects / ranges.
- Single-owner ranges (below) mean a `ValueRange`/`AttrRange` is marked as part of its owner — no separate range roots.

## Sweep

- **Per-worker** exact-fit free lists in the [heap](runtime/heap.md) (`HeapLocal.gc_free_*`); freed ObjectId slots and store ranges are **reused lock-free** by subsequent allocation on the owning worker. The STW sweep distributes freed memory round-robin across workers' shards — no shared alloc mutex.
- Non-moving: no compaction pass; scattered death leaves fragmentation (measured real, not recoverable by page-return — see status).

## Safepoints

- Collections fire **only** at the `forceThunk` safepoint, and **only at native-depth 0** (no builtin mid-flight holding un-rooted temporaries), when an allocated-bytes byte threshold is crossed.
- On collection, the **`heap_token` is bumped**, which invalidates thread-local caches and the thread-local [thunk-result memo](runtime/thunks.md) — stale ObjectId-keyed entries can't survive a sweep.

## Single-owner range invariant

Every `ValueRange` / `AttrRange` (the backing store for lists and attrsets) has exactly **one owner** object. Therefore **range liveness == owner liveness**: the mark need only trace owners, and the sweep can free a range the moment its owner dies. This invariant is what makes precise marking of the range stores tractable.

## Status

| Mode | State |
|------|-------|
| w=1 | **Fully working, byte-identical** (incl. ReleaseSafe UAF-detector gauntlet under `FIX_GC_STEP_MB=64`). Minor pause ~48ms (mark ~33ms — ~94% of it the young-survivor transitive drain; roots + remset are single-digit ms thanks to the incremental chunk-constant scan — plus sweep ~15ms). Dormant (budget never crossed): **+2.5% wall vs non-gc, no RSS delta** (interleaved medians, 2026-07-07). |
| w>1 | **Fully working, byte-identical, on by default** (validated w=8: 512m/768m budgets, `FIX_GC_STEP_MB=64` ×13-28 collections, detector build). The mark is **parallel** across parked workers (atomic bitmap + per-worker work-stealing deques + STW help-mark, participants capped by `FIX_GC_PAR_CAP`, default 8), evacuation is a shared claim-loop, and the free lists are **per-worker sharded** (lock-free reuse). Barrier spin ~4-11ms/collection at w=8. Dormant: **+2.2% wall vs non-gc** (was +22% before lazy arming). |

**Net verdict on time:** the dormant cost is the comptime rooting tax only (~2-2.5%): force-chain/temp-root maintenance must stay complete from process start (entries live across the arming boundary), so it cannot be runtime-gated. When collecting, the pause is the young-survivor drain + young-slot sweep; frequency is budget-driven, so total GC wall scales with allocation-past-budget, not run length. The RSS bound is real (live set plateaus while total allocation grows linearly); `madvise` page-return recovers only ~32MB (scattered non-moving death) → dead. The end goal remains concurrent SATB, for which the parallel mark is the substrate.

## Correctness tooling

- **UAF detector** (ReleaseSafe + `-Dgc`): freed slots are *not reused* and every read asserts the alloc bit is set — surfaces dangling ObjectIds at the read, at their source.
- **Swept-range poisoning**: freed ranges are overwritten with an invalid thunk so any stale reader trips immediately.
- **`FIX_GC_STEP_MB`**: env override — collect every N MB of fresh allocation from a low start threshold (eager tracking, ignores the budget) to shake out rooting gaps.
- **`FIX_GC_OFF`** (never enable reclaim), **`FIX_GC_NOREUSE`** (bump-only A/B), **`FIX_GC_PAR_CAP`** (mark/evac participant cap), **`FIX_MAX_MEMORY`** (budget override) — measurement/tuning knobs.
- **`gc_validate.sh`** (repo root): golden-hash + wall + GC-report one-liner per run.

## Not the Phase-0 probe

`-Dgc` *also* names the **Phase-0 mark-only probe** (mark + headroom sampling, **no reclaim**) used to justify this work and measure the reclaimable fraction. This doc describes the **full collector** (mark + sweep + reuse). For the probe framing and its headroom numbers see [perf/probes.md](perf/probes.md); the ceiling analysis it feeds is in [perf/model.md](perf/model.md).

Code: `src/runtime/gc.zig` (tracer), `src/runtime/heap/gc.zig` (collector driver: arm/evac/sweep/threshold), `src/eval/gc.zig` (roots, STW glue, budget resolution).
