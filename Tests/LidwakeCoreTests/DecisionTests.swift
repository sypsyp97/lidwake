import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §1: Decision.evaluate rules and their order.
    @Suite struct DecisionTests {
        static let now = Date(timeIntervalSince1970: 1_800_000_000)
        static let ac = PowerState(onBattery: false, chargePercent: 100)

        @Test func constantsMatchSpec() {
            #expect(Decision.defaultSettle == 300)
            #expect(Decision.lowBatteryPercent == 20)
        }

        @Test func noActivityAndNoHistoryIsIdle() {
            let inputs = Inputs(forced: false, herdrWorking: false, backgroundTask: false, power: Self.ac)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: nil)
            #expect(out.hold == false)
            #expect(out.reason == .idle)
            #expect(out.lastActive == nil)
        }

        @Test func herdrUnreachableAloneIsNotActive() {
            let inputs = Inputs(forced: false, herdrWorking: nil, backgroundTask: false, power: Self.ac)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: nil)
            #expect(out.hold == false)
            #expect(out.reason == .idle)
            #expect(out.lastActive == nil)
        }

        @Test(
            "active sources hold, set lastActive=now, and follow priority forced > herdrWorking > backgroundTask",
            arguments: [
                (true, false, false, Reason.forced),
                (true, true, true, Reason.forced),
                (true, nil, true, Reason.forced),
                (true, nil, false, Reason.forced),
                (false, true, false, Reason.herdrWorking),
                (false, true, true, Reason.herdrWorking),
                (false, false, true, Reason.backgroundTask),
                (false, nil, true, Reason.backgroundTask),
            ] as [(Bool, Bool?, Bool, Reason)]
        )
        func activeReasonPriority(forced: Bool, herdr: Bool?, background: Bool, expected: Reason) {
            let inputs = Inputs(forced: forced, herdrWorking: herdr, backgroundTask: background, power: Self.ac)
            let earlier = Self.now.addingTimeInterval(-1000)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: earlier)
            #expect(out.hold == true)
            #expect(out.reason == expected)
            #expect(out.lastActive == Self.now)
        }

        @Test func activeWithoutHistorySetsLastActive() {
            let inputs = Inputs(forced: false, herdrWorking: false, backgroundTask: true, power: Self.ac)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: nil)
            #expect(out.hold == true)
            #expect(out.lastActive == Self.now)
        }

        @Test(
            "inactive within the settle window keeps holding as settling",
            arguments: [0.0, 1.0, 299.0, 299.999, -5.0]
        )
        func settlingInsideWindow(elapsed: TimeInterval) {
            let inputs = Inputs(forced: false, herdrWorking: false, backgroundTask: false, power: Self.ac)
            let last = Self.now.addingTimeInterval(-elapsed)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: last)
            #expect(out.hold == true)
            #expect(out.reason == .settling)
            #expect(out.lastActive == last)
        }

        @Test(
            "inactive at or after the settle window is idle (exactly 300 s is not settling)",
            arguments: [300.0, 300.001, 301.0, 10_000.0]
        )
        func idleAtOrAfterWindow(elapsed: TimeInterval) {
            let inputs = Inputs(forced: false, herdrWorking: nil, backgroundTask: false, power: Self.ac)
            let last = Self.now.addingTimeInterval(-elapsed)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: last)
            #expect(out.hold == false)
            #expect(out.reason == .idle)
            #expect(out.lastActive == last)
        }

        @Test func customSettleIsHonoured() {
            let inputs = Inputs(forced: false, herdrWorking: false, backgroundTask: false, power: Self.ac)
            let inside = Decision.evaluate(
                inputs, now: Self.now, lastActive: Self.now.addingTimeInterval(-9.5), settle: 10)
            #expect(inside.hold == true)
            #expect(inside.reason == .settling)
            let boundary = Decision.evaluate(
                inputs, now: Self.now, lastActive: Self.now.addingTimeInterval(-10), settle: 10)
            #expect(boundary.hold == false)
            #expect(boundary.reason == .idle)
            // Default settle (300 s) would still be settling at 60 s.
            let defaulted = Decision.evaluate(inputs, now: Self.now, lastActive: Self.now.addingTimeInterval(-60))
            #expect(defaulted.reason == .settling)
        }

        struct PowerCase: Sendable, CustomTestStringConvertible {
            var onBattery: Bool
            var charge: Int?
            var forced: Bool
            var herdr: Bool?
            var background: Bool
            var hold: Bool
            var reason: Reason
            var testDescription: String {
                "battery=\(onBattery) charge=\(charge.map(String.init) ?? "nil") forced=\(forced) herdr=\(String(describing: herdr)) bg=\(background) ⇒ \(reason)"
            }
        }

        @Test(
            "battery-low threshold and AC ignoring charge",
            arguments: [
                PowerCase(onBattery: true, charge: nil, forced: true, herdr: true, background: true, hold: false, reason: .batteryLow),
                PowerCase(onBattery: true, charge: 19, forced: true, herdr: false, background: false, hold: false, reason: .batteryLow),
                PowerCase(onBattery: true, charge: 0, forced: false, herdr: true, background: false, hold: false, reason: .batteryLow),
                PowerCase(onBattery: true, charge: 19, forced: false, herdr: false, background: false, hold: false, reason: .batteryLow),
                PowerCase(onBattery: true, charge: 20, forced: true, herdr: false, background: false, hold: true, reason: .forced),
                PowerCase(onBattery: true, charge: 20, forced: false, herdr: false, background: false, hold: false, reason: .idle),
                PowerCase(onBattery: true, charge: 100, forced: false, herdr: false, background: true, hold: true, reason: .backgroundTask),
                PowerCase(onBattery: false, charge: 5, forced: true, herdr: false, background: false, hold: true, reason: .forced),
                PowerCase(onBattery: false, charge: 0, forced: false, herdr: false, background: true, hold: true, reason: .backgroundTask),
                PowerCase(onBattery: false, charge: nil, forced: false, herdr: true, background: false, hold: true, reason: .herdrWorking),
            ]
        )
        func powerRules(_ c: PowerCase) {
            let inputs = Inputs(
                forced: c.forced, herdrWorking: c.herdr, backgroundTask: c.background,
                power: PowerState(onBattery: c.onBattery, chargePercent: c.charge))
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: nil)
            #expect(out.hold == c.hold)
            #expect(out.reason == c.reason)
        }

        @Test func batteryLowOverridesSettlingAndKeepsLastActive() {
            let inputs = Inputs(
                forced: false, herdrWorking: false, backgroundTask: false,
                power: PowerState(onBattery: true, chargePercent: 5))
            let last = Self.now.addingTimeInterval(-10)
            let out = Decision.evaluate(inputs, now: Self.now, lastActive: last)
            #expect(out.hold == false)
            #expect(out.reason == .batteryLow)
            #expect(out.lastActive == last)
        }

        @Test func batteryLowWhileActiveDoesNotUpdateLastActive() {
            let inputs = Inputs(
                forced: true, herdrWorking: true, backgroundTask: true,
                power: PowerState(onBattery: true, chargePercent: nil))
            let last = Self.now.addingTimeInterval(-1000)
            let withHistory = Decision.evaluate(inputs, now: Self.now, lastActive: last)
            #expect(withHistory.reason == .batteryLow)
            #expect(withHistory.lastActive == last)
            let withoutHistory = Decision.evaluate(inputs, now: Self.now, lastActive: nil)
            #expect(withoutHistory.reason == .batteryLow)
            #expect(withoutHistory.lastActive == nil)
        }

        @Test func lastActiveUpdatesOnlyWhenActive() {
            let last = Self.now.addingTimeInterval(-50)
            let idle = Inputs(forced: false, herdrWorking: false, backgroundTask: false, power: Self.ac)
            let active = Inputs(forced: false, herdrWorking: true, backgroundTask: false, power: Self.ac)
            #expect(Decision.evaluate(idle, now: Self.now, lastActive: last).lastActive == last)
            #expect(Decision.evaluate(active, now: Self.now, lastActive: last).lastActive == Self.now)
        }
    }
}
