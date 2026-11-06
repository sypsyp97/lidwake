import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §7: Journal + JournalStore.
    @Suite struct JournalStoreTests {
        static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        @Test func journalDefaultsAreNotOwnedAndNoLastActive() {
            let j = Journal()
            #expect(j.owned == false)
            #expect(j.lastActive == nil)
            #expect(Journal(owned: false, lastActive: nil) == j)
        }

        @Test func roundTripOwnedWithLastActive() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            let j = Journal(owned: true, lastActive: Self.t0)
            try store.save(j)
            #expect(store.load() == j)
            // A second store instance on the same directory reads the persisted state.
            #expect(JournalStore(directory: dir).load() == j)
        }

        @Test func roundTripNotOwnedWithoutLastActive() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            try store.save(Journal(owned: true, lastActive: Self.t0))
            let j = Journal(owned: false, lastActive: nil)
            try store.save(j)
            #expect(store.load() == j)
        }

        @Test func savesToJournalJsonInDirectory() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            try JournalStore(directory: dir).save(Journal(owned: true, lastActive: Self.t0))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal.json").path))
        }

        @Test func missingFileLoadsDefault() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            #expect(JournalStore(directory: dir).load() == Journal())
        }

        @Test(
            "corrupt file loads default",
            arguments: ["", "not json", "{", #"{"owned":"#, "[1,2,3]", #"{"owned":"yes"}"#]
        )
        func corruptFileLoadsDefault(contents: String) throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            try Data(contents.utf8).write(to: dir.appendingPathComponent("journal.json"))
            #expect(JournalStore(directory: dir).load() == Journal())
        }

        @Test func initCreatesMissingDirectory() throws {
            let base = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(base) }
            let nested = base.appendingPathComponent("x/y/state", isDirectory: true)
            let store = JournalStore(directory: nested)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
            let j = Journal(owned: true, lastActive: Self.t0)
            try store.save(j)
            #expect(store.load() == j)
        }

        @Test func saveLeavesOnlyTheJournalFileBehind() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            for i in 0..<20 {
                try store.save(Journal(owned: i % 2 == 0, lastActive: Self.t0.addingTimeInterval(Double(i))))
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries == ["journal.json"])
            #expect(store.load() == Journal(owned: false, lastActive: Self.t0.addingTimeInterval(19)))
        }

        static let child = ProcessIdentity(pid: 31337, startTime: 1_799_999_999_123_456)

        @Test func journalDefaultHasNoPending() {
            #expect(Journal().pending == nil)
            #expect(Journal(owned: true, lastActive: Self.t0).pending == nil)
        }

        @Test func roundTripWithPending() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            let j = Journal(owned: true, lastActive: Self.t0, pending: Self.child)
            try store.save(j)
            #expect(store.load() == j)
            #expect(store.load().pending == Self.child)
            #expect(JournalStore(directory: dir).load() == j)
        }

        @Test func savingNilPendingClearsIt() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            try store.save(Journal(owned: true, lastActive: Self.t0, pending: Self.child))
            try store.save(Journal(owned: true, lastActive: Self.t0, pending: nil))
            #expect(store.load() == Journal(owned: true, lastActive: Self.t0))
            #expect(store.load().pending == nil)
        }

        @Test func legacyJsonWithoutPendingOrLastActiveLoadsWithNilPending() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            try Data(#"{"owned":true}"#.utf8).write(to: dir.appendingPathComponent("journal.json"))
            #expect(JournalStore(directory: dir).load() == Journal(owned: true, lastActive: nil, pending: nil))
        }

        @Test func legacyJsonWithoutPendingKeepsOwnedAndLastActive() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            try store.save(Journal(owned: true, lastActive: Self.t0, pending: Self.child))
            // Rewrite the file as an older version would have written it: no "pending" key.
            let url = dir.appendingPathComponent("journal.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            var dict = try #require(object as? [String: Any])
            #expect(dict["pending"] != nil)
            dict.removeValue(forKey: "pending")
            try JSONSerialization.data(withJSONObject: dict).write(to: url)
            #expect(store.load() == Journal(owned: true, lastActive: Self.t0, pending: nil))
        }

        @Test func saveReplacesCorruptFile() throws {
            let dir = try TempPaths.makeDirectory("journal")
            defer { TempPaths.remove(dir) }
            try Data("garbage".utf8).write(to: dir.appendingPathComponent("journal.json"))
            let store = JournalStore(directory: dir)
            let j = Journal(owned: true, lastActive: nil)
            try store.save(j)
            #expect(store.load() == j)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["journal.json"])
        }
    }
}
