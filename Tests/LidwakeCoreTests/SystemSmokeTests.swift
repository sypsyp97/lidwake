import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §6: read-only smoke checks of the real implementations (no sudo, no pmset writes).
    @Suite struct SystemSmokeTests {
        @Test func pmsetSleepControlReadsSleepDisabledFromIORegistry() {
            #expect(PmsetSleepControl().isSleepDisabled() != nil)
        }

        @Test func powerAssertionHoldThenDoubleReleaseDoesNotCrash() throws {
            let assertion = PowerAssertion(name: "lidwake-test")
            try assertion.hold()
            assertion.release()
            assertion.release()
        }
    }
}
