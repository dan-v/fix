---------------------------- MODULE FutureWaitTSO ----------------------------
(***************************************************************************)
(* A store-buffer (TSO) refinement of FutureWait's ONE unfenced seam: the  *)
(* resolver's empty-list wake check.  FutureWait models Enroll and Publish *)
(* as atomic actions; the implementation makes them atomic by serializing  *)
(* on the tagged `Future.waiters` word.  What that spec cannot express is  *)
(* the memory-model obligation on the wake's EMPTY fast path: the check    *)
(* must be a seq_cst RMW (which drains the resolver's store buffer), not a *)
(* plain load.  With a plain load the resolver's `state` store can still   *)
(* sit in its store buffer while it reads waiters = empty; a concurrent    *)
(* enroller then locks the word, re-checks `state` against MEMORY, reads   *)
(* the stale value, and parks forever (shipped briefly in 2026-08 as an    *)
(* intermittent default-workers hang).                                     *)
(*                                                                         *)
(* Scope: exactly that seam, minimal machinery.  One resolver, one         *)
(* enroller, and a store buffer for the resolver only (the enroller has no *)
(* buffered stores that matter).  Enroll is one atomic action because the  *)
(* implementation holds the waiters word-lock across CAS + re-check +      *)
(* push — but its `state` read comes from MEMORY, which is the point.      *)
(* WakeEnrolled carries an untagged drain guard: the steal is a CAS (an    *)
(* RMW, hence a fence) in the implementation.                              *)
(***************************************************************************)
EXTENDS Sequences

VARIABLES
    mstate,  \* MEMORY value of Future.state: "unresolved" | "resolved"
    waiters, \* MEMORY value of the waiters word: "empty" | "enrolled"
    rbuf,    \* resolver store buffer: <<>> or <<"resolved">>
    rphase,  \* resolver: "publishing" | "waking" | "done"
    wphase   \* enroller: "idle" | "parked" | "done"

vars == <<mstate, waiters, rbuf, rphase, wphase>>

Init ==
    /\ mstate = "unresolved"
    /\ waiters = "empty"
    /\ rbuf = <<>>
    /\ rphase = "publishing"
    /\ wphase = "idle"

\* The resolver's state store enters its store buffer.
Publish ==
    /\ rphase = "publishing"
    /\ rbuf' = <<"resolved">>
    /\ rphase' = "waking"
    /\ UNCHANGED <<mstate, waiters, wphase>>

\* Memory catches up with the buffer at any later point.
Drain ==
    /\ rbuf # <<>>
    /\ mstate' = Head(rbuf)
    /\ rbuf' = Tail(rbuf)
    /\ UNCHANGED <<waiters, rphase, wphase>>

\* Enroll: lock-CAS on the waiters word, re-check state, park or bail —
\* atomic under the word-lock, but the state re-check reads MEMORY (the
\* resolver's buffered store is invisible to it).
Enroll ==
    /\ wphase = "idle"
    /\ waiters = "empty"
    /\ IF mstate = "resolved"
           THEN /\ wphase' = "done" \* bail: future already terminal
                /\ UNCHANGED waiters
           ELSE /\ wphase' = "parked"
                /\ waiters' = "enrolled"
    /\ UNCHANGED <<mstate, rbuf, rphase>>

\* The wake's empty-list fast path.  The tagged guard is the seq_cst RMW:
\* it drains the resolver's store buffer before the word is read.
\* Replacing it with TRUE (MUTATION_WAKE_FENCE) is the plain load — TLC
\* then finds the lost wakeup as a ParkedEventuallyWakes violation.
WakeEmpty ==
    /\ rphase = "waking"
    /\ rbuf = <<>> \* MUTATION_WAKE_FENCE
    /\ waiters = "empty"
    /\ rphase' = "done"
    /\ UNCHANGED <<mstate, waiters, rbuf, wphase>>

\* Wake with an enrolled waiter: the list steal is a CAS (an RMW), so the
\* buffer is drained by the time the waiter is woken — the woken fiber's
\* state re-read is guaranteed to see the published value.
WakeEnrolled ==
    /\ rphase = "waking"
    /\ rbuf = <<>>
    /\ waiters = "enrolled"
    /\ waiters' = "empty"
    /\ rphase' = "done"
    /\ wphase' = "done"
    /\ UNCHANGED <<mstate, rbuf>>

\* Explicit stutter for the orphaned-waiter state so the lost wakeup
\* surfaces as a LIVENESS violation (the harness greps for it) rather
\* than a TLC deadlock.
Stuck ==
    /\ rphase = "done"
    /\ wphase = "parked"
    /\ rbuf = <<>>
    /\ UNCHANGED vars

Terminated ==
    /\ rphase = "done"
    /\ wphase \in {"idle", "done"}
    /\ UNCHANGED vars

Next ==
    \/ Publish
    \/ Drain
    \/ Enroll
    \/ WakeEmpty
    \/ WakeEnrolled
    \/ Stuck
    \/ Terminated

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ mstate \in {"unresolved", "resolved"}
    /\ waiters \in {"empty", "enrolled"}
    /\ rbuf \in {<<>>, <<"resolved">>}
    /\ rphase \in {"publishing", "waking", "done"}
    /\ wphase \in {"idle", "parked", "done"}

\* The property the 2026-08 bug violated: a parked waiter is always
\* eventually woken.
ParkedEventuallyWakes == (wphase = "parked") ~> (wphase = "done")

=============================================================================
