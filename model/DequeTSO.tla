------------------------------ MODULE DequeTSO ------------------------------
(***************************************************************************)
(* A store-buffer (TSO) refinement of the Chase-Lev deque in               *)
(* src/base/deque.zig, scoped to what sequentially-consistent TLA+ cannot  *)
(* express: the seqCstFence in `pop` between the owner's `bottom`          *)
(* decrement store and its `top` load.  Under TSO the decrement can sit in *)
(* the owner's store buffer while the `top` load executes; a stealer then  *)
(* reads the STALE (pre-decrement) `bottom` from memory, believes an       *)
(* element the owner is popping is still available, and takes it — the     *)
(* classic fenceless-Chase-Lev double-take (Le et al. 2013, sec. 4).      *)
(*                                                                         *)
(* Model shape: one owner popping a pre-loaded deque of N elements         *)
(* (indices 0..N-1, top = 0, bottom = N), a set of stealers, and a store   *)
(* buffer for the owner's `bottom` writes only — `top` is written solely   *)
(* by CAS RMWs, which on x86 (lock cmpxchg) drain the issuing core's       *)
(* buffer and go straight to memory; stealers write nothing else.  Pushes  *)
(* are out of scope: a push's slot-then-`bottom` store order is preserved  *)
(* by TSO automatically, so no fence obligation exists there to check.     *)
(* Slot contents are also out of scope (index-level exactly-once is the    *)
(* protocol property; slot-word atomicity is WordSlot's job in Zig).       *)
(*                                                                         *)
(* The owner reads `bottom` through its own buffer (TSO store-to-load      *)
(* forwarding); stealers read `bottom` from memory.  The steal-side fence  *)
(* (top load before bottom load) is NOT modeled: TSO preserves load-load   *)
(* order, so its obligation lives outside this memory model — it is not a  *)
(* tagged mutation because removing it here would (correctly) change      *)
(* nothing.                                                                *)
(*                                                                         *)
(* Tagged mutations (each guard's marker names it; exact marker strings    *)
(* must appear ONLY on guard lines — the harness rewrites every line       *)
(* containing one), each of which TLC must reject via NoDuplication:       *)
(*   pop fence  — drop the drain guard on pop's top read (the plain-load   *)
(*     pop): stealers race the buffered decrement and double-take.         *)
(*   pop CAS    — the owner's last-element CAS always "wins".              *)
(*   steal CAS  — a stealer's CAS always "wins".                           *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    N,       \* number of pre-loaded elements (indices 0..N-1)
    Stealers \* stealer identities

Indices == 0..N-1
Takers == Stealers \cup {"owner"}

VARIABLES
    mem_top,    \* MEMORY value of `top` (CAS-only, never buffered)
    mem_bottom, \* MEMORY value of `bottom`
    obuf,       \* owner's store buffer: FIFO of pending `bottom` values
    ophase,     \* owner: "idle" | "reading" | "casing" | "done"
    b_local,    \* owner's popped index (bottom - 1 at PopBegin)
    t_local,    \* owner's saved `top` for the last-element CAS
    sphase,     \* per-stealer: "idle" | "read_bottom" | "cas"
    st,         \* per-stealer saved `top`
    takenBy     \* per-index set of takers — duplication detector

vars == <<mem_top, mem_bottom, obuf, ophase, b_local, t_local, sphase, st, takenBy>>

\* TSO store-to-load forwarding: the owner's own `bottom` read sees its
\* newest buffered store; memory only after drain.
ownerBottom == IF obuf = <<>> THEN mem_bottom ELSE obuf[Len(obuf)]

\* A CAS is an RMW: on x86 the lock prefix drains the issuing core's store
\* buffer before the operation.  Owner CAS actions use these to flush.
flushedBottom == IF obuf = <<>> THEN mem_bottom ELSE obuf[Len(obuf)]

Init ==
    /\ mem_top = 0
    /\ mem_bottom = N
    /\ obuf = <<>>
    /\ ophase = "idle"
    /\ b_local = 0
    /\ t_local = 0
    /\ sphase = [s \in Stealers |-> "idle"]
    /\ st = [s \in Stealers |-> 0]
    /\ takenBy = [i \in Indices |-> {}]

\* Memory catches up with the oldest buffered store at any point.
Drain ==
    /\ obuf # <<>>
    /\ mem_bottom' = Head(obuf)
    /\ obuf' = Tail(obuf)
    /\ UNCHANGED <<mem_top, ophase, b_local, t_local, sphase, st, takenBy>>

(* ------------------------------- Owner ------------------------------- *)

\* pop: `b = bottom - 1; bottom = b` — the decrement store enters the
\* buffer.  The fence sits between this and the `top` read below.
PopBegin ==
    /\ ophase = "idle"
    /\ LET nb == ownerBottom - 1 IN
        /\ b_local' = nb
        /\ obuf' = Append(obuf, nb)
    /\ ophase' = "reading"
    /\ UNCHANGED <<mem_top, mem_bottom, t_local, sphase, st, takenBy>>

\* pop's `top` read + branch.  The tagged guard is the seqCstFence: the
\* buffered decrement must be globally visible before the owner may act on
\* the `top` it reads.  The three branches share the guard; the mutation
\* replaces every tagged line, i.e. deletes the fence wholesale.

\* b < t: deque observed empty — restore `bottom := t` (buffered) and stop.
PopSeeEmpty ==
    /\ ophase = "reading"
    /\ obuf = <<>> \* MUTATION_POP_FENCE
    /\ b_local < mem_top
    /\ obuf' = Append(obuf, mem_top)
    /\ ophase' = "done"
    /\ UNCHANGED <<mem_top, mem_bottom, b_local, t_local, sphase, st, takenBy>>

\* b > t: not the last element — the owner takes index b with NO CAS.
\* This branch is exactly what the fence protects: without it, stealers
\* still see the pre-decrement `bottom` and can take the same index.
PopTakeInner ==
    /\ ophase = "reading"
    /\ obuf = <<>> \* MUTATION_POP_FENCE
    /\ b_local > mem_top
    /\ takenBy' = [takenBy EXCEPT ![b_local] = @ \cup {"owner"}]
    /\ ophase' = "idle"
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, b_local, t_local, sphase, st>>

\* b = t: last element — race stealers for it via CAS on `top`.
PopSeeLast ==
    /\ ophase = "reading"
    /\ obuf = <<>> \* MUTATION_POP_FENCE
    /\ b_local = mem_top
    /\ t_local' = mem_top
    /\ ophase' = "casing"
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, b_local, sphase, st, takenBy>>

\* The last-element CAS.  RMW: flushes the buffer, then compares-and-swaps
\* atomically.  Either way the code then stores `bottom := t + 1` (a fresh
\* buffered store).
PopCasWin ==
    /\ ophase = "casing"
    /\ mem_top = t_local \* MUTATION_POP_CAS
    /\ mem_top' = t_local + 1
    /\ takenBy' = [takenBy EXCEPT ![b_local] = @ \cup {"owner"}]
    /\ mem_bottom' = flushedBottom
    /\ obuf' = <<t_local + 1>>
    /\ ophase' = "idle"
    /\ UNCHANGED <<b_local, t_local, sphase, st>>

PopCasLose ==
    /\ ophase = "casing"
    /\ mem_top # t_local
    /\ mem_bottom' = flushedBottom
    /\ obuf' = <<t_local + 1>>
    /\ ophase' = "idle"
    /\ UNCHANGED <<mem_top, b_local, t_local, sphase, st, takenBy>>

(* ------------------------------ Stealers ------------------------------ *)

StealReadTop(s) ==
    /\ sphase[s] = "idle"
    /\ st' = [st EXCEPT ![s] = mem_top]
    /\ sphase' = [sphase EXCEPT ![s] = "read_bottom"]
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, ophase, b_local, t_local, takenBy>>

\* The stealer's `bottom` read hits MEMORY — the owner's buffered decrement
\* is invisible to it.  That staleness is the raw material of the bug; the
\* pop fence is what keeps it harmless.
StealSeeWork(s) ==
    /\ sphase[s] = "read_bottom"
    /\ mem_bottom > st[s]
    /\ sphase' = [sphase EXCEPT ![s] = "cas"]
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, ophase, b_local, t_local, st, takenBy>>

StealSeeEmpty(s) ==
    /\ sphase[s] = "read_bottom"
    /\ mem_bottom <= st[s]
    /\ sphase' = [sphase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, ophase, b_local, t_local, st, takenBy>>

StealCasWin(s) ==
    /\ sphase[s] = "cas"
    /\ mem_top = st[s] \* MUTATION_STEAL_CAS
    /\ mem_top' = st[s] + 1
    /\ takenBy' = [takenBy EXCEPT ![st[s]] = @ \cup {s}]
    /\ sphase' = [sphase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<mem_bottom, obuf, ophase, b_local, t_local, st>>

StealCasLose(s) ==
    /\ sphase[s] = "cas"
    /\ mem_top # st[s]
    /\ sphase' = [sphase EXCEPT ![s] = "idle"]
    /\ UNCHANGED <<mem_top, mem_bottom, obuf, ophase, b_local, t_local, st, takenBy>>

OwnerAct == PopBegin \/ PopSeeEmpty \/ PopTakeInner \/ PopSeeLast
                \/ PopCasWin \/ PopCasLose
StealerAct(s) == StealReadTop(s) \/ StealSeeWork(s) \/ StealSeeEmpty(s)
                     \/ StealCasWin(s) \/ StealCasLose(s)

Next ==
    \/ Drain
    \/ OwnerAct
    \/ \E s \in Stealers : StealerAct(s)

\* Fairness per agent (plus the drain): stealers retry forever, so weak
\* fairness on each one's action set is enough for every element to be
\* claimed eventually.
Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(Drain)
    /\ WF_vars(OwnerAct)
    /\ \A s \in Stealers : WF_vars(StealerAct(s))

TypeOK ==
    /\ mem_top \in 0..N
    /\ mem_bottom \in -1..N
    /\ obuf \in Seq(-1..N)
    /\ ophase \in {"idle", "reading", "casing", "done"}
    /\ b_local \in -1..N
    /\ t_local \in 0..N
    /\ sphase \in [Stealers -> {"idle", "read_bottom", "cas"}]
    /\ st \in [Stealers -> 0..N]
    /\ takenBy \in [Indices -> SUBSET Takers]

\* THE property: no element is ever returned twice (owner and stealer, or
\* two stealers, both handing out the same index).
NoDuplication == \A i \in Indices : Cardinality(takenBy[i]) <= 1

\* And none is lost: every element is eventually claimed by someone.
AllTaken == <>(\A i \in Indices : takenBy[i] # {})

=============================================================================
