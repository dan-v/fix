# GC copying nursery — target architecture

Status: DESIGN (2026-07-05). Branch `gc-copying-nursery` off `main`. Supersedes
the `gc-concurrent` direction (generational non-moving minor + concurrent-SATB
major): both are abandoned. Concurrent-SATB **lost to tuned STW** by measurement
(`project_gc_concurrent_major`: allocate-black floating garbage +240MB > the
pause it hid). The `gc-concurrent` minor collector was *too slow for too little
RSS* — a non-moving sweep that walked all young objects and freed each dead range
into the scattered exact-fit free list (`project_gc_rss_levers`: "scattered
death", `madvise` recovered only 32MB), plus a blanket remembered-set barrier tax.

This plan lands the *clean end state* in one direction. Intermediate byte-identical
steps are not a goal — correctness bar is byte-identical `.drv` at the landing.

## Thesis

Short pauses are a **generational** property, not a **concurrency** property. A
traditional whole-heap mark freezes N workers for ~200ms because it marks the
whole heap every time. The fix is not "mark concurrently" (pay barrier tax +
floating garbage) — it is "don't mark the whole heap most of the time." A minor
collection touches only young *survivors*, and 83% of objects die young
(`project_deforestation_ceiling`), so that set is tiny. **STW is fine. N workers
stopping is fine. They stop for ~ms, frequently, instead of ~200ms rarely.**

The RSS win comes from **copying**: survivors are relocated contiguously, so
death is contiguous *by construction* — which is exactly the cure for the
scattered-death that capped `madvise` at 32MB. A copying collector cannot
fragment; there are no reuse-holes to fail to fit into. So we delete the
`RangeFreeList` machinery entirely.

## The decoupling that makes it work

Slots and ranges are **separate stores**, and slot placement never constrains
range placement (a `.list` slot holds a range addressed by `(segment, offset)`
independent of the owner's id). This lets us move exactly the store where it pays:

| Store | Shape | Moving? | Why |
|---|---|---|---|
| `objects` (slots) | uniform, fixed-size | **non-moving** | Uniform ⇒ a freed slot fits any object exactly ⇒ zero fragmentation already; free-id stack bounds it at peak-live. Nothing to compact. Stable `ObjectId` keeps lock-free publish/read and **every id-keyed cache valid for free**. |
| `values` / `attrs` / `attr_positions` (ranges) | variable-length, **single-owner** | **copying / compacting** | Where all fragmentation (and the bulk of reclaimable bytes) lives. Single-owner (`heap.zig` "every construction site reserves fresh + copies") ⇒ relocating a range updates exactly **one** back-pointer, reached deterministically during the trace. |

This is consistent with the existing `gc.md` doctrine ("ObjectIds stay put; a
moving collector would have to rewrite every ObjectId in every parked fiber —
infeasible"). We keep ObjectIds put. Only ranges move.

### Why non-moving slots costs nothing

- **No fragmentation:** uniform slots, free-stack reuse, exact fit always.
- **No post-peak tail to return:** live-set *plateaus* (`project_gc_effort`), so
  a compacted slot array wouldn't shrink below peak anyway.
- **Not memory-bound:** working set fits L3 (`project_not_memory_bound`), so the
  locality gain from compacting slots ≈ 0.
- **Caches stay valid:** id-keyed caches (thunk-result memo, drv-attr caches)
  never go stale because the id never moves — the range relocating underneath is
  invisible to a cache that holds a `Value`/id, not a raw range. Moving slots is
  the *only* thing that would force enumerating/rewriting those caches. Keeping
  slots put turns the un-rooted caches from a corruption risk into a non-issue.

## Design

### Young: per-worker bump arena, copying minor GC

- Allocate by bumping a per-worker young **range arena** (values/attrs/attr_pos)
  — same shape as today's `LocalChunk` TLAB, no free list, no sync.
- Object slots allocated after the last minor are **young** (tracked by the young
  bitmap carried over from `gc-concurrent`). Reused ids from the free stack are
  young again (bitmap handles arbitrary ids; young is not a contiguous range).
- **Minor GC (STW):** mark live young from roots + remembered set → **evacuate
  survivor ranges into the old arena** (bump-append; update the single owner's
  range field) + **promote survivor slots** (flip young→old bit, id unchanged) →
  **reset each young arena bump pointer to 0**. The dead are never touched.
  Cost: mark O(live young), copy O(survivor bytes), reset O(1). Pause: low-ms.

### Old: bump arena, rare STW mark-compact

- Promotions bump-append to the old arena. In a fixpoint eval the survivors are
  the long-lived shared structure (module attrsets, the shared thunk graph —
  `project_tracing_jit`), so old-gen death is rare: between majors the old arena
  only grows (dead old ranges are floating garbage, **not holes** — no
  fragmentation to fit into).
- **Major GC (STW, rare):** full parallel mark (reuse the existing parallel-STW
  marker) + **mark-compact** the old range arenas (slide/evacuate survivors,
  update single owners), reclaim dead slot ids to the free stack. For a one-shot
  eval this may never trigger; it is the safety valve, not the common path.

### Write barrier: one site

In a lazy functional heap almost nothing mutates a published object — merges
allocate fresh, ranges are write-once. The **only** significant old→young pointer
creator is **thunk resolution** (writing a result into an existing thunk slot).
So the generational barrier is a **card-mark at the thunk-resolve site alone**,
not a blanket per-store barrier. Minor GC scans dirty cards over the slot array
for old→young roots. (If thunk and result are usually co-young — deforestation
implies created-and-forced within one minor cycle — most cards stay clean.)
This is what kills the `gc-concurrent` branch's mutator tax.

## The one sharp edge (ranges)

A native builtin can hold a raw `[]Value` slice into the range store across a
safepoint; relocating that range mid-builtin would dangle the slice — the same
class the `gc_debug` poison detector already guards for *freeing*
(`project_gc_depth_gt0_pervasive`). Bounded by single-owner + the existing
safepoint discipline (builtins either complete without a safepoint, re-fetch
after one, or register a temp root). Handle explicitly in the copy path; the
poison detector extends naturally to relocation.

## Non-goals

- No concurrent mark, no SATB, no allocate-black, no write barrier beyond the
  single thunk-resolve card mark.
- No moving of object slots (stable ids are load-bearing and there is nothing to
  gain — see above).
- No `RangeFreeList` — deleted. The only "free list" that survives is the trivial
  uniform slot-id stack.

## Build order (clean landing; intermediates need not be byte-identical)

1. **Young arenas + young bitmap.** Per-worker young range arenas (bump, no
   reuse). Carry over the young-slot bitmap + promote bit from `gc-concurrent`.
2. **Copying minor collector.** Mark young → evacuate survivor ranges to old →
   promote slots → reset arenas. Poison/relocation handling on the copy path.
3. **Thunk-resolve card barrier + card scan.** Replace any blanket remembered-set
   barrier with a card mark at the resolve site; minor scans dirty cards.
4. **Delete `RangeFreeList`; old = bump + rare STW mark-compact major** (reuse the
   existing parallel marker for the mark half).

Target: minor pauses low-ms, RSS bounded by contiguous young reset (real
page-return, fixing scattered death), the exact-fit free-list mess gone.

See `project_gc_parallel_mark_done_freelist_blocker`,
`project_gc_generational_minor_blocked`, `project_gc_concurrent_major`,
`project_gc_rss_levers`, `project_deforestation_ceiling`, `gc.md`,
`gc-parallel-mark-plan.md`.
