# Non-moving GC conversion (drop the copying-nursery re-fetch tax)

Branch `perf/gc-nonmoving` off `perf/thin-thunks`. Motivation: measured GC cost (w=32,
`-Dgc`, spec on) is **~0.7s of always-on mutator tax + ~0.15s collection**. The tax is
the copying (moving) collector's price — the ~30-site re-fetch discipline (builtins
re-fetch store slices per element because a minor *evacuates/relocates* ranges) plus
per-alloc young/old bookkeeping. That tax buys RSS bounding via contiguous death — which
is now deprioritized (RSS is fine; GC is wanted for reclaim, not compaction). So make the
collector **non-moving**: objects/ranges never relocate ⇒ the re-fetch tax is deletable.

## The substrate already exists (from the pre-copying mark-sweep on `main`)
- `ObjectHeap.sweep()` (heap.zig:1458) — non-moving free-in-place (frees dead objects'
  ranges to `RangeFreeList` + slot to `gc_free_objects`).
- `gcFreeObjectRanges` (heap.zig:1556) — the per-object range-return used by `sweep`.
- `RangeFreeList` + `gc_free_{values,attrs,attr_pos}` — the reclaim lists.
- `main`'s `reserveRangeLocal` POPS these free lists before bumping (main:605/653) — the
  reuse path the copying nursery *removed* (replaced with young-bump + evacuation).

## Keep the generational young mark (efficiency); only make the SWEEP non-moving
Do NOT go full-mark-sweep (mark all live each collection — the copying nursery's parallel
*young-gated* mark is why w>1 collection is viable). Keep: parallel young-gated mark,
`gc_young_slots` list, remembered-set barrier, `gc_old_bits`. Change only the per-young-slot
disposition and the range allocator.

## Increments (each: byte-identical .drv w=1/w=32 + `-Dgc` ReleaseSafe gauntlet clean)
1. **Non-moving minor + free-list alloc** (the core, coupled):
   - `gcEvacListInto` (heap.zig:1297) → *sweep* young list: marked ⇒ `gcSetOld(id)` only
     (promote bit-flip; **ranges stay put — no `gcEvacuateObject`**); unmarked ⇒
     `gcFreeObjectRanges(dst, objects.get(id))` + free slot id.
   - `gcMinorCollect` (heap.zig:1273): **remove `gcResetNursery`** (survivor ranges must
     stay; dead ranges freed individually above). Drop the parallel-evac phase.
   - `reserveValuesLocal`/`reserveAttrsLocal`/attr-pos: pop `gc_free_{values,attrs,attr_pos}`
     before the young/bump path (restore main:605/653).
   - Young/tenured range partition becomes vestigial (harmless: young segments just stop
     resetting; they're a non-moving region reused via free lists). Can keep `reserveYoung`
     as-is initially; the free-list pop makes reuse work without the reset.
   - Gate: gauntlet clean (no missed-edge/poison/UAF), byte-identical, measure wall.
2. **Delete the re-fetch discipline** (the perf payoff, ~0.7s target): the ~51 `if (comptime
   build_options.gc)` re-fetch sites in `src/vm/builtins/*` + force.zig become unnecessary
   (ranges never move) — revert them to holding the slice across forces. Measure wall drop.
3. **Cleanup**: delete `gcEvacuateObject`/`gcEvacValues`/`gcEvacAttrs`/the parallel-evac
   queue/`gcResetNursery`/`reserveYoung`/`resetYoung`/`poisonYoung` and the young-range
   partition in stable_segments once #1/#2 prove out.

## Risks
- Fragmentation: non-moving + `RangeFreeList.pop(n)` exact-size reuse can fragment (main
  ran w=1 only; w>1 shards the free lists round-robin in `sweep`). Watch reserved-vs-live.
- The `gc_debug` poison net (poisonYoung) assumed nursery reset; with in-place free the
  poison moves to `gcFreeObjectRanges` (already poisons there, heap.zig:1562) — verify the
  young-reset poison removal doesn't blind the detector.
- w>1: promotion is a bit-flip (already atomic); freeing to per-worker shards during a STW
  minor is single-writer (collector) — same as `sweep`. The parallel young mark is unchanged.
