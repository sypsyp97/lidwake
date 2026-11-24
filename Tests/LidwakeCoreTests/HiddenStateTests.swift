import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct HiddenStateTests {
        @Test func deniedDirectorySearchPreservesOwnedJournal() throws {
            try #require(geteuid() != 0)
            let dir = try TempPaths.makeDirectory("journal-search")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let store = JournalStore(directory: dir)
            let file = dir.appendingPathComponent(RecoveryFiles.journal)
            let original = Data(#"{"owned":true}"#.utf8)
            try original.write(to: file)
            let mode = try RecoveryFiles.mode(of: dir)

            do {
                try #require(chmod(dir.path, 0o600) == 0)
                defer { #expect(chmod(dir.path, mode_t(mode)) == 0) }
                let result = access(file.path, F_OK)
                let lookupError = errno
                try #require(result == -1 && lookupError == EACCES)
                #expect(store.inspect() == JournalState.unreadable)
                #expect(store.load() == Journal(owned: true))
            }
            #expect(try Data(contentsOf: file) == original)
        }

        @Test func cleanupPreservesNestedTemporaryFile() throws {
            let dir = try TempPaths.makeDirectory("nested-temp")
            defer { TempPaths.remove(dir) }
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(dir))
            defer { lock.release() }
            let sub = dir.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            let nested = sub.appendingPathComponent("journal.json.tmp-nested")
            let original = Data("nested contents".utf8)
            try original.write(to: nested)
            try Data("interrupted save".utf8).write(to: dir.appendingPathComponent("journal.json.tmp-top"))

            JournalStore(directory: dir).removeStaleTemporaryFiles()

            #expect(try RecoveryFiles.names(in: dir) == ["lock", "sub"])
            #expect(try Data(contentsOf: nested) == original)
        }

        @Test(arguments: [true, false])
        func statusReportsForceFileAndPowerPrecedence(forced: Bool) throws {
            let dir = try TempPaths.makeDirectory("status-force")
            defer { TempPaths.remove(dir) }
            if forced { try Data().write(to: dir.appendingPathComponent("force")) }

            let before = PowerSource.read()
            let run = try CLIProcessTests.runToEnd(["status"], stateDir: dir)
            let after = PowerSource.read()
            try #require(run.exitedCleanly, "stderr: \(run.stderr)")
            let lines = run.stdout.lowercased().split(separator: "\n")
            func field(_ name: String) throws -> String {
                let line = try #require(lines.first { $0.hasPrefix(name + ":") }, "\(run.stdout)")
                return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            }

            #expect(try field("forced") == String(forced))
            let power = try field("power").components(separatedBy: ", charge ")
            try #require(power.count == 2)
            try #require(["ac", "battery"].contains(power[0]))
            let chargeText = power[1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            let charge = Int(chargeText)
            if let charge {
                try #require((0...100).contains(charge))
            } else {
                try #require(["unknown", "?", "none", "n/a"].contains(chargeText))
            }
            let reported = PowerState(onBattery: power[0] == "battery", chargePercent: charge)
            if before == after { #expect(reported == before) }

            let low = reported.onBattery && (reported.chargePercent ?? 0) < 20
            if forced || low {
                let decision = try field("decision").split(separator: " ")
                #expect(decision.contains(low ? "hold=false" : "hold=true"))
                #expect(decision.contains(low ? "reason=batterylow" : "reason=forced"))
            }
        }
    }
}
