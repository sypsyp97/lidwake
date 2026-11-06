import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §9: CLIParser.parse.
    @Suite struct CLIParserTests {
        @Test func runDefaults() throws {
            #expect(try CLIParser.parse(["run"]) == .run(dryRun: false, ticks: nil, interval: 30))
        }

        @Test(
            "run options in any order",
            arguments: [
                (["run", "--dry-run"], true, nil, 30.0),
                (["run", "--ticks", "5"], false, 5, 30.0),
                (["run", "--ticks", "1"], false, 1, 30.0),
                (["run", "--interval", "0.05"], false, nil, 0.05),
                (["run", "--interval", "45"], false, nil, 45.0),
                (["run", "--dry-run", "--ticks", "20", "--interval", "0.05"], true, 20, 0.05),
                (["run", "--interval", "2.5", "--dry-run", "--ticks", "3"], true, 3, 2.5),
                (["run", "--ticks", "7", "--interval", "10"], false, 7, 10.0),
                (["run", "--interval", "86400"], false, nil, 86400.0),
                (["run", "--dry-run", "--interval", "86400"], true, nil, 86400.0),
            ] as [([String], Bool, Int?, Double)]
        )
        func runWithOptions(args: [String], dryRun: Bool, ticks: Int?, interval: Double) throws {
            #expect(try CLIParser.parse(args) == .run(dryRun: dryRun, ticks: ticks, interval: interval))
        }

        @Test func status() throws {
            #expect(try CLIParser.parse(["status"]) == .status)
        }

        @Test func on() throws {
            #expect(try CLIParser.parse(["on"]) == .on)
        }

        @Test func off() throws {
            #expect(try CLIParser.parse(["off"]) == .off)
        }

        @Test func restore() throws {
            #expect(try CLIParser.parse(["restore"]) == .restore)
        }

        @Test(
            "usage errors",
            arguments: [
                [],
                [""],
                ["bogus"],
                ["RUN"],
                ["--dry-run"],
                ["--ticks", "3"],
                ["run", "--bogus"],
                ["run", "extra"],
                ["run", "--ticks"],
                ["run", "--ticks", "0"],
                ["run", "--ticks", "-1"],
                ["run", "--ticks", "abc"],
                ["run", "--ticks", "1.5"],
                ["run", "--ticks", ""],
                ["run", "--interval"],
                ["run", "--interval", "0"],
                ["run", "--interval", "-1"],
                ["run", "--interval", "abc"],
                ["run", "--interval", ""],
                ["run", "--interval", "nan"],
                ["run", "--interval", "86400.001"],
                ["run", "--interval", "86401"],
                ["run", "--interval", "1e300"],
                ["run", "--interval", "inf"],
                ["run", "--interval", "+inf"],
                ["run", "--interval", "infinity"],
                ["run", "--interval", "-inf"],
                ["run", "--dry-run", "--interval", "1e300"],
                ["run", "--dry-run", "--ticks"],
                ["status", "--dry-run"],
                ["status", "extra"],
                ["on", "x"],
                ["on", "--ticks", "1"],
                ["off", "--interval", "5"],
                ["off", "x"],
                ["restore", "--dry-run"],
                ["restore", "extra"],
            ] as [[String]]
        )
        func usageErrors(args: [String]) {
            let error = #expect(throws: CommandError.self) { try CLIParser.parse(args) }
            if case .usage(let message)? = error {
                #expect(!message.isEmpty)
            }
        }
    }
}
