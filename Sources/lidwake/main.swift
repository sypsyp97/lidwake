import Darwin
import Foundation
import LidwakeCore
import os

private let log = Logger(subsystem: "dev.lidwake", category: "cli")

/// Live inputs: force file, herdr socket, open task files, internal battery.
struct SystemInputs: InputsProvider {
  let forceFile: URL
  let herdr: HerdrClient
  let scanner: TaskFileScanner

  func inputs() -> Inputs {
    Inputs(
      forced: FileManager.default.fileExists(atPath: forceFile.path),
      herdrWorking: herdrWorking(),
      backgroundTask: scanner.hasOpenTaskOutput(),
      power: PowerSource.read())
  }

  private func herdrWorking() -> Bool? {
    do {
      return try HerdrSnapshot.workingAgentCount(herdr.snapshot()) > 0
    } catch {
      log.debug("herdr unreachable: \(String(describing: error), privacy: .public)")
      return nil
    }
  }
}

/// Dry run: reads the real flag once, then only simulates and prints writes. This process
/// stands in for the pmset child, so the journal path runs as in a real write.
final class DryRunSleepControl: SleepControl {
  private let state: OSAllocatedUnfairLock<Bool?>

  init(initial: Bool?) {
    state = OSAllocatedUnfairLock(initialState: initial)
  }

  func isSleepDisabled() -> Bool? { state.withLock { $0 } }

  func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws {
    guard let me = ProcessIdentity(running: getpid()) else { throw DryRunError.noIdentity }
    try recorded(me)
    print("dry-run: would run /usr/bin/sudo -n /usr/bin/pmset -a disablesleep \(on ? 1 : 0)")
    state.withLock { $0 = on }
  }
}

enum DryRunError: Error {
  case noIdentity
}

/// Conditions that a later retry can clear; they exit with 75 (EX_TEMPFAIL).
enum Busy: Error, CustomStringConvertible {
  /// `restore` refuses to race a pmset child that has not ended yet.
  case pmsetRunning(pid: Int32)
  /// Another `run` or `restore` holds the state directory's lock.
  case locked(path: String)

  var description: String {
    switch self {
    case .pmsetRunning(let pid): "pmset still running (pid \(pid))"
    case .locked(let path): "another lidwake instance holds \(path)"
    }
  }
}

/// Takes an exclusive, non-blocking flock on `<directory>/lock` for the rest of the process.
/// The descriptor stays open on purpose: the kernel releases the lock on exit or crash.
func lockInstance(in directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let path = directory.appendingPathComponent("lock").path
  let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
    let code = errno
    close(fd)
    guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    throw Busy.locked(path: path)
  }
}

struct DryRunAssertion: AssertionHolder {
  func hold() {}
  func release() {}
}

@MainActor
final class Runner {
  private let controller: Controller
  private let remaining: Int?
  private let dryRun: Bool
  private var count = 0

  init(controller: Controller, ticks: Int?, dryRun: Bool) {
    self.controller = controller
    self.remaining = ticks
    self.dryRun = dryRun
  }

  func tick() {
    let outcome = controller.tick(now: Date())
    count += 1
    if dryRun {
      print("tick \(count): hold=\(outcome.hold) reason=\(outcome.reason.rawValue)")
    }
    if let remaining, count >= remaining { shutdown() }
  }

  func shutdown() -> Never {
    controller.stop()
    exit(0)
  }
}

func stateDirectory() -> URL {
  if let custom = ProcessInfo.processInfo.environment["LIDWAKE_STATE_DIR"], !custom.isEmpty {
    return URL(fileURLWithPath: custom, isDirectory: true)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lidwake")
}

func systemInputs(stateDir: URL) -> SystemInputs {
  let home = FileManager.default.homeDirectoryForCurrentUser
  return SystemInputs(
    forceFile: stateDir.appendingPathComponent("force"),
    herdr: HerdrClient(socketPath: home.appendingPathComponent(".config/herdr/herdr.sock").path),
    scanner: TaskFileScanner(root: URL(fileURLWithPath: "/private/tmp/claude-\(getuid())")))
}

@MainActor
func run(dryRun: Bool, ticks: Int?, interval: TimeInterval, stateDir: URL) throws -> Never {
  // A dry run keeps its own journal and lock so it never claims the real flag or blocks
  // the real agent.
  let directory = dryRun ? stateDir.appendingPathComponent("dry-run") : stateDir
  try lockInstance(in: directory)
  let sleep: SleepControl =
    dryRun
    ? DryRunSleepControl(initial: PmsetSleepControl().isSleepDisabled()) : PmsetSleepControl()
  let assertion: AssertionHolder =
    dryRun ? DryRunAssertion() : PowerAssertion(name: "lidwake: Claude Code work active")
  let store = JournalStore(directory: directory)
  let controller = Controller(
    provider: systemInputs(stateDir: stateDir), sleep: sleep, assertion: assertion, store: store,
    probe: LiveProcessProbe())
  controller.start(now: Date())
  let runner = Runner(controller: controller, ticks: ticks, dryRun: dryRun)

  let signals = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { runner.shutdown() } }
    source.resume()
    return source
  }
  let timer = DispatchSource.makeTimerSource(queue: .main)
  timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(5))
  timer.setEventHandler { MainActor.assumeIsolated { runner.tick() } }
  timer.resume()
  log.info("running interval=\(interval, privacy: .public)s dryRun=\(dryRun, privacy: .public)")
  // The main run loop keeps main-queue work on the main thread (dispatchMain does not),
  // which MainActor.assumeIsolated requires.
  while true { withExtendedLifetime((signals, timer)) { CFRunLoopRun() } }
}

