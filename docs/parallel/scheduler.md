# Scheduler

*Per-worker work-stealing queues with a demand/speculation priority split — the layer that decides who runs which [fiber](fibers.md) next, and when a thread sleeps.*

## Mental model

The scheduler owns, **per worker `i`**, a set of queues plus a wake word. Every worker owns the same set; the only structural difference is that worker 0 runs on the calling OS thread while workers `1..N-1` are helper threads spawned in `start()`.

| Structure | Contents | Discipline |
|---|---|---|
| `ready_queues[i]` | woken/blocked [fibers](fibers.md) ready to resume | drained **first**; stealable; deduped |
| `urgent_queues[i]` | demand tasks (fan-out of a strict consumer; the critical path) | drained next; not spec-rationed (fixed 4096-slot deque, full push → force inline) |
| `novel_queues[i]` | first-ever [speculative](speculation.md) force of each code region | drained before the bulk backlog; cap-exempt |
| `spec_queues[i]` | bulk [speculative](speculation.md) tasks (bets on future demand) | drained last of the eager lanes; **capped** |
| `cont_queues[i]` | work-first split-and-steal continuations (`FIX_WORK_FIRST`) | owner-inline; idle peers steal |
| `wake_words[i]` | a futex word | parking / wake signalling |

Tasks and ready fibers are **pushed onto the submitter's own worker queues** — there is no MPMC contention on the submit hot path. Idle workers *steal* from other workers' queues. This is the standard work-stealing shape (cheap local push/pop, occasional contended steal) specialized with a priority split so that **demand always beats speculation**.

What fills these queues is the [speculation / fan-out policy](speculation.md); this doc is the transport and priority mechanism. The [worker drain loop](workers.md) is the consumer.

A `Task` is a tagged union — `force_thunk`, `force_list_range`, `force_attrs_sweep`, `force_attrs_range`, `import_prefetch`, `readdir_prefetch` — but the queue transport treats them uniformly; see [speculation](speculation.md) for what each does.

## Queue implementations

The lanes use two different structures, chosen per lane's access pattern.

### Chase-Lev deque — urgent & cont

The `urgent` and `cont` queues are lock-free **Chase-Lev work-stealing deques** (the generic engine is `containers.Deque`):

- **Owner** pushes/pops at the **bottom** (LIFO). Push is a release store to the slot + a bottom bump; pop is an acquire-side bottom decrement. No CAS on the common path.
- **Stealers** take from the **top** (FIFO) via a seq_cst `top` CAS — multi-consumer.
- **Ordering:** bottom writes release / stealer reads acquire; the `top` CAS is seq_cst so the owner's last-element pop and a concurrent steal agree on who got it. A seq_cst fence in `pop` after the bottom write stops the owner "seeing past" a stealer.
- **Last-element race:** when one element remains, the owner's pop races the stealer via the same `top` CAS; the loser restores `bottom`.

LIFO-for-owner keeps freshly-spawned work hot in cache and deep-first (good for dependency chains); FIFO-for-stealer hands thieves the *oldest*, most-likely-independent work. A full push returns `false` — for urgent that's the caller's cue to force the work inline; for a cont it just stops splitting.

### Mutexed ring — spec & novel

The `spec` and `novel` lanes are **`SpinMutex`-guarded bounded rings** (`SpecQueue`), not Chase-Lev. Speculation is low-volume (tens of thousands of submissions per NixOS eval, against millions of forces), so a mutex ring is affordable and it buys two behaviors a Chase-Lev deque cannot express:

- **Ring overwrite (`FIX_SPEC_EVICT`).** When the ring is full, drop the **oldest** queued task to admit the fresh one — the newest submission was created nearest the demand head, the oldest is the stalest bet. The novel lane always ring-overwrites.
- **Newest-first stealing (`FIX_SPEC_LIFO`).** Stealers take the newest task, so a just-submitted seed is picked up in microseconds even under a saturated backlog. The novel lane always steals newest-first. The owner always pops its own ring newest-first.

