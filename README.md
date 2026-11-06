# lidwake

lidwake keeps a MacBook awake with the lid closed while Claude Code work is active.
When the work stops, lidwake restores normal sleep.

## How it works

Every 30 seconds, lidwake reads these inputs:

- The force file `~/.lidwake/force` (`lidwake on` creates it, `lidwake off` removes it).
- The herdr socket `~/.config/herdr/herdr.sock`. One or more agents with status `working` count as active.
- Open Claude Code task output files `/private/tmp/claude-<uid>/**/tasks/*.output`. A running background task keeps its file open.
- The internal battery.

If one input is active, lidwake runs `sudo -n /usr/bin/pmset -a disablesleep 1`.
It also holds a `PreventUserIdleSystemSleep` power assertion.
After the work stops, lidwake waits 5 minutes. Then it runs `pmset -a disablesleep 0`.
On battery power below 20 % charge, lidwake always releases the hold.

lidwake writes `~/.lidwake/journal.json` before it sets the flag.
If lidwake stops unexpectedly, the next run reads the journal and keeps ownership of the flag.
It clears the flag at the next idle check, and it keeps the ownership until `pmset -a disablesleep 0` succeeds.
lidwake records each `pmset` child in the journal before the child runs. While a recorded child is still running, lidwake does not change the flag. A recorded child that is stopped never ran `pmset`, so lidwake kills it.
If the flag was already `1` before lidwake needed it, lidwake does not touch it.

## Install

1. Build the binary:

   ```sh
   swift build -c release
   sudo install -m 0755 .build/release/lidwake /usr/local/bin/lidwake
   ```

2. Install the sudoers rule. The rule allows only the two `pmset` commands:

   ```sh
   sed "s/USERNAME/$(id -un)/" support/sudoers-lidwake > /tmp/sudoers-lidwake
   sudo visudo -cf /tmp/sudoers-lidwake
   sudo install -m 0440 -o root -g wheel /tmp/sudoers-lidwake /etc/sudoers.d/lidwake
   rm /tmp/sudoers-lidwake
   ```

3. Test without changes to the system:

   ```sh
   lidwake status
   lidwake run --dry-run --ticks 3 --interval 1
   ```

4. Start the LaunchAgent:

   ```sh
   cp support/com.lidwake.agent.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lidwake.agent.plist
   ```

## Commands

| command | action |
|---|---|
| `lidwake run [--dry-run] [--ticks N] [--interval S]` | Run the control loop. `--dry-run` prints the `pmset` commands and does not run them. |
| `lidwake status` | Show the inputs, the `SleepDisabled` flag, the journal, and the decision. |
| `lidwake on` / `lidwake off` | Force the hold on, or remove the force. |
| `lidwake restore` | Run `pmset -a disablesleep 0` if lidwake owns the flag. If the command fails, lidwake keeps the ownership and exits with status 1. `restore` kills a recorded child that is stopped. If the child has not ended yet, `restore` changes nothing and exits with status 75; run it again. |

Set `LIDWAKE_STATE_DIR` to use a state directory other than `~/.lidwake`.
Logs go to the unified log: `log stream --predicate 'subsystem == "dev.lidwake"'`.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.lidwake.agent
lidwake restore
rm ~/Library/LaunchAgents/com.lidwake.agent.plist
sudo rm /etc/sudoers.d/lidwake /usr/local/bin/lidwake
rm -rf ~/.lidwake
pmset -g | grep SleepDisabled   # expect 0
```

## Risks

- A closed MacBook in a bag can overheat while it stays awake. Do not put the Mac in a bag while lidwake holds sleep.
- `SleepDisabled` is a system-wide setting, and it persists until a process clears it. If lidwake gets `SIGKILL` or the Mac loses power, the flag can stay set until lidwake starts again. Run `pmset -g | grep SleepDisabled` to check. Run `lidwake restore` to clear it; if the journal is gone, run `sudo pmset -a disablesleep 0`.
- lidwake cannot tell its own `SleepDisabled=1` from a `pmset -a disablesleep 1` that you run while lidwake owns the flag. In that case, lidwake clears the flag when the work stops.
- The sudoers rule lets every process of your user toggle `SleepDisabled` without a password.
- lidwake reads the battery state only every 30 seconds. The charge can drop below 20 % before the next check.

## Verification

- `swift test`: 156 tests (Swift Testing), written test-first from `docs/SPEC.md` by a separate author from the implementation. They cover the decision rules, the herdr client (timeouts, size cap, no fd leaks), the libproc task scanner, the journal, the controller's crash-recovery rules with fakes, real child processes for the orphan guard, and the CLI as a subprocess. No test calls `sudo` or changes `SleepDisabled`.
- `tla/`: a TLA+ model of the controller protocol, checked with TLC (`tla/check.sh`). Crashes may happen between any two steps; `pmset` may fail; the user may change the flag. Five properties hold (never undo a user setting, no unowned hold after a crash, sleep eventually restored, assertion follows hold, type safety), and ten deliberately broken variants are each caught. See `tla/README.md`.
- `leaks --atExit -- lidwake run --dry-run --ticks 20 --interval 0.05` reports 0 leaks.

## License

MIT
