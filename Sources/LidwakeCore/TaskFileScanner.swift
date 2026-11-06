import Darwin
import Foundation

/// Finds open Claude Code background-task output files (`<root>/**/tasks/<id>.output`)
/// among the current user's processes.
public struct TaskFileScanner: Sendable {
  private let root: String

  /// The root may not exist yet; it is resolved again on every scan.
  public init(root: URL) {
    self.root = root.path
  }

  public func hasOpenTaskOutput() -> Bool {
    // Vnode paths are canonical, so compare against the canonical root plus "/".
    let rootPrefix = Array((Self.canonicalPath(root) + "/").utf8)
    for pid in Self.currentUserPIDs() where pid > 0 {
      for fd in Self.vnodeFDs(of: pid)
      where Self.hasTaskOutputOpen(pid: pid, fd: fd, rootPrefix: rootPrefix) {
        return true
      }
    }
    return false
  }

  /// `relative` is the path below the root: `[dir/...]tasks/<name>.output`.
  static func isTaskOutput(relative: Substring) -> Bool {
    let components = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2, components[components.count - 2] == "tasks" else { return false }
    let name = components[components.count - 1]
    return name.hasSuffix(".output") && name.count > ".output".count
  }

  /// realpath of the deepest existing ancestor, with the missing tail appended,
  /// so a root that does not exist yet still resolves /tmp -> /private/tmp.
  static func canonicalPath(_ path: String) -> String {
    var head = (path as NSString).standardizingPath
    var tail: [String] = []
    while true {
      if let resolved = realpath(head, nil) {
        defer { free(resolved) }
        return tail.reversed().reduce(String(cString: resolved)) {
          ($0 as NSString).appendingPathComponent($1)
        }
      }
      let parent = (head as NSString).deletingLastPathComponent
      if parent == head || parent.isEmpty { return path }
      tail.append((head as NSString).lastPathComponent)
      head = parent
    }
  }

  private static func hasTaskOutputOpen(pid: pid_t, fd: Int32, rootPrefix: [UInt8]) -> Bool {
    var info = vnode_fdinfowithpath()
    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
      return false
    }
    return withUnsafeBytes(of: info.pvip.vip_path) { raw in
      let length = raw.firstIndex(of: 0) ?? raw.count
      let path = raw[..<length]
      guard path.starts(with: rootPrefix) else { return false }
      let relative = String(decoding: path.dropFirst(rootPrefix.count), as: UTF8.self)
      return isTaskOutput(relative: relative[...])
    }
  }

  private static func currentUserPIDs() -> [pid_t] {
    let uid = getuid()
    let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
    guard needed > 0 else { return [] }
    // Slack for processes started between the two calls.
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
    let bytes = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else { return [] }
    return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size))
  }

  /// Empty for processes that deny access (EPERM) or exited mid-scan.
  private static func vnodeFDs(of pid: pid_t) -> [Int32] {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 4)
    let bytes = fds.withUnsafeMutableBytes { buffer in
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else { return [] }
    return fds.prefix(Int(bytes) / stride)
      .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) }
      .map(\.proc_fd)
  }
}
