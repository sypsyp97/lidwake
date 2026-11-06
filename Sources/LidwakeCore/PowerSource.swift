import Foundation
import IOKit.ps

public enum PowerSource {
  public static func parse(_ description: [String: Any]) -> PowerState {
    let onBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
    guard let current = description[kIOPSCurrentCapacityKey] as? Int,
      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
    else { return PowerState(onBattery: onBattery, chargePercent: nil) }
    let (scaled, overflow) = current.multipliedReportingOverflow(by: 100)
    let percent = overflow ? (current > 0 ? 100 : 0) : scaled / maximum
    return PowerState(onBattery: onBattery, chargePercent: min(max(percent, 0), 100))
  }

  /// The internal battery's state; a Mac without one reports AC with unknown charge.
  public static func read() -> PowerState {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return PowerState(onBattery: false, chargePercent: nil) }
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any],
        (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
      else { continue }
      return parse(description)
    }
    return PowerState(onBattery: false, chargePercent: nil)
  }
}
