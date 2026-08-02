# Workers & the eval driver

*N worker threads draining a shared [scheduler](scheduler.md), plus the
top-level fiber that drives root evaluation — where "parallel mode" actually
runs.*

## Worker model

`--workers N` uses **N total worker threads**: **N−1 spawned helpers** plus
**worker 0 on the calling thread**. They share the same queue and fiber
machinery. Worker 0 additionally launches and returns the top-level demand
fiber, and a few policies recognize that role; for example, it is exempt from
the helper spinner cap. The scheduler spawns only workers `1..N−1`.

Each worker `i` owns (see [scheduler](scheduler.md) for the queue internals):

- its lane of the scheduler queues — `ready_queues[i]`, `urgent_queues[i]`, `novel_queues[i]`, `spec_queues[i]`, and `wake_words[i]`
- a **fiber free-list** of recyclable [fiber](fibers.md) slots.

### The fiber free-list

Creating a fiber costs a 16 MiB virtual `mmap` plus a VM; [`reset`](fibers.md)ting one is a single trampoline-slot store — so workers pool them:

- **Prewarm** `prewarm_fiber_count = 4` fibers per worker at `Worker.init`; **grow on demand** when more blocking work is in flight than the pool holds. There is no fixed pool size.
- `acquireFreeFiber` pops the free-list LIFO or allocates a fresh slot; a
  finished fiber is **`reset` in place** (stack pointer rewound, new entry/arg
  installed) rather than freed and re-allocated.
- **Ownership returns home.** A fiber stolen and run by another worker is, once `.finished`, pushed back onto its **allocator-worker's** free-list — not the thief's — and that owner is nudged in case it is parked waiting on this very fiber. This keeps allocation and teardown ownership unambiguous. The per-slot `run_mu` SpinMutex and `in_runfiber` atomic coordinate the hand-back safely (below).
- **Overflow stacks are trimmed.** When a worker is about to park it calls `sweepFreeStacks`: free-list fibers deeper than the prewarm count are spike overflow (a burst of blocking work grew the pool) and give their dirty 16 MiB mappings back to the OS via [`releaseStackPages`](fibers.md), keeping a 64 KiB warm top. A `stack_released` flag (cleared on reuse) makes each park-cycle release a fiber at most once. This runs only at park time — never on the task-completion path, where `madvise` volume would dominate.

Each fiber also owns a **scratch arena** backing its VM's run-path allocations (builtin temp buffers, drv hashing, equality scratch). Arena semantics are load-bearing: run paths free best-effort and error/suspend paths abandon allocations wholesale. `recycleScratch` resets the arena (retaining one 64 KiB chunk) each time the fiber returns to the free-list, so a never-reset arena's dead interleaved pages don't accumulate.

### The drain loop

Every worker (helpers via `run`, main-while-draining via `runTopLevel`) runs the same `drainStep`, in strict priority order:

```
while not shutdown:
    gcSafepoint()                 # park here if a GC stop is requested
    if drainStep():               # did one unit of work?
        continue
    parkAndAccount()              # spin-then-futex WAIT

drainStep():                      # returns true if it did work
    pick a ready fiber   (own queue, else steal)   → resume it
    else pick a task     (own queues, else steal)  → wrap in a fiber, resume
    else return false             # caller parks
```

Priority within `drainStep` mirrors the scheduler's discipline: **ready fibers → demand/speculation tasks**, and within the task pick, own queues before stealing and urgent before novel before spec. A dequeued task runs by resetting a free-list fiber to `slotEntry` (which reads the task off the slot and forces it); a dequeued ready fiber is resumed directly.

`runFiber` takes the slot's `run_mu` around the resume (serializing a stealer that pops the same ready node against the current owner) and holds `in_runfiber` at 1 across the resume, clearing it to 0 after, so teardown can tell when the fiber is truly idle. It also refreshes the heap's per-thread speculation-context flag from the fiber's VM state on every resume, buckets the elapsed wall into `busy_ns`, and recycles or accounts the fiber based on whether it finished or yielded.

**`gcSafepoint`** is a per-loop-iteration poll: if a [GC](../gc.md) stop is requested the worker parks at the safepoint until released. This is how the collector reaches a stop-the-world barrier without preempting mid-op.

## The Engine

The **`Engine`** (defined in `evaluator.zig`) holds the state shared across all workers and fibers:

