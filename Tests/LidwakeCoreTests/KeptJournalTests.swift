import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct KeptJournalTests {
        private func timestamp(in name: String, between start: Date, and end: Date) throws -> String {
            try #require(name.hasPrefix(RecoveryFiles.copyPrefix))
            let parts = name.dropFirst(RecoveryFiles.copyPrefix.count)
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            try #require(parts.count == 2 && !parts[1].isEmpty, "Missing timestamp or unique part in \(name)")
            let text = String(parts[0])
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(secondsFromGMT: 0)
            utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            utc.isLenient = false
            let date = try #require(utc.date(from: text), "Invalid UTC copy timestamp in \(name)")
            #expect(utc.string(from: date) == text)
            #expect(date.timeIntervalSince1970 >= floor(start.timeIntervalSince1970))
            #expect(date.timeIntervalSince1970 <= floor(end.timeIntervalSince1970))
            return text
        }

        @Test func consecutiveLoadsKeepDistinctTimestampedCopies() throws {
            let dir = try TempPaths.makeDirectory("copy-time")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let store = JournalStore(directory: dir)
            let journal = dir.appendingPathComponent(RecoveryFiles.journal)

            func recover(_ bytes: Data) throws -> (name: String, stamp: String) {
                try bytes.write(to: journal)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: journal.path)
                let existing = try RecoveryFiles.names(in: dir)
                let start = Date()
                _ = store.load()
                let end = Date()
                let added = try RecoveryFiles.names(in: dir).subtracting(existing)
                try #require(added.count == 1)
                let name = try #require(added.first)
                return try (name, timestamp(in: name, between: start, and: end))
            }

            let first = try recover(Data([0xFE]))
            let second = try recover(Data([0xFF]))
            #expect(first.name != second.name)
            if first.stamp == second.stamp {
                let prefixLength = RecoveryFiles.copyPrefix.count + first.stamp.count + 1
                #expect(first.name.dropFirst(prefixLength) != second.name.dropFirst(prefixLength))
            }
            #expect(try Data(contentsOf: dir.appendingPathComponent(first.name)) == Data([0xFE]))
            #expect(try Data(contentsOf: dir.appendingPathComponent(second.name)) == Data([0xFF]))
        }

        private func checkStatus(in dir: URL, expecting sortedNames: [String]) throws {
            let run = try CLIProcessTests.runToEnd(["status"], stateDir: dir)
            try #require(run.exitedCleanly, "stderr: \(run.stderr)")
            let label = "kept unreadable journals:"
            let expected = "\(label) \(sortedNames.count) (\(sortedNames.joined(separator: ",")))"
            var summaries = [String]()
            for line in run.stdout.components(separatedBy: .newlines) {
                if line.hasPrefix(label) {
                    summaries.append(line.replacingOccurrences(of: ", ", with: ","))
                } else {
                    #expect(!line.contains(RecoveryFiles.copyPrefix), "Unexpected copy name in stdout: \(line)")
                }
            }
            #expect(summaries == (sortedNames.isEmpty ? [] : [expected]))
        }

        @Test func statusOmitsLineForNearMatchAndDirectory() throws {
            let dir = try TempPaths.makeDirectory("no-copies")
            defer { TempPaths.remove(dir) }
            try RecoveryFiles.garbage.write(to: dir.appendingPathComponent("journal.json.corruptX"))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("journal.json.corrupt-dir"), withIntermediateDirectories: false)
            try checkStatus(in: dir, expecting: [])
            #expect(try RecoveryFiles.names(in: dir) == ["journal.json.corruptX", "journal.json.corrupt-dir"])
        }

        private func fileStat(_ url: URL) throws -> stat {
            var info = stat()
            try #require(stat(url.path, &info) == 0)
            return info
        }

        /// Call after the byte snapshot and before chmod. A control read on this volume must advance atime.
        private func checkForReads(of files: [URL], during status: () throws -> Void) throws {
            let aged = timespec(tv_sec: 900_000_000, tv_nsec: 0)
            func age(_ url: URL) throws {
                let mtime = try fileStat(url).st_mtimespec
                try #require(utimensat(AT_FDCWD, url.path, [aged, mtime], 0) == 0)
            }
            let control = try #require(files.first)
            try age(control)
            try #require(try fileStat(control).st_atimespec.tv_sec == aged.tv_sec)
            _ = try Data(contentsOf: control)
            try #require(try fileStat(control).st_atimespec.tv_sec > aged.tv_sec, "Control read must advance atime")
            for file in files { try age(file) }

            try status()
            for file in files {
                let atime = try fileStat(file).st_atimespec
                #expect(atime.tv_sec == aged.tv_sec && atime.tv_nsec == aged.tv_nsec, "Read \(file.lastPathComponent)")
            }
        }

        @Test func statusListsOneCopyWithoutReadingItsBytes() throws {
            let dir = try TempPaths.makeDirectory("one-copy")
            defer { TempPaths.remove(dir) }
            let name = "journal.json.corrupt-20241101T121314Z-only"
            let copy = dir.appendingPathComponent(name)
            try RecoveryFiles.garbage.write(to: copy)
            try RecoveryFiles.checkUnchanged(in: dir) {
                try checkForReads(of: [copy]) {
                    try checkStatus(in: dir, expecting: [name])
                }
            }
        }

        @Test func statusSortsDirectoryEntriesWithoutReadingAnyCopy() throws {
            let dir = try TempPaths.makeDirectory("many-copies")
            defer { TempPaths.remove(dir) }
            let suffixes = [
                "20241101T121314Z-z", "20240101T000000Z-a", "by hand", "20241101T121314Z-a", "wren", "cedar",
                "zulu", "apple", "rome", "oslo", "lima", "berlin",
            ]
            let names = suffixes.map { RecoveryFiles.copyPrefix + $0 }
            let files = names.map { dir.appendingPathComponent($0) }
            for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
            let sorted = names.sorted()
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            try #require(entries != sorted, "Sort fixture must enumerate out of order on this volume")

            let unreadable = dir.appendingPathComponent(RecoveryFiles.copyPrefix + "by hand")
            let mode = try RecoveryFiles.mode(of: unreadable)
            try RecoveryFiles.checkUnchanged(in: dir) {
                try checkForReads(of: files) {
                    try #require(chmod(unreadable.path, 0) == 0)
                    defer { #expect(chmod(unreadable.path, mode_t(mode)) == 0) }
                    try checkStatus(in: dir, expecting: sorted)
                    #expect(try RecoveryFiles.mode(of: unreadable) == 0)
                }
            }
        }

        @Test func dryRunUsesUTCAndStatusListsOnlyItsSelectedDirectory() throws {
            let dir = try TempPaths.makeDirectory("dry-copy-status")
            defer { TempPaths.remove(dir) }
            let parentName = RecoveryFiles.copyPrefix + "parent-only"
            try Data("parent".utf8).write(to: dir.appendingPathComponent(parentName))
            let dry = dir.appendingPathComponent("dry-run", isDirectory: true)
            try FileManager.default.createDirectory(at: dry, withIntermediateDirectories: false)
            try RecoveryFiles.garbage.write(to: dry.appendingPathComponent(RecoveryFiles.journal))
            let start = Date()
            let run = try CLIProcessTests.Run(
                ["run", "--dry-run", "--ticks", "1", "--interval", "0.05"], stateDir: dir,
                environment: ["TZ": "Pacific/Honolulu"])
            try #require(run.wait(seconds: 10))
            let end = Date()
            try #require(run.exitedCleanly, "stderr: \(run.stderr)")
            let names = try RecoveryFiles.names(in: dry).filter { $0.hasPrefix(RecoveryFiles.copyPrefix) }
            try #require(names.count == 1)
            let name = try #require(names.first)
            #expect(name != parentName)
            #expect(try Data(contentsOf: dry.appendingPathComponent(name)) == RecoveryFiles.garbage)
            try RecoveryFiles.checkUnchanged(in: dry) {
                try checkStatus(in: dir, expecting: [parentName])
                try checkStatus(in: dry, expecting: [name])
            }
            _ = try timestamp(in: name, between: start, and: end)
        }
    }
}
