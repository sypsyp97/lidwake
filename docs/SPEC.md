# lidwake — specification

Keep a MacBook awake with the lid closed while Claude Code work is active; restore normal sleep afterwards.
Swift 6 package, macOS 14+, native APIs only (Foundation, Darwin/libproc, IOKit, os.Logger). No third-party dependencies.
Library target `LidwakeCore` holds all logic (public API below). Executable `lidwake` is a thin CLI over it.
Tests use Swift Testing (`import Testing`) in `Tests/LidwakeCoreTests`. `Package.swift` is fixed; do not edit it.

Background (prior art read before design: jtc268/clamshell, pehqge/coffee, TurboKach/LidAwake, kafeifei/LidAwake, richardlinq/lidawake):
- Only `pmset -a disablesleep 1|0` (root) keeps a Mac awake with the lid closed. Power assertions alone do not.
- `SleepDisabled` is readable without root from the IORegistry entry `IOPMrootDomain`, property `"SleepDisabled"`.
- herdr socket `~/.config/herdr/herdr.sock`: newline-delimited JSON; request `{"id":"s1","method":"session.snapshot","params":{}}\n`; the server answers one line and closes the connection (no reuse possible).
  Response shape: `{"id":"s1","result":{"snapshot":{"agents":[{"pane_id":"w49:p1","agent":"claude","agent_status":"working", ...}, ...], ...}}}`. Status values: idle, working, blocked, done, unknown.
- Claude Code background tasks keep their output file open while they run: `/private/tmp/claude-<uid>/<project>/<session>/tasks/<id>.output`.

## 1. Decision (pure)
```swift
public struct PowerState: Equatable, Sendable { public var onBattery: Bool; public var chargePercent: Int?; public init(onBattery: Bool, chargePercent: Int?) }
public struct Inputs: Equatable, Sendable {
    public var forced: Bool          // manual "on"
    public var herdrWorking: Bool?   // nil = herdr unreachable
    public var backgroundTask: Bool  // a task output file is open
    public var power: PowerState
    public init(forced: Bool, herdrWorking: Bool?, backgroundTask: Bool, power: PowerState)
}
public enum Reason: String, Equatable, Sendable { case forced, herdrWorking, backgroundTask, settling, idle, batteryLow }
public struct Outcome: Equatable, Sendable { public var hold: Bool; public var reason: Reason; public var lastActive: Date?; public init(hold: Bool, reason: Reason, lastActive: Date?) }
public enum Decision {
    public static let defaultSettle: TimeInterval = 300
    public static let lowBatteryPercent = 20
    public static func evaluate(_ inputs: Inputs, now: Date, lastActive: Date?, settle: TimeInterval = defaultSettle) -> Outcome
}
```
Rules, in order:
1. batteryLow = `power.onBattery && (chargePercent == nil || chargePercent! < 20)`. If batteryLow: `hold=false, reason=.batteryLow`; lastActive unchanged. Battery low overrides everything, including forced.
2. active = forced || herdrWorking == true || backgroundTask. Reason priority when active: forced > herdrWorking > backgroundTask. Active ⇒ `hold=true`, `lastActive=now`.
3. Not active, lastActive != nil and `now - lastActive < settle` ⇒ `hold=true, reason=.settling`, lastActive unchanged.
4. Else `hold=false, reason=.idle`, lastActive unchanged.
On AC power the charge is ignored (AC with 5% still holds when active).

## 2. herdr snapshot parsing (pure)
```swift
public enum HerdrError: Error, Equatable { case malformed, timeout, tooLarge, connect(Int32), io(Int32) }
public enum HerdrSnapshot { public static func workingAgentCount(_ json: Data) throws -> Int }
```
Counts entries in `result.snapshot.agents` whose `agent_status == "working"`. Missing `agents` key (but valid `result.snapshot`) ⇒ 0. Not JSON, no `result`, or `result.snapshot` missing ⇒ throws `HerdrError.malformed`. An `error` object in the response (`{"id":..,"error":{...}}`) ⇒ `.malformed`.

## 3. herdr client (socket, bounded)
```swift
public struct HerdrClient: Sendable {
    public static let maxResponseBytes = 4 * 1024 * 1024
    public init(socketPath: String, timeout: TimeInterval = 2)
    public func snapshot() throws -> Data   // one connect, one request line, read to newline or EOF, close
}
```
- AF_UNIX stream socket via Darwin calls. Send/receive timeouts = `timeout` (SO_SNDTIMEO/SO_RCVTIMEO). Connect failure ⇒ `.connect(errno)`. No answer within timeout ⇒ `.timeout`. More than `maxResponseBytes` before newline/EOF ⇒ `.tooLarge`. Returned Data excludes the trailing newline.
- The socket fd is closed on every path (success, timeout, error). Repeated calls must not grow the process's open-fd count.
- Request line exactly: `{"id":"lidwake","method":"session.snapshot","params":{}}` + `\n`.

