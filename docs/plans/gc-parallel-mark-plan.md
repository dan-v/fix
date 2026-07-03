# GC parallel-STW mark — Phase 2a (of "off-clock mark")

Status: DESIGN (2026-07-03). First stage of moving the ~0.2s/collection mark off
the wall clock. Sibling of [gc-plan.md](gc-plan.md); the concurrent-SATB upgrade
(write barrier + allocate-black + termination while mutators run) is **Phase 2b**,
a separate later spec. This stage keeps stop-the-world but makes the *mark*
parallel across idle workers, so the pause shrinks ~mark/parallel-factor and
collection can finally run at `--workers>1`.

## Goal

At a collection, instead of the winner marking alone while peers **spin**, the
parked peers **help mark**. Enable collection at w>1. Pause drops toward
mark/~3.7× (Phase 0: parallel mark scales ~3.7× at ~8 threads, bandwidth-bound,
degrades past that). Correctness bar unchanged: byte-identical `.drv`.

## Non-goals (explicitly Phase 2b or later)

- **No write barrier, allocate-black, concurrent mark, or mark-during-mutation.**
  This stage is still stop-the-world; only the mark is parallelized.
- **No parallel root-scan or parallel sweep.** Root-scan is small vs. the mark;
  sweep is ~51 ms. Keep both serial (collector-only) until measured to matter.
- **No change to the safepoint/snapshot mechanism.** We reuse the existing
  precise root set (kept cheap — rooting is ~0.6%, see
  `project_gc_tax_rooting_measured_dead`) scanned at the existing forceThunk
  safepoint. No depth-0 requirement.

## Why mark is NOT an eval Task

Mark is graph work, but it does not belong in the scheduler's `Task`/fiber
system: (1) it runs during STW while eval tasks are *paused* — those queued
`force_thunk`/`force_list_range` tasks are GC roots we must not execute
mid-collection; (2) mark never blocks, so it needs no fiber (no stack, no yield,
no context switch). So we reuse the *deque data structure*, not the Task enum or
the fiber worker loop. Mark is a stackless drain loop over its own deque.

## Design

### Unit 1 — generic `Deque(T)` (extract, don't copy)

`scheduler.zig` already has a correct lock-free **Chase-Lev** work-stealing deque
(`TaskQueue`, fixed power-of-two capacity, owner `push`/`pop` LIFO, multi-consumer
FIFO `steal`, with load-bearing memory orderings incl. the `mfence` in `pop`).
Extract it verbatim into `src/parallel/deque.zig` as `Deque(comptime T: type)`,
**preserving every atomic ordering and the fence** — this is a mechanical
genericization, not a rewrite.

- Migrate `scheduler.zig` to `Deque(Task)` (keep the `TaskQueue`-specific
  `gcMark` as a free function or a small wrapper over `Deque(Task)`; the deque
  itself stays payload-agnostic). Validate: existing scheduler push/pop/steal
  unit tests pass; full eval byte-identical w=1/w=32 (pure refactor).
- The marker (Unit 2) instantiates `Deque(ObjectId)`.

Interface: `Deque(T)` with `init(alloc, cap)`, `deinit`, `push(T) bool`,
`pop() ?T`, `steal() ?T`. Payload-agnostic — no `Task`/`ObjectId` knowledge.

### Unit 2 — parallel marker (`gc.zig` Tracer)

