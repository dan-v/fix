# Scheduler

*Per-worker work-stealing queues with a demand/speculation priority split — the layer that decides who runs which [fiber](fibers.md) next, and when a thread sleeps.*

## Mental model

The scheduler owns, **per worker `i`**, a set of queues plus a wake word. Every worker owns the same set; the only structural difference is that worker 0 runs on the calling OS thread while workers `1..N-1` are helper threads spawned in `start()`.

| Structure | Contents | Discipline |
|---|---|---|
| `ready_queues[i]` | woken/blocked [fibers](fibers.md) ready to resume | drained **first**; stealable; deduped |
| `urgent_queues[i]` | demand tasks (fan-out of a strict consumer; the critical path) | drained next; not spec-rationed (fixed 4096-slot deque; demand handles rejected work) |
| `novel_queues[i]` | first-ever [speculative](speculation.md) force of each code region | drained before the bulk backlog; cap-exempt |
| `spec_queues[i]` | bulk [speculative](speculation.md) tasks (bets on future demand) | drained last of the eager lanes; **capped** |
| `wake_words[i]` | a futex word | parking / wake signalling |

Tasks and ready fibers are **pushed onto the submitter's own worker queues** — there is no MPMC contention on the submit hot path. Idle workers *steal* from other workers' queues. This is the standard work-stealing shape (cheap local push/pop, occasional contended steal) specialized with a priority split so that **demand always beats speculation**.

What fills these queues is the [speculation / fan-out policy](speculation.md); this doc is the transport and priority mechanism. The [worker drain loop](workers.md) is the consumer.

A `Task` is a tagged union — `force_thunk`, `force_list_range`, `force_attrs_sweep`, `force_attrs_range`, `import_prefetch`, `readdir_prefetch` — but the queue transport treats them uniformly; see [speculation](speculation.md) for what each does.

## Queue implementations

The lanes use two different structures, chosen per lane's access pattern.

### Chase-Lev deque — urgent

The `urgent` queue is a lock-free **Chase-Lev work-stealing deque** (the generic engine is `containers.Deque`):

- **Owner** pushes/pops at the **bottom** (LIFO). Push is a release store to the slot + a bottom bump; pop is an acquire-side bottom decrement. No CAS on the common path.
- **Stealers** take from the **top** (FIFO) via a seq_cst `top` CAS — multi-consumer.
- **Ordering:** bottom writes release / stealer reads acquire; the `top` CAS is seq_cst so the owner's last-element pop and a concurrent steal agree on who got it. A seq_cst fence in `pop` after the bottom write stops the owner "seeing past" a stealer.
- **Last-element race:** when one element remains, the owner's pop races the stealer via the same `top` CAS; the loser restores `bottom`.

LIFO-for-owner keeps freshly-spawned work hot in cache and deep-first (good for dependency chains); FIFO-for-stealer hands thieves the *oldest*, most-likely-independent work. A full push returns `false`, leaving the unqueued remainder to the caller's demand path.

### Mutexed ring — spec & novel

The `spec` and `novel` lanes are **`SpinMutex`-guarded bounded rings** (`SpecQueue`), not Chase-Lev. Bulk-spec owners pop newest, stealers take oldest, and a full push rejects. The novel lane instead overwrites its oldest entry and is consumed newest-first: the first speculative instance of a chunk (a potential subsystem/chain root) must not lose a pop/steal race against repeat-instance work, so it gets a cap-exempt, always-fresh-first lane of its own.

## Ready queues

