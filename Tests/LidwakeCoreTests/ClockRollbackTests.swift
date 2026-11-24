import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    @Suite struct ClockRollbackTests {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        @Test(arguments: [Reason.settling, .batteryLow, .herdrWorking, .idle])
        func futureTimeIsCorrectedInEveryBranch(reason: Reason) {
            let inputs: Inputs
            switch reason {
            case .settling, .idle: inputs = Fixtures.idle()
            case .batteryLow: inputs = Fixtures.forced(power: Fixtures.lowBattery)
            default: inputs = Fixtures.working()
            }
            let outcome = Decision.evaluate(
                inputs, now: now, lastActive: now.addingTimeInterval(86_400),
                settle: reason == .idle ? 0 : Decision.defaultSettle)
            #expect(outcome == Outcome(hold: reason == .settling || reason == .herdrWorking, reason: reason, lastActive: now))
        }

        @Test func correctedTimeBoundsTheNextSettleWindow() {
            let settle: TimeInterval = 37
            let idle = Fixtures.idle()
            let corrected = Decision.evaluate(idle, now: now, lastActive: now.addingTimeInterval(86_400), settle: settle)
            let before = Decision.evaluate(
                idle, now: now.addingTimeInterval(settle - 1), lastActive: corrected.lastActive, settle: settle)
            let end = Decision.evaluate(
                idle, now: now.addingTimeInterval(settle), lastActive: before.lastActive, settle: settle)
            #expect(before == Outcome(hold: true, reason: .settling, lastActive: now))
            #expect(end == Outcome(hold: false, reason: .idle, lastActive: now))
        }

        @Test func clockEquivalenceAndUnchangedDecisionRules() throws {
            let seed: UInt64 = 0xCC10_C005
            var rng = RecoveryRandom(seed: seed)
            for index in 0..<500 {
                let inputs = Inputs(
                    forced: rng.index(2) == 0, herdrWorking: [true, false, nil][rng.index(3)],
                    backgroundTask: rng.index(2) == 0,
                    power: PowerState(
                        onBattery: rng.index(2) == 0,
                        chargePercent: [nil, 0, 19, 20, 21, 100][rng.index(6)]))
                let time = now.addingTimeInterval(Double(rng.index(100_000)))
                let settle = TimeInterval(1 + rng.index(300))
                let future = time.addingTimeInterval(Double(1 + rng.index(86_400)))
                let present = Decision.evaluate(inputs, now: time, lastActive: time, settle: settle)
                try #require(
                    Decision.evaluate(inputs, now: time, lastActive: future, settle: settle) == present,
                    "seed \(seed), sample \(index), future \(future), inputs \(inputs)")
                let age = [0, settle - 1, settle, settle + 1, Double(rng.index(600))][rng.index(5)]
                for previous in [nil, time, time.addingTimeInterval(-age)] {
                    let expected = expectedDecision(inputs, now: time, lastActive: previous, settle: settle)
                    try #require(
                        Decision.evaluate(inputs, now: time, lastActive: previous, settle: settle) == expected,
                        "seed \(seed), sample \(index), previous \(String(describing: previous)), inputs \(inputs)")
                }
            }
        }
    }
}
