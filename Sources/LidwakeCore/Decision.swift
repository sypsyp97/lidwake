import Foundation

public struct PowerState: Equatable, Sendable {
  public var onBattery: Bool
  public var chargePercent: Int?

  public init(onBattery: Bool, chargePercent: Int?) {
    self.onBattery = onBattery
    self.chargePercent = chargePercent
  }
}

public struct Inputs: Equatable, Sendable {
  /// Manual "on" (the force file exists).
  public var forced: Bool
  /// `nil` means herdr was unreachable.
  public var herdrWorking: Bool?
  /// A Claude Code task output file is open.
  public var backgroundTask: Bool
  public var power: PowerState

  public init(forced: Bool, herdrWorking: Bool?, backgroundTask: Bool, power: PowerState) {
    self.forced = forced
    self.herdrWorking = herdrWorking
    self.backgroundTask = backgroundTask
    self.power = power
  }
}

public enum Reason: String, Equatable, Sendable {
  case forced, herdrWorking, backgroundTask, settling, idle, batteryLow
}

public struct Outcome: Equatable, Sendable {
  public var hold: Bool
  public var reason: Reason
  public var lastActive: Date?

  public init(hold: Bool, reason: Reason, lastActive: Date?) {
    self.hold = hold
    self.reason = reason
    self.lastActive = lastActive
  }
}

public enum Decision {
  public static let defaultSettle: TimeInterval = 300
  public static let lowBatteryPercent = 20

  public static func evaluate(
    _ inputs: Inputs, now: Date, lastActive: Date?, settle: TimeInterval = defaultSettle
  ) -> Outcome {
    let power = inputs.power
    if power.onBattery, (power.chargePercent ?? 0) < lowBatteryPercent {
      return Outcome(hold: false, reason: .batteryLow, lastActive: lastActive)
    }
    if let reason = activeReason(inputs) {
      return Outcome(hold: true, reason: reason, lastActive: now)
    }
    if let lastActive, now.timeIntervalSince(lastActive) < settle {
      return Outcome(hold: true, reason: .settling, lastActive: lastActive)
    }
    return Outcome(hold: false, reason: .idle, lastActive: lastActive)
  }

  private static func activeReason(_ inputs: Inputs) -> Reason? {
    if inputs.forced { return .forced }
    if inputs.herdrWorking == true { return .herdrWorking }
    if inputs.backgroundTask { return .backgroundTask }
    return nil
  }
}
