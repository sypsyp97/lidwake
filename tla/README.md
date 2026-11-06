# TLA+ model of the lidwake Controller

`Lidwake.tla` models the crash-safety protocol in `docs/SPEC.md` §6 (SleepControl), §7 (Journal), §8 (Controller) and §9 (`run` / `stop` / `restore`), as amended in commits revision 3 (orphan guard) and revision 4 (kill stopped orphans).
The model was written from the spec only. No Swift source or test was read.

## Run

```sh
./check.sh       # base + mutations + limitation; exit 0 only when every run gives its expected result
./check.sh -v    # also print every TLC error trace
```

`check.sh` uses `$JAVA` (default `/opt/homebrew/opt/openjdk/bin/java`) and `$TLA_JAR` (default `~/.local/share/tla/tla2tools.jar`).
Each property is also checked in its own TLC run, so one violation does not hide another. The full run takes about 30 s.

## What the model contains

| Model variable | Meaning |
|---|---|
| `sd` | System flag `SleepDisabled` |
| `userSet` | The user's intent: the value of the last manual `pmset disablesleep` |
| `jOwned`, `jSettle`, `jPend` | `journal.json` on disk: `owned`, `lastActive` as remaining settle ticks, `pending` child identity (0 = nil) |
| `pc`, `memOwned`, `memS`, `memPend`, `hold`, `caller` | Agent process: program counter, in-memory journal, last `Outcome.hold`, which step is inside `setSleepDisabled` |
| `assertHeld` | Power assertion held by the agent |
| `termPending` | SIGTERM/SIGINT received, `stop()` not yet run |
| `active`, `battLow` | Decision inputs (environment, nondeterministic) |
| `child`, `childPh`, `childId`, `childRes` | `sudo pmset` child of the agent or of `restore`: value, phase (suspended / recorded / resumed), identity, unread exit status |
| `nextId` | Identity of the next child; identities are never reused (pid + start time) |
| `orphans` | Recorded children whose parent crashed: set of `<<identity, value, phase>>`, phase `stopped` (never resumed), `running`, or `dying` (SIGKILLed while stopped, not yet reaped) |
| `rpc` | `lidwake restore` process |
| `calm` | Liveness hypothesis: the environment has gone quiet for good |

`setSleepDisabled(v, recorded:)` is five atomic steps:

1. spawn the child suspended (`childPh = "susp"`);
2. `recorded`: save the journal with `pending = identity` and the owned value of the step;
3. resume the child (`"run"`); the child then exits with success (flag set to `v`) or failure;
4. the call returns or throws: the parent reads the exit status;
5. save the journal with `pending = nil` and the outcome.

A crash before step 2 leaves a stopped child with no flag effect that nothing probes. A crash between step 2 and step 3 leaves a recorded orphan that stays stopped forever unless killed. A crash after step 3 leaves a running orphan that can land at any later time.

`probe.state(pending)` is `gone` when no orphan has that identity, `stopped` when it is stopped, else `running` (a killed child that is not yet reaped also reads `running`). `probe.kill(pending)` SIGKILLs a stopped orphan; it never runs pmset and is reaped later.

Agent steps, each atomic:

- `start()`: load the journal (owned, `lastActive`, pending). No flag read, no save, no pmset call.
- `tick()`: evaluate → save `lastActive` → orphan guard → branch on (`hold`, `owned`) → set the assertion to `hold`.
  - Orphan guard: if `pending != nil`, probe. `stopped` → kill it, no `setSleepDisabled` call this tick. `running` → no call this tick. `gone` → save `pending = nil`, then branch.
  - `hold && !owned`: read flag. `true` or nil → no claim. `false` → write-ahead save `owned=true` → call `pmset 1` → on failure `owned=false`.
  - `hold && owned`: read flag. `false` → call `pmset 1` (owned stays true). `true` or nil → no call.
  - `!hold && owned`: call `pmset 0` (no read) → on success `owned=false`.
- `stop()`: if owned: orphan guard (`stopped` → kill; not `gone` → no call, owned stays true) → call `pmset 0` → on success `owned=false` → release assertion → exit.
- `restore`: load journal → probe pending. `stopped` → kill, probe again. Not `gone` → exit 75, nothing changed. `gone` and owned → call `pmset 0` → success `owned=false`.

The model always allows these environment events, between any two steps:

- a crash of the agent or of `restore`; the kernel releases the assertion;
- a running orphaned `pmset` child landing at any later time, or failing; a stopped orphan never runs by itself;
- a failed `pmset` call in `tick`, `stop` or `restore`;
- a nil result from `isSleepDisabled()`;
- SIGTERM, input changes, and `pmset disablesleep 0` by the user;
- `pmset disablesleep 1` by the user, but only while lidwake has no claim on the flag (`UserRace = FALSE`).

launchd `KeepAlive` restarts the agent; a restart runs `start()`.

## Abstractions and assumptions

- Time: `lastActive` is a counter of remaining settle ticks, 0..`S` (`S = 2`). Active sets it to `S`; each settling tick subtracts 1.
- Battery low is one boolean input. It forces `hold = false` and leaves the counter unchanged (SPEC §1 rule 1).
- `forced`, herdr and background tasks are one boolean input, `active`.
- SIGTERM is handled between ticks, not inside a tick (SPEC §9: a dispatch source on the run loop).
- `restore` runs only while the agent is not running. The agent does not restart while `restore` runs.
- Journal saves and the `recorded` save do not fail.
- The probe is exact: identities are not reused (`ProcessIdentity` start time).
- Two identities (`Ids = {1, 2}`) alternate. In the base model at most one child exists at a time, so two are enough.
- `AssertionHolder.hold()` does not throw.
- Liveness hypothesis (`calm`): eventually no activity, no user action, no crash, no SIGTERM, no `pmset` failure and no nil read. Agent steps, `restore` steps, launchd restarts, `pmset` successes of resumed children (live and orphaned) and the reaping of killed children are weakly fair. A stopped orphan gets no fairness: it stays stopped forever unless lidwake kills it. The battery input can still change after `calm`.
- `probe.kill` of a stopped child always succeeds. The real kill can fail (for example a permission error on the root-owned `sudo` child); the model does not check that case.

