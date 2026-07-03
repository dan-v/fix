# Scheduler

*Per-worker work-stealing deques with a two-tier demand/speculation priority — the layer that decides who runs which [fiber](fibers.md) next, and when a thread sleeps.*

## Mental model

The scheduler owns, **per worker `i`**, four things:

| Structure | Contents | Discipline |
|---|---|---|
| `urgent_queues[i]` | demand tasks (fan-out of a strict consumer; the critical path) | drained **first**, **uncapped** |
| `spec_queues[i]` | [speculative](speculation.md) tasks (bets on future demand) | drained only when urgent + ready empty; **capped** |
| `ready_queues[i]` | woken/blocked [fibers](fibers.md) ready to resume | stealable; deduped |
| `wake_words[i]` | a futex word | parking / wake signalling |

Tasks and ready fibers are **pushed onto the submitter's own worker queues** — there is no MPMC contention on the submit hot path. Idle workers *steal* from other workers' queues. This is the standard work-stealing shape (cheap local push/pop, occasional contended steal) specialized with a priority split so that **demand always beats speculation**.

What fills these queues is the [speculation / fan-out policy](speculation.md); this doc is the transport and priority mechanism only. The [worker drain loop](workers.md) is the consumer.

## Chase-Lev deque

Each `urgent`/`spec` queue is a lock-free **Chase-Lev work-stealing deque**:

- **Owner** pushes/pops at the **bottom** (LIFO). Push is a release store to the slot + a bottom bump; pop is an acquire-side bottom decrement. No CAS on the common path.
- **Stealers** take from the **top** (FIFO) via a seq_cst `top` CAS — multi-consumer.
- **Ordering:** bottom writes release / stealer reads acquire; `top` CAS is seq_cst so the owner's last-element pop and a concurrent steal agree on who got it. A seq_cst fence in `pop` after the bottom write stops the owner "seeing past" a stealer.
- **Last-element race:** when one element remains, the owner's pop races the stealer via the same `top` CAS; the loser restores `bottom`.

LIFO-for-owner keeps freshly-spawned work hot in cache and deep-first (good for dependency chains); FIFO-for-stealer hands thieves the *oldest*, most-likely-independent work.

## Ready queues

Woken fibers land on `ready_queues[i]` — a **`SpinMutex`-guarded intrusive FIFO of `*ReadyNode`** (a small MPMC list, since any worker can wake a fiber onto any queue). Dedup is the [fiber's](fibers.md) `ReadyNode.queued` 0→1 CAS: `enqueueReady` pushes only on a winning CAS, `pop` resets it. **A fiber is on the ready queues at most once**, no matter how many wakers fire.

## The two-tier cap

Demand is unbounded; speculation is *rationed* so a burst of bad bets can't bury the real work or exhaust memory.

- **Urgent: uncapped.** Demand fan-out is on the critical path; refusing it would serialize the very work parallelism exists to spread. (Backing arrays are large — `urgent_queue_capacity = 4096` per worker.)
- **Spec: capped** at `spec_backlog_per_helper × (workers − 1)` = **128 × (N−1)** ≈ **4096 in-flight at N=32**, gated by a shared `pending_tasks` counter.
- **Over-cap spec submit returns `false`** → the caller **falls back to running the work serially, inline**. Speculation is best-effort; the fallback is what makes an over-cap submit harmless rather than lost work.

This asymmetry encodes the cost model: at N=32 cores are mostly idle, so speculative CPU is nearly free — but its real cost is *scheduling* (spec runs to completion once started), so it must be *rationed and preemptible-in-priority*, never allowed to displace demand. See the [parallel redesign plan](../plans/parallel-redesign-plan.md) for the fuller cost-model discussion.

## Submit & wake path

```
submit / submitUrgent(task):
    push task onto queues[submitter_id]          # own queue, no contention
    (spec only) if over cap → return false        # caller runs it inline
    burst-wake up to burst_wake_budget (=4) parked workers

enqueueReady(fiber):
    if ready_node.queued CAS 0→1:                 # dedup
        push onto ready_queues[target_id]
        wake target (or a parked worker)
```

**Burst wake.** Fan-out arrives in waves (one strict consumer spawns many children at once). Waking one worker per submit would trickle; waking *all* would thundering-herd. So a submission that opens work wakes **up to `burst_wake_budget` = 4** parked workers — enough to spread a wave, bounded to avoid stampede. `pending_tasks` also lets a submitter *skip* the `futex_wake` syscall entirely when a helper is already known to be spinning.

## Parking

A worker with nothing to do calls **`parkWorker(wake_word)`**:

```
parkWorker(i):
    spin a bounded number of iterations         # cheap: work often lands fast
    if still no work:
        re-check queues once more               # guard the lost-wakeup window
        futex WAIT on wake_words[i]             # Linux; else sched_yield loop
    # woken by: task submit (within a burst), ready enqueue, or shutdown
```

**Spin-before-park** is the architectural lever (see [perf notes](../perf/model.md)): at these fan-out rates work usually materializes within the spin window, so most parks avoid the syscall pair entirely. The **lost-wakeup re-check** immediately before `WAIT` closes the classic gap — a submit that lands between "decided to park" and "actually parked" would otherwise sleep a worker with work waiting; the re-check catches it.

## Scheduling discipline

- **Demand preempts speculation.** A worker always drains urgent + ready before touching spec. Demand fibers run flat-out.
- **Spec is rationed, not prioritized down mid-run.** Once a spec task starts it runs to completion (no preemption of a running fiber); the cap + inline fallback are the only throttle.
- **Promotion — PLANNED, not landed.** The intended next step: when a *demand* fiber blocks on a thunk being computed by a *spec* fiber, promote that spec fiber to demand priority, **contagiously** (its own spec dependencies promote too). This would make the critical path pull its blockers up out of the spec tier. Today a demand waiter simply parks on the [`Future`](../runtime/thunks.md) and the spec fiber finishes at spec priority. Do not assume promotion when reasoning about latency.

[Imports](imports.md) submit and park through this same machinery (an `ImportEntry` wraps a `Future`; a helper compiling an import is just another task).

---

Code: `src/parallel/`, `src/eval/`
