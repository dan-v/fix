------------------------------- MODULE Shutdown -------------------------------
EXTENDS FiniteSets

CONSTANTS Helpers, Jobs

VARIABLES helperPhase, externalJobs, resourcesAlive

vars == <<helperPhase, externalJobs, resourcesAlive>>

Init ==
    /\ helperPhase = [h \in Helpers |-> "running"]
    /\ externalJobs = {}
    /\ resourcesAlive = TRUE

BeginJob(h, j) ==
    /\ helperPhase[h] = "running"
    /\ j \in Jobs \ externalJobs
    /\ externalJobs' = externalJobs \cup {j}
    /\ UNCHANGED <<helperPhase, resourcesAlive>>

StopHelper(h) ==
    /\ helperPhase[h] = "running"
    /\ helperPhase' = [helperPhase EXCEPT ![h] = "barrier"]
    /\ UNCHANGED <<externalJobs, resourcesAlive>>

CompleteJob(j) ==
    /\ j \in externalJobs
    /\ resourcesAlive
    /\ externalJobs' = externalJobs \ {j}
    /\ UNCHANGED <<helperPhase, resourcesAlive>>

DestroyHelper(h) ==
    /\ helperPhase[h] = "barrier"
    /\ \A peer \in Helpers: helperPhase[peer] \in {"barrier", "destroyed"}
    /\ externalJobs = {} \* MUTATION_EXTERNAL_DRAIN
    /\ helperPhase' = [helperPhase EXCEPT ![h] = "destroyed"]
    /\ UNCHANGED <<externalJobs, resourcesAlive>>

FreeResources ==
    /\ resourcesAlive
    /\ \A h \in Helpers: helperPhase[h] = "destroyed"
    /\ externalJobs = {}
    /\ resourcesAlive' = FALSE
    /\ UNCHANGED <<helperPhase, externalJobs>>

Next ==
    \/ \E h \in Helpers, j \in Jobs: BeginJob(h, j)
    \/ \E h \in Helpers: StopHelper(h)
    \/ \E j \in Jobs: CompleteJob(j)
    \/ \E h \in Helpers: DestroyHelper(h)
    \/ FreeResources

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ helperPhase \in [Helpers -> {"running", "barrier", "destroyed"}]
    /\ externalJobs \subseteq Jobs
    /\ resourcesAlive \in BOOLEAN

CallbacksNeedResources == externalJobs # {} => resourcesAlive
NoDestroyWithCallbacks == externalJobs # {} =>
    \A h \in Helpers: helperPhase[h] # "destroyed"
FreedIsTerminal == ~resourcesAlive =>
    /\ externalJobs = {}
    /\ \A h \in Helpers: helperPhase[h] = "destroyed"

=============================================================================
