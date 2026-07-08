# GC

*A non-moving, precise, generational collector (`-Dgc`). It is compiled into the default build and runs at all worker counts; `-Dgc=false` builds the collector-free evaluator. A run that never crosses half its memory budget stays dormant and pays only the mutator rooting tax (~2–2.5% wall, measured), because reclaim tracking is armed lazily at the first budget/2 safepoint. Enabling collection never changes output — the [interpreter](vm/dispatch.md) is canonical and evaluation is byte-identical with the collector dormant, collecting, or absent.*

**Why a collector at all.** `fix`'s object stores are append-only bump allocators (see [heap](runtime/heap.md)), so without reclamation peak RSS tracks *total* allocation, not the live set — and the live set plateaus (~228 MB on nixos_toplevel) while total allocation grows linearly (~1.2 GB). The collector's job is to bound RSS on memory-constrained machines; it is not a throughput lever (mark is a wall tax — see [perf/model](perf/model.md)).

**Zero-cost when absent.** `build_options.gc` is a comptime flag. Every root-enumeration, safepoint, and bitmap path is `comptime`-guarded and compiles to nothing under `-Dgc=false`.

## Memory budget (the collection policy)

One number decides when the collector runs: a heap-reserved-bytes budget, defended against.

- Resolution order: `--max-memory=N` (MiB, or `Nk`/`Nm`/`Ng`) → `FIX_MAX_MEMORY` (same format) → **half of `/proc/meminfo` MemAvailable** (fallbacks: half MemTotal, then 2 GiB). Half, because the budget bounds only the four heap stores — side allocations (chunks, interner, strings, thread stacks) ride on top, and other processes need headroom. `0` = never collect (reclaim machinery never enabled — bump-only, like `FIX_GC_OFF`).
- **Lazy arming**: below budget/2 the heap only compares its reserved-bytes cursor against the threshold once per TLAB refill — no young-slot tracking, no write barrier, no free-list probes. The first budget/2 crossing runs an arming stop-the-world safepoint (`armLazy`): everything allocated so far becomes untracked/old (the unreclaimable floor, ≈ reserved at budget/2 by construction), and real collections start at the full budget, re-armed to `max(budget, reserved + clamp(budget/8, 64MB, 1GB))` after each.
- Consequence: on a big-RAM machine the default budget dwarfs any eval → **zero collections, zero arming, rooting-tax only**; on a small-RAM device collections start well before OOM and peak reserved stays bounded near the budget (measured: `--max-memory=512m` holds nixos_toplevel at ~850 MB reserved vs ~1.4 GB unbounded, byte-identical).

## Why non-moving + precise

- **Non-moving.** [ObjectIds](runtime/heap.md) are dense indices baked into thunks, [values](runtime/values.md), and range headers across many *suspended [fibers](parallel/fibers.md)*. A moving collector would have to rewrite every ObjectId in every parked fiber's state — infeasible. So objects stay put; survivors are promoted in place (the generation bit flips, the id is unchanged) and fragmentation is accepted as the price.
- **Precise.** No C-stack / register scan. The collector walks *exact heap edges* from an enumerated root set via the heap's trace map. This is why roots must be enumerated explicitly and completely (below) — a missed root is a use-after-free, not a conservative over-retention.

## Generational structure

Collections are **minor** and young-gated: each minor examines only the objects allocated since the last collection — recorded per-worker in `HeapLocal.gc_young_slots` (appended on allocation once tracking is armed, cleared after each minor) — so the work is O(young), not O(total).

- **Young/old.** Objects allocated after arming are young; a minor promotes marked survivors to old (in place) and reclaims the dead.
- **Remembered set.** An old→young write barrier records old objects that come to reference young ones, so the young-gated mark can seed from roots *plus* the remembered set and stop at old boundaries without missing live young children.
- **Incremental chunk-constant scan.** Chunk constants can hold heap references and chunks are never collected, so their constants are permanent roots — but only chunks compiled since the last minor can still reference a young object, so the root scan resumes from `gc_chunks_scanned` rather than rescanning all chunks every cycle.

## Root set

Marking starts from every place a live ObjectId can be reached without going through the heap (`markRoots` in `src/eval/gc.zig`):

```
Root set (all must be enumerated — precise):
  • Every worker VM (via each fiber's VM):
      – operand stack + all Frames        (vm/dispatch.md)
      – Frame.upvalues                     (runtime/thunks.md)
      – builtins + the value in-flight at the safepoint
  • In-flight force chain    vm.gc_force_chain   (the suspended
        forceThunk stack, runtime/thunks.md)
  • Native temp roots        vm.gc_temp_roots    (loop-based builtins
        holding transient objects across allocations)
  • Each fiber's assigned-but-unprocessed task target
  • Scheduler-queued task targets            (parallel/scheduler.md)
  • Thread-local thunk-memo + attr-cache entries (token-keyed;
        auto-invalidated on heap token bump — see below)
  • Transient import VMs                      (parallel/imports.md)
  • Old→young remembered set (seeds the young-gated mark)
  • Chunk constants — pinned, never swept (scanned incrementally)
  • Resolved import results + current-token lazy-derivation cache
```

## Mark

- Precise **bitmap**: one bit per ObjectId (marked/live).
- Explicit **worklist**, no recursion (heap graphs are deep).
- From each root, follow exact heap edges via the trace map; mark reached young objects and account live bytes / objects / ranges. The mark stops at old objects (reached only through the remembered set).
- Single-owner ranges (below) mean a `ValueRange`/`AttrRange` is marked as part of its owner — no separate range roots.

