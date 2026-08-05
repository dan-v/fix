------------------------------ MODULE FutureWait ------------------------------
EXTENDS FiniteSets

CONSTANTS Waiters, Claimers, NoClaimer

Terminal == {"resolved", "errored", "blackhole"}

\* Each waiter cycles idle -> waiting -> woken -> idle. The woken -> idle step
\* models the fiber observing its wake and becoming free to re-enroll, which
\* is exactly what happens after `reset()` drops a transient failure back to
\* `.unresolved` and wakes the list so it can retry.
WaiterState == {"idle", "waiting", "woken"}

VARIABLES state, claimer, wstate

vars == <<state, claimer, wstate>>

Init ==
    /\ state = "unresolved"
    /\ claimer = NoClaimer
    /\ wstate = [w \in Waiters |-> "idle"]

Claim(c) ==
    /\ state = "unresolved"
    /\ c \in Claimers
    /\ state' = "evaluating"
    /\ claimer' = c
    /\ UNCHANGED wstate

Enroll(w) ==
    /\ state = "evaluating" \* MUTATION_ENROLL_RECHECK
    /\ wstate[w] = "idle"
    /\ wstate' = [wstate EXCEPT ![w] = "waiting"]
    /\ UNCHANGED <<state, claimer>>

WakeAll == [w \in Waiters |-> IF wstate[w] = "waiting" THEN "woken" ELSE wstate[w]]

Publish(outcome) ==
    /\ state = "evaluating"
    /\ outcome \in Terminal
    /\ state' = outcome
    /\ claimer' = NoClaimer
    /\ wstate' = WakeAll

Reset ==
    /\ state = "evaluating"
    /\ state' = "unresolved"
    /\ claimer' = NoClaimer
    /\ wstate' = WakeAll

Observe(w) ==
    /\ wstate[w] = "woken"
    /\ wstate' = [wstate EXCEPT ![w] = "idle"]
    /\ UNCHANGED <<state, claimer>>

\* Terminal outcomes are sticky; the explicit stutter step keeps TLC's
\* deadlock check enabled by distinguishing *resolved* from *stuck*.
Done ==
    /\ state \in Terminal
    /\ UNCHANGED vars

Next ==
    \/ \E c \in Claimers: Claim(c)
    \/ \E w \in Waiters: Enroll(w)
    \/ \E outcome \in Terminal: Publish(outcome)
    \/ Reset
    \/ \E w \in Waiters: Observe(w)
    \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ state \in {"unresolved", "evaluating"} \cup Terminal
    /\ claimer \in Claimers \cup {NoClaimer}
    /\ wstate \in [Waiters -> WaiterState]

SingleClaimer == (state = "evaluating") <=> (claimer \in Claimers)

\* An enrolled waiter exists only while a claimer is evaluating. Enrollment
\* against an unresolved or terminal future is the lost-wakeup bug the
\* under-lock state recheck in `enrollWaiter` exists to prevent.
\*
\* REFINEMENT OBLIGATION (below TLC's semantics — TLA+ actions are
\* sequentially consistent, so TLC cannot check this): the implementation
\* must make Enroll and Publish genuinely atomic w.r.t. each other. Both
\* serialize on the tagged `Future.waiters` word (LSB = lock), and —
\* the trap actually hit in 2026-08 — Publish's EMPTY-list fast path must
\* still synchronize on that word (a seq_cst RMW, `fetchOr 0`), not a
\* plain load: with a plain load the resolver's `state` store can sit in
\* its store buffer while it reads waiters == 0, a concurrent enroller
\* re-checks `state`, reads the stale value, and parks forever —
\* violating EveryWaiterWakes in an execution this spec cannot express.
WaitingImpliesEvaluating ==
    \A w \in Waiters: wstate[w] = "waiting" => state = "evaluating"

EventuallyLeavesEvaluation == (state = "evaluating") ~> (state # "evaluating")

\* No waiter is ever stranded: every enrollment is drained by a publication
\* or a reset.
EveryWaiterWakes ==
    \A w \in Waiters: (wstate[w] = "waiting") ~> (wstate[w] = "woken")

=============================================================================
