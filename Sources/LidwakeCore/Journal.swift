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

public enum JournalState: Equatable, Sendable {
  case missing
  case valid(Journal)
  case unreadable
}

public struct JournalStore: Sendable {
  private static let temporaryPrefix = "journal.json.tmp-"
  private static let corruptPrefix = "journal.json.corrupt-"

  private let directory: URL
  private let file: URL

  public init(directory: URL) {
    self.directory = directory
    file = directory.appendingPathComponent("journal.json")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      log.error("cannot create \(directory.path, privacy: .public): \(error, privacy: .public)")
    }
  }

  /// Reads the journal without creating, renaming, writing or deleting any file.
  public func inspect() -> JournalState {
    do {
      return .valid(try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file)))
    } catch CocoaError.fileReadNoSuchFile {
      return .missing
    } catch {
      log.error("unreadable journal \(file.path, privacy: .public): \(error, privacy: .public)")
      return .unreadable
    }
  }

  /// An unreadable journal loads as owned: lidwake cannot tell whether it set
  /// `SleepDisabled=1`. Its bytes are copied to a new `journal.json.corrupt-*` file first,
  /// and journal.json is replaced only after the copy exists. If the copy fails,
  /// journal.json stays as it is for this load, and a later save replaces it.
  public func load() -> Journal {
    switch inspect() {
    case .missing:
      return Journal()
    case .valid(let journal):
      return journal
    case .unreadable:
      let owned = Journal(owned: true)
      do {
        let copy = try keepCopy()
        log.notice("kept unreadable journal as \(copy, privacy: .public)")
      } catch {
        log.error(
          "cannot copy unreadable journal, left as it is: \(error, privacy: .public)")
        return owned
      }
      do {
        try save(owned)
      } catch {
        log.error("cannot save owned journal: \(error, privacy: .public)")
      }
      return owned
    }
  }

  /// Writes a uniquely named temporary file, fsyncs it, and renames it over the journal,
  /// so readers see either the old or the new journal. A failed save removes the temp file.
  public func save(_ j: Journal) throws {
    let temp = directory.appendingPathComponent(Self.temporaryPrefix + UUID().uuidString).path
    try writeNew(temp, JSONEncoder().encode(j))
    guard rename(temp, file.path) == 0 else {
      let error = POSIXError.current()
      unlink(temp)
      throw error
    }
  }

  /// Deletes the temporary files that a crash between create and rename in `save` left
  /// behind. Only files whose name starts with `journal.json.tmp-` are touched. The caller
  /// must hold the instance lock, because a lock holder is the only writer.
  public func removeStaleTemporaryFiles() {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      log.error("cannot list \(directory.path, privacy: .public): \(error, privacy: .public)")
      return
    }
    for name in names where name.hasPrefix(Self.temporaryPrefix) {
      let path = directory.appendingPathComponent(name).path
      if unlink(path) == 0 {
        log.info("removed stale \(path, privacy: .public)")
      } else {
        log.error(
          "cannot remove \(path, privacy: .public): \(POSIXError.current(), privacy: .public)")
      }
    }
  }

  /// Names of the regular `journal.json.corrupt-*` files in the directory, sorted. Reads
  /// names and file types only; never opens, moves or deletes a file.
  public func keptUnreadableCopies() throws -> [String] {
    let manager = FileManager.default
    var kept: [String] = []
    for name in try manager.contentsOfDirectory(atPath: directory.path)
    where name.hasPrefix(Self.corruptPrefix) {
      let path = directory.appendingPathComponent(name).path
      do {
        // attributesOfItem uses lstat, so a symbolic link is not a regular file.
        let type = try manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        if type == .typeRegular { kept.append(name) }
      } catch {
        log.error("cannot stat \(path, privacy: .public): \(error, privacy: .public)")
      }
    }
    return kept.sorted()
  }

  /// Copies the exact bytes of journal.json to a new file named
  /// `journal.json.corrupt-<yyyyMMdd'T'HHmmss'Z' UTC>-<UUID>` and returns its path. The
  /// fixed-width time makes names sort by time; the UUID keeps copies made in the same
  /// second distinct. An existing file is never overwritten.
  private func keepCopy() throws -> String {
    let data = try Data(contentsOf: file)
    let time = Date().formatted(
      Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
        timeZone: .gmt))
    let name = Self.corruptPrefix + time + "-" + UUID().uuidString
    let copy = directory.appendingPathComponent(name).path
    try writeNew(copy, data)
    return copy
  }

  /// Creates `path` (fails if it exists), writes `data` and fsyncs it. A failed write
  /// removes the file.
  private func writeNew(_ path: String, _ data: Data) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError.current() }
    do {
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      unlink(path)
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
