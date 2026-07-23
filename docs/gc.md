# GC

*A non-moving, precise, generational collector. It is part of every supported build and runs at all worker counts. Reclaim tracking is armed lazily at the first budget/2 safepoint, so smaller evaluations avoid young tracking, barriers, and free-list probes. Collection never changes output — the [interpreter](vm/dispatch.md) remains canonical.*

**Why a collector at all.** Without reclamation, the stores track *total* allocation rather than the live set. The collector bounds retained heap storage on memory-constrained machines; current cost measurements belong in [perf/model](perf/model.md).

## Memory budget (the collection policy)

One number decides when the collector runs: a heap-reserved-bytes budget, defended against.

- Resolution order: `--gc-budget=N` (MiB, or `Nk`/`Nm`/`Ng`) → **half of `/proc/meminfo` MemTotal**, clamped by defaults of 256 MiB–8 GiB (fallback: half of an assumed 4 GiB). `FIX_GC_FLOOR` and `FIX_GC_CEILING` override those bounds with the same size syntax. The budget covers the evaluator heap stores, not total process RSS; side allocations such as chunks, interned strings, and thread stacks sit outside it. `0` = never collect (reclaim machinery remains dormant and allocation stays bump-only).
- **Lazy arming**: below budget/2 the heap only compares its reserved-bytes cursor against the threshold once per TLAB refill — no young-slot tracking, no write barrier, no free-list probes. The first budget/2 crossing runs an arming stop-the-world safepoint (`armLazy`): everything allocated so far becomes untracked/old (the unreclaimable floor, ≈ reserved at budget/2 by construction), and real collections start at the full budget, re-armed to `max(budget, reserved + clamp(budget/8, 64MB, 1GB))` after each.
- Consequence: evaluations below the arming threshold do not collect, while constrained budgets begin reclamation before heap reservations grow without bound.

## Why non-moving + precise

- **Non-moving.** [ObjectIds](runtime/heap.md) are dense indices baked into thunks, [values](runtime/values.md), and range headers across many *suspended [fibers](parallel/fibers.md)*. A moving collector would have to rewrite every ObjectId in every parked fiber's state — infeasible. So objects stay put; survivors are promoted in place (the generation bit flips, the id is unchanged) and fragmentation is accepted as the price.
- **Precise.** No C-stack / register scan. The collector walks *exact heap edges* from an enumerated root set via the heap's trace map. This is why roots must be enumerated explicitly and completely (below) — a missed root is a use-after-free, not a conservative over-retention.

## Generational structure