## Properties

| Name | Kind | Statement |
|---|---|---|
| `TypeOK` | invariant | Every variable stays in its domain |
| `NoOrphanHold` | invariant | `(sd /\ ~userSet) => jOwned`: a flag that is on against the user's intent always has `owned=true` on disk. This holds in every state, so a crash at any point cannot leak the flag. It is stronger than "no such state while the process is down". |
| `AssertionIffHold` | invariant | Between ticks, the agent holds the assertion iff the last outcome had `hold = true` |
| `NeverClobberUser` | action | `[][~(sd /\ ~sd' /\ userSet')]_vars`: lidwake never turns the flag off while the user's intent is on |
| `EventuallyRestored` | temporal | `<>[](sd = userSet)` under the fairness and `calm` hypothesis |

## Constants

| Constant | Meaning |
|---|---|
| `UserRace` | TRUE: the user can run `pmset disablesleep 1` at any instant. FALSE (base): only while lidwake has no claim (`Quiet`: journal not owned, no child, no orphan, no `restore` running). SPEC §8 accepts the TRUE case as a known limitation. |
| `Mutation` | `"none"` or one seeded bug (`Lidwake_bug.tla`) |

## Results (TLC 2026.09.23, 18 workers, 2026-11-06, Spec revision 4)

`./check.sh` exits 0.

### Base (`Lidwake.cfg`): all five properties hold

```
Model checking completed. No error has been found.
427000 states generated, 82920 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 49.
```

### Mutations (`Lidwake_bug.tla`): each seeded bug is caught by its property

| Mutation | Property | TLC result |
|---|---|---|
| `saveAfterPmset`: save `owned=true` after `pmset 1` (no write-ahead) | `NoOrphanHold` | violated, 1127 distinct, depth 13 |
| `startDropsOwned`: `start()` drops owned (rule before revision 2) | `NoOrphanHold` | violated, 2678 distinct, depth 16 |
| `noOrphanGuard`: no probe of `pending` in tick, stop, restore | `NoOrphanHold` | violated, 13057 distinct, depth 21 |
| `recordAfterResume`: save `pending` after the child is resumed | `NoOrphanHold` | violated, 11862 distinct, depth 20 |
| `nilClaims`: a nil read claims the flag (rule before revision 2) | `NeverClobberUser` | violated, 4899 distinct, depth 17 |
| `clearUnowned`: `!hold` clears the flag also when not owned | `NeverClobberUser` | violated, 916 distinct, depth 11 |
| `dropOwnedOnFail`: a failed `pmset 0` sets `owned=false` | `EventuallyRestored` | violated, 86448 distinct, depth 49 |
| `noKillStopped`: a stopped pending child is not killed (rule before revision 4) | `EventuallyRestored` | violated, 72768 distinct, depth 50 |
| `noAssertOnFail`: a failed enable skips the assertion step | `AssertionIffHold` | violated, 2156 distinct, depth 15 |
| `typeOverflow`: settle counter set to `S+1` | `TypeOK` | violated, 158 distinct, depth 7 |

`noKillStopped` trace (only changed variables shown): the flag is on and owned → `restore` spawns `pmset 0` → `RRecord jPend=1` → `RCrash orphans={<<1,"off","stopped">>}` → `BecomeCalm` → restart → `SLoad memPend=1` → every tick `TProbe` sees `stopped` and makes no call → loop with `sd=TRUE, userSet=FALSE` forever.
`noOrphanGuard` trace: `CRecord jPend=1` for `pmset 1` → `Crash` → `restore` calls `pmset 0` without a probe → `RSaveOk jOwned=FALSE` → the running orphan lands, `sd=TRUE`.
`recordAfterResume` trace: `CResume` before the record → `Crash` with `jPend=0` → `restore` sees no pending → `pmset 0` succeeds → `RSaveOk jOwned=FALSE` → the orphan lands, `sd=TRUE`.

TLC runs with 18 workers, so the state counts of violated runs and the reported counterexamples can differ between runs.

### Limitation (`UserRace = TRUE`)

`TypeOK`, `NoOrphanHold`, `AssertionIffHold` hold (1023296 states generated, 175656 distinct). `NeverClobberUser` (depth 16) and `EventuallyRestored` fail, as SPEC §8 states: lidwake cannot tell its own `1` from a user's `1` set while it owns the flag.

## History

- SPEC before revision 2: five gaps (user race; `start` dropped ownership before a crashed `pmset 1` landed; `stop` and `restore` dropped ownership after a failed `pmset 0`; nil reads treated as false).
- Spec revision 2: closed four, documented the user race. The model then found that an orphaned `pmset 1` can land after a later successful `pmset 0` (through tick, `stop` and `restore`).
- Spec revision 3: orphan guard (record the child before it runs, no `setSleepDisabled` call while it is alive). All properties hold under the assumption that every orphan eventually exits. A child recorded but not resumed stays stopped, so that assumption can fail.
- Spec revision 4: kill a stopped pending child. The model drops the assumption for stopped orphans; all properties hold.
