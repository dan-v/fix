# Workers & the eval driver

*N symmetric worker threads draining a shared [scheduler](scheduler.md), plus the top-level fiber that drives root evaluation — where "parallel mode" actually runs.*

## Worker model

`--workers N` spawns **N total** threads: **N−1 helpers** plus **main, running on the calling thread**. Workers are **symmetric** — post-redesign there is *no behavioral main/helper split*; main is worker 0 and steals, parks, and drains exactly like a helper. (Historically main had privileged roles; that is gone.)

Each worker `i` owns (see [scheduler](scheduler.md) for the queue internals):

- `urgent_queues[i]`, `spec_queues[i]`, `ready_queues[i]`, `wake_words[i]`
- a **fiber free-list** of recyclable [fiber](fibers.md) slots.

### The fiber free-list

Fibers are expensive to create (8 MiB mmap) and cheap to [`reset`](fibers.md) — so workers pool them:

- **Prewarm** `prewarm_fiber_count = 4` fibers per worker at startup; **grow on demand** when more work is in flight than the pool holds.
- A finished fiber is **`reset` in place** (stack pointer rewound, new entry/arg installed) rather than freed and re-allocated.
- **Ownership returns home.** A fiber stolen and run by another worker is, once `.finished`, returned to its **allocator-worker's** free-list — not the thief's. This keeps free-lists balanced and bounds each worker's fiber count. The `run_mu` SpinMutex and `in_runfiber` atomic on each slot (below) coordinate the hand-back safely.

### The drain loop

Every worker (helpers and main-while-parked) runs the same loop:

```
while not shutdown:
    gcSafepoint()                 # park here if a GC stop is requested
    if drainStep():               # did one unit of work?
        continue
    parkWorker(wake_word)         # nothing to do → spin then futex WAIT

drainStep():                      # returns true if it did work
    pop own ready fiber          → resume it        # highest priority
    else pop own urgent task     → wrap in a fiber, resume
    else steal a task (ready/urgent/spec, others)   → resume
    else return false             # caller parks
```

Priority within `drainStep` mirrors the scheduler's discipline: **own ready fibers → own demand tasks → steal**, and demand (urgent) always before speculation. A dequeued task is run by resuming a free-list fiber whose entry is the task; a dequeued ready fiber is resumed directly. `run_fiber` takes the slot's `run_mu` around the resume (serializing a stealer that pops the same ready node against the current owner) and flips `in_runfiber` 1→0 across the run so teardown can tell when the fiber is truly idle.

**`gcSafepoint`** is a per-loop-iteration poll: if a [GC](../gc.md) stop is requested the worker parks at the safepoint until released. This is how the (opt-in) collector reaches a stop-the-world barrier without preempting mid-op.

## The Evaluator

The **`Evaluator`** (the `eval.zig` facade) holds the state shared across all workers and fibers:

- **chunk registry** (compiled [bytecode](../compiler/pipeline.md)), **[intern](../runtime/interning.md) table**, **[heap](../runtime/heap.md)**, **scheduler**, **file/[import](imports.md) caches**, [derivation](../derivation/model.md) caches.
- **per-worker arenas** — each worker allocates from its own non-thread-safe arena, so the hot allocation path takes no lock. Cross-worker sharing goes through the heap / interned tables, which *are* concurrency-safe.

`scheduler.start(workerFn)` is idempotent (safe to call once per eval). Per-eval mutable state — diagnostics, the trace arena — is mutex-protected because concurrent helper [imports](imports.md) touch it.

## Top-level evaluation

Root evaluation does **not** run on the bare main thread. Instead:

1. Main creates a **top-level fiber** (a custom entry) that evaluates the root expression.
2. When that fiber forces a busy [thunk](../runtime/thunks.md) — one another worker already claimed — it **parks on the [`Future`](../runtime/thunks.md)** (yields), exactly like any other blocked fiber.
3. **While the top-level fiber is parked, main runs the drain loop** — draining its own ready fibers and stealing tasks. So main **participates in stealing and never idle-waits**: the calling thread is a full worker, not a supervisor blocked on a condition variable.
4. When the top-level entry retires, main keeps draining until **every fiber is back on a free-list** — i.e. all stolen/in-flight work has quiesced.

This is why main is "just worker 0": the root computation is a fiber like any other, and the thread that launched the eval spends its time as a peer worker.

## Teardown quiescence

Tearing down workers while a stolen fiber is still running (on another thread, or mid-resume) would free a stack out from under live execution — a wake-after-free. Two mechanisms prevent it:

- **`in_runfiber`** (per fiber slot, atomic): set while a fiber is actually being resumed. Teardown of a slot **spins until `in_runfiber` is 0**, so a fiber that a thief is still inside is never reclaimed.
- **`awaitHelpersQuiescent`**: a barrier main crosses **before** it tears down the worker threads, ensuring no helper is still spinning in a drain loop that could wake into freed memory.

Together: no fiber is reclaimed while owned, and no worker is torn down while another might wake it.

## Race invariants (summary)

The parallel path rests on a small set of invariants proven load-bearing by real corruption bugs; see [invariants](../invariants.md) and [thunks](../runtime/thunks.md) for the full history.

- **Cell-thunk binding:** cells are born `.evaluating` (claimed) so a helper can't resolve a binding to a placeholder `null` before the real value is published.
- **Fiber resume:** `ReadyNode.queued` CAS + per-slot `run_mu` — a [fiber](fibers.md) is enqueued once and resumed by one thread at a time.
- **Waiter wake:** a waiter re-checks thunk state under `waiters_mu` before parking (the [Future](../runtime/thunks.md) claim/wait protocol).
- **Fiber ownership returns home** to the allocator-worker's free-list.
- **Speculation is strictly one layer** (`in_speculation`): a spec fiber does not itself spawn further speculation — the [speculation](speculation.md) brake that bounds fan-out.

For *why* all this parallelism buys a bounded speedup — the serial critical-path floor where helpers sit ~87% idle — see [perf/model](../perf/model.md).

---

Code: `src/parallel/`, `src/eval/`
