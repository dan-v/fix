# Parallel evaluation redesign

Status: plan (2026-06-27). Supersedes the framing in the `critical_path_floor`
memo, which is now stale — see §1.

## 0. Non-goals / invariants (read first)

- **No nixpkgs.lib coupling.** Every mechanism keys off generic evaluator
  concepts (strict consumers, chunk strictness bitmasks, blackhole/waiter
  state). Nothing knows what `mkIf`/`mkMerge`/`evalModules` are. We make
  nixpkgs fast *incidentally* by making Nix fast.
- **Byte-identical `.drv` at w=1 and w=32** is the safety net for every step.
  A/B each change against it.
- **Resume, never reset.** Re-running a partially-executed body is unsafe
  (it produced a different value after `error.StackOverflow`; see
  `thunk_reset_correctness`). All "stop and continue later" is fiber
  suspend/resume with stack intact — never re-entry from the top.

## 1. Where we actually are (measured 2026-06-27, w=32, nixos_toplevel)

Decomposition (best of 7, `date`-wrapped, uninstrumented):

| config                         | best  |
|--------------------------------|-------|
| spec + fanout (current)        | 1.247 |
| fanout only (`--no-spec`)      | 1.938 |
| spec only (`--no-fanout`)      | 2.186 |
| neither                        | 2.760 |
| w=1 serial                     | 2.750 |

- `neither` ≈ serial: 32 workers buy nothing without the work-finding
  machinery — the lazy demand frontier is a thin chain.
- **Consumer-demand fanout is already the bigger lever** (1.94 vs 2.19).
  Speculation adds ~0.69s of *earliness* on top.

Timeline (`-Dtimeline`, per-worker run/park):

- **Worker 0 parks 61% of the time; runs only 0.34s of the ~1.14s wall.**
  This *overturns* the `critical_path_floor` memo's "main never waits." At
  1.3s the floor is no longer worker-0's serial run — it's a **cross-worker
  dependency chain** that migrates across fibers via park/resume.
- All 32 workers average **~25% busy** (7.3% with spec off). Enormous latent
  capacity; the limit is dependency-chain *depth*, not throughput.

### The cost-model flip (the key conclusion)

Because cores are idle ~75% of the time, **speculative CPU is nearly free** —
burning a parked core on a dead body costs ~0 wall (confirmed by the older
"waste costs ~0 wall time" finding). The cost of speculation was never CPU. It
is two *scheduling* failures:

1. **Demand latency** — a worker that runs a spec body to completion can't
   serve newly-arrived demand promptly.
2. **Intra-speculation starvation** — one worker pours all cycles into one
   expensive (maybe dead) body while a cheap, soon-demanded body sits
   unstarted.

So the bug in today's speculation is **run-to-completion scheduling**, not the
guessing. We don't delete speculation — we make it fair, preemptible, and
promotable. And we make *being wrong* free, rather than making the guess
accurate.

## 2. Target architecture — three generic demand sources + one discipline

All three are generic; none knows about the module system.

### A. Consumer strict-demand fanout (deep)  — *provable, zero-waste*

At a **strict consumer** fork its full transitive strict frontier as *urgent*
work, not one level. Today fanout is `fanOutListShallow` / `fanOutAttrsShallow`
(one level; depth happens only by lucky cascade) and `derivation.zig:290` only
submits immediate input entries.

Headliner: **derivation build** (`derivationStrict`). Drv hashing is *fully
strict* — it coerces every input to a string, transitively. The demand is
known, total, and universal to all Nix the instant the drv build starts. Fork
the whole coercion frontier. Other strict consumers: deep-force of the root
result; strict folds / the k-way layered-merge flatten; N-ary string concat.

### B. Producer strict-upvalue fanout (Layer 1)  — *provable, from Phase A*

When a thunk body starts, the bytecode already determines which upvalues it
will force (Phase A shallow strictness bitmasks already exist). Fork those
**shallow-strict** upvalues at thunk entry — it's not a guess, the body will
provably demand them within a few instructions. Recursion happens naturally
(each forked thunk forks *its* shallow-strict set); do **not** prefetch deep
(Phase B showed deep prefetch cascades catastrophically). Phase B was "redundant
with speculation" only *because run-to-completion spec was already doing it by
guess* — once spec is fair/curtailed, this is the principled replacement.

