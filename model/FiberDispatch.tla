---------------------------- MODULE FiberDispatch -----------------------------
EXTENDS FiniteSets, Naturals

CONSTANTS Fibers, Workers

Lifecycle == {"free", "running", "suspended"}

VARIABLES lifecycle, runOwners, queued, claimed, wakeCredits

vars == <<lifecycle, runOwners, queued, claimed, wakeCredits>>

Init ==
    /\ lifecycle = [f \in Fibers |-> "free"]
    /\ runOwners = [f \in Fibers |-> {}]
    /\ queued = {}
    /\ claimed = {}
    /\ wakeCredits = [f \in Fibers |-> 0]

Start(f, w) ==
    /\ lifecycle[f] = "free"
    /\ f \notin queued \cup claimed
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "running"]
    /\ runOwners' = [runOwners EXCEPT ![f] = {w}]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Suspend(f) ==
    /\ lifecycle[f] = "running"
    /\ runOwners[f] # {}
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "suspended"]
    /\ runOwners' = [runOwners EXCEPT ![f] = {}]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Wake(f) ==
    /\ lifecycle[f] \in {"running", "suspended"}
    /\ f \notin queued
    /\ wakeCredits[f] < 2
    /\ queued' = queued \cup {f}
    /\ wakeCredits' = [wakeCredits EXCEPT ![f] = @ + 1]
    /\ UNCHANGED <<lifecycle, runOwners, claimed>>

Pop(f) ==
    /\ f \in queued
    /\ f \notin claimed
    /\ queued' = queued \ {f}
    /\ claimed' = claimed \cup {f}
    /\ UNCHANGED <<lifecycle, runOwners, wakeCredits>>

AcquireRun(f, w) ==
    /\ f \in claimed
    /\ runOwners[f] = {} \* MUTATION_ACQUIRE_EXCLUSIVE
    /\ lifecycle[f] # "free"
    /\ claimed' = claimed \ {f}
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "running"]
    /\ runOwners' = [runOwners EXCEPT ![f] = @ \cup {w}]
    /\ wakeCredits' = [wakeCredits EXCEPT ![f] = @ - 1]
    /\ UNCHANGED queued

Finish(f) ==
    /\ lifecycle[f] = "running"
    /\ runOwners[f] # {}
    /\ wakeCredits[f] = 0
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "free"]
    /\ runOwners' = [runOwners EXCEPT ![f] = {}]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Next ==
    \/ \E f \in Fibers, w \in Workers: Start(f, w)
    \/ \E f \in Fibers: Suspend(f)
    \/ \E f \in Fibers: Wake(f)
    \/ \E f \in Fibers: Pop(f)
    \/ \E f \in Fibers, w \in Workers: AcquireRun(f, w)
    \/ \E f \in Fibers: Finish(f)

\* Fairness applies only to `AcquireRun`: workers always convert a popped wake
\* token into a run once ownership is vacated. Whether the workload starts,
\* suspends, wakes, or finishes fibers is its own business.
Fairness == \A f \in Fibers: WF_vars(\E w \in Workers: AcquireRun(f, w))

Spec == Init /\ [][Next]_vars /\ Fairness

TypeOK ==
    /\ lifecycle \in [Fibers -> Lifecycle]
    /\ runOwners \in [Fibers -> SUBSET Workers]
    /\ queued \subseteq Fibers
    /\ claimed \subseteq Fibers
    /\ wakeCredits \in [Fibers -> 0..2]

\* At most one worker ever runs a fiber — the double-run that a queued
\* wake-before-yield would cause if `AcquireRun` did not insist on vacated
\* ownership.
ExclusiveRunOwner == \A f \in Fibers: Cardinality(runOwners[f]) <= 1

FreeIsDetached == \A f \in Fibers:
    lifecycle[f] = "free" =>
        /\ runOwners[f] = {}
        /\ f \notin queued \cup claimed
        /\ wakeCredits[f] = 0

OwnersOnlyWhileRunning == \A f \in Fibers:
    runOwners[f] # {} => lifecycle[f] = "running"

ReadyTokenAccounting == \A f \in Fibers:
    wakeCredits[f] = (IF f \in queued THEN 1 ELSE 0)
                     + (IF f \in claimed THEN 1 ELSE 0)

\* A popped wake token is never lost: the suspended fiber it names runs again.
ClaimedTokenRuns == \A f \in Fibers:
    (f \in claimed /\ lifecycle[f] = "suspended") ~> (lifecycle[f] = "running")

=============================================================================