## 4. Background-task scan (libproc)
```swift
public struct TaskFileScanner: Sendable {
    public init(root: URL)   // e.g. /private/tmp/claude-501 ; the root may not exist yet at init. It is canonicalised (realpath of the deepest existing ancestor) on EACH scan, so /tmp, /var symlinks work and a root created or recreated later is found
    public func hasOpenTaskOutput() -> Bool
}
```
- True iff some process of the current uid (`proc_listpids(PROC_UID_ONLY, getuid())`, `PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`) has an open vnode whose path is under the canonical root, whose parent directory is named `tasks`, and whose extension is `.output`. Depth between root and `tasks` is free (≥ 0 levels).
- Not matching: file outside root; `.output` not in a `tasks` dir; other extensions; closed files; a path that merely starts with the root string (`/private/tmp/claude-5010/...` for root `/private/tmp/claude-501`).
- Processes that deny access (EPERM, exited mid-scan) are skipped silently. Buffers bounded by the counts libproc reports. Repeated scans must not grow memory or open fds.

## 5. Power source (IOKit)
```swift
public enum PowerSource {
    public static func parse(_ description: [String: Any]) -> PowerState   // pure
    public static func read() -> PowerState                               // IOPSCopyPowerSourcesInfo/List/Description
}
```
`parse`: `"Power Source State"` == `"Battery Power"` ⇒ onBattery true; `"AC Power"` ⇒ false; missing ⇒ false. Charge = `"Current Capacity" * 100 / "Max Capacity"` (Int, rounded down), nil if either missing or max ≤ 0; clamp to 0...100. `read()` on a Mac with no battery ⇒ `PowerState(onBattery: false, chargePercent: nil)`.

## 6. Sleep control + assertion (protocols; real impls not unit-tested)
```swift
public struct ProcessIdentity: Codable, Equatable, Sendable { public var pid: Int32; public var startTime: UInt64; public init(pid: Int32, startTime: UInt64) }  // startTime = sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID) kp_proc.p_starttime sec*1e6+usec (readable for root-owned sudo children as a normal user; PROC_PIDTBSDINFO is not), guards against pid reuse
public protocol SleepControl: Sendable {
    func isSleepDisabled() -> Bool?
    // Spawns the privileged child SUSPENDED, calls `recorded(identity)`, resumes it only if that returned normally, waits for it.
    // If `recorded` throws: the child is killed (SIGKILL) before it runs, and the error is rethrown. Nonzero child exit ⇒ throws.
    func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws
}
public enum ProcessState: Equatable, Sendable { case gone, running, stopped }
public protocol ProcessProbe: Sendable {
    func state(_ id: ProcessIdentity) -> ProcessState   // real (sysctl KERN_PROC_PID): gone unless pid exists AND p_starttime equals id.startTime; stopped iff kp_proc.p_stat == SSTOP
    func kill(_ id: ProcessIdentity)                     // SIGKILL, only if state(id) != .gone (identity re-checked first)
}
public struct LiveProcessProbe: ProcessProbe { public init() }
public protocol AssertionHolder: Sendable { func hold() throws; func release() }
public struct PmsetSleepControl: SleepControl { public init() }      // read: IORegistry IOPMrootDomain "SleepDisabled"; write: posix_spawn(POSIX_SPAWN_START_SUSPENDED) of /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0|1, then SIGCONT, waitpid; nonzero exit ⇒ throws
public final class PowerAssertion: AssertionHolder { public init(name: String) }  // IOPMAssertionCreateWithName(PreventUserIdleSystemSleep); release idempotent; deinit releases
```

## 7. Journal (state persisted across crashes)
```swift
public struct Journal: Codable, Equatable, Sendable { public var owned: Bool; public var lastActive: Date?; public var pending: ProcessIdentity?; public init(owned: Bool = false, lastActive: Date? = nil, pending: ProcessIdentity? = nil) }
public struct JournalStore: Sendable {
    public init(directory: URL)            // creates directory if needed; file "journal.json"
    public func load() -> Journal          // missing or corrupt file ⇒ Journal() (owned=false)
    public func save(_ j: Journal) throws  // atomic: write temp file, fsync it, rename over journal.json; never leaves a partial or temp file
}
```
`owned == true` means lidwake set `SleepDisabled=1` and has not restored it yet. `pending` = the privileged pmset child that may still be running (recorded before it is resumed). A journal written by an older version without `pending` loads with pending=nil.