### C. Fair preemptible run-ahead (Layer 3 residue + decision-gated)

The rehabilitated speculation, for work whose need isn't provable yet (e.g. a
body behind an unresolved condition). Properties:

- Runs on a fiber with a **time-slice** (cheap counter at call / tail-call /
  back-edge — straight-line code self-terminates; expensive bodies are
  expensive *because* they loop/recurse, which is where the counter ticks).
- On slice expiry: **push self to the back of the spec queue** (that *is*
  round-robin, reusing the queue you have) and yield.
- On every yield: one atomic load on the urgent queue; if demand exists,
  **defer and serve demand first** (bounds demand latency to one slice).
- Leaves the queue only by **completing** or being **promoted** (§3).
- **Abandonment is free**: purity + blackhole means a half-done body has no
  escaped state. We never cancel; we just stop scheduling it. A dead `mkIf`
  branch is indistinguishable from "demand never came" and costs one slice.

The knob is a *fairness slice*, workload-independent ("how long before another
body gets a turn"), not the `isSpeculatableUserFunc` guess about nixpkgs shapes.

### Scheduler discipline (invariants tying A/B/C together)

- Demand (urgent) **always** preempts speculation at yield points.
- Speculative fibers **never** run to completion uninterrupted.
- **Promotion is contagious** along blocked-on edges: a demand-path fiber
  blocked on a suspended-spec owner promotes it, transitively down the chain.
- Demand fibers run **flat-out** — they pay no fine-grained-yield tax; only
  spec fibers time-slice. (Otherwise we tax the critical path we're protecting.)

## 3. Promotion / resume mechanism (the "should it be resumed?" answer)

The predicate is **"is a demand-path fiber blocked on it?"**, observed for free
at the waiter-list park — no polling, no oracle.

A suspended spec fiber leaves `B` as `.evaluating`, claimed, `B.owner = fiber`,
`fiber.speculative_suspended = true`. When any fiber `force(B)`s:

1. `B` complete  → read the memo (best case).
2. `B` not started → claim & run normally.
3. `B` suspended-spec → if the forcer is demand-path (demand fiber, or itself
   `promoted`): set `B.owner.promoted = true`, `submitUrgent(resume B.owner)`,
   then park on `B`'s waiter list and yield.

Dedup against the spec-queue's stale resume entry via the existing
`ReadyNode.queued` CAS + per-fiber resume `SpinMutex` (the resume-race fix).
Promotion propagates one blocked-on edge at a time, so the whole suspended
chain feeding a demanded value lifts to demand priority automatically.

## 4. Phased plan (measure → build; each phase A/B'd + byte-identity checked)

- **P0 — instrument (do first).** I1–I4 below. Don't build until they answer
  the gating questions.
- **P1 — deep consumer strict-demand fanout (A), drv-build first.** Lowest
  risk, generic, extends the already-bigger lever. A/B vs current.
- **P2 — producer strict-upvalue fanout (B) from Phase A bitmasks.** Shallow
  only. A/B; watch for the Phase-B cascade regression.
- **P3 — fair/preemptible run-ahead (C).** Convert spec from run-to-completion
  to time-sliced fibers + round-robin re-enqueue + demand-preempt + promote.
  **Highest concurrency risk** (resumable fibers in the queue multiplies the
  resume/waiter/free-while-enrolled race surface). Gate on I3 proving
  head-of-line is real; otherwise ship only "spec fibers yield + check demand"
  (90% of the value, fraction of the risk).
- **P4 — curtail the guess.** If P1+P2+C subsume it, delete
  `isSpeculatableUserFunc`-gated `submit` sites (collections.zig:348/411/448,
  closures.zig:157, force.zig:442). A/B: deep-demand+strict-upvalue-only vs
  current. If equal, the overfit heuristic is gone.

## 5. Instrumentation catalog (P0) — each tied to the decision it gates

- **I1 — speculative-hit 3-bucket classifier.** For each spec hit, after the
  run, bucket it: (a) *provable-strict* — was a shallow-strict upvalue of a
  running chunk per Phase A; (b) *decision-released-reachable* — reachable from
  a strict consumer whose parent was reached; (c) *neither* (genuine guess).
  Records `ever_demanded?` too. **Decides:** how much earliness P1/P2 recover
  provably vs the residue C must carry. If (c) is small, the guess was never
  doing much.
- **I2 — spec task lifecycle profiler.** Per spec task: `{started, completed,
  cost (reductions/cycles), ever_demanded, ns_start→first_demand}`. **Decides:**
  the fairness-slice size; the cheap-needed vs expensive-dead split; whether
  "expensive, needed, lost head-start" is a real bucket under C.
- **I3 — head-of-line / demand-latency probe.** On each `submitUrgent`: was an
  idle (parked) worker available? Did any demanded thunk wait behind a
  longer-running spec body on the same worker with no idle worker free?
  **Decides:** P3 round-robin vs the cheap yield-and-check. (At 75% idle the
  pool may already absorb this — if so, skip the risky round-robin.)
- **I4 — critical-chain composition trace.** Walk the wake→produce→wake edges
  in the timeline to measure the cross-worker chain's *depth* and split it into
  irreducible value-DAG vs still-collapsible merge-folds (post-`layered_merge`).
  **Decides:** the ceiling. If the wall is ~pure DAG depth, A/B/C only make the
  engine honest/cheaper/robust — they won't beat 1.25; **depth reduction
  (deforestation) is the separate wall lever.** Set success criteria
  accordingly.
- **I5 — promotion telemetry (post-P3).** Promotions fired, promotion latency,
  fraction of demanded thunks that were mid-speculation, contagion depth.
  Validates the mechanism and guards byte-identity.

## 7. Progress log

**2026-06-27 — I1 landed + pathology bounded.**

- **I1 spec-census** (commits 5091fe7, f0e8afd): teardown census splits resolved
  thunks by `Future.demanded`, reports total created. Result OVERTURNS the
  misprediction premise: undemanded (forced-but-never-needed) is **0.2%** —
  speculation's guesses are ~perfect on nixos_toplevel. The cost is **churn +
  cross-worker duplication**: spec inflates thunk creation +38% (7.86M→10.84M)
  and resolves +1.16M *demanded* duplicates (thread-local memo doesn't cross
  workers; its own comment: 10.8% of bytecode forces are duplicates). So P3
  (fair/preemptible spec) is NOT a benchmark lever — there's no wrong-path work
  to throttle here.

- **BUT the misprediction case must not be a self-inflicted pathology for some
  FUTURE workload** (user steer). Demonstrated it (test/spec_pathology.nix): a
  lazy list of 256 substantial-but-never-demanded bodies made w=32 **4× slower
  than serial w=1** — speculation gates only on static body SIZE
  (`body_is_substantial` ≥ 256 bytecode bytes), never runtime cost or
  demand-likelihood, and the drain loop pulled the whole dead backlog before
  shutdown.

- **Fix landed** (commit e0a0528): `Scheduler.suppress_background`, set once a
  top-level result is ready, stops workers STARTING new spec/fan-out tasks while
  the drain loop finishes already-suspended fibers. Safe (a suspended fiber only
  waits on an already-claimed thunk, never a queued task — no teardown-race
  surgery). Pathology 0.160→0.091s (4×→1.4×); nixos_toplevel neutral +
  byte-identical.

- **Residual / next robustness step:** the ~1.4× tail is the spec elements
  already in-flight when the result completed — they must drain (correctness).
  Eliminating them needs either (a) safely retiring suspended speculative fibers
  at teardown (the fiber-lifecycle-race minefield — see worker.zig:282-285), or
  (b) fuel-bounding a speculative force so a single dead body can't run long.
  (b) is the lower-risk path and is the real "clean up speculation" follow-up.
  Also possible: gate speculation on a runtime-cost signal, not just body size.

## 6. Honest success criteria

This redesign's win is **robustness + freed CPU + non-overfit + bounded demand
latency** — a benchmark-independent engine that matches ~1.25 with provable
demand instead of a nixpkgs-tuned guess. Going *below* 1.25 is gated on I4: if
the chain is mostly irreducible DAG depth, that requires the deforestation lever
(`deforestation_ceiling`), not better scheduling. Don't conflate the two.
