# lidwake feature map

Baseline preconditions for every file below:
- `swift build` in the tree under test; doctor green (see `SKILL.md`).
- `LW` = the tree's debug binary with `LIDWAKE_STATE_DIR=$ISO/state` and `CFFIXED_USER_HOME=$ISO/home`.
- Idle scenarios need zero open Claude Code task output files (doctor prints the count). With one open, every decision reads `backgroundTask`. A command run from a Claude Code Bash tool holds its own `tasks/*.output` file, so idle scenarios are unreachable from inside Claude Code: run them from a plain terminal while no Claude Code session runs a command. The task root (`/private/tmp/claude-<uid>`) has no override.

| file | area | status |
|---|---|---|
| `journal.md` | journal.json: load, unreadable recovery, temp file sweep, inspect | mapped |
| `decision.md` | run loop decisions on dry run: forced, settling, clock moved back | mapped |
| `journeys.md` | crash and restart, corrupt journal then restart | mapped |
| — | `restore` on an owned journal (real `sudo pmset`) | UNMAPPED: writes the live flag |
| — | non-dry `run` under launchd, sudoers rule, `support/install-root.sh` | UNMAPPED: writes the live flag, needs root |
| — | herdr socket input (`session.snapshot`) | UNMAPPED: needs a fake herdr socket under `$ISO/home/.config/herdr/` |

Sweep order: `journal.md`, `decision.md`, `journeys.md`.
