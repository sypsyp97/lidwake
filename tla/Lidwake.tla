------------------------------- MODULE Lidwake -------------------------------
(***************************************************************************)
(* Model of the lidwake Controller protocol, written from docs/SPEC.md      *)
(* sections 6 (SleepControl), 7 (Journal), 8 (Controller) and 9 (run/stop/ *)
(* restore), as amended in commits 6fff56b (orphan guard) and 2b0ce82     *)
(* (kill stopped orphans). No implementation code was consulted.           *)
(*                                                                         *)
(* Every step that touches the disk (journal save), pmset, the IORegistry  *)
(* read or the process probe is its own atomic action, so a crash, a user  *)
(* action or an environment change can interleave between any two steps.  *)
(* setSleepDisabled(v, recorded:) is modelled as: spawn the child          *)
(* suspended -> `recorded` saves journal.pending = child identity -> resume *)
(* -> child runs and exits -> parent reads the exit status -> parent saves *)
(* pending = nil with the outcome. A crash before the record save leaves a *)
(* stopped child with no flag effect. A crash after the record save but   *)
(* before the resume leaves a recorded orphan that stays stopped forever   *)
(* unless killed. A crash after the resume leaves a running orphan that    *)
(* can land at any later time. isSleepDisabled() can return nil.           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    S,          \* settle window in ticks (abstracts Decision.defaultSettle)
    UserRace,   \* TRUE: the user may run `pmset disablesleep 1` at any instant.
                \* FALSE: only while lidwake holds no claim on the flag (Quiet);
                \* SPEC 8 "Known limitation".
    Mutation    \* "none" or the name of one seeded bug (see Lidwake_bug.tla)

VARIABLES
    sd,          \* system flag SleepDisabled (IOPMrootDomain)
    userSet,     \* the user's intent: value of the last manual `pmset disablesleep`
    jOwned,      \* journal.json on disk: owned
    jSettle,     \* journal.json on disk: lastActive, as remaining settle ticks 0..S
    jPend,       \* journal.json on disk: pending child identity, 0 = nil
    pc,          \* agent program counter; "down" = process not running
    memOwned,    \* agent in-memory journal: owned
    memS,        \* agent in-memory journal: lastActive (remaining settle ticks)
    memPend,     \* agent in-memory journal: pending
    hold,        \* hold flag of the last Decision outcome
    assertHeld,  \* PreventUserIdleSystemSleep assertion held by the agent
    termPending, \* SIGTERM/SIGINT received, stop() not yet run
    caller,      \* which agent step is inside setSleepDisabled
    active,      \* input: forced || herdrWorking || backgroundTask
    battLow,     \* input: battery low (overrides everything)
    child,       \* pmset child of the agent or of restore: "none" | "on" | "off"
    childPh,     \* "none" | "susp" (spawned suspended) | "rec" (recorded) |
                 \* "run" (resumed)
    childId,     \* identity of that child (pid + start time), 0 = none
    childRes,    \* its exit status not yet read by the parent: "none" | "ok" | "fail"
    nextId,      \* identity of the next child (identities are never reused)
    orphans,     \* recorded children whose parent crashed: set of
                 \* <<identity, "on"|"off", "stopped"|"running"|"dying">>
                 \* ("dying" = SIGKILLed while stopped, not yet reaped)
    rpc,         \* `lidwake restore` program counter; "none" = not running
    calm         \* environment has gone quiet for good (liveness hypothesis)

vars == <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend, hold,
          assertHeld, termPending, caller, active, battLow, child, childPh, childId,
          childRes, nextId, orphans, rpc, calm>>

Ids == {1, 2}
Vals == {"on", "off"}
OPhases == {"stopped", "running", "dying"}
PCs == {"down", "s_load",
        "idle", "t_saveLA", "t_probe", "t_pendClear",
        "t_kill", "t_read", "t_wal", "t_readOwned", "t_assert",
        "c_spawn", "c_record", "c_resume", "c_record2", "c_wait", "c_save",
        "p_probe", "p_kill", "p_pendClear", "p_release"}
RPCs == {"none", "r_load", "r_probe", "r_kill", "r_spawn", "r_record", "r_resume", "r_record2",
         "r_wait", "r_saveOk", "r_saveFail"}
Callers == {"none", "en", "re", "off", "stop"}

TypeOK ==
    /\ sd \in BOOLEAN /\ userSet \in BOOLEAN
    /\ jOwned \in BOOLEAN /\ jSettle \in 0..S /\ jPend \in {0} \cup Ids
    /\ pc \in PCs /\ memOwned \in BOOLEAN /\ memS \in 0..S /\ memPend \in {0} \cup Ids
    /\ hold \in BOOLEAN /\ assertHeld \in BOOLEAN /\ termPending \in BOOLEAN
    /\ caller \in Callers /\ active \in BOOLEAN /\ battLow \in BOOLEAN
    /\ child \in {"none"} \cup Vals /\ childPh \in {"none", "susp", "rec", "run"}
    /\ childId \in {0} \cup Ids /\ childRes \in {"none", "ok", "fail"}
    /\ nextId \in Ids /\ orphans \subseteq (Ids \X Vals \X OPhases)
    /\ rpc \in RPCs /\ calm \in BOOLEAN

Init ==
    /\ sd \in BOOLEAN /\ userSet = sd
    /\ jOwned = FALSE /\ jSettle = 0 /\ jPend = 0
    /\ pc = "down" /\ memOwned = FALSE /\ memS = 0 /\ memPend = 0
    /\ hold = FALSE /\ assertHeld = FALSE /\ termPending = FALSE /\ caller = "none"
    /\ active \in BOOLEAN /\ battLow \in BOOLEAN
    /\ child = "none" /\ childPh = "none" /\ childId = 0 /\ childRes = "none"
    /\ nextId = 1 /\ orphans = {}
    /\ rpc = "none" /\ calm = FALSE

\* JournalStore.save of the agent's in-memory journal: one atomic rename.
Save == jOwned' = memOwned /\ jSettle' = memS /\ jPend' = memPend

\* ProcessProbe.state(id): "gone" | "running" | "stopped". Only children of a
\* dead parent can be probed (own children are waited for). A SIGKILLed child
\* that is not yet reaped still exists and is not stopped: "running".
ProbeState(id) ==
    IF id = 0 \/ ~\E o \in orphans : o[1] = id THEN "gone"
    ELSE IF \E o \in orphans : o[1] = id /\ o[3] = "stopped" THEN "stopped"
    ELSE "running"

\* ProcessProbe.kill(id): SIGKILL. Only a stopped orphan is ever killed.
KillOrphan(id) ==
    orphans' = {IF o[1] = id /\ o[3] = "stopped" THEN <<o[1], o[2], "dying">> ELSE o
                : o \in orphans}

