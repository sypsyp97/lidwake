import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct ControllerStatePropertyTests {
        /// A failed read hides the flag. Only a successful write or a manual clear changes it.
        final class FlagSensor: SleepControl, @unchecked Sendable {
            let flag = FakeSleepControl(state: false)
            private let lock = NSLock()
            private var readable = true

            func setReadable(_ value: Bool) {
                lock.withLock { readable = value }
            }

            func isSleepDisabled() -> Bool? {
                lock.withLock { readable ? flag.state : nil }
            }

            func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws {
                try flag.setSleepDisabled(on, recorded: recorded)
            }
        }

        enum Operation: CaseIterable, Hashable {
            case active, idle, batteryLow, corrupt, restart, stop, userOff
        }

        @Test func seededOperationsRespectDiskAndInMemoryOwnership() throws {
            let seed: UInt64 = 0xC012_5A7E
            var rng = RecoveryRandom(seed: seed)
            let dir = try TempPaths.makeDirectory("state-property")
            defer { TempPaths.remove(dir) }
            let store = JournalStore(directory: dir)
            let sensor = FlagSensor()
            let inputs = FakeInputsProvider(Fixtures.idle())
            let settle: TimeInterval = 3
            func newController() -> (controller: Controller, assertion: FakeAssertion) {
                let assertion = FakeAssertion()
                let controller = Controller(
                    provider: inputs, sleep: sensor, assertion: assertion, store: store,
                    probe: FakeProcessProbe(), settle: settle)
                return (controller, assertion)
            }

            var memory = Journal()
            var disk = JournalState.valid(memory)
            var flag = false
            var expectedHeld = false
            try store.save(memory)
            var instance: (controller: Controller, assertion: FakeAssertion)? = newController()
            instance?.controller.start(now: ControllerTests.t0)
            try #require(instance?.assertion.held == expectedHeld, "initial start, seed \(seed)")
            var operations: Set<Operation> = []
            var simulatedReads: [Operation: Set<Bool?>] = [:]
            var corruptRestarts = 0
            for step in 1...256 {
                let now = ControllerTests.t0.addingTimeInterval(Double(step))
                let choices: [Operation]
                if instance == nil {
                    choices = [.restart, .restart, .userOff]
                } else if disk == .unreadable {
                    // Recover at restart, or overwrite the damaged journal with a changed lastActive.
                    choices = [.restart, .restart, .active, .userOff]
                } else {
                    choices = [.active, .idle, .batteryLow, .active, .idle, .batteryLow, .corrupt, .restart, .stop, .userOff]
                }
                let op = choices[rng.index(choices.count)]
                let message = "seed \(seed), step \(step), operation \(op)"
                operations.insert(op)
                let callCount = sensor.flag.calls.count
                var expectedCalls: [Bool] = []

                switch op {
                case .active, .idle, .batteryLow:
                    let running = try #require(instance, "\(message)")
                    switch op {
                    case .active: inputs.current = Fixtures.working()
                    case .batteryLow: inputs.current = Fixtures.forced(power: Fixtures.lowBattery)
                    default: inputs.current = Fixtures.idle()
                    }
                    let readable = rng.index(3) != 0
                    sensor.setReadable(readable)
                    let read: Bool? = readable ? flag : nil
                    simulatedReads[op, default: []].insert(read)
                    let decision = expectedDecision(inputs.current, now: now, lastActive: memory.lastActive, settle: settle)
                    expectedHeld = decision.hold
                    memory.lastActive = decision.lastActive
                    if decision.hold && read == false {
                        expectedCalls = [true]
                        memory.owned = true
                        flag = true
                    } else if !decision.hold && memory.owned {
                        expectedCalls = [false]
                        memory.owned = false
                        flag = false
                    }
                    let actual = running.controller.tick(now: now)
                    try #require(actual == decision, "\(message)")
                    disk = .valid(memory)

                case .corrupt:
                    guard case .valid(let journal) = store.inspect(), journal.pending == nil else {
                        Issue.record("unexpected pending or unreadable journal before corruption: \(message)")
                        return
                    }
                    try Data("damaged at step \(step)".utf8).write(to: dir.appendingPathComponent(RecoveryFiles.journal))
                    disk = .unreadable

                case .restart:
                    switch disk {
                    case .valid(let saved): memory = saved
                    case .unreadable:
                        corruptRestarts += 1
                        memory = Journal(owned: true)
                        disk = .valid(memory)
                    case .missing:
                        Issue.record("seeded journal disappeared: \(message)")
                        return
                    }
                    instance = newController()
                    expectedHeld = false
                    instance?.controller.start(now: now)

                case .stop:
                    if memory.owned {
                        expectedCalls = [false]
                        memory.owned = false
                        flag = false
                        disk = .valid(memory)
                    }
                    let running = try #require(instance, "\(message)")
                    running.controller.stop()
                    expectedHeld = false
                    try #require(!running.assertion.held, "\(message)")
                    instance = nil

                case .userOff:
                    sensor.flag.state = false
                    flag = false
                }

                let calls = Array(sensor.flag.calls.dropFirst(callCount))
                let state = store.inspect()
                if let instance {
                    try #require(instance.assertion.held == expectedHeld, "\(message)")
                }
                if sensor.flag.state == true {
                    switch state {
                    case .valid(let journal): try #require(journal.owned, "flag on without ownership: \(message)")
                    case .unreadable: break
                    case .missing: Issue.record("flag on without a journal: \(message)")
                    }
                }
                try #require(calls == expectedCalls, "\(message)")
                try #require(sensor.flag.state == flag, "\(message)")
                try #require(state == disk, "\(message)")
            }
            #expect(operations == Set(Operation.allCases), "seed \(seed)")
            for input in [Operation.active, .idle, .batteryLow] {
                #expect(simulatedReads[input] == Set([true, false, nil]), "seed \(seed), inputs \(input)")
            }
            #expect(corruptRestarts > 0, "seed \(seed)")
        }
    }
}
