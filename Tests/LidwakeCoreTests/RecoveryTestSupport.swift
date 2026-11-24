import Darwin
import Foundation
import LidwakeCore
import Testing

/// SplitMix64. Keep the operation sequence reproducible across test runs.
struct RecoveryRandom {
    var seed: UInt64

    mutating func index(_ count: Int) -> Int {
        seed &+= 0x9E3779B97F4A7C15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Int((value ^ (value >> 31)) % UInt64(count))
    }
}

struct FileImage: Equatable {
    let bytes: Data
    let mode: Int
}

enum RecoveryFiles {
    static let journal = "journal.json"
    static let copyPrefix = "journal.json.corrupt-"
    static let garbage = Data([0xFF, 0, 0x80, 0x0A])

    static func names(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    static func mode(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    static func image(of dir: URL, excluding: Set<String> = []) throws -> [String: FileImage] {
        var result: [String: FileImage] = [:]
        for name in try names(in: dir).subtracting(excluding) {
            let file = dir.appendingPathComponent(name)
            result[name] = try FileImage(bytes: Data(contentsOf: file), mode: mode(of: file))
        }
        return result
    }

    static func readJournal(in dir: URL) throws -> Journal {
        let bytes = try Data(contentsOf: dir.appendingPathComponent(journal))
        return try JSONDecoder().decode(Journal.self, from: bytes)
    }

    /// Age each entry to detect same-byte rewrites. Age the directory to detect temporary entries.
    static func checkUnchanged(in dir: URL, readOnly: Bool = true, _ operation: () throws -> Void) throws {
        struct Stamp: Equatable {
            let inode: UInt64
            let modified: Date
        }
        let paths = try names(in: dir).map { dir.appendingPathComponent($0).path } + (readOnly ? [dir.path] : [])
        func stamps() throws -> [String: Stamp] {
            var result: [String: Stamp] = [:]
            for path in paths {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
                let modified = try #require(attributes[.modificationDate] as? Date)
                result[path] = Stamp(inode: inode.uint64Value, modified: modified)
            }
            return result
        }
        for path in paths {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                ofItemAtPath: path)
        }
        let contents = try image(of: dir)
        let metadata = try stamps()
        try operation()
        #expect(try image(of: dir) == contents)
        #expect(try stamps() == metadata)
    }

    /// The caller supplies a readable file. Check its mode before restoring read access,
    /// then compare its bytes and every sibling to the original directory.
    static func checkWithReadAccessDenied(in dir: URL, readOnly: Bool = true, _ body: () throws -> Void) throws {
        let file = dir.appendingPathComponent(journal)
        let mode = try mode(of: file)
        try checkUnchanged(in: dir, readOnly: readOnly) {
            try #require(chmod(file.path, 0) == 0)
            defer { #expect(chmod(file.path, mode_t(mode)) == 0) }
            try #require((try? Data(contentsOf: file)) == nil, "chmod 000 must prevent the test user from reading")
            try body()
            #expect(try Self.mode(of: file) == 0)
        }
    }
}

/// SPEC §1 rules 1–4, for a nil or nonfuture timestamp.
func expectedDecision(_ inputs: Inputs, now: Date, lastActive: Date?, settle: TimeInterval) -> Outcome {
    if inputs.power.onBattery && (inputs.power.chargePercent ?? 0) < 20 {
        return Outcome(hold: false, reason: .batteryLow, lastActive: lastActive)
    }
    if inputs.forced { return Outcome(hold: true, reason: .forced, lastActive: now) }
    if inputs.herdrWorking == true { return Outcome(hold: true, reason: .herdrWorking, lastActive: now) }
    if inputs.backgroundTask { return Outcome(hold: true, reason: .backgroundTask, lastActive: now) }
    if let lastActive, now.timeIntervalSince(lastActive) < settle {
        return Outcome(hold: true, reason: .settling, lastActive: lastActive)
    }
    return Outcome(hold: false, reason: .idle, lastActive: lastActive)
}
