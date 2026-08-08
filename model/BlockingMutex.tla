---------------------------- MODULE BlockingMutex ----------------------------
EXTENDS Naturals, FiniteSets

\* sync.zig's BlockingMutex: the tri-state futex mutex (0 unlocked / 1 locked
\* uncontended / 2 locked contended). lock() is one weak CAS 0 -> 1; the slow
\* path spins the same CAS a bounded number of times, then loops
\* { swap(2): prev 0 means acquired; else futex-wait while state == 2 }.
\* unlock() swaps 0 and wakes one waiter only when the swapped-out state was 2.
\* Since the TSan SpinMutex alias, this lock stands in for EVERY SpinMutex
\* site in sanitizer builds, so its no-lost-wake obligation carries those
\* sections too.
\*
\* Each thread performs exactly ONE lock/unlock cycle and retires: the futex
\* protocol admits barging (a fresh locker can overtake a parked waiter), so
\* per-thread progress under infinite re-locking is not a theorem even for
\* correct code — but with finite work, every parked thread must be handed
\* the lock or observe it free, which is precisely the no-lost-wake claim.
\*
\* Weak CAS failure is modeled by leaving EnterSlow/GiveUp unguarded (a CAS
\* may "fail" at any time, even uncontended). Futex spurious wakeups are
\* deliberately NOT modeled: they only release threads from park, so they can
\* mask a lost wake — omitting them keeps the adversary strongest and the
\* mutation checks below discriminating.

CONSTANTS Threads

\* pc: "start" (fast-path CAS) -> "spin" (bounded CAS retries) -> "swap"
\* (the swap(2) loop head) -> "wait" (between swap and the futex's atomic
\* value recheck) -> "parked" (asleep in the kernel) -> "holding" -> "done".
VARIABLES state, pc

vars == <<state, pc>>

Init ==
    /\ state = 0
    /\ pc = [t \in Threads |-> "start"]

\* Fast path: cmpxchg(0 -> 1).
FastLock(t) ==
    /\ pc[t] = "start"
    /\ state = 0 \* MUTATION_FAST_GUARD
    /\ state' = 1
    /\ pc' = [pc EXCEPT ![t] = "holding"]

\* The fast CAS failed (contention or weak-CAS spurious failure).
EnterSlow(t) ==
    /\ pc[t] = "start"
    /\ pc' = [pc EXCEPT ![t] = "spin"]
    /\ UNCHANGED state

\* One bounded-spin retry succeeds.
SpinLock(t) ==
    /\ pc[t] = "spin"
    /\ state = 0
    /\ state' = 1
    /\ pc' = [pc EXCEPT ![t] = "holding"]

\* The spin budget runs out (any number of failed retries collapses here).
GiveUp(t) ==
    /\ pc[t] = "spin"
    /\ pc' = [pc EXCEPT ![t] = "swap"]
    /\ UNCHANGED state

\* swap(2) returned 0: the mutex was free, we own it (state is now 2, so our
\* own unlock will issue a possibly-spurious wake — harmless by design).
SwapAcquire(t) ==
    /\ pc[t] = "swap"
    /\ state = 0 \* MUTATION_SWAP_ACQUIRE
    /\ state' = 2
    /\ pc' = [pc EXCEPT ![t] = "holding"]

\* swap(2) returned nonzero: someone holds it; mark contended and head to the
\* futex.
SwapContend(t) ==
    /\ pc[t] = "swap"
    /\ state # 0
    /\ state' = 2
    /\ pc' = [pc EXCEPT ![t] = "wait"]

\* Futex wait: the kernel atomically parks us only while the word still reads
\* 2. This value recheck is the whole point of a futex — parking without it
\* sleeps through the wake that already happened.
FutexSleep(t) ==
    /\ pc[t] = "wait"
    /\ state = 2 \* MUTATION_WAIT_RECHECK
    /\ pc' = [pc EXCEPT ![t] = "parked"]
    /\ UNCHANGED state

\* Futex wait observed state # 2 and returned immediately; retry the swap.
FutexBail(t) ==
    /\ pc[t] = "wait"
    /\ state # 2
    /\ pc' = [pc EXCEPT ![t] = "swap"]
    /\ UNCHANGED state

\* unlock() when the swapped-out state was 1: nobody advertised contention,
\* no wake needed.
UnlockPlain(t) ==
    /\ pc[t] = "holding"
    /\ state = 1 \* MUTATION_UNLOCK_PLAIN
    /\ state' = 0
    /\ pc' = [pc EXCEPT ![t] = "done"]

\* unlock() when the swapped-out state was 2: wake one parked waiter (the
\* kernel picks which); a wake with an empty wait queue is a no-op.
UnlockWake(t) ==
    /\ pc[t] = "holding"
    /\ state = 2
    /\ state' = 0
    /\ \/ \E u \in Threads:
             /\ pc[u] = "parked"
             /\ pc' = [pc EXCEPT ![t] = "done", ![u] = "swap"]
       \/ /\ \A u \in Threads: pc[u] # "parked"
          /\ pc' = [pc EXCEPT ![t] = "done"]

\* All threads retired; explicit stutter keeps TLC's deadlock check on.
Done ==
    /\ \A t \in Threads: pc[t] = "done"
    /\ UNCHANGED vars

Next ==
    \/ \E t \in Threads:
        \/ FastLock(t)
        \/ EnterSlow(t)
        \/ SpinLock(t)
        \/ GiveUp(t)
        \/ SwapAcquire(t)
        \/ SwapContend(t)
        \/ FutexSleep(t)
        \/ FutexBail(t)
        \/ UnlockPlain(t)
        \/ UnlockWake(t)
    \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ state \in 0..2
    /\ pc \in [Threads -> {"start", "spin", "swap", "wait", "parked", "holding", "done"}]

MutualExclusion ==
    Cardinality({t \in Threads: pc[t] = "holding"}) <= 1

\* A free word means nobody is inside the critical section.
FreeMeansNoHolder ==
    (state = 0) => \A t \in Threads: pc[t] # "holding"

\* No parked thread is ever stranded: while anyone sleeps in the kernel, some
\* thread is still active to continue the wake chain (hold-and-unlock-wake,
\* or a woken/late thread that will re-swap the word to 2 and eventually
\* hand off). A parked thread whose last potential waker retired IS the
\* lost-wakeup bug — this catches it as a safety violation at the exact
\* state, rather than leaving it to the liveness checker.
ParkedHasSuccessor ==
    (\E t \in Threads: pc[t] = "parked")
        => \E u \in Threads: pc[u] \in {"start", "spin", "swap", "wait", "holding"}

\* Every thread that wants the lock eventually gets through it. With one
\* cycle per thread this is exactly "no acquisition or wake is ever lost".
EveryLockerFinishes ==
    \A t \in Threads: (pc[t] # "done") ~> (pc[t] = "done")

=============================================================================