## Sweep (reclaim)

- Processing each young object: **marked ⇒ survivor**, promoted in place (`gcSetOld`, id unchanged, ranges stay put); **unmarked ⇒ dead**, its store ranges returned to the free lists in place and its slot id recycled.
- **Per-worker** free lists in the [heap](runtime/heap.md) (`HeapLocal.gc_free_objects` for slot ids; `gc_free_values` / `gc_free_attrs` / `gc_free_attr_pos` are exact-fit range lists keyed by length). A dead object's slot id and ranges are pushed into the free shard of whichever worker evacuated its young-slot list, then **reused lock-free** by that worker's subsequent allocations (exact-length range match; slot ids LIFO). No shared alloc mutex.
- Non-moving: no compaction pass; scattered death leaves fragmentation (measured real, not recoverable by page-return — see status).

## Safepoints

- Collections fire **only** at the `forceThunk` safepoint, and **only at native-depth 0** (no builtin mid-flight holding un-rooted temporaries), when the reserved-bytes threshold is crossed.
- On collection the **`heap` token is bumped**, which invalidates thread-local caches and the thread-local [thunk-result memo](runtime/thunks.md): they hold Values weakly (not roots), so a fresh token makes every stale ObjectId-keyed slot miss rather than read a reused id. This is why those caches needn't be traced.

## Single-owner range invariant

Every `ValueRange` / `AttrRange` (the backing store for lists and attrsets) has exactly **one owner** object. Therefore **range liveness == owner liveness**: the mark need only trace owners, and the sweep can free a range the moment its owner dies. This invariant is what makes precise marking of the range stores tractable.

## Parallelism

At `--workers=1` a minor is serial on the lone mutator. At `--workers>1` every live worker is parked at a safepoint, so the collector recruits the parked peers:

- **Parallel mark** — an atomic bitmap + per-worker work-stealing deques; the collector seeds roots + remembered set into its own deque, opens the mark, and parked peers help-drain to global termination. Participants are capped by `FIX_GC_PAR_CAP` (default 8; the mark is contention-bound past ~8).
- **Parallel evacuation** — the young-object lists are a shared claim-loop; each participant claims lists and promotes/frees them into its own tenured TLAB and free shard.
- The eval still runs `worker_count`-wide; only the mark+evac is throttled by the cap. Peers over the cap park idle rather than pile on.

## Status

| Mode | State |
|------|-------|
| w=1 | **Fully working, byte-identical** (incl. ReleaseSafe UAF-detector gauntlet under `FIX_GC_STEP_MB=64`). Minor pause ~48ms (mark ~33ms — ~94% of it the young-survivor transitive drain; roots + remset are single-digit ms thanks to the incremental chunk-constant scan — plus sweep ~15ms). Dormant (budget never crossed): **+2.5% wall vs collector-free, no RSS delta**. |
| w>1 | **Fully working, byte-identical** (validated w=8: 512m/768m budgets, `FIX_GC_STEP_MB=64` ×13–28 collections, detector build). Mark + evac are parallel across parked peers (see above); free lists are per-worker sharded. Barrier spin ~4–11ms/collection at w=8. Dormant: **+2.2% wall vs collector-free**. |

**Net verdict on time:** the dormant cost is the comptime rooting tax only (~2–2.5%): force-chain / temp-root maintenance must stay complete from process start (entries live across the arming boundary), so it cannot be runtime-gated. When collecting, the pause is the young-survivor drain + young-slot sweep; frequency is budget-driven, so total GC wall scales with allocation-past-budget, not run length. The RSS bound is real; `madvise` page-return recovers only ~32 MB (scattered non-moving death). The end goal is concurrent SATB, for which the parallel mark is the substrate.

## Correctness tooling

- **UAF detector** (ReleaseSafe + `-Dgc`): freed slots are *not reused* and every read asserts the alloc bit is set — surfaces dangling ObjectIds at the read, at their source. A companion closure check verifies the minor mark is closed (every young child of a live parent is marked) before the sweep, panicking with the offending parent→child edge so a missed barrier/root is caught at its source.
- **Swept-range poisoning**: freed ranges are overwritten with an invalid thunk so any stale reader trips immediately.
- **`FIX_GC_STEP_MB`**: collect every N MB of fresh allocation from a low start threshold (eager tracking, ignores the budget) to shake out rooting gaps.
- **`FIX_GC_OFF`** (never enable reclaim — bump-only), **`FIX_GC_NOREUSE`** (skip free-list reuse; A/B the reuse path), **`FIX_GC_PAR_CAP`** (mark/evac participant cap), **`FIX_MAX_MEMORY`** (budget override) — measurement/tuning knobs.
- **`FIX_GC_REPORT`**: dump the per-run collection report (pauses, promoted/freed, live vs reserved breakdown) to stderr; off by default so ordinary `-Dgc` runs stay quiet.

Code: `src/runtime/gc.zig` (the precise `Tracer` / marker), `src/runtime/heap/gc.zig` (collector driver: arm / evac / sweep / threshold), `src/eval/gc.zig` (root enumeration, stop-the-world glue, budget resolution). The reclaimable-headroom analysis this bounds is in [perf/model](perf/model.md); the measurement flags are in [perf/probes](perf/probes.md).
