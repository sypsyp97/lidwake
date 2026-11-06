import Darwin

/// A process, told apart from a later process that reuses its pid by its start time.
public struct ProcessIdentity: Codable, Equatable, Sendable {
  public var pid: Int32
  /// Start time in microseconds since the epoch.
  public var startTime: UInt64

  public init(pid: Int32, startTime: UInt64) {
    self.pid = pid
    self.startTime = startTime
  }

  /// The identity of the process that has `pid` now; nil when no such process exists.
  public init?(running pid: Int32) {
    guard let info = processInfo(pid) else { return nil }
    self.init(info, pid: pid)
  }

  private init(_ info: kinfo_proc, pid: Int32) {
    let start = info.kp_proc.p_un.__p_starttime
    self.init(pid: pid, startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
  }

  /// `.gone` unless the pid exists with this start time; `.stopped` iff it is in SSTOP.
  var state: ProcessState {
    guard let info = processInfo(pid), ProcessIdentity(info, pid: pid) == self else {
      return .gone
    }
    return info.kp_proc.p_stat == SSTOP ? .stopped : .running
  }
}

/// Uses `sysctl(KERN_PROC_PID)`, which also reads processes of other users, such as a
/// setuid-root `sudo` child. `PROC_PIDTBSDINFO` refuses those to a non-root caller.
private func processInfo(_ pid: Int32) -> kinfo_proc? {
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
  return info
}

public enum ProcessState: Equatable, Sendable {
  case gone, running, stopped
}

public protocol ProcessProbe: Sendable {
  func state(_ id: ProcessIdentity) -> ProcessState
  /// SIGKILL, only while `id` still names a live process.
  func kill(_ id: ProcessIdentity)
}

public struct LiveProcessProbe: ProcessProbe {
  public init() {}

  public func state(_ id: ProcessIdentity) -> ProcessState {
    id.state
  }

  /// The identity is re-checked right before the signal, so a reused pid is not hit.
  public func kill(_ id: ProcessIdentity) {
    guard id.state != .gone else { return }
    Darwin.kill(id.pid, SIGKILL)
  }
}

/// Runs `arguments` as a child that starts suspended. `recorded` gets the child's identity
/// before the child runs; if it throws, the child is killed unrun and the error is rethrown.
/// Throws when the child does not exit with status 0.
func runSuspended(_ arguments: [String], recorded: (ProcessIdentity) throws -> Void) throws {
  let pid = try spawnSuspended(arguments)
  do {
    guard let identity = ProcessIdentity(running: pid) else {
      throw SleepControlError(detail: "cannot read the start time of pid \(pid)")
    }
    try recorded(identity)
  } catch {
    kill(pid, SIGKILL)
    _ = waitStatus(pid)
    throw error
  }
  kill(pid, SIGCONT)
  let status = waitStatus(pid)
  guard status == 0 else {
    throw SleepControlError(
      detail: "\(arguments.joined(separator: " ")) ended with wait status \(status)")
  }
}

/// stdin, stdout and stderr go to /dev/null; no other descriptor is inherited.
private func spawnSuspended(_ arguments: [String]) throws -> pid_t {
  var attributes: posix_spawnattr_t?
  var actions: posix_spawn_file_actions_t?
  try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
  defer { posix_spawnattr_destroy(&attributes) }
  try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
  defer { posix_spawn_file_actions_destroy(&actions) }
  let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT)
  try check(posix_spawnattr_setflags(&attributes, flags), "posix_spawnattr_setflags")
  for (fd, mode) in [
    (STDIN_FILENO, O_RDONLY), (STDOUT_FILENO, O_WRONLY), (STDERR_FILENO, O_WRONLY),
  ] {
    try check(
      posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0),
      "posix_spawn_file_actions_addopen")
  }
  let argv = arguments.map { strdup($0) }
  defer { for arg in argv { free(arg) } }
  var pid: pid_t = 0
  try check(
    posix_spawn(&pid, arguments[0], &actions, &attributes, argv + [nil], environ),
    "posix_spawn \(arguments[0])")
  return pid
}

private func check(_ result: Int32, _ call: String) throws {
  guard result == 0 else {
    throw SleepControlError(detail: "\(call): \(String(cString: strerror(result)))")
  }
}

/// The raw `waitpid` status (0 = exited with status 0); -1 when the child cannot be waited for.
private func waitStatus(_ pid: pid_t) -> Int32 {
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 {
    guard errno == EINTR else { return -1 }
  }
  return status
}
