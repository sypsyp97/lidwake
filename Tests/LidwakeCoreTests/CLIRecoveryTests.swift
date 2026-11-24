import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct CLIRecoveryTests {
        /// Use the inputs from the same status sample. Background work and power can change between commands.
        func checkedStatus(in dir: URL, lastActive: Date?) throws -> String {
            var journal = ""
            try RecoveryFiles.checkUnchanged(in: dir) {
                let flagBefore = PmsetSleepControl().isSleepDisabled()
                let run = try CLIProcessTests.runToEnd(["status"], stateDir: dir)
                let flagAfter = PmsetSleepControl().isSleepDisabled()
                try #require(run.exitedCleanly, "stderr: \(run.stderr)")
                let lines = run.stdout.lowercased().split(separator: "\n")
                func field(_ label: String) throws -> String {
                    let line = try #require(lines.first { $0.hasPrefix(label + ":") }, "\(run.stdout)")
                    return line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                }

                let forced = try field("forced")
                #expect(forced == "false")
                #expect(try field("herdr") == "unreachable")  // The CLI runner supplies an empty home.
                let background = try #require(Bool(try field("background task")))
                let power = try field("power")
                let parts = power.components(separatedBy: ", charge ")
                try #require(parts.count == 2, "\(power)")
                try #require(["ac", "battery"].contains(parts[0]), "\(power)")
                let chargeText = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))
                let charge = Int(chargeText)
                if let charge {
                    #expect((0...100).contains(charge))
                } else {
                    #expect(["?", "unknown", "n/a", "none"].contains(chargeText), "\(power)")
                }
                let flag = try field("sleepdisabled")
                let unknownFlags = ["unknown", "unreadable", "?"]
                if flagBefore == flagAfter {
                    if let flagBefore {
                        #expect(flag == (flagBefore ? "1" : "0"))
                    } else {
                        #expect(unknownFlags.contains(flag))
                    }
                } else {
                    #expect((["0", "1"] + unknownFlags).contains(flag))
                }
                let inputs = Inputs(
                    forced: false, herdrWorking: nil, backgroundTask: background,
                    power: PowerState(onBattery: parts[0] == "battery", chargePercent: charge))
                let expected = expectedDecision(inputs, now: Date(), lastActive: lastActive, settle: Decision.defaultSettle)
                let decision = try field("decision")
                #expect(decision.contains("hold=\(expected.hold)"))
                #expect(decision.contains("reason=\(expected.reason.rawValue.lowercased())"))
                journal = try field("journal")
            }
            return journal
        }

        @Test func statusReportsUnreadableAndLeavesAllFilesAlone() throws {
            let dir = try TempPaths.makeDirectory("status-corrupt")
            defer { TempPaths.remove(dir) }
            try RecoveryFiles.garbage.write(to: dir.appendingPathComponent(RecoveryFiles.journal))
            try Data("partial".utf8).write(to: dir.appendingPathComponent("journal.json.tmp-x"))
            let journal = try checkedStatus(in: dir, lastActive: nil)
            let words = Set(journal.split { !$0.isLetter }.map(String.init))
            #expect(words.isSuperset(of: ["unreadable", "run", "restore"]), "\(journal)")
            #expect(!words.isDisjoint(with: ["next", "will", "on"]), "\(journal)")
            let keepsCopy = /\b(?:run|restore|and|will)\s+(?:keep|save|preserve|retain)s?\s+(?:a|the)\s+copy\b/
            let treatsAsOwned = /\b(?:and|will|run|restore)\s+(?:treat|regard)s?\s+sleepdisabled\s+as\s+owned\b/
            #expect(journal.contains(keepsCopy), "\(journal)")
            #expect(journal.contains(treatsAsOwned), "\(journal)")
        }

        @Test(arguments: [false, true])
        func statusDisplaysMissingOrValidJournal(present: Bool) throws {
            let dir = try TempPaths.makeDirectory("status-journal")
            defer { TempPaths.remove(dir) }
            try Data("partial".utf8).write(to: dir.appendingPathComponent("journal.json.tmp-x"))
            let time = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 5)
            let child = ProcessIdentity(pid: 1234, startTime: 9876)
            if present {
                try JournalStore(directory: dir).save(Journal(owned: true, lastActive: time, pending: child))
            }
            let journal = try checkedStatus(in: dir, lastActive: present ? time : nil)
            #expect(journal.contains("owned=\(present)"))
            #expect(journal.contains("lastactive=\(present ? time.description : "none")"))
            #expect(journal.contains("pending=\(present ? "pid \(child.pid)" : "none")"))
        }

        @Test func dryRunRecoversEvidenceAndRemovesInterruptedSave() throws {
            let dir = try TempPaths.makeDirectory("dry-corrupt")
            defer { TempPaths.remove(dir) }
            let dry = dir.appendingPathComponent("dry-run", isDirectory: true)
            try FileManager.default.createDirectory(at: dry, withIntermediateDirectories: false)
            try RecoveryFiles.garbage.write(to: dry.appendingPathComponent(RecoveryFiles.journal))
            try Data("partial".utf8).write(to: dry.appendingPathComponent("journal.json.tmp-x"))
            let run = try CLIProcessTests.runToEnd(["run", "--dry-run", "--ticks", "1", "--interval", "0.05"], stateDir: dir)
            #expect(run.exitedCleanly, "stderr: \(run.stderr)")
            let files = try RecoveryFiles.image(of: dry)
            #expect(files["journal.json.tmp-x"] == nil)
            let copies = files.filter { $0.key.hasPrefix(RecoveryFiles.copyPrefix) }
            #expect(copies.count == 1)
            #expect(copies.first?.value.bytes == RecoveryFiles.garbage)
            _ = try RecoveryFiles.readJournal(in: dry)
            #expect(try RecoveryFiles.names(in: dir) == ["dry-run"])
        }

        @Test func onAndOffLeaveUnreadableJournalAndTemporaryFileAlone() throws {
            let dir = try TempPaths.makeDirectory("force-corrupt")
            defer { TempPaths.remove(dir) }
            try RecoveryFiles.garbage.write(to: dir.appendingPathComponent(RecoveryFiles.journal))
            try Data("partial".utf8).write(to: dir.appendingPathComponent("journal.json.tmp-x"))
            let before = try RecoveryFiles.image(of: dir)
            let on = try CLIProcessTests.runToEnd(["on"], stateDir: dir)
            #expect(on.exitedCleanly)
            var afterOn = try RecoveryFiles.image(of: dir)
            #expect(afterOn.removeValue(forKey: "force") != nil)
            #expect(afterOn == before)
            let off = try CLIProcessTests.runToEnd(["off"], stateDir: dir)
            #expect(off.exitedCleanly)
            #expect(try RecoveryFiles.image(of: dir) == before)
        }

        @Test func restoreCleansStaleTemporaryFileForValidUnownedJournal() throws {
            let dir = try TempPaths.makeDirectory("restore-stale")
            defer { TempPaths.remove(dir) }
            try Data(#"{"owned":false}"#.utf8).write(to: dir.appendingPathComponent(RecoveryFiles.journal))
            try Data("partial".utf8).write(to: dir.appendingPathComponent("journal.json.tmp-x"))
            try #require(try RecoveryFiles.readJournal(in: dir) == Journal())
            let run = try CLIProcessTests.runToEnd(["restore"], stateDir: dir)
            #expect(run.exitedCleanly, "stderr: \(run.stderr)")
            #expect(try RecoveryFiles.names(in: dir) == [RecoveryFiles.journal, "lock"])
            #expect(try RecoveryFiles.readJournal(in: dir) == Journal())
        }

        @Test(arguments: ["run", "restore"])
        func lockContentionPreservesInterruptedSave(command: String) throws {
            let dir = try TempPaths.makeDirectory("locked-cleanup")
            defer { TempPaths.remove(dir) }
            let target = command == "run" ? dir.appendingPathComponent("dry-run", isDirectory: true) : dir
            let lock = try CLIProcessTests.HeldLock(CLIProcessTests.lockFile(target))
            defer { lock.release() }
            try Data(#"{"owned":false}"#.utf8).write(to: target.appendingPathComponent(RecoveryFiles.journal))
            try #require(try RecoveryFiles.readJournal(in: target) == Journal())
            try Data("partial".utf8).write(to: target.appendingPathComponent("journal.json.tmp-x"))
            let args = command == "run" ? ["run", "--dry-run", "--ticks", "1", "--interval", "0.05"] : ["restore"]
            try RecoveryFiles.checkUnchanged(in: target) {
                let locked = try CLIProcessTests.runToEnd(args, stateDir: dir)
                CLIProcessTests.expectLockedOut(locked, command)
            }
        }
    }
}
