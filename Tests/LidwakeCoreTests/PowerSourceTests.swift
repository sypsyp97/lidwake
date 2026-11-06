import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §5: PowerSource.parse (pure) and read().
    @Suite struct PowerSourceTests {
        struct ParseCase: Sendable, CustomTestStringConvertible {
            var state: String?
            var current: Int?
            var max: Int?
            var onBattery: Bool
            var charge: Int?
            var testDescription: String {
                "state=\(state ?? "nil") cur=\(current.map(String.init) ?? "nil") max=\(max.map(String.init) ?? "nil")"
            }

            var dictionary: [String: Any] {
                var d: [String: Any] = [:]
                if let state { d["Power Source State"] = state }
                if let current { d["Current Capacity"] = current }
                if let max { d["Max Capacity"] = max }
                return d
            }
        }

        @Test(
            "parse covers state, charge ratio, rounding, missing keys, max<=0 and clamping",
            arguments: [
                ParseCase(state: "Battery Power", current: 50, max: 100, onBattery: true, charge: 50),
                ParseCase(state: "AC Power", current: 80, max: 100, onBattery: false, charge: 80),
                ParseCase(state: nil, current: 80, max: 100, onBattery: false, charge: 80),
                ParseCase(state: "Battery Power", current: 4000, max: 5000, onBattery: true, charge: 80),
                ParseCase(state: "Battery Power", current: 2, max: 3, onBattery: true, charge: 66),
                ParseCase(state: "Battery Power", current: 999, max: 1000, onBattery: true, charge: 99),
                ParseCase(state: "Battery Power", current: 19, max: 100, onBattery: true, charge: 19),
                ParseCase(state: "Battery Power", current: 0, max: 100, onBattery: true, charge: 0),
                ParseCase(state: "AC Power", current: 100, max: 100, onBattery: false, charge: 100),
                ParseCase(state: "Battery Power", current: nil, max: 100, onBattery: true, charge: nil),
                ParseCase(state: "Battery Power", current: 50, max: nil, onBattery: true, charge: nil),
                ParseCase(state: "AC Power", current: nil, max: nil, onBattery: false, charge: nil),
                ParseCase(state: "Battery Power", current: 50, max: 0, onBattery: true, charge: nil),
                ParseCase(state: "Battery Power", current: 50, max: -5, onBattery: true, charge: nil),
                ParseCase(state: "AC Power", current: 150, max: 100, onBattery: false, charge: 100),
                ParseCase(state: "Battery Power", current: -10, max: 100, onBattery: true, charge: 0),
                ParseCase(state: nil, current: nil, max: nil, onBattery: false, charge: nil),
            ]
        )
        func parse(_ c: ParseCase) {
            let state = PowerSource.parse(c.dictionary)
            #expect(state == PowerState(onBattery: c.onBattery, chargePercent: c.charge))
        }

        @Test func parseAcceptsNSNumberValuesAsIOKitDeliversThem() {
            let d: [String: Any] = [
                "Power Source State": "Battery Power" as NSString,
                "Current Capacity": NSNumber(value: 37),
                "Max Capacity": NSNumber(value: 100),
            ]
            #expect(PowerSource.parse(d) == PowerState(onBattery: true, chargePercent: 37))
        }

        @Test func readReturnsSaneState() {
            let state = PowerSource.read()
            if let charge = state.chargePercent {
                #expect((0...100).contains(charge))
            }
        }
    }
}
