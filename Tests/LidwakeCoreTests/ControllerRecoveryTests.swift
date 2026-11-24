import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct ControllerRecoveryTests {
        typealias Rig = ControllerTests.Rig

        @Test(arguments: [Reason.idle, .herdrWorking, .batteryLow])
        func tickAfterCorruptionUsesRecoveredOwnership(reason: Reason) throws {
            let inputs: Inputs
            switch reason {
            case .idle: inputs = Fixtures.idle()
            case .batteryLow: inputs = Fixtures.forced(power: Fixtures.lowBattery)
            default: inputs = Fixtures.working()
            }
            let rig = try Rig(sleepState: true, inputs: inputs)
            defer { rig.cleanup() }
            try RecoveryFiles.garbage.write(to: rig.dir.appendingPathComponent(RecoveryFiles.journal))
            rig.controller.start(now: rig.at(0))
            #expect(!rig.assertion.held)
            #expect(rig.sleep.calls.isEmpty)
            let outcome = rig.controller.tick(now: rig.at(0))
            let active = reason == .herdrWorking
            #expect(outcome == Outcome(hold: active, reason: reason, lastActive: active ? rig.at(0) : nil))
            #expect(rig.sleep.calls == (active ? [] : [false]))
            #expect(rig.sleep.state == active)
            #expect(try RecoveryFiles.readJournal(in: rig.dir) == Journal(owned: active, lastActive: outcome.lastActive))
        }

        @Test func controllerPersistsClockCorrectionAndExpiresOnTime() throws {
            let now = ControllerTests.t0
            let rig = try Rig(
                sleepState: true, journal: Journal(owned: true, lastActive: now.addingTimeInterval(86_400)),
                settle: 30)
            defer { rig.cleanup() }
            rig.controller.start(now: now)
            #expect(!rig.assertion.held)
            #expect(rig.controller.tick(now: now) == Outcome(hold: true, reason: .settling, lastActive: now))
            #expect(try RecoveryFiles.readJournal(in: rig.dir) == Journal(owned: true, lastActive: now))
            #expect(rig.controller.tick(now: rig.at(30)) == Outcome(hold: false, reason: .idle, lastActive: now))
            #expect(rig.sleep.calls == [false])
        }

        struct Observation: Equatable {
            let outcome: Outcome?
            let journal: Journal
            let otherFiles: [String: FileImage]
            let recoveredCopy: FileImage?
            let calls: [Bool]
            let flag: Bool?
            let held: Bool
        }

        func trace(_ rig: Rig, controller: Controller, assertion: FakeAssertion, copy: String? = nil) throws -> [Observation] {
            func observe(_ outcome: Outcome?) throws -> Observation {
                var files = try RecoveryFiles.image(of: rig.dir)
                files.removeValue(forKey: RecoveryFiles.journal)
                // Each independent recovery chooses its own suffix. Track that exact name at every step.
                let recoveredCopy = try copy.map { name in
                    let entry = files.removeValue(forKey: name)
                    return try #require(entry, "recovery copy \(name) disappeared")
                }
                return try Observation(
                    outcome: outcome, journal: RecoveryFiles.readJournal(in: rig.dir), otherFiles: files,
                    recoveredCopy: recoveredCopy, calls: rig.sleep.calls, flag: rig.sleep.state, held: assertion.held)
            }
            var states = [try observe(nil)]
            for (seconds, inputs) in [
                (1, Fixtures.working()), (2, Fixtures.idle()), (3, Fixtures.forced(power: Fixtures.lowBattery)),
                (400, Fixtures.idle()), (401, Fixtures.forced()),
            ] {
                rig.provider.current = inputs
                let outcome = controller.tick(now: rig.at(Double(seconds)))
                #expect(assertion.held == outcome.hold, "tick at \(seconds) s")
                states.append(try observe(outcome))
            }
            return states
        }

        @Test func crashBeforeRenameMatchesUninterruptedRun() throws {
            let saved = Journal(owned: true, lastActive: ControllerTests.t0.addingTimeInterval(-30))
            let clean = try Rig(sleepState: true, journal: saved)
            defer { clean.cleanup() }
            let crashed = try Rig(sleepState: true, journal: saved)
            defer { crashed.cleanup() }
            for rig in [clean, crashed] {
                for name in ["force", "lock", "journal.json.tmpx", "journal.json.corrupt-old", "other"] {
                    try Data(name.utf8).write(to: rig.dir.appendingPathComponent(name))
                }
            }
            let expected = try RecoveryFiles.image(of: crashed.dir)
            try Data(#"{"owned":false}"#.utf8).write(to: crashed.dir.appendingPathComponent("journal.json.tmp-x"))
            clean.controller.start(now: clean.at(0))
            #expect(!clean.assertion.held)
            crashed.controller.start(now: crashed.at(0))
            #expect(!crashed.assertion.held)
            #expect(try RecoveryFiles.image(of: crashed.dir) == expected)
            let uninterrupted = try trace(clean, controller: clean.controller, assertion: clean.assertion)
            let recovered = try trace(crashed, controller: crashed.controller, assertion: crashed.assertion)
            #expect(uninterrupted == recovered)
        }

        @Test func restartAfterRecoveryMatchesContinuingFromSameCheckpoint() throws {
            func replay(restart: Bool) throws -> [Observation] {
                let rig = try Rig(sleepState: true)
                defer { rig.cleanup() }
                try RecoveryFiles.garbage.write(to: rig.dir.appendingPathComponent(RecoveryFiles.journal))
                rig.controller.start(now: rig.at(0))
                #expect(!rig.assertion.held)
                let files = try RecoveryFiles.image(of: rig.dir)
                let copies = files.filter { $0.key.hasPrefix(RecoveryFiles.copyPrefix) }
                try #require(copies.count == 1)
                let copy = try #require(copies.first)
                #expect(copy.value.bytes == RecoveryFiles.garbage)
                #expect(try RecoveryFiles.readJournal(in: rig.dir) == Journal(owned: true))
                #expect(rig.sleep.calls.isEmpty)
                if restart {
                    let assertion = FakeAssertion()
                    let second = Controller(
                        provider: rig.provider, sleep: rig.sleep, assertion: assertion,
                        store: JournalStore(directory: rig.dir), probe: rig.probe)
                    second.start(now: rig.at(0))
                    #expect(!assertion.held)
                    return try trace(rig, controller: second, assertion: assertion, copy: copy.key)
                }
                return try trace(rig, controller: rig.controller, assertion: rig.assertion, copy: copy.key)
            }
            let continued = try replay(restart: false)
            let restarted = try replay(restart: true)
            #expect(continued == restarted)
        }
    }
}