\* Kill a stopped pending child (mutant "noKillStopped" removes it).
KillStopped == Mutation # "noKillStopped"

\* The orphan guard is active (mutant "noOrphanGuard" removes it).
Guard == Mutation # "noOrphanGuard"

\* Possible results of isSleepDisabled(): the flag, or nil (unreadable).
\* Reads stop failing once the environment is calm.
ReadResults == LET v == IF sd THEN "true" ELSE "false"
               IN IF calm THEN {v} ELSE {v, "nil"}

\* lidwake has no claim on the flag (used only when UserRace = FALSE).
Quiet == ~jOwned /\ (pc = "down" \/ ~memOwned) /\ child = "none"
         /\ orphans = {} /\ rpc = "none"

\* Agent: next pc after lastActive is saved and the guard allows calls.
Branch == CASE hold /\ ~memOwned -> "t_read"
          [] hold /\ memOwned -> "t_readOwned"
          [] ~hold /\ (memOwned \/ Mutation = "clearUnowned") -> "c_spawn"
          [] OTHER -> "t_assert"
BranchCaller == IF ~hold /\ (memOwned \/ Mutation = "clearUnowned") THEN "off" ELSE caller

(***************************************************************************)
(* Environment                                                             *)
(***************************************************************************)
ToggleActive ==
    /\ ~calm /\ active' = ~active
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
ToggleBatt ==
    /\ battLow' = ~battLow
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, child, childPh,
                      childId, childRes, nextId, orphans, rpc, calm>>
BecomeCalm ==
    /\ ~calm /\ calm' = TRUE /\ active' = FALSE
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc>>
UserOn ==
    /\ ~calm /\ (UserRace \/ Quiet) /\ sd' = TRUE /\ userSet' = TRUE
    /\ UNCHANGED <<jOwned, jSettle, jPend, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
UserOff ==
    /\ ~calm /\ sd' = FALSE /\ userSet' = FALSE
    /\ UNCHANGED <<jOwned, jSettle, jPend, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
