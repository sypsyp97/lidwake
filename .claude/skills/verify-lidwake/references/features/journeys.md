# Journeys

## Crash during save, then restart
1. `mkdir -p $ISO/state/dry-run`; write a valid journal there; add `journal.json.tmp-crash` (what a SIGKILL between create and rename leaves).
2. `LW run --dry-run --ticks 1 --interval 0.05`.
3. Evidence: `journal.json.tmp-crash` gone, journal valid, other files kept.
4. Round trip: second `LW run --dry-run --ticks 1` ⇒ same listing (no new files), same `owned`.

## SIGKILL between the temp write and the rename of a real save
1. Valid unowned journal in `$ISO/state/dry-run/`.
2. `lldb -b -o "settings set target.env-vars LIDWAKE_STATE_DIR=$ISO/state CFFIXED_USER_HOME=$ISO/home" -o 'breakpoint set -n rename' -o 'process launch -- run --dry-run --ticks 1 --interval 0.05' -o 'bt 5' -o "platform shell ls -A $ISO/state/dry-run" -o 'process kill' .build/debug/lidwake`
3. Evidence: backtrace shows `JournalStore.save` under `Controller.tick`; the listing shows the real `journal.json.tmp-<uuid>`; after the kill the file is still there.
4. Restart: `LW run --dry-run --ticks 1 --interval 0.05` ⇒ that exact file is gone, journal valid. This is the only check that ties the name `save` writes to the name the sweep deletes.

## Corrupt journal, restart, restart again
1. Garbage journal in `$ISO/state/dry-run/`.
2. `LW run --dry-run --ticks 1` ⇒ one `journal.json.corrupt-*` copy, journal valid.
3. Second run ⇒ no second copy (journal is valid now), same decisions for the same inputs.

## Live agent untouched
Before and after every journey: `launchctl print gui/$(id -u)/com.lidwake.agent` pid unchanged. Do not compare `~/.lidwake/journal.json` hashes: the live agent rewrites `lastActive` on its own ticks. Isolation evidence = every command carries `LIDWAKE_STATE_DIR` and `CFFIXED_USER_HOME`.
