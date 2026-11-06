import Foundation
import IOKit
import IOKit.pwr_mgt
import os

public protocol SleepControl: Sendable {
  /// `nil` when the flag cannot be read.
  func isSleepDisabled() -> Bool?
  /// Starts the privileged child suspended and passes its identity to `recorded` before the
  /// child runs. If `recorded` throws, the child is killed unrun and the error is rethrown.
  func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws
}

public protocol AssertionHolder: Sendable {
  func hold() throws
  func release()
}

struct SleepControlError: Error, Equatable {
  let detail: String
}

/// Reads `SleepDisabled` from IOPMrootDomain (no root needed); writes it through
/// `sudo -n pmset`, which the sudoers rule in `support/` allows without a password.
public struct PmsetSleepControl: SleepControl {
  public init() {}

  public func isSleepDisabled() -> Bool? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(
      service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
    return (value as? NSNumber)?.boolValue
  }

  public func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws {
    try runSuspended(
      ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"],
      recorded: recorded)
  }
}

/// PreventUserIdleSystemSleep assertion. `hold` and `release` are idempotent.
public final class PowerAssertion: AssertionHolder {
  private let name: String
  private let id = OSAllocatedUnfairLock<IOPMAssertionID?>(initialState: nil)

  public init(name: String) {
    self.name = name
  }

  deinit {
    release()
  }

  public func hold() throws {
    try id.withLock { current in
      guard current == nil else { return }
      var newID = IOPMAssertionID(0)
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &newID)
      guard result == kIOReturnSuccess else {
        throw SleepControlError(detail: "IOPMAssertionCreateWithName returned \(result)")
      }
      current = newID
    }
  }

  public func release() {
    id.withLock { current in
      guard let held = current else { return }
      IOPMAssertionRelease(held)
      current = nil
    }
  }
}