Woken fibers land on `ready_queues[i]` — a **`SpinMutex`-guarded intrusive FIFO of `*ReadyNode`** (a small MPMC list, since any worker can wake a fiber onto any queue). Dedup is the [fiber's](fibers.md) `ReadyNode.queued` 0→1 CAS: `enqueueReady` pushes only on a winning CAS, `pop` resets it. **A fiber is on the ready queues at most once**, no matter how many wakers fire. `pop` reads the head lock-free before taking the mutex, so the common case — every idle worker's steal scan probing a peer's empty ready queue — costs a relaxed load, not a line-owning CAS.

## The two-tier cap

Urgent admission does not consult the speculative cap; speculation is *rationed* so a burst of bad bets cannot bury the real work or exhaust memory.

- **Urgent: not spec-rationed.** Demand fan-out never consults the speculative backlog cap. The lane is still a fixed 4096-slot Chase-Lev deque (`urgent_queue_capacity = 4096` per worker); a full push returns `false`, and the caller's authoritative demand walk handles the unqueued remainder.
- **Spec: capped** at `spec_backlog_per_helper × (N−1)` = **128 × (N−1)** = **3968 in-flight at N=32**, gated by a shared `pending_tasks` counter. `FIX_SPEC_BACKLOG` sweeps the per-helper figure — it is the primary peak-RSS↔wall knob.
- **Spec drain is also capped by crew size** (`spec_helper_cap`, default **16**; `FIX_SPEC_HELPERS` overrides): workers above the cap never pop or steal bulk-spec tasks. Capped workers use a lane-aware pre-park probe (`takableWork`) so they do not spin on work they cannot take. The cap is inert when every worker is eligible.
- **Over-cap spec submit returns `false`** → that pre-force is skipped. The thunk remains lazy and ordinary demand computes it if needed.
- **Novel: cap-exempt.** `submitNovel` does not test the backlog cap — its total volume is bounded structurally at one task per chunk. (A novel task still increments `pending_tasks` for pop/wake bookkeeping; it just is not *gated* by it.)

This asymmetry encodes the cost model: at high worker counts cores are mostly idle, but speculative work still adds scheduling and allocation pressure, so it is rationed and cooperatively bails at checkpoints.

## Submit & wake path

```
submit / submitNovel / submitUrgent(task):
    push task onto own lane's queue[submitter_id]   # own queue, no contention
    (spec only) if over cap → return false   # thunk remains lazy
    burst-wake / periodic re-wake a parked worker

enqueueReady(fiber):
    if ready_node.queued CAS 0→1:                    # dedup
        push onto ready_queues[target_id]
        wake target
```

**Burst wake + periodic re-wake.** Fan-out arrives in waves (one strict consumer spawns many children at once). Waking one worker per submit would trickle; waking *all* would thundering-herd. So the ramp at the *start* of a burst wakes **up to `burst_wake_budget` = 4** parked workers, and thereafter — under a standing backlog — **every 64th submit** re-nudges one worker. The periodic re-wake matters: without it a helper whose pre-park spin expired during a lull would stay parked for the rest of the eval no matter how much stealable work piles up. Both decisions read the pre-increment `pending_tasks` value (`prev`): the wake fires only when `prev < wake_budget` (the ramp) or `(prev & 63) == 0` (the re-wake), so a standing backlog issues no `futex_wake` per submit. `wakeWorker` then elides even that syscall when the target's wake word is already `1` (a prior wake is still in flight).

## Parking

A worker with nothing to do calls **`parkWorker(wake_word)`**, but only after a bounded pre-park spin driven by the [worker](workers.md):

```
pre-park spin (bounded):
    poll pending task summaries                                # cheap shared loads
    if any → return to the drain loop

parkWorker(i):
    if wake word already set → consume it, return   # lost-wakeup guard
    if shutdown → return
    futex WAIT on wake_words[i]                      # Linux; else spin/yield
```

**Spin-before-park** is the architectural lever (see [perf notes](../perf/model.md)): at these fan-out rates work usually materializes within the spin window, so most parks avoid the syscall pair entirely. The spin polls **shared counters** (a single relaxed load each), never per-queue CAS probes, whose contention would destroy cache coherence across dozens of cores.

**Spinner cap.** The number of helpers concurrently in the spin-rescan loop is capped at `max(7, N/4)` (`maxSpinners`). Wider pools keep only a fraction scanning while the rest park until a submit-side wake, bounding O(N)-per-rescan idle work. Worker 0 is exempt because it carries demand.

**Lost-wakeup guard.** `parkWorker` checks the wake word (a submit/wake sets it to 1) immediately before the futex `WAIT`, using the futex "expected value" so a wake landing between "decided to park" and "actually parked" returns from the syscall at once. `wakeWorker` swaps the word to 1 and skips the syscall if it was already 1 (a prior wake is still in flight).

## Scheduling discipline

- **Demand lanes win admission order.** A worker drains ready fibers and urgent tasks before touching the novel or spec lanes. Both `pop` (own queues) and the steal scan walk lanes in priority order: urgent → novel → spec.
- **No scheduler preemption.** Once a spec task starts, only its cooperative [bail checkpoints](speculation.md) can stop it early.
- **Priority inheritance is off by default.** Normally a demand fiber blocking on a spec-owned thunk parks on the [`Future`](../runtime/thunks.md). `FIX_RESCUE=1` enables advisory promotion: the owner stops bailing and routes its sub-forces urgently until the task boundary.

[Imports](imports.md) submit and park through this same machinery (an `ImportEntry` wraps a `Future`; a helper compiling an import is just another claim/wait).

## False-sharing isolation

The scheduler's globally write-hot atomics — `next_victim`, `next_fiber_id`, `pending_tasks`, `spinners`, `ready_pending`, `urgent_pending`, and the two spec/novel non-empty victim masks — each sit alone in a 128-byte destructive-interference block via `containers.Isolated`. A **comptime assertion** at the end of `Scheduler` proves no two of them (and no other, read-mostly or cold, field) share a block: packed together, each `fetchAdd` would invalidate its neighbors' lines on every submit/pop/steal across all workers. The per-worker `ReadyQueue`, `SpecQueue`, `WakeWord`, and activity-`Counters` structs are each `align(cache_line)` for the same reason, so adjacent workers never share a line even though the packed structs are smaller than one.

The per-worker activity counters are **single-writer** (a worker touches only its own slot), so updates are plain non-atomic adds. They are summed after quiescence.

The steal scan is further short-circuited by **per-lane stealable-work summaries** (`ready_pending` / `urgent_pending` counters and `spec_mask` / `novel_mask` bitmasks): `pending_tasks` says work *exists* but not in which lane, so without these every idle pass paid an O(N) per-peer probe over all four classes even when a class was provably empty. One read-mostly load per class replaces the walk. The summaries lag their queues (incremented after push, decremented after take), so a stale zero only ever skips one scan pass — never a park decision, which `pending_tasks` still gates.

## Garbage collection

The scheduler hosts the collector's **stop-the-world barrier**: a worker that crosses the collection threshold wins `gcTryBeginCollection`, waits for every peer to park at its own safepoint, then (for `--workers>1`) opens a parallel-mark gate so parked peers drain the mark graph through an installed hook instead of spinning idle. The evaluator-owned `GcCoordinator` installs that hook together with the heap's collection callback as one lifecycle operation. It is a full two-phase barrier — the collector waits for all peers to *clear* their parked flag before returning — so a slow peer can never carry stale state into the next collection. The scheduler also exposes `gcMarkPendingTasks`, marking every heap object referenced by a queued task.

---

Code: `src/expr/eval/workers/scheduler.zig`, `src/expr/eval/workers/worker.zig`
