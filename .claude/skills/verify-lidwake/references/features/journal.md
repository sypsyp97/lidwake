# Journal

`<state>/journal.json` records whether lidwake owns `SleepDisabled`, the last active time, and a pending pmset child. Dry runs use `<state>/dry-run/journal.json`.

## Sub-features
- load: missing ⇒ `Journal()`; valid ⇒ as saved.
- unreadable recovery (SPEC §7 revision 5): copy exact bytes to `journal.json.corrupt-*`, save `owned=true`, load as owned.
- stale temp sweep: `run` and `restore`, under the lock, delete `journal.json.tmp-*` and nothing else.
- inspect: `status` reads without writing; unreadable prints a `journal:` line containing `unreadable`.
- kept copies: `status` prints `kept unreadable journals: <n> (<names sorted>)` when `<state>` holds `journal.json.corrupt-*` files (names `journal.json.corrupt-<yyyyMMdd'T'HHmmss'Z'>-<uuid>`, UTC).

## How to reach it
`lidwake run [--dry-run]` (start), `lidwake restore`, `lidwake status`.

## Driving it
```bash
printf 'garbage{' > "$ISO/state/journal.json"; ls -la "$ISO/state" > "$ISO/before"
LW status; echo rc=$?                          # journal: unreadable (...); rc=0
ls -la "$ISO/state" | diff "$ISO/before" -    # empty: status wrote nothing

mkdir -p "$ISO/state/dry-run"; printf 'garbage{' > "$ISO/state/dry-run/journal.json"
: > "$ISO/state/dry-run/journal.json.tmp-stale"; : > "$ISO/state/dry-run/keep.txt"
LW run --dry-run --ticks 1 --interval 0.05; echo rc=$?
ls "$ISO/state/dry-run"                        # journal.json, journal.json.corrupt-<uuid>, keep.txt, lock; no tmp-stale
cmp "$ISO/state/dry-run"/journal.json.corrupt-* <(printf 'garbage{')   # identical bytes
LIDWAKE_STATE_DIR="$ISO/state/dry-run" CFFIXED_USER_HOME="$ISO/home" .build/debug/lidwake status | grep 'kept unreadable journals: 1'
python3 -m json.tool "$ISO/state/dry-run/journal.json"                # valid journal
```
- Recovery as owned: with idle inputs and the real flag reading 1, the dry run prints `dry-run: would run /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0` (the old rule printed nothing and wrote `owned:false`).

## State
| location | lifetime | writers | readers | reset trigger | round-trip check |
|---|---|---|---|---|---|
| `<state>/journal.json` | disk, across restarts | `run` (Controller save), `restore` | `run` start, `restore`, `status` | a successful `pmset 0` writes `owned=false` | second `LW status` prints the same journal line |
| `<state>/journal.json.corrupt-*` | disk, never deleted by lidwake | load of an unreadable journal | the user | manual delete | bytes equal the corrupt input; a second corruption adds a second copy |
| `<state>/journal.json.tmp-*` | from create to rename in one save; survives a crash | `JournalStore.save` | nobody | next `run` / `restore` start | gone after the next `run --dry-run --ticks 1` |
| `<state>/lock` | process (flock), file kept | `run`, `restore` | kernel | process exit | `lsof -t <state>/lock` empty after exit |

## Gotchas
- `--dry-run` uses `<state>/dry-run/`, not `<state>/`: put test journals there.
- The dry run reads the real `SleepDisabled` once at start (the live agent may hold it at 1), then simulates. Its `would run` lines depend on that read.
- `status` builds a `JournalStore`, which creates a missing state directory. Compare listings of an existing directory.
- A chmod 000 journal cannot be copied: load still returns owned, journal.json stays as it was until the next save. Restore the mode before cleanup.
