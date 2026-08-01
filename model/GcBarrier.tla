------------------------------ MODULE GcBarrier -------------------------------
EXTENDS FiniteSets

CONSTANTS Workers, Collector

Peers == Workers \ {Collector}

VARIABLES phase, parked, markOpen, helped

vars == <<phase, parked, markOpen, helped>>

Init ==
    /\ phase = "idle"
    /\ parked = {}
    /\ markOpen = FALSE
    /\ helped = {}

TryBegin ==
    /\ phase = "idle"
    /\ phase' = "collecting"
    /\ UNCHANGED <<parked, markOpen, helped>>

Park(w) ==
    /\ phase = "collecting"
    /\ w \in Peers \ parked
    /\ parked' = parked \cup {w}
    /\ UNCHANGED <<phase, markOpen, helped>>

OpenMark ==
    /\ phase = "collecting"
    /\ parked = Peers
    /\ ~markOpen
    /\ markOpen' = TRUE
    /\ UNCHANGED <<phase, parked, helped>>

Help(w) ==
    /\ phase = "collecting"
    /\ markOpen
    /\ w \in parked \ helped
    /\ helped' = helped \cup {w}
    /\ UNCHANGED <<phase, parked, markOpen>>

CloseMark ==
    /\ phase = "collecting"
    /\ markOpen
    /\ helped = Peers
    /\ markOpen' = FALSE
    /\ UNCHANGED <<phase, parked, helped>>

BeginRelease ==
    /\ phase = "collecting"
    /\ parked = Peers
    /\ helped = Peers
    /\ ~markOpen
    /\ phase' = "releasing" \* MUTATION_RELEASE_PHASE
    /\ UNCHANGED <<parked, markOpen, helped>>

Leave(w) ==
    /\ phase = "releasing"
    /\ w \in parked
    /\ parked' = parked \ {w}
    /\ UNCHANGED <<phase, markOpen, helped>>

EndRelease ==
    /\ phase = "releasing"
    /\ parked = {}
    /\ phase' = "idle"
    /\ helped' = {}
    /\ UNCHANGED <<parked, markOpen>>

Next ==
    \/ TryBegin
    \/ \E w \in Peers: Park(w)
    \/ OpenMark
    \/ \E w \in Peers: Help(w)
    \/ CloseMark
    \/ BeginRelease
    \/ \E w \in Peers: Leave(w)
    \/ EndRelease

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"idle", "collecting", "releasing"}
    /\ parked \subseteq Peers
    /\ helped \subseteq Peers
    /\ markOpen \in BOOLEAN

IdleIsClean == phase = "idle" =>
    /\ parked = {}
    /\ helped = {}
    /\ ~markOpen
ReleaseClosesMark == phase = "releasing" => ~markOpen
HelpOnlyWhileParked == phase = "collecting" => helped \subseteq parked
NoGenerationOverlap == phase # "idle" => ~ENABLED TryBegin

=============================================================================