Make the precise mark parallel-safe:
- **Atomic mark bitmap.** `testAndSet` becomes an atomic OR on the bitmap word +
  check-old-bit, so concurrent markers reaching the same object race safely and
  exactly one enqueues it. (Today it's a plain read-modify-write.)
- **Per-marker `Deque(ObjectId)`.** Replace the single `stack` with N deques
  (one per active marker). A marker drains its own (LIFO `pop`), and when empty
  `steal`s from a random peer. Scanning an object = the existing trace-map edge
  walk (unchanged); each newly-marked child is `push`ed to the marker's own deque.
- **Stats.** `LiveStats` accumulation must be per-marker then summed at the end
  (avoid a shared atomic per object — it would cache-line-bounce). Each marker
  keeps a local `LiveStats`; the collector sums them after termination.

### Unit 3 — STW help-mark + termination (`scheduler.zig` / `eval.zig`)

- **Cap active markers at `min(worker_count, 8)`.** Beyond ~8 the walk is
  bandwidth-bound and degrades. The extra workers still park.
- **Peers help-mark instead of spinning.** Today `gcSafepointPark` spins until
  the collection ends. Instead, the ≤8 designated markers run the mark loop
  (drain own deque → steal → repeat) until termination; the rest park as now.
- **Seed.** The collector scans the roots (serial) into the markers' deques
  (round-robin or all into marker 0's, letting stealing spread them), then
  releases the markers.
- **Termination = mirror the scheduler's idle-count mechanism** (proven for eval
  work-stealing): an atomic `active_markers` count decremented when a marker goes
  idle (own deque empty AND all steals fail) and re-incremented on a successful
  steal, with the same last-item-steal race handling the scheduler already uses.
  Mark is done when `active_markers == 0` and all deques are empty. **Do NOT** use
  a per-mark atomic counter (millions of increments across 8 threads → cache-line
  ping-pong that would erase the parallel win).
- After termination the collector alone runs the (serial) sweep, exactly as today.

### Unit 4 — enable at w>1 + validation

- Flip the `worker_count == 1`-only gate in `ensureMainWorker` so collection runs
  at w>1 with the parallel marker. The STW barrier, all-worker root marking,
  per-worker thread-local cache marking, and suspended-fiber coverage are already
  built (see gc-plan.md); this wires the parallel marker into them.

## Correctness bar

- **Byte-identical `.drv`** at w=8 and w=32, ≥30 runs each, 0 failures, with
  `FIX_GC_WN=1` + aggressive `FIX_GC_STEP_MB` (many collections). This is the
  primary gate — a parallel-mark data race shows as a swept-live-object
  corruption.
- **Deque extraction** validated separately first: scheduler unit tests + full
  eval byte-identical (it must be a no-op refactor before the marker is built on
  it).
- ReleaseSafe `-Dgc` detector where reliable (note: the detector is unreliable at
  w>1 per prior work — lean on ReleaseFast byte-identical + the swept-range
  poison at w=1, plus w>1 byte-identical stress).

## Success metric

Pause per collection drops from ~0.2 s toward ~0.05–0.06 s (mark/~3.7×), measured
via the GC report's mark-time total / collections. w=32 with a loose bound (a few
collections) stays within a small wall budget while peak RSS drops ~2×. If the
parallel mark does NOT scale (e.g. the atomic bitmap or steal contention
dominates), that's the signal to stop and reconsider before Phase 2b.

## Risks

- **Parallel-mark memory ordering** (atomic bitmap + deque orderings) — the deque
  is proven; the atomic `testAndSet` is the new surface. A missed ordering =
  double-scan (benign) or missed-mark (UAF). Byte-identical stress is the gate.
- **Termination race** — the classic work-stealing termination bug (declaring
  done while a steal is in flight). Mitigate by mirroring the scheduler's existing
  mechanism exactly rather than inventing one.
- **STW time-to-safepoint** — a worker deep in a long builtin delays the pause
  start. Pre-existing (STW already requires this); not made worse here.
- **w>1 detector unreliability** — already known; compensate with ReleaseFast
  byte-identical stress at w=8/w=32.

## Decomposition (build order)

1. `Deque(T)` extraction + scheduler migration (pure refactor, byte-identical).
2. Parallel-safe Tracer (atomic bitmap + per-marker deques + per-marker stats),
   unit-tested in isolation (multi-thread mark of a known graph → exact live set).
3. STW help-mark + idle-count termination, cap 8.
4. Enable at w>1 + the byte-identical w=8/w=32 gauntlet + measure the pause.
