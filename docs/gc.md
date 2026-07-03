# GC

*An experimental non-moving precise mark-sweep collector (`-Dgc`), off by default, zero-cost when off. STATUS: w=1 works and is byte-identical (~-16% RSS, ~81% of heap reclaimable) but serial-mark is a net-negative wall tax; w>1 STW infra is built but GATED OFF on a barrier handshake race. Experimental; interpreter canonical.*

**Zero-cost when off.** `-Dgc` is a comptime `build_options.gc` flag; every root-enumeration, safepoint, and bitmap path is guarded and compiles to nothing when disabled. Enabling it never changes output — the [interpreter](vm/dispatch.md) is canonical and evaluation is byte-identical with the collector on or off.

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

- Size-classed free lists in the [heap](runtime/heap.md); freed ObjectId slots return to their class and are **reused** by subsequent allocation.
- Non-moving: no compaction pass; scattered death leaves fragmentation (measured real, not recoverable by page-return — see status).

## Safepoints

- Collections fire **only** at the `forceThunk` safepoint, and **only at native-depth 0** (no builtin mid-flight holding un-rooted temporaries), when an allocated-bytes byte threshold is crossed.
- On collection, the **`heap_token` is bumped**, which invalidates thread-local caches and the thread-local [thunk-result memo](runtime/thunks.md) — stale ObjectId-keyed entries can't survive a sweep.

## Single-owner range invariant

Every `ValueRange` / `AttrRange` (the backing store for lists and attrsets) has exactly **one owner** object. Therefore **range liveness == owner liveness**: the mark need only trace owners, and the sweep can free a range the moment its owner dies. This invariant is what makes precise marking of the range stores tractable.

## Status

| Mode | State |
|------|-------|
| w=1 | **Fully working, byte-identical.** ~0.2s per collection at deep fixpoint; ~5.6% mutator rooting tax. Measured ~81% of the heap reclaimable, ~-16% peak RSS (1208MB allocated vs 228MB live at w=1). |
| w>1 | Full STW infra **built but dormant** — gated off on a barrier *back-to-back-collection handshake* race. NOT a roots bug (a full conservative stack scan did **not** fix it); needs a **generation-tagged barrier**. |

**Net verdict on time:** serial mark is a wall tax. The RSS bound is real and valuable, but the ~0.2s/collection serial mark + ~5.6% tax makes it net-negative on *time* — mark must move **off the wall clock** (concurrent-on-idle or parallel STW) to pay. The live set plateaus while total allocation grows linearly, so the RSS win is genuine; the cost is the mark, not the sweep. Page-return via `madvise` recovers only ~32MB (scattered non-moving death) → dead; migrating range stores to mmap won't help RSS either.

## Correctness tooling

- **UAF detector** (ReleaseSafe + `-Dgc`): freed slots are *not reused* and every read asserts the alloc bit is set — surfaces dangling ObjectIds at the read, at their source.
- **Swept-range poisoning**: freed ranges are overwritten with an invalid thunk so any stale reader trips immediately.
- **`FIX_GC_STEP_MB`**: env override for the byte threshold — force aggressive/early collection to shake out rooting gaps.

## Not the Phase-0 probe

`-Dgc` *also* names the **Phase-0 mark-only probe** (mark + headroom sampling, **no reclaim**) used to justify this work and measure the reclaimable fraction. This doc describes the **full collector** (mark + sweep + reuse). For the probe framing and its headroom numbers see [perf/probes.md](perf/probes.md); the ceiling analysis it feeds is in [perf/model.md](perf/model.md).

See [docs/plans/gc-plan.md](plans/gc-plan.md) for the design and roadmap.

Code: `src/runtime/gc.zig`
