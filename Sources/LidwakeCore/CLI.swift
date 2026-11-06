import Foundation

public enum Command: Equatable {
  case run(dryRun: Bool, ticks: Int?, interval: TimeInterval)
  case status, on, off, restore
}

public enum CommandError: Error, Equatable {
  case usage(String)
}

public enum CLIParser {
  private static let defaultInterval: TimeInterval = 30
  /// One day. Also rejects NaN and infinity, which fail every comparison or this bound.
  private static let maxInterval: TimeInterval = 86_400
  private static let usage = """
    usage: lidwake run [--dry-run] [--ticks N] [--interval SECONDS]
           lidwake status | on | off | restore
    """

  /// `args` excludes argv[0].
  public static func parse(_ args: [String]) throws -> Command {
    guard let name = args.first else { throw CommandError.usage(usage) }
    let options = args.dropFirst()
    let simple: [String: Command] = [
      "status": .status, "on": .on, "off": .off, "restore": .restore,
    ]
    if let command = simple[name] {
      guard options.isEmpty else { throw CommandError.usage("\(name) takes no options\n\(usage)") }
      return command
    }
    guard name == "run" else { throw CommandError.usage("unknown command '\(name)'\n\(usage)") }
    return try parseRun(Array(options))
  }

  private static func parseRun(_ options: [String]) throws -> Command {
    var dryRun = false
    var ticks: Int?
    var interval = defaultInterval
    var rest = options[...]
    while let option = rest.popFirst() {
      switch option {
      case "--dry-run":
        dryRun = true
      case "--ticks":
        guard let value = rest.popFirst().flatMap({ Int($0) }), value >= 1 else {
          throw CommandError.usage("--ticks needs an integer N >= 1\n\(usage)")
        }
        ticks = value
      case "--interval":
        guard let value = rest.popFirst().flatMap({ TimeInterval($0) }), value > 0,
          value <= maxInterval
        else {
          throw CommandError.usage("--interval needs seconds S with 0 < S <= 86400\n\(usage)")
        }
        interval = value
      default:
        throw CommandError.usage("unknown option '\(option)'\n\(usage)")
      }
    }
    return .run(dryRun: dryRun, ticks: ticks, interval: interval)
  }
}
