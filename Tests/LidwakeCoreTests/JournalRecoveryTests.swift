import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct JournalRecoveryTests {
        @Test func successiveRecoveriesPreserveBothOriginals() throws {
            let dir = try TempPaths.makeDirectory("recover")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let store = JournalStore(directory: dir)
            let file = dir.appendingPathComponent(RecoveryFiles.journal)
            let recovery = Journal(owned: true)
            for bytes in [RecoveryFiles.garbage, Data(#"{"owned":"#.utf8)] {
                try bytes.write(to: file)
                let before = try RecoveryFiles.image(of: dir)
                #expect(store.load() == recovery)
                let after = try RecoveryFiles.image(of: dir)
                let added = Set(after.keys).subtracting(before.keys)
                try #require(added.count == 1)
                let name = try #require(added.first)
                #expect(name.hasPrefix(RecoveryFiles.copyPrefix))
                #expect(after[name]?.bytes == bytes)
                for (key, image) in before where key != RecoveryFiles.journal {
                    #expect(after[key] == image, "existing file \(key) changed during recovery")
                }
                #expect(try RecoveryFiles.readJournal(in: dir) == recovery)
                #expect(store.load() == recovery)
                #expect(try RecoveryFiles.image(of: dir) == after)
            }
        }

        @Test
        func failedCopyPreservesUnreadableOriginalAndReturnsOwned() throws {
            try #require(geteuid() != 0, "copy failure requires a non-root user")
            let dir = try TempPaths.makeDirectory("copy-denied")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            try RecoveryFiles.garbage.write(to: dir.appendingPathComponent(RecoveryFiles.journal))
            let store = JournalStore(directory: dir)
            try RecoveryFiles.checkWithReadAccessDenied(in: dir, readOnly: false) {
                #expect(store.load() == Journal(owned: true))
            }
        }

        @Test func failedReplacementKeepsCopyAndOriginalAndReturnsOwned() throws {
            let dir = try TempPaths.makeDirectory("replace-denied")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let source = dir.appendingPathComponent(RecoveryFiles.journal)
            try RecoveryFiles.garbage.write(to: source)
            try #require(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
            defer {
                // A filesystem copy can also inherit the source's immutable flag.
                for name in (try? RecoveryFiles.names(in: dir)) ?? [RecoveryFiles.journal]
                where name == RecoveryFiles.journal || name.hasPrefix(RecoveryFiles.copyPrefix) {
                    #expect(chflags(dir.appendingPathComponent(name).path, 0) == 0)
                }
            }
            let store = JournalStore(directory: dir)
            #expect(store.load() == Journal(owned: true))
            #expect(try Data(contentsOf: source) == RecoveryFiles.garbage)
            let names = try RecoveryFiles.names(in: dir)
            let copies = names.filter { $0.hasPrefix(RecoveryFiles.copyPrefix) }
            try #require(copies.count == 1)
            let copy = try #require(copies.first)
            #expect(try Data(contentsOf: dir.appendingPathComponent(copy)) == RecoveryFiles.garbage)
            #expect(names == ["lock", RecoveryFiles.journal, copy])
        }
    }
}
