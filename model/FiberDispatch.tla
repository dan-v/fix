---------------------------- MODULE FiberDispatch -----------------------------
EXTENDS FiniteSets, Naturals

CONSTANTS Fibers, Workers, NoWorker

Lifecycle == {"free", "running", "suspended"}

VARIABLES lifecycle, runOwner, queued, claimed, wakeCredits

vars == <<lifecycle, runOwner, queued, claimed, wakeCredits>>

Init ==
    /\ lifecycle = [f \in Fibers |-> "free"]
    /\ runOwner = [f \in Fibers |-> NoWorker]
    /\ queued = {}
    /\ claimed = {}
    /\ wakeCredits = [f \in Fibers |-> 0]

Start(f, w) ==
    /\ lifecycle[f] = "free"
    /\ f \notin queued \cup claimed
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "running"]
    /\ runOwner' = [runOwner EXCEPT ![f] = w]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Suspend(f) ==
    /\ lifecycle[f] = "running"
    /\ runOwner[f] # NoWorker
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "suspended"]
    /\ runOwner' = [runOwner EXCEPT ![f] = NoWorker]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Wake(f) ==
    /\ lifecycle[f] \in {"running", "suspended"}
    /\ f \notin queued
    /\ wakeCredits[f] < 2
    /\ queued' = queued \cup {f}
    /\ wakeCredits' = [wakeCredits EXCEPT ![f] = @ + 1]
    /\ UNCHANGED <<lifecycle, runOwner, claimed>>

Pop(f) ==
    /\ f \in queued
    /\ f \notin claimed
    /\ queued' = queued \ {f}
    /\ claimed' = claimed \cup {f}
    /\ UNCHANGED <<lifecycle, runOwner, wakeCredits>>

AcquireRun(f, w) ==
    /\ f \in claimed
    /\ runOwner[f] = NoWorker
    /\ lifecycle[f] # "free"
    /\ claimed' = claimed \ {f}
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "running"]
    /\ runOwner' = [runOwner EXCEPT ![f] = w]
    /\ wakeCredits' = [wakeCredits EXCEPT ![f] = @ - 1]
    /\ UNCHANGED queued

Finish(f) ==
    /\ lifecycle[f] = "running"
    /\ runOwner[f] # NoWorker
    /\ wakeCredits[f] = 0
    /\ lifecycle' = [lifecycle EXCEPT ![f] = "free"]
    /\ runOwner' = [runOwner EXCEPT ![f] = NoWorker]
    /\ UNCHANGED <<queued, claimed, wakeCredits>>

Next ==
    \/ \E f \in Fibers, w \in Workers: Start(f, w)
    \/ \E f \in Fibers: Suspend(f)
    \/ \E f \in Fibers: Wake(f)
    \/ \E f \in Fibers: Pop(f)
    \/ \E f \in Fibers, w \in Workers: AcquireRun(f, w)
    \/ \E f \in Fibers: Finish(f)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ lifecycle \in [Fibers -> Lifecycle]
    /\ runOwner \in [Fibers -> Workers \cup {NoWorker}]
    /\ queued \subseteq Fibers
    /\ claimed \subseteq Fibers
    /\ wakeCredits \in [Fibers -> 0..2]

FreeIsDetached == \A f \in Fibers:
    lifecycle[f] = "free" =>
        /\ runOwner[f] = NoWorker
        /\ f \notin queued \cup claimed
        /\ wakeCredits[f] = 0

RunningHasOwner == \A f \in Fibers:
    (runOwner[f] # NoWorker) => lifecycle[f] = "running"

ReadyTokenAccounting == \A f \in Fibers:
    wakeCredits[f] = (IF f \in queued THEN 1 ELSE 0)
                     + (IF f \in claimed THEN 1 ELSE 0)

NoDuplicateQueueEntry == queued \subseteq Fibers
OneRunOwner == runOwner \in [Fibers -> Workers \cup {NoWorker}]

=============================================================================
