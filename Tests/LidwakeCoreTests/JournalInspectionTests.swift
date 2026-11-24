import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct JournalInspectionTests {
        enum FileCase: CaseIterable, Sendable {
            case missing, valid, garbage, truncated, missingOwned
        }

        @Test(arguments: FileCase.allCases)
        func inspectClassifiesWithoutChangingFiles(fileCase: FileCase) throws {
            let dir = try TempPaths.makeDirectory("inspect")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            let file = dir.appendingPathComponent(RecoveryFiles.journal)
            for name in ["journal.json.tmp-left", "journal.json.corrupt-old", "force"] {
                try Data(name.utf8).write(to: dir.appendingPathComponent(name))
            }
            let expected: JournalState
            switch fileCase {
            case .missing:
                expected = .missing
            case .valid:
                let saved = Journal(
                    owned: false, lastActive: Date(timeIntervalSince1970: 1_700_000_000),
                    pending: ProcessIdentity(pid: 1234, startTime: 9876))
                try store.save(saved)
                expected = .valid(saved)
            case .garbage:
                try RecoveryFiles.garbage.write(to: file)
                expected = .unreadable
            case .truncated:
                try Data(#"{"owned":true"#.utf8).write(to: file)
                expected = .unreadable
            case .missingOwned:
                try Data("{}".utf8).write(to: file)
                expected = .unreadable
            }
            try RecoveryFiles.checkUnchanged(in: dir) {
                #expect(store.inspect() == expected)
            }
        }

        @Test
        func inspectClassifiesReadFailureWithoutChangingFiles() throws {
            try #require(geteuid() != 0, "read failure requires a non-root user")
            let dir = try TempPaths.makeDirectory("inspect-denied")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            try store.save(Journal(owned: false))
            try RecoveryFiles.checkWithReadAccessDenied(in: dir) {
                #expect(store.inspect() == JournalState.unreadable)
            }
        }

        @Test func cleanupDeletesOnlyTemporaryFilesAndCanRunAgain() throws {
            let dir = try TempPaths.makeDirectory("stale")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let store = JournalStore(directory: dir)
            try store.save(Journal(owned: true))
            for name in ["force", "unrelated", "journal.json.tmpx", "journal.json.corrupt-a"] {
                try Data(name.utf8).write(to: dir.appendingPathComponent(name))
            }
            let keep = try RecoveryFiles.image(of: dir)
            let folder = dir.appendingPathComponent("journal.json.tmp-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let notes = folder.appendingPathComponent("notes.txt")
            let original = Data("user notes\n".utf8)
            try original.write(to: notes)
            for name in ["journal.json.tmp-1", "journal.json.tmp-2", "journal.json.tmp-"] {
                try Data(name.utf8).write(to: dir.appendingPathComponent(name))
            }
            for _ in 0..<2 {
                store.removeStaleTemporaryFiles()
                #expect(try RecoveryFiles.image(of: dir, excluding: [folder.lastPathComponent]) == keep)
                #expect(try RecoveryFiles.names(in: folder) == ["notes.txt"])
                #expect(try Data(contentsOf: notes) == original)
            }
        }

        @Test(arguments: ["journal.json.tmp-a", "journal.json.tmp-b"])
        func cleanupContinuesWhenOneFileCannotBeRemoved(protectedName: String) throws {
            let dir = try TempPaths.makeDirectory("cleanup-denied")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            for name in ["journal.json.tmp-a", "journal.json.tmp-b", "journal.json.tmp-c"] {
                try Data(name.utf8).write(to: dir.appendingPathComponent(name))
            }
            let protected = dir.appendingPathComponent(protectedName)
            try #require(chflags(protected.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { #expect(chflags(protected.path, 0) == 0) }
            JournalStore(directory: dir).removeStaleTemporaryFiles()
            #expect(try RecoveryFiles.names(in: dir) == ["lock", protectedName])
            #expect(try Data(contentsOf: protected) == Data(protectedName.utf8))
        }
    }
}