## 8. Controller (orchestration, injected dependencies)
```swift
public protocol InputsProvider: Sendable { func inputs() -> Inputs }
public final class Controller {
    public init(provider: InputsProvider, sleep: SleepControl, assertion: AssertionHolder, store: JournalStore, probe: ProcessProbe, settle: TimeInterval = Decision.defaultSettle)
    public func start(now: Date)                 // reconcile after crash
    @discardableResult public func tick(now: Date) -> Outcome
    public func stop()                           // clean shutdown
}
```
- Every `setSleepDisabled` call goes through one path: its `recorded` callback saves `pending = identity` (with the owned value the step requires) BEFORE the child runs; after the call returns or throws, `pending = nil` is saved together with the outcome.
- Stopped orphan: a pending child that is `.stopped` was never resumed (crash between record and SIGCONT) and never ran pmset ⇒ the controller calls `probe.kill(pending)` and treats it like a running orphan until the probe reports `.gone`.
- Orphan guard (TLA+ WaitForOrphans): while `journal.pending != nil && probe.state(pending) != .gone`, the controller makes NO `setSleepDisabled` call (start, tick, stop). The assertion still follows hold. When the probe reports it gone, `pending = nil` is saved and normal rules apply from that tick. Reason: a pmset child of a crashed run can land after a later successful clear.
- `start`: load journal. If `owned`: keep owned=true and `lastActive` as they are, whatever `isSleepDisabled()` returns (a crashed run's pmset child may still land; ownership is only dropped after a successful `setSleepDisabled(false)`). If not owned: nothing.
- `tick`: evaluate Decision with journal.lastActive; save new lastActive.
  - hold && !owned: read `isSleepDisabled()`. `true` (set by the user, not us) ⇒ do not touch it, owned stays false. `nil` (unreadable) ⇒ do not claim; retry next tick. `false` ⇒ write-ahead: save owned=true FIRST, then `setSleepDisabled(true)`; on throw revert to owned=false and save (retry next tick).
  - hold && owned: if `isSleepDisabled() == false` (e.g. crash between write-ahead and pmset) ⇒ `setSleepDisabled(true)` again; throw ⇒ retry next tick. `true` or `nil` ⇒ no call.
  - !hold && owned: `setSleepDisabled(false)` (idempotent, called even if the flag already reads false or nil); on success owned=false and save; on throw owned stays true, retry next tick.
  - !hold && !owned: no call.
  - Never sets SleepDisabled=false unless owned.
- `stop`: if owned ⇒ `setSleepDisabled(false)`; success ⇒ owned=false and save; throw ⇒ owned stays true on disk (next start/tick retries), log. Always release assertion. Idempotent.
- Known limitation: if the user manually runs `pmset -a disablesleep 1` while lidwake owns the flag, lidwake cannot tell the two apart and clears it when idle. While lidwake does not own the flag, a user setting is never touched.
- The assertion is held iff the last outcome had hold=true, independent of whether setSleepDisabled succeeded (a failed enable still holds the assertion).

## 9. CLI (`lidwake`)
```swift
public enum Command: Equatable { case run(dryRun: Bool, ticks: Int?, interval: TimeInterval), status, on, off, restore }
public enum CLIParser { public static func parse(_ args: [String]) throws -> Command }  // args exclude argv[0]
public enum CommandError: Error, Equatable { case usage(String) }
```
- `run` (default interval 30 s), options `--dry-run` (no sudo/pmset; logs intended actions), `--ticks N` (stop after N ticks; N ≥ 1), `--interval S` (0 < S ≤ 86400; finite). `status`, `on`, `off`, `restore` take no options. Empty args or unknown command/option or bad number ⇒ `.usage(message)`.
- Usage error ⇒ message on stderr, exit status 64 (EX_USAGE).
- Single instance: `run` and `restore` take an exclusive non-blocking `flock` on `<stateDir>/lock` (fd opened O_CLOEXEC so spawned children never inherit it; file kept, never unlinked; lock held for the process lifetime, released by the kernel on exit/crash). Lock held by another process ⇒ stderr message, exit 75, nothing read or changed. `on`/`off`/`status` do not lock. A `run --dry-run` uses its own state (`<stateDir>/dry-run/`) and its own lock there, so it never blocks or is blocked by the real agent.
- `on` creates `<stateDir>/force`, `off` removes it (idempotent). Forced = file exists. State dir `~/.lidwake` (overridable by env `LIDWAKE_STATE_DIR`).
- `run`: Controller loop on a DispatchSourceTimer (leeway 5 s); SIGTERM/SIGINT ⇒ `stop()` then exit 0. One reused TaskFileScanner/HerdrClient instance; no per-tick unbounded allocations.
- `restore`: if `pending` is `.stopped` ⇒ kill it first, then poll `state` every 10 ms for up to 2 s until `.gone` (SIGKILL and reaping are asynchronous); if `pending` is still not `.gone` ⇒ stderr "pmset still running", exit 75, nothing changed. Else only if journal owned: `setSleepDisabled(false)`; success ⇒ owned=false, exit 0; throw ⇒ owned stays true, message on stderr, exit 1. Not owned ⇒ exit 0, nothing changed.
- Logging via `os.Logger(subsystem: "dev.lidwake", category: ...)` on state changes and errors.

## 10. Deliverables outside Swift
- `support/com.lidwake.agent.plist` (LaunchAgent: `lidwake run`, KeepAlive true, RunAtLoad true).
- `support/sudoers-lidwake`: NOPASSWD for exactly `/usr/bin/pmset -a disablesleep 0` and `/usr/bin/pmset -a disablesleep 1` for the installing user.
- `README.md`: install / uninstall / risks.

## Quality bars
- `swift build -Xswiftc -warnings-as-errors` clean; `swift format lint --strict` clean on Sources.
- No force-unwrap / force-try in Sources. Errors are thrown or logged, never swallowed without a log line.
- `leaks --atExit -- .build/debug/lidwake run --dry-run --ticks 20 --interval 0.05` reports 0 leaks.