func status(stateDir: URL) {
  let inputs = systemInputs(stateDir: stateDir).inputs()
  let journal = JournalStore(directory: stateDir).load()
  let outcome = Decision.evaluate(inputs, now: Date(), lastActive: journal.lastActive)
  let herdr = inputs.herdrWorking.map { $0 ? "working" : "not working" } ?? "unreachable"
  let charge = inputs.power.chargePercent.map { "\($0)%" } ?? "unknown"
  let disabled = PmsetSleepControl().isSleepDisabled().map { $0 ? "1" : "0" } ?? "unknown"
  print(
    """
    forced: \(inputs.forced)
    herdr: \(herdr)
    background task: \(inputs.backgroundTask)
    power: \(inputs.power.onBattery ? "battery" : "AC"), charge \(charge)
    SleepDisabled: \(disabled)
    journal: owned=\(journal.owned) lastActive=\(journal.lastActive.map { "\($0)" } ?? "none") \
    pending=\(journal.pending.map { "pid \($0.pid)" } ?? "none")
    decision: hold=\(outcome.hold) reason=\(outcome.reason.rawValue)
    """)
}

/// True once `id` is gone. A stopped child was never resumed and never ran pmset, so it is
/// killed; SIGKILL and reaping are asynchronous, so its end is polled every 10 ms for 2 s.
func isGone(afterEndingStopped id: ProcessIdentity) -> Bool {
  let probe = LiveProcessProbe()
  let state = probe.state(id)
  guard state == .stopped else { return state == .gone }
  probe.kill(id)
  let deadline = Date().addingTimeInterval(2)
  while probe.state(id) != .gone, Date() < deadline { usleep(10_000) }
  return probe.state(id) == .gone
}

/// Clears an owned flag through the same recorded path as the controller: the child's
/// identity is saved before it runs, and `pending = nil` is saved with the outcome.
func restore(stateDir: URL) throws {
  try lockInstance(in: stateDir)
  let store = JournalStore(directory: stateDir)
  var journal = store.load()
  if let pending = journal.pending, !isGone(afterEndingStopped: pending) {
    throw Busy.pmsetRunning(pid: pending.pid)
  }
  guard journal.owned else {
    print("nothing to restore: lidwake does not own SleepDisabled")
    return
  }
  let result = Result {
    try PmsetSleepControl().setSleepDisabled(false) { identity in
      journal.pending = identity
      try store.save(journal)
    }
  }
  journal.pending = nil
  if case .success = result { journal.owned = false }
  try store.save(journal)
  try result.get()
  print("SleepDisabled=0 restored")
}

func setForced(_ on: Bool, stateDir: URL) throws {
  let file = stateDir.appendingPathComponent("force")
  if on {
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try Data().write(to: file)
  } else {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
      // Already off.
    }
  }
}

do {
  let stateDir = stateDirectory()
  switch try CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {
  case .run(let dryRun, let ticks, let interval):
    try run(dryRun: dryRun, ticks: ticks, interval: interval, stateDir: stateDir)
  case .status: status(stateDir: stateDir)
  case .on: try setForced(true, stateDir: stateDir)
  case .off: try setForced(false, stateDir: stateDir)
  case .restore: try restore(stateDir: stateDir)
  }
} catch CommandError.usage(let message) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(64)
} catch let busy as Busy {
  FileHandle.standardError.write(Data("lidwake: \(busy)\n".utf8))
  exit(75)
} catch {
  log.error("\(String(describing: error), privacy: .public)")
  FileHandle.standardError.write(Data("lidwake: \(error)\n".utf8))
  exit(1)
}