Routine collections are **minor** and young-gated: each minor examines only the objects allocated since the last collection — recorded per-worker in `HeapLocal.gc_young_slots` (appended on allocation once tracking is armed, cleared after each minor) — so the work is O(young), not O(total). Once promoted objects reach the major gate (the previous major's live-object count, with a one-million-object floor), the next collection performs a full, non-gated mark and sweep to reclaim unreachable old objects.

- **Young/old.** Objects allocated after arming are young; a minor promotes marked survivors to old (in place) and reclaims the dead.
- **Remembered set.** An old→young write barrier records old objects that come to reference young ones, so the young-gated mark can seed from roots *plus* the remembered set and stop at old boundaries without missing live young children.
- **Incremental chunk-constant scan.** Chunk constants can hold heap references and chunks are never collected, so their constants are permanent roots — but only chunks compiled since the last minor can still reference a young object, so the root scan resumes from `gc_chunks_scanned` rather than rescanning all chunks every cycle.

## Root set

Marking starts from every place a live ObjectId can be reached without going through the heap (`markRoots` in `src/expr/eval/gc_controller.zig`):

```
Root set (all must be enumerated — precise):
  • Every worker VM (via each fiber's VM):
      – operand stack + all Frames        (vm/dispatch.md)
      – Frame.upvalue_owner + upvalues     (runtime/thunks.md)
      – builtins + the value in-flight at the safepoint
  • In-flight force chain    vm.gc_roots.force_chain (the suspended
        forceThunk stack, runtime/thunks.md)
  • Native temp roots        vm.gc_roots.temporary (loop-based builtins
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
- A major uses the same trace map without the young gate, rescans all chunk constants, and also seeds remembered mutable edges that cannot always be recovered by rescanning their source object.
- Single-owner ranges (below) mean a `ValueRange`/`AttrRange` is marked as part of its owner — no separate range roots.

## Sweep (reclaim)

- Processing each young object: **marked ⇒ survivor**, promoted in place (`gcSetOld`, id unchanged, ranges stay put); **unmarked ⇒ dead**, its store ranges returned to the free lists in place and its slot id recycled.
- **Worker-local caches with shared overflow** in the [heap](runtime/heap.md) (`HeapLocal.gc_free_objects` for slot ids; `gc_free_values` / `gc_free_attrs` / `gc_free_attr_pos` are range lists keyed by length). Minor sweep first returns dead storage to its allocation worker even when a different helper processes that worker's young list. At the stop-the-world boundary, unused slots and ranges move to shared overflow. Mutators refill object ids 4096 at a time and compatible range classes 256 at a time, so cross-worker reuse needs one lock per batch rather than the old lock and peer probes on every allocation. Consecutive adjacent ranges are coalesced as sweep streams them back, without allocating per-range address metadata. TLAB suffixes that cannot fit the next request and unused worst-case merge capacity are returned explicitly because no owner exists for sweep to find. Allocation takes exact range matches first, otherwise uses a non-empty-class best-fit index and splits the smallest suitable range; slot ids are LIFO.
- Spilled bytecode/deferred-thunk captures record their value-store range. An unresolved dead thunk returns that range during sweep; a forced thunk returns it immediately after its evaluation frame unwinds and just before publishing its result or sticky error. Transient failures keep the range for retry. Closure frames record and root the heap closure that owns their raw upvalue slice, so a live executing closure keeps its captures while dead closures return their value-store ranges during sweep.
- Non-moving: no compaction pass, so scattered death can leave fragmentation.
- A major sweeps every allocated object slot rather than the young lists, then tenures every survivor and clears the remembered set. It also rebuilds each store's fragmented free ranges from a bitmap and releases the now-empty vectors for obsolete range-length classes, preventing historical class distributions from retaining allocator capacity indefinitely. The full sweep is currently serial.

## Safepoints

- Collections fire at the `forceThunk` safepoint when the reserved-byte threshold is crossed. The coordinating fiber may enter at any native depth because builtin temporaries follow the explicit-root discipline; peer fibers park only at native-depth-zero boundaries before assisting the collection.
- Current-token thunk-memo and attr-cache entries are roots because they can momentarily be the sole reference to a shared value. After collection the **heap token is bumped**, making every old cache slot miss before a recycled ObjectId can be read as the prior value.

## Single-owner range invariant

Every `ValueRange` / `AttrRange` (the backing store for lists and attrsets) has exactly **one owner** object. Therefore **range liveness == owner liveness**: the mark need only trace owners, and the sweep can free a range the moment its owner dies. This invariant is what makes precise marking of the range stores tractable.

## Parallelism

At `--workers=1` a minor is serial on the lone mutator. At `--workers>1` every live worker is parked at a safepoint, so the collector recruits the parked peers:

- **Parallel mark** — an atomic bitmap plus per-worker work-stealing deques. The collector seeds roots and the remembered set, then parked peers help drain to global termination. `FIX_GC_PAR_CAP` caps participants.
- **Parallel minor sweep** — the per-worker young-object lists form a shared claim loop; each participant promotes marked survivors in place and returns dead slots and ranges to its own free shard.
- **Parallel major mark** — the same parked peers drain a non-young-gated full mark, then remain parked while the collector performs the full sweep serially.
- Evaluation still runs `worker_count`-wide; collection participation is capped. Peers over the cap remain parked.

## Status

| Mode | State |
|------|-------|
| w=1 | Minor and major collection are enabled; detector builds validate reads and mark closure. |
| w>1 | Minor mark/sweep and major mark run across parked peers; major sweep is serial and free lists are per-worker sharded. |

**Cost model:** force-chain and temporary-root maintenance must stay complete across the arming boundary. Once collection is active, minor pauses consist of survivor marking and young-list sweep; a less-frequent major adds a full-heap sweep. Frequency is budget-driven. Non-moving fragmentation limits how much storage can be returned directly to the OS.

## Correctness tooling

- **UAF detector** (ReleaseSafe): freed slots are *not reused* and every read asserts the alloc bit is set — surfaces dangling ObjectIds at the read, at their source. A companion closure check verifies the minor mark is closed (every young child of a live parent is marked) before the sweep, panicking with the offending parent→child edge so a missed barrier/root is caught at its source.
- **Swept-range poisoning**: freed ranges are overwritten with an invalid thunk so any stale reader trips immediately.
- **`FIX_GC_STEP_MB`**: collect every N MB of fresh allocation from a low start threshold (eager tracking, ignores the budget) to shake out rooting gaps.
- **`FIX_GC_NOREUSE`** (skip free-list reuse; validate the reuse path) and **`FIX_GC_PAR_CAP`** (collection participant cap) are validation/tuning knobs.
- **`--gc-report`** dumps the per-run collection report (pauses, promoted/freed, live vs reserved breakdown) to stderr.

Code: `src/runtime/gc.zig` (the precise serial/parallel marker and metrics), `src/runtime/heap/collector.zig` (arming, sweep, and threshold policy), and `src/expr/eval/gc_controller.zig` (root enumeration, stop-the-world integration, and budget resolution). The reclaimable-headroom analysis this bounds is in [perf/model](perf/model.md); the measurement flags are in [perf/probes](perf/probes.md).