SigTerm ==
    /\ ~calm /\ pc # "down" /\ ~termPending /\ termPending' = TRUE
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, caller, active, battLow, child, childPh,
                      childId, childRes, nextId, orphans, rpc, calm>>

\* The parent of the live child dies. A child still suspended and not
\* recorded never runs (no flag effect, never probed). A recorded child that
\* was not resumed stays stopped. A resumed child keeps running.
\* An exit status nobody read is lost.
KillChild ==
    /\ orphans' = CASE child # "none" /\ childPh = "rec"
                        -> orphans \cup {<<childId, child, "stopped">>}
                   [] child # "none" /\ childPh = "run"
                        -> orphans \cup {<<childId, child, "running">>}
                   [] OTHER -> orphans
    /\ child' = "none" /\ childPh' = "none" /\ childId' = 0 /\ childRes' = "none"

Crash ==
    /\ ~calm /\ pc # "down" /\ pc' = "down" /\ assertHeld' = FALSE
    /\ caller' = "none" /\ KillChild
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, termPending, active, battLow, nextId, rpc, calm>>

\* launchd KeepAlive restarts the agent; new process, fresh memory.
Restart ==
    /\ pc = "down" /\ rpc = "none" /\ pc' = "s_load"
    /\ memOwned' = FALSE /\ memS' = 0 /\ memPend' = 0 /\ hold' = FALSE
    /\ assertHeld' = FALSE /\ termPending' = FALSE
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, caller, active, battLow,
                      child, childPh, childId, childRes, nextId, orphans, rpc, calm>>

(***************************************************************************)
(* pmset children finish                                                   *)
(***************************************************************************)
ChildOk ==
    /\ child # "none" /\ childPh = "run"
    /\ sd' = (child = "on") /\ child' = "none" /\ childPh' = "none" /\ childRes' = "ok"
    /\ UNCHANGED <<userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow,
                      childId, nextId, orphans, rpc, calm>>
ChildFail ==
    /\ ~calm /\ child # "none" /\ childPh = "run"
    /\ child' = "none" /\ childPh' = "none" /\ childRes' = "fail"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow,
                      childId, nextId, orphans, rpc, calm>>
\* A running orphan exits; a stopped orphan never runs by itself.
OrphanOk ==
    /\ \E o \in orphans : o[3] = "running" /\ sd' = (o[2] = "on") /\ orphans' = orphans \ {o}
    /\ UNCHANGED <<userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, rpc, calm>>
OrphanFail ==
    /\ ~calm /\ \E o \in orphans : o[3] = "running" /\ orphans' = orphans \ {o}
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, rpc, calm>>
\* A SIGKILLed stopped orphan is reaped (launchd); it never ran pmset.
OrphanReap ==
    /\ \E o \in orphans : o[3] = "dying" /\ orphans' = orphans \ {o}
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, rpc, calm>>

(***************************************************************************)
(* Controller.start(now): load the journal; keep owned, lastActive and     *)
(* pending. No flag read, no save, no pmset call.                          *)
(***************************************************************************)
SLoad ==
    /\ pc = "s_load" /\ pc' = "idle"
    /\ memOwned' = IF Mutation = "startDropsOwned" THEN FALSE ELSE jOwned
    /\ jOwned' = IF Mutation = "startDropsOwned" THEN FALSE ELSE jOwned
    /\ memS' = jSettle /\ memPend' = jPend
    /\ UNCHANGED <<sd, userSet, jSettle, jPend, hold, assertHeld, termPending,
                      caller, active, battLow, child, childPh, childId, childRes,
                      nextId, orphans, rpc, calm>>

(***************************************************************************)
(* Controller.tick(now) (SPEC 1 + 8)                                       *)
(***************************************************************************)
Eval ==
    /\ pc = "idle" /\ ~termPending
    /\ hold' = (~battLow /\ (active \/ memS > 0))
    /\ memS' = IF battLow THEN memS
               ELSE IF active THEN (IF Mutation = "typeOverflow" THEN S + 1 ELSE S)
               ELSE IF memS > 0 THEN memS - 1 ELSE 0
    /\ pc' = "t_saveLA"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memPend,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
\* save new lastActive; then the orphan guard, then branch on (hold, owned).
TSaveLA ==
    /\ pc = "t_saveLA" /\ Save
    /\ IF memPend # 0 /\ Guard
       THEN pc' = "t_probe" /\ UNCHANGED caller
       ELSE pc' = Branch /\ caller' = BranchCaller
    /\ UNCHANGED <<sd, userSet, memOwned, memS, memPend, hold, assertHeld,
                      termPending, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>