With both `spec`-lane knobs off the ring reproduces the classic semantics: owner pops newest, stealers take oldest, full push rejects. The novel lane exists for the same reason the split does — the first speculative instance of a chunk (a potential subsystem/chain root) must not lose a pop/steal race against hundreds of repeat-instance junk tasks, so it gets a small, cap-exempt, always-fresh-first lane of its own.

## Ready queues

Woken fibers land on `ready_queues[i]` — a **`SpinMutex`-guarded intrusive FIFO of `*ReadyNode`** (a small MPMC list, since any worker can wake a fiber onto any queue). Dedup is the [fiber's](fibers.md) `ReadyNode.queued` 0→1 CAS: `enqueueReady` pushes only on a winning CAS, `pop` resets it. **A fiber is on the ready queues at most once**, no matter how many wakers fire. `pop` reads the head lock-free before taking the mutex, so the common case — every idle worker's steal scan probing a peer's empty ready queue — costs a relaxed load, not a line-owning CAS.

## The two-tier cap

Demand is unbounded; speculation is *rationed* so a burst of bad bets can't bury the real work or exhaust memory.

- **Urgent: not spec-rationed.** Demand fan-out is on the critical path; refusing it would serialize the very work parallelism exists to spread, so it never consults the `pending_tasks` cap. It is not *unbounded*, though: the lane is a fixed 4096-slot Chase-Lev deque (`urgent_queue_capacity = 4096` per worker), and a full push returns `false`, whereupon the submitter forces the work inline — demand is at worst run serially, never dropped.
- **Spec: capped** at `spec_backlog_per_helper × (N−1)` = **128 × (N−1)** = **3968 in-flight at N=32**, gated by a shared `pending_tasks` counter. `FIX_SPEC_BACKLOG` sweeps the per-helper figure — it is the primary peak-RSS↔wall knob.
- **Spec drain is also capped by crew size** (`spec_helper_cap`, default **16**; `FIX_SPEC_HELPERS` overrides): workers with id > 16 never pop or steal bulk-spec tasks. The backlog cap alone stops binding at high worker counts — with 31 unrestricted drainers, w=32 executed 3.1× w=8's spec volume (thunks created +32%, busy 2×), all junk-cascade growth. Capping the *drain* restores w=8-like admission economics; capped workers use a lane-aware pre-park probe (`takableWork`) so they never busy-spin on a backlog they cannot touch. Inert at ≤17 workers by construction (every worker id is within the cap).
- **Over-cap spec submit** either **evicts the oldest queued spec task** (`FIX_SPEC_EVICT`) or **returns `false`** → the caller **falls back to running the work serially, inline**. Speculation is best-effort; the fallback is what makes an over-cap submit harmless rather than lost work.
- **Novel: cap-exempt.** `submitNovel` does not test the backlog cap — its total volume is bounded structurally at one task per chunk. (A novel task still increments `pending_tasks` for pop/wake bookkeeping; it just is not *gated* by it.)

This asymmetry encodes the cost model: at high worker counts cores are mostly idle, so speculative CPU is nearly free — but its real cost is *scheduling* (a spec task runs to completion once started) and *allocation pressure*, so it must be *rationed*, never allowed to displace demand.

## Submit & wake path

```
submit / submitNovel / submitUrgent(task):
    push task onto own lane's queue[submitter_id]   # own queue, no contention
    (spec only) if over cap → evict-oldest or return false   # caller runs it inline
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
    poll pending_tasks / cont_pending / scavengeable-backlog   # cheap shared loads
    if any → return to the drain loop

parkWorker(i):
    if wake word already set → consume it, return   # lost-wakeup guard
    if shutdown → return
    futex WAIT on wake_words[i]                      # Linux; else spin/yield
```

**Spin-before-park** is the architectural lever (see [perf notes](../perf/model.md)): at these fan-out rates work usually materializes within the spin window, so most parks avoid the syscall pair entirely. The spin polls **shared counters** (a single relaxed load each), never per-queue CAS probes, whose contention would destroy cache coherence across dozens of cores.

**Spinner cap.** The number of helpers concurrently in the spin-rescan loop is capped at `max(7, N/4)` (`maxSpinners`): it never binds at `N ≤ 8` (all helpers spin, measured-optimal there), but past that only a fraction keep scanning while the rest park until a submit-side wake re-engages them — bounding the O(N)-per-rescan idle-scan churn that otherwise burns the SMT siblings of busy workers. Worker 0 is exempt; it is the demand thread and its wake latency is critical.

**Lost-wakeup guard.** `parkWorker` checks the wake word (a submit/wake sets it to 1) immediately before the futex `WAIT`, using the futex "expected value" so a wake landing between "decided to park" and "actually parked" returns from the syscall at once. `wakeWorker` swaps the word to 1 and skips the syscall if it was already 1 (a prior wake is still in flight).

## Scheduling discipline

- **Demand preempts speculation.** A worker always drains ready fibers and urgent tasks before touching the novel or spec lanes. Both `pop` (own queues) and the steal scan walk lanes in priority order: urgent → novel → spec.
- **Spec is rationed, not prioritized down mid-run.** Once a spec task starts, its fiber runs to completion (no preemption of a running fiber); the cap, eviction, and inline fallback are the only throttle. In-flight speculation is instead abandoned cooperatively via the [bail-on-demand brake](speculation.md).
- **No cross-tier priority promotion.** When a *demand* fiber blocks on a thunk currently being computed by a *spec* fiber, the demand fiber simply parks on the [`Future`](../runtime/thunks.md) and the spec fiber finishes at spec priority. There is no mechanism to pull a blocking spec fiber up into the demand tier — do not assume one when reasoning about latency.

[Imports](imports.md) submit and park through this same machinery (an `ImportEntry` wraps a `Future`; a helper compiling an import is just another claim/wait).

## False-sharing isolation

The scheduler's globally write-hot atomics — `next_victim`, `next_fiber_id`, `pending_tasks`, `spinners`, `cont_pending`, `ready_pending`, `urgent_pending`, and the two spec/novel non-empty victim masks — each sit alone in a 128-byte destructive-interference block via `containers.Isolated`. A **comptime assertion** at the end of `Scheduler` proves no two of them (and no other, read-mostly or cold, field) share a block: packed together, each `fetchAdd` would invalidate its neighbors' lines on every submit/pop/steal across all workers. The per-worker `ReadyQueue`, `SpecQueue`, `WakeWord`, and activity-`Counters` structs are each `align(cache_line)` for the same reason, so adjacent workers never share a line even though the packed structs are smaller than one.

The per-worker activity counters are **single-writer** (a worker touches only its own slot) and therefore plain non-atomic adds — the cross-core coherence traffic that shared atomic counters caused scaled *against* the machine past ~8 workers. They are summed at report time, after quiescence.

The steal scan is further short-circuited by **per-lane stealable-work summaries** (`ready_pending` / `urgent_pending` / `cont_pending` counters and `spec_mask` / `novel_mask` bitmasks): `pending_tasks` says work *exists* but not in which lane, so without these every idle pass paid an O(N) per-peer probe over all five classes even when a class was provably empty. One read-mostly load per class replaces the walk. The summaries lag their queues (incremented after push, decremented after take), so a stale zero only ever skips one scan pass — never a park decision, which `pending_tasks` still gates.

## Garbage collection (`-Dgc`)

When the optional generational [collector](../gc.md) is built in, the scheduler hosts the **stop-the-world barrier**: a worker that crosses the collection threshold at a safepoint CASes `gc_stop_requested`, becomes the sole collector, waits for every peer to park at its own safepoint, then (for `--workers>1`) opens a parallel-mark gate so parked peers drain the mark graph through an installed hook instead of spinning idle. It is a full two-phase barrier — the collector waits for all peers to *clear* their parked flag before returning — so a slow peer can never carry a stale state into the next collection. The scheduler also exposes `gcMarkPendingTasks`, marking every heap object referenced by a queued task (a queued force is a live reference). All of this is `void` and inert without `-Dgc`.

---

Code: `src/nix/scheduler.zig`, `src/nix/vm/worker.zig`
