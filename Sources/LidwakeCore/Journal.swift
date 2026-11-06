import Foundation
import os

private let log = Logger(subsystem: "dev.lidwake", category: "journal")

public struct Journal: Codable, Equatable, Sendable {
  /// lidwake set `SleepDisabled=1` and has not restored it yet.
  public var owned: Bool
  public var lastActive: Date?
  /// The privileged pmset child that may still be running, recorded before it was resumed.
  /// A journal without this key (older versions) decodes as nil.
  public var pending: ProcessIdentity?

  public init(owned: Bool = false, lastActive: Date? = nil, pending: ProcessIdentity? = nil) {
    self.owned = owned
    self.lastActive = lastActive
    self.pending = pending
  }
}

public struct JournalStore: Sendable {
  private let file: URL

  public init(directory: URL) {
    file = directory.appendingPathComponent("journal.json")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      log.error("cannot create \(directory.path, privacy: .public): \(error, privacy: .public)")
    }
  }

  /// A missing or unreadable journal means "nothing owned".
  public func load() -> Journal {
    do {
      return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
    } catch CocoaError.fileReadNoSuchFile {
      return Journal()
    } catch {
      log.error("unreadable journal \(file.path, privacy: .public): \(error, privacy: .public)")
      return Journal()
    }
  }

  /// Writes a uniquely named temporary file, fsyncs it, and renames it over the journal,
  /// so readers see either the old or the new journal. A failed save removes the temp file.
  public func save(_ j: Journal) throws {
    let data = try JSONEncoder().encode(j)
    let temp = file.path + ".tmp-" + UUID().uuidString
    let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError.current() }
    do {
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temp, file.path) == 0 else { throw POSIXError.current() }
    } catch {
      unlink(temp)
      throw error
    }
  }
}

extension POSIXError {
  /// The error for the calling thread's current `errno`.
  static func current() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