\* pending not gone => no setSleepDisabled call this tick; the assertion follows
\* hold. Stopped => kill it, then treat it like a running orphan.
TProbe ==
    /\ pc = "t_probe"
    /\ CASE ProbeState(memPend) = "gone" -> pc' = "t_pendClear" /\ memPend' = 0
       [] ProbeState(memPend) = "stopped" /\ KillStopped
            -> pc' = "t_kill" /\ UNCHANGED memPend
       [] OTHER -> pc' = "t_assert" /\ UNCHANGED memPend
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
TKill ==
    /\ pc = "t_kill" /\ KillOrphan(memPend) /\ pc' = "t_assert"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, rpc, calm>>
TPendClear ==
    /\ pc = "t_pendClear" /\ Save /\ pc' = Branch /\ caller' = BranchCaller
    /\ UNCHANGED <<sd, userSet, memOwned, memS, memPend, hold, assertHeld,
                      termPending, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>
\* hold && !owned: true => user's, leave it; nil => do not claim; false => claim.
TRead ==
    /\ pc = "t_read"
    /\ \E seen \in ReadResults :
       IF seen = "false" \/ (seen = "nil" /\ Mutation = "nilClaims")
       THEN /\ caller' = "en"
            /\ IF Mutation = "saveAfterPmset"
               THEN pc' = "c_spawn" /\ UNCHANGED memOwned
               ELSE pc' = "t_wal" /\ memOwned' = TRUE
       ELSE pc' = "t_assert" /\ UNCHANGED <<memOwned, caller>>
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memS, memPend, hold,
                      assertHeld, termPending, active, battLow, child, childPh,
                      childId, childRes, nextId, orphans, rpc, calm>>
\* write-ahead: save owned=true FIRST
TWal ==
    /\ pc = "t_wal" /\ Save /\ pc' = "c_spawn"
    /\ UNCHANGED <<sd, userSet, memOwned, memS, memPend, hold, assertHeld,
                      termPending, caller, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>
\* hold && owned: read false => setSleepDisabled(true) again; true/nil => no call.
TReadOwned ==
    /\ pc = "t_readOwned"
    /\ \E seen \in ReadResults :
       IF seen = "false" THEN pc' = "c_spawn" /\ caller' = "re"
       ELSE pc' = "t_assert" /\ UNCHANGED caller
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
\* assertion held iff the last outcome had hold=true (SPEC 8, last bullet)
TAssert ==
    /\ pc = "t_assert" /\ assertHeld' = hold /\ pc' = "idle" /\ caller' = "none"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, termPending, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>

(***************************************************************************)
(* setSleepDisabled(v, recorded:) called by the agent (SPEC 6 + 8)         *)
(***************************************************************************)
CallVal == IF caller \in {"en", "re"} THEN "on" ELSE "off"

CSpawn ==
    /\ pc = "c_spawn" /\ child = "none" /\ childRes = "none"
    /\ child' = CallVal /\ childPh' = "susp" /\ childId' = nextId
    /\ nextId' = IF nextId = 1 THEN 2 ELSE 1
    /\ pc' = IF Mutation = "recordAfterResume" THEN "c_resume" ELSE "c_record"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow,
                      childRes, orphans, rpc, calm>>
\* `recorded`: save pending = identity (with the owned value of this step)
CRecord ==
    /\ pc = "c_record" /\ memPend' = childId
    /\ jPend' = childId /\ jOwned' = memOwned /\ jSettle' = memS
    /\ childPh' = "rec" /\ pc' = "c_resume"
    /\ UNCHANGED <<sd, userSet, memOwned, memS, hold, assertHeld, termPending,
                      caller, active, battLow, child, childId, childRes, nextId,
                      orphans, rpc, calm>>
CResume ==
    /\ pc = "c_resume" /\ childPh' = "run"
    /\ pc' = IF Mutation = "recordAfterResume" THEN "c_record2" ELSE "c_wait"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childId, childRes, nextId, orphans, rpc, calm>>
\* mutant "recordAfterResume" only: the record save after the child runs
CRecord2 ==
    /\ pc = "c_record2" /\ memPend' = childId
    /\ jPend' = childId /\ jOwned' = memOwned /\ jSettle' = memS
    /\ pc' = "c_wait"
    /\ UNCHANGED <<sd, userSet, memOwned, memS, hold, assertHeld, termPending,
                      caller, active, battLow, child, childPh, childId, childRes,
                      nextId, orphans, rpc, calm>>
