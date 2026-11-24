---
name: verify-lidwake
description: "Drive the lidwake CLI through its production entry points on isolated state and collect side-effect evidence (journal bytes, files, exit codes, stdout). Use to prove a lidwake change works and for regression sweeps. Never drives the installed LaunchAgent or real pmset writes."
---

# Verify lidwake

## Pick a flow
- Installed agent (`/usr/local/bin/lidwake`, LaunchAgent `com.lidwake.agent`, state `~/.lidwake`): read-only. Never drive it, never write `~/.lidwake`, never run `restore` against it.
- Tree under test: build it, then run its binary with an isolated state dir and home on every command:

```bash
cd <worktree> && swift build
ISO=$(mktemp -d /tmp/verify.XXXXXX); mkdir -p "$ISO/state" "$ISO/home"
LW() { LIDWAKE_STATE_DIR="$ISO/state" CFFIXED_USER_HOME="$ISO/home" "$PWD/.build/debug/lidwake" "$@"; }
# cleanup: case $ISO in /tmp/verify.*) rm -rf "$ISO";; *) echo refuse;; esac
```

`CFFIXED_USER_HOME` moves the herdr socket path, so herdr reads as unreachable. `LIDWAKE_STATE_DIR` moves journal, lock and force file.

## Doctor
`LIDWAKE_STATE_DIR="$ISO/state" CFFIXED_USER_HOME="$ISO/home" .claude/skills/verify-lidwake/doctor.sh` prints, and exits 1 on any FAIL:
- identity: tree HEAD, Sources committed, debug binary newer than every source file (hash printed)
- isolation: state dir and home are not the live ones
- ownership: nobody holds `<state>/lock`
- live agent pid and real `SleepDisabled` (information only)
- inputs isolation cannot hide: open Claude Code task output files, power source

## Command surface
| category | command | evidence |
|---|---|---|
| inspect | `LW status` | stdout lines `journal:` and `decision:`; state dir unchanged |
| drive | `LW run --dry-run --ticks N --interval 0.05` | stdout `tick k: hold=… reason=…`; files in `$ISO/state/dry-run/` |
| drive | `LW on` / `LW off` | `$ISO/state/force` exists / absent |
| drive, needs sudo | `LW restore` | only with `owned=false` (no pmset); owned or unreadable journal runs real `sudo pmset` ⇒ not driven |

## Proof bar
- Production entry only: the built `lidwake` binary with argv. Calling `LidwakeCore` from a script is inspection, not proof.
- Evidence = journal bytes (`python3 -m json.tool`), file listing (`ls -la`), exit code, stdout. Then a round trip: a second process (`status` or another `run --dry-run`) reads the same state.
- `swift test --sanitize thread` leaves a TSan binary in `.build/debug`; run `swift build` again before `leaks --atExit`, which cannot inspect a TSan heap.
- A non-dry `run` and `restore` on an owned journal write the real machine-wide `SleepDisabled`. Not driven; name them as unreachable here and cover them with the dry-run path, which goes through the same journal code.

## Feature map
`references/features/README.md` is the index and the sweep order.
