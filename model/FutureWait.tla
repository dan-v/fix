------------------------------ MODULE FutureWait ------------------------------
EXTENDS FiniteSets

CONSTANTS Waiters, Claimers, NoClaimer

Terminal == {"resolved", "errored", "blackhole"}

VARIABLES state, claimer, waiting, woken, enrolled

vars == <<state, claimer, waiting, woken, enrolled>>

Init ==
    /\ state = "unresolved"
    /\ claimer = NoClaimer
    /\ waiting = {}
    /\ woken = {}
    /\ enrolled = {}

Claim(c) ==
    /\ state = "unresolved"
    /\ c \in Claimers
    /\ state' = "evaluating"
    /\ claimer' = c
    /\ UNCHANGED <<waiting, woken, enrolled>>

Enroll(w) ==
    /\ state = "evaluating" \* MUTATION_ENROLL_RECHECK
    /\ w \in Waiters \ enrolled
    /\ waiting' = waiting \cup {w}
    /\ enrolled' = enrolled \cup {w}
    /\ UNCHANGED <<state, claimer, woken>>

Publish(outcome) ==
    /\ state = "evaluating"
    /\ outcome \in Terminal
    /\ state' = outcome
    /\ claimer' = NoClaimer
    /\ woken' = woken \cup waiting
    /\ waiting' = {}
    /\ UNCHANGED enrolled

Reset ==
    /\ state = "evaluating"
    /\ state' = "unresolved"
    /\ claimer' = NoClaimer
    /\ woken' = woken \cup waiting
    /\ waiting' = {}
    /\ UNCHANGED enrolled

Next ==
    \/ \E c \in Claimers: Claim(c)
    \/ \E w \in Waiters: Enroll(w)
    \/ \E outcome \in Terminal: Publish(outcome)
    \/ Reset

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ state \in {"unresolved", "evaluating"} \cup Terminal
    /\ claimer \in Claimers \cup {NoClaimer}
    /\ waiting \subseteq Waiters
    /\ woken \subseteq Waiters
    /\ enrolled \subseteq Waiters

SingleClaimer == (state = "evaluating") <=> (claimer \in Claimers)
TerminalDrained == state \in Terminal => waiting = {}
NoLostEnrollment == enrolled = waiting \cup woken
NoDoubleWake == waiting \cap woken = {}
EventuallyLeavesEvaluation == [](state = "evaluating" ~> state # "evaluating")

=============================================================================