\* the call returns or throws; pending = nil with the outcome
CWait ==
    /\ pc = "c_wait" /\ childRes # "none" /\ childRes' = "none" /\ childId' = 0
    /\ memPend' = 0
    /\ memOwned' =
         CASE caller = "en" ->
                IF childRes = "ok"
                THEN (IF Mutation = "saveAfterPmset" THEN TRUE ELSE memOwned)
                ELSE FALSE                                  \* revert to owned=false
           [] caller \in {"off", "stop"} ->
                IF childRes = "ok" \/ Mutation = "dropOwnedOnFail"
                THEN FALSE ELSE memOwned                    \* throw: owned stays true
           [] OTHER -> memOwned                             \* "re": owned stays true
    /\ pc' = "c_save"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memS, hold, assertHeld,
                      termPending, caller, active, battLow, child, childPh, nextId,
                      orphans, rpc, calm>>
CSave ==
    /\ pc = "c_save" /\ Save
    /\ pc' = CASE caller = "stop" -> "p_release"
             [] caller = "en" /\ ~memOwned /\ Mutation = "noAssertOnFail" -> "idle"
             [] OTHER -> "t_assert"
    /\ UNCHANGED <<sd, userSet, memOwned, memS, memPend, hold, assertHeld,
                      termPending, caller, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>

(***************************************************************************)
(* Controller.stop() on SIGTERM/SIGINT, run between ticks (SPEC 8, 9)     *)
(***************************************************************************)
PBegin ==
    /\ pc = "idle" /\ termPending
    /\ pc' = CASE ~memOwned -> "p_release"
             [] memPend # 0 /\ Guard -> "p_probe"
             [] OTHER -> "c_spawn"
    /\ caller' = "stop"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
\* pending not gone => no call, owned stays true on disk
PProbe ==
    /\ pc = "p_probe"
    /\ CASE ProbeState(memPend) = "gone" -> pc' = "p_pendClear" /\ memPend' = 0
       [] ProbeState(memPend) = "stopped" /\ KillStopped
            -> pc' = "p_kill" /\ UNCHANGED memPend
       [] OTHER -> pc' = "p_release" /\ UNCHANGED memPend
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, rpc, calm>>
PKill ==
    /\ pc = "p_kill" /\ KillOrphan(memPend) /\ pc' = "p_release"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, rpc, calm>>
PPendClear ==
    /\ pc = "p_pendClear" /\ Save /\ pc' = "c_spawn"
    /\ UNCHANGED <<sd, userSet, memOwned, memS, memPend, hold, assertHeld,
                      termPending, caller, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>
PRelease ==
    /\ pc = "p_release" /\ assertHeld' = FALSE /\ pc' = "down" /\ caller' = "none"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, memOwned, memS, memPend,
                      hold, termPending, active, battLow, child, childPh, childId,
                      childRes, nextId, orphans, rpc, calm>>

(***************************************************************************)
(* `lidwake restore` (SPEC 9): separate process, run while the agent is    *)
(* not running. Pending stopped => kill it first. Pending not gone =>      *)
(* exit 75, nothing changed. Else only if                                  *)
(* owned: setSleepDisabled(false); success => owned=false; throw => owned  *)
(* stays true. The journal does not change between its load and its own  *)
(* saves (the agent is down), so later steps read the disk values.        *)
(***************************************************************************)
RStart ==
    /\ ~calm /\ pc = "down" /\ rpc = "none" /\ rpc' = "r_load"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
RLoad ==
    /\ rpc = "r_load"
    /\ rpc' = CASE jPend # 0 /\ Guard -> "r_probe"
              [] jOwned -> "r_spawn"
              [] OTHER -> "none"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
RProbe ==
    /\ rpc = "r_probe"
    /\ rpc' = CASE ProbeState(jPend) = "gone" -> IF jOwned THEN "r_spawn" ELSE "none"
              [] ProbeState(jPend) = "stopped" /\ KillStopped -> "r_kill"
              [] OTHER -> "none"                              \* exit 75
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
\* kill, then probe again: gone => go on; not yet reaped => exit 75
RKill ==
    /\ rpc = "r_kill" /\ KillOrphan(jPend) /\ rpc' = "r_probe"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, calm>>