- **chunk registry** (compiled [bytecode](../compiler/pipeline.md)), **[intern](../runtime/interning.md) table**, **[heap](../runtime/heap.md)**, **scheduler**, **file/[import](imports.md) caches**, [derivation](../derivation/model.md) caches.
- Cross-worker sharing goes through the heap and interned tables, which *are* concurrency-safe; the hot per-fiber allocation path takes no lock because it lands in the fiber's private scratch arena.

`scheduler.start(helperLoop, evaluator)` spawns the `N−1` helper threads (thread ids `1..N−1`); a `started` compare-and-swap makes a second call a no-op. Per-eval mutable state — diagnostics, the trace arena, retained AST arenas — is mutex-protected because concurrent helper [imports](imports.md) touch it.

## Top-level evaluation

Root evaluation does **not** run on the bare main thread. Instead `runTopLevel`:

1. Main resets `suppress_background` to false (each top-level entry begins able to start background work), acquires a free fiber, marks it the **demand** fiber, and resumes it to evaluate the root expression.
2. When that fiber forces a busy [thunk](../runtime/thunks.md) — one another worker already claimed — it **parks on the [`Future`](../runtime/thunks.md)** (yields), exactly like any other blocked fiber.
3. **While the top-level fiber is parked, main runs `drainStep`** — draining
   its own ready fibers and stealing tasks. If no runnable work exists, main can
   park like the other workers; it is a worker, not a supervisor waiting only
   for the root result.
4. Once the demanded result is ready (the top-level fiber is back on the free-list), main sets `suppress_background` so no *new* speculative/fan-out work starts; it then keeps draining until **every fiber on this worker is back on a free-list** — i.e. all in-flight suspended fibers have quiesced. In-flight fibers still finish (a suspended fiber only waits on an already-claimed thunk, never on a queued task), so only un-started backlog is skipped.

This is why main is "just worker 0": the root computation is a fiber like any other, and the thread that launched the eval spends its time as a peer worker.

## Teardown quiescence

Tearing down workers while a stolen fiber is still running (on another thread, or mid-resume) would free a stack out from under live execution — a wake-after-free. Two mechanisms prevent it:

- **`in_runfiber`** (per fiber slot, atomic): set while a fiber is actually being resumed. `Worker.deinit` **spins until `in_runfiber` is 0** for each slot, so a fiber that a thief is still inside is never reclaimed.
- **`awaitHelpersQuiescent`**: a barrier each helper crosses **after** its drain loop exits and **before** it destroys its fibers, so all forcing has stopped before any fiber is freed. Otherwise a helper could free a still-enrolled speculative fiber while another helper, finishing its last quantum, resolves that fiber's thunk and wakes the freed memory. Once no worker can submit more fiber-scoped blocking work, teardown must also drain `external_jobs`: a blocking-pool or daemon callback keeps stack-local work cells and a `Future` pointer until it returns, including in single-worker mode.

Together: no fiber is reclaimed while owned, and no worker is torn down while another might wake it. On `deinit` each worker also reports its fiber/VM-stack high-water and its `idle_ns`/`busy_ns` to the scheduler for `--stats`.

## Race invariants (summary)

The parallel path rests on a small set of invariants proven load-bearing by real corruption bugs; see [invariants](../invariants.md) and [thunks](../runtime/thunks.md) for the full analysis.

- **Cell-thunk binding:** binding cells are born `.evaluating` (claimed) so a helper can't resolve a binding to a placeholder before the real value is published.
- **Fiber resume:** `ReadyNode.queued` CAS + per-slot `run_mu` — a [fiber](fibers.md) is enqueued once and resumed by one thread at a time.
- **Waiter wake:** a waiter re-checks thunk state under the [`Future`](../runtime/thunks.md) claim/wait protocol before parking.
- **Fiber ownership returns home** to the allocator-worker's free-list.
- **External callbacks return before teardown:** publishing their future can
  resume and finish the parked fiber before the callback itself returns, so
  callback quiescence—not publication alone—guards stack reclamation.
- **Speculative cascades are bounded:** `speculation.active` blocks recursive creation-time speculation and sibling sweeps; queue caps and task budgets bound recursive fan-out and map-style submissions. See [speculation](speculation.md).

For *why* all this parallelism buys a bounded speedup — the serial critical-path floor where helpers sit mostly idle — see [perf/model](../perf/model.md).

---

Code: `src/expr/eval/workers/worker.zig`, `src/expr/eval/workers/context.zig`, `src/expr/eval/workers/scheduler.zig`