RSpawn ==
    /\ rpc = "r_spawn" /\ child = "none" /\ childRes = "none"
    /\ child' = "off" /\ childPh' = "susp" /\ childId' = nextId
    /\ nextId' = IF nextId = 1 THEN 2 ELSE 1
    /\ rpc' = IF Mutation = "recordAfterResume" THEN "r_resume" ELSE "r_record"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow,
                      childRes, orphans, calm>>
RRecord ==
    /\ rpc = "r_record" /\ jPend' = childId /\ childPh' = "rec" /\ rpc' = "r_resume"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childId, childRes, nextId, orphans, calm>>
RResume ==
    /\ rpc = "r_resume" /\ childPh' = "run"
    /\ rpc' = IF Mutation = "recordAfterResume" THEN "r_record2" ELSE "r_wait"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childId, childRes, nextId, orphans, calm>>
RRecord2 ==
    /\ rpc = "r_record2" /\ jPend' = childId /\ rpc' = "r_wait"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
RWait ==
    /\ rpc = "r_wait" /\ childRes # "none" /\ childRes' = "none" /\ childId' = 0
    /\ rpc' = IF childRes = "ok" THEN "r_saveOk" ELSE "r_saveFail"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow, child,
                      childPh, nextId, orphans, calm>>
RSaveOk ==
    /\ rpc = "r_saveOk" /\ jPend' = 0 /\ jOwned' = FALSE /\ rpc' = "none"
    /\ UNCHANGED <<sd, userSet, jSettle, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
RSaveFail ==
    /\ rpc = "r_saveFail" /\ jPend' = 0 /\ rpc' = "none"
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, pc, memOwned, memS, memPend, hold,
                      assertHeld, termPending, caller, active, battLow, child,
                      childPh, childId, childRes, nextId, orphans, calm>>
RCrash ==
    /\ ~calm /\ rpc # "none" /\ rpc' = "none" /\ KillChild
    /\ UNCHANGED <<sd, userSet, jOwned, jSettle, jPend, pc, memOwned, memS, memPend,
                      hold, assertHeld, termPending, caller, active, battLow,
                      nextId, calm>>

(***************************************************************************)
(* Specification                                                           *)
(***************************************************************************)
DaemonStep == SLoad
    \/ Eval \/ TSaveLA \/ TProbe \/ TKill \/ TPendClear \/ TRead \/ TWal \/ TReadOwned
    \/ TAssert \/ CSpawn \/ CRecord \/ CResume \/ CRecord2 \/ CWait \/ CSave
    \/ PBegin \/ PProbe \/ PKill \/ PPendClear \/ PRelease
RestoreStep == RLoad \/ RProbe \/ RKill \/ RSpawn \/ RRecord \/ RResume \/ RRecord2 \/ RWait
    \/ RSaveOk \/ RSaveFail

Next == DaemonStep \/ RestoreStep
    \/ ToggleActive \/ ToggleBatt \/ BecomeCalm \/ UserOn \/ UserOff \/ SigTerm
    \/ Crash \/ Restart \/ ChildOk \/ ChildFail \/ OrphanOk \/ OrphanFail \/ OrphanReap
    \/ RStart \/ RCrash

\* Liveness hypothesis: agent and restore steps are not starved, launchd
\* restarts the agent, every resumed child (live or orphaned) eventually
\* exits, a killed child is eventually reaped (pmset failures and nil reads
\* stop once calm), and the environment eventually goes quiet (no activity,
\* crashes, user actions). A stopped orphan gets no fairness: it stays
\* stopped forever unless killed.
Fairness == WF_vars(DaemonStep) /\ WF_vars(RestoreStep) /\ WF_vars(Restart)
         /\ WF_vars(ChildOk) /\ WF_vars(OrphanOk) /\ WF_vars(OrphanReap)
         /\ WF_vars(BecomeCalm)

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
\* lidwake never turns SleepDisabled off while the user's intent is "on".
NeverClobberUser == [][~(sd /\ ~sd' /\ userSet')]_vars

\* A flag that is on against the user's intent is always backed by
\* owned=TRUE on disk. Stronger than "no such state while crashed": it
\* holds in every state, so no crash at any point can leak the flag.
NoOrphanHold == (sd /\ ~userSet) => jOwned

\* Between ticks, a running agent holds the assertion iff the last outcome held.
AssertionIffHold == pc = "idle" => (assertHeld = hold)

EventuallyRestored == <>[](sd = userSet)
=============================================================================
