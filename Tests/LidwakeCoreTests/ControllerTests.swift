import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §8: Controller orchestration with fake dependencies.
    @Suite struct ControllerTests {
        static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        /// Wires a Controller to fakes and a fresh journal directory.
        final class Rig {
            let dir: URL
            let store: JournalStore
            let provider: FakeInputsProvider
            let sleep: FakeSleepControl
            let assertion = FakeAssertion()
            let probe: FakeProcessProbe
            let controller: Controller

            init(
                sleepState: Bool?, inputs: Inputs = Fixtures.idle(), journal: Journal? = nil,
                settle: TimeInterval? = nil, running: [ProcessIdentity] = [],
                stopped: [ProcessIdentity] = []
            ) throws {
                let dir = try TempPaths.makeDirectory("controller")
                self.dir = dir
                store = JournalStore(directory: dir)
                if let journal {
                    do {
                        try store.save(journal)
                    } catch {
                        TempPaths.remove(dir)
                        throw error
                    }
                }
                provider = FakeInputsProvider(inputs)
                sleep = FakeSleepControl(state: sleepState)
                probe = FakeProcessProbe(running: running, stopped: stopped)
                if let settle {
                    controller = Controller(
                        provider: provider, sleep: sleep, assertion: assertion, store: store, probe: probe,
                        settle: settle)
                } else {
                    controller = Controller(
                        provider: provider, sleep: sleep, assertion: assertion, store: store, probe: probe)
                }
            }

            func at(_ seconds: TimeInterval) -> Date { ControllerTests.t0.addingTimeInterval(seconds) }

            /// Removes the journal directory. Tests call it via `defer` so the directory
            /// outlives every use of the rig, independent of when ARC releases it.
            func cleanup() { TempPaths.remove(dir) }
        }

        // MARK: tick

        @Test func idleTickTouchesNothing() throws {
            let rig = try Rig(sleepState: false)
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            let out = rig.controller.tick(now: rig.at(0))
            #expect(out.hold == false)
            #expect(out.reason == .idle)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == false)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load().owned == false)
        }

        @Test func activeTickDisablesSleepOwnsItAndHoldsAssertion() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            let out = rig.controller.tick(now: rig.at(0))
            #expect(out.hold == true)
            #expect(out.reason == .herdrWorking)
            #expect(out.lastActive == rig.at(0))
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0)))
        }

        @Test func tickOutcomeMatchesDecisionAndUsesInputsFromProvider() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.forced())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            #expect(rig.controller.tick(now: rig.at(0)).reason == .forced)
            rig.provider.current = Inputs(
                forced: false, herdrWorking: nil, backgroundTask: true, power: Fixtures.acPower)
            let out = rig.controller.tick(now: rig.at(10))
            #expect(out.reason == .backgroundTask)
            #expect(out.lastActive == rig.at(10))
        }

        @Test func repeatedActiveTicksMakeNoRedundantCalls() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.controller.tick(now: rig.at(30))
            rig.controller.tick(now: rig.at(60))
            #expect(rig.sleep.calls == [true])
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(60)))
        }

        @Test func settlingKeepsHoldThenReleasesAfterSettleWindow() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))

            rig.provider.current = Fixtures.idle()
            let settling = rig.controller.tick(now: rig.at(100))
            #expect(settling.hold == true)
            #expect(settling.reason == .settling)
            #expect(rig.sleep.calls == [true])
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0)))

            let idle = rig.controller.tick(now: rig.at(300))
            #expect(idle.hold == false)
            #expect(idle.reason == .idle)
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.sleep.state == false)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0)))

            rig.controller.tick(now: rig.at(330))
            rig.controller.tick(now: rig.at(360))
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.assertion.held == false)
        }

        @Test func customSettlePassedToControllerIsUsed() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working(), settle: 60)
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.provider.current = Fixtures.idle()
            #expect(rig.controller.tick(now: rig.at(59)).reason == .settling)
            #expect(rig.controller.tick(now: rig.at(60)).reason == .idle)
            #expect(rig.sleep.calls == [true, false])
        }

        @Test func userSetSleepDisabledIsNeverTouched() throws {
            let rig = try Rig(sleepState: true, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            let active = rig.controller.tick(now: rig.at(0))
            #expect(active.hold == true)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load().owned == false)

            rig.provider.current = Fixtures.idle()
            let idle = rig.controller.tick(now: rig.at(1000))
            #expect(idle.hold == false)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == false)

            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
        }

        @Test func tickSavesLastActiveEvenWhenNotOwning() throws {
            let rig = try Rig(sleepState: true, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(5))
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(5)))
        }

        @Test func unreadableSleepStateDoesNotClaimAndRetriesNextTick() throws {
            let rig = try Rig(sleepState: nil, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            let first = rig.controller.tick(now: rig.at(0))
            #expect(first.hold == true)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == true)

            rig.controller.tick(now: rig.at(30))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == true)

            // Once the flag reads false, the next hold tick claims it.
            rig.sleep.state = false
            rig.controller.tick(now: rig.at(60))
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)
        }

        @Test func unreadableSleepStateNotOwnedNeverDisablesOnIdleOrStop() throws {
            let rig = try Rig(sleepState: nil, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.provider.current = Fixtures.idle()
            let idle = rig.controller.tick(now: rig.at(1000))
            #expect(idle.hold == false)
            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == false)
        }

        @Test func holdWhileOwnedWithUnreadableFlagMakesNoCall() throws {
            let rig = try Rig(
                sleepState: nil, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            let out = rig.controller.tick(now: rig.at(10))
            #expect(out.hold == true)
            rig.controller.tick(now: rig.at(40))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(40)))
            #expect(rig.assertion.held == true)
        }

        @Test func holdWhileOwnedReappliesEnableWhenFlagReadsFalse() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            #expect(rig.sleep.calls == [true])

            // Something reset the flag while lidwake still owns it.
            rig.sleep.state = false
            rig.controller.tick(now: rig.at(30))
            #expect(rig.sleep.calls == [true, true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)

            // The re-apply goes through the same path: its own child is recorded before it runs.
            let seen = probe.seen
            #expect(seen.count == 2)
            #expect(rig.sleep.identities.count == 2)
            #expect(seen.last?.0 == true)
            #expect(seen.last?.1.owned == true)
            #expect(seen.last?.1.pending == rig.sleep.identities.last)
            #expect(rig.store.load().pending == nil)
        }

        @Test func reapplyAfterCrashRecordsPendingBeforeChildRunsAndClearsAfter() throws {
            // Restarted run: owned on disk, flag reads false, hold ⇒ re-apply.
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(10))
            let seen = probe.seen
            #expect(seen.count == 1)
            #expect(rig.sleep.identities.count == 1)
            #expect(seen.first?.0 == true)
            #expect(seen.first?.1.owned == true)
            #expect(seen.first?.1.pending == rig.sleep.identities.first)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: nil))
        }

        @Test func holdWhileOwnedFailedReapplyKeepsOwnershipAndRetries() throws {
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            rig.sleep.failNext(1)
            let first = rig.controller.tick(now: rig.at(10))
            #expect(first.hold == true)
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)

            rig.controller.tick(now: rig.at(40))
            #expect(rig.sleep.calls == [true, true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)

            rig.controller.tick(now: rig.at(70))
            #expect(rig.sleep.calls == [true, true])
        }

        @Test(
            "idle tick while owned disables sleep even if the flag already reads false/nil",
            arguments: [false, nil] as [Bool?]
        )
        func idleWhileOwnedDisablesWhateverFlagReads(state: Bool?) throws {
            let rig = try Rig(sleepState: state, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            let out = rig.controller.tick(now: rig.at(1000))
            #expect(out.hold == false)
            #expect(rig.sleep.calls == [false])
            #expect(rig.store.load() == Journal(owned: false, lastActive: ControllerTests.t0))
            #expect(rig.assertion.held == false)

            rig.controller.tick(now: rig.at(1030))
            rig.controller.stop()
            #expect(rig.sleep.calls == [false])
        }

        @Test func idleWhileOwnedFailedDisableWithFlagFalseKeepsOwnershipAndRetries() throws {
            let rig = try Rig(sleepState: false, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            rig.sleep.failNext(1)
            rig.controller.tick(now: rig.at(1000))
            #expect(rig.sleep.calls == [false])
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == false)

            rig.controller.tick(now: rig.at(1030))
            #expect(rig.sleep.calls == [false, false])
            #expect(rig.store.load().owned == false)
        }

        @Test func failedEnableIsRetriedNextTick() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.sleep.failNext(1)
            rig.controller.start(now: rig.at(0))
            let first = rig.controller.tick(now: rig.at(0))
            #expect(first.hold == true)
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == true)

            rig.controller.tick(now: rig.at(30))
            #expect(rig.sleep.calls == [true, true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)
        }

        @Test func failedDisableIsRetriedNextTick() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.provider.current = Fixtures.idle()
            rig.sleep.failNext(1)

            let first = rig.controller.tick(now: rig.at(400))
            #expect(first.hold == false)
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == false)

            rig.controller.tick(now: rig.at(430))
            #expect(rig.sleep.calls == [true, false, false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)

            rig.controller.tick(now: rig.at(460))
            #expect(rig.sleep.calls == [true, false, false])
        }

        /// Thread-safe recorder of journal snapshots taken inside `setSleepDisabled`.
        final class JournalProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var _seen: [(Bool, Journal)] = []
            var seen: [(Bool, Journal)] { lock.lock(); defer { lock.unlock() }; return _seen }
            func record(_ on: Bool, _ j: Journal) { lock.lock(); _seen.append((on, j)); lock.unlock() }
        }

        @Test func journalSaysOwnedBeforeSleepIsDisabled() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            let seen = probe.seen
            #expect(seen.count == 1)
            #expect(seen.first?.0 == true)
            #expect(seen.first?.1.owned == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == true)
        }

        @Test func failedEnableRevertsWriteAheadOwnership() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.sleep.failNext(1)
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            // Write-ahead happened before the failing call, then was reverted and saved.
            #expect(probe.seen.map(\.1.owned) == [true])
            #expect(rig.store.load().owned == false)
            #expect(rig.sleep.state == false)

            // A restart now must not see a stale owned=true.
            let restarted = Controller(
                provider: rig.provider, sleep: rig.sleep, assertion: FakeAssertion(), store: rig.store,
                probe: rig.probe)
            restarted.start(now: rig.at(1))
            #expect(rig.store.load().owned == false)
            #expect(rig.sleep.calls == [true])
        }

        @Test func crashBetweenWriteAheadAndPmsetIsReappliedOnNextHoldTick() throws {
            // Journal says owned, but SleepDisabled never became true (crash before pmset ran).
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0)))

            let hold = rig.controller.tick(now: rig.at(10))
            #expect(hold.hold == true)
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10)))
            #expect(rig.assertion.held == true)

            rig.provider.current = Fixtures.idle()
            let idle = rig.controller.tick(now: rig.at(1000))
            #expect(idle.hold == false)
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(10)))
            #expect(rig.assertion.held == false)
        }

        @Test func crashBetweenWriteAheadAndPmsetIsClearedOnNextIdleTick() throws {
            let rig = try Rig(sleepState: false, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(5))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().owned == true)

            rig.controller.tick(now: rig.at(1000))
            // setSleepDisabled(false) runs while the journal still says owned; ownership drops after.
            #expect(probe.seen.map(\.0) == [false])
            #expect(probe.seen.map(\.1.owned) == [true])
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0)))
            #expect(rig.assertion.held == false)
        }

        @Test func batteryLowReleasesEvenWhenForced() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.forced())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            #expect(rig.sleep.calls == [true])

            rig.provider.current = Fixtures.forced(power: Fixtures.lowBattery)
            let out = rig.controller.tick(now: rig.at(30))
            #expect(out.hold == false)
            #expect(out.reason == .batteryLow)
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.assertion.held == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0)))
        }

        @Test func assertionHeldIffLastOutcomeHeld() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            // (inputs, time, expected hold): active, settling, idle, idle, forced, battery low, active.
            let steps: [(Inputs, TimeInterval, Bool)] = [
                (Fixtures.working(), 0, true),
                (Fixtures.idle(), 100, true),
                (Fixtures.idle(), 400, false),
                (Fixtures.idle(), 430, false),
                (Fixtures.forced(), 460, true),
                (Fixtures.forced(power: Fixtures.lowBattery), 490, false),
                (Fixtures.working(), 520, true),
            ]
            for (inputs, seconds, expected) in steps {
                rig.provider.current = inputs
                let out = rig.controller.tick(now: rig.at(seconds))
                #expect(out.hold == expected, "at t+\(seconds)")
                #expect(rig.assertion.held == out.hold, "at t+\(seconds)")
            }
        }

        // MARK: pending child identity (write-ahead of the privileged child)

        @Test func pendingIsRecordedBeforeEnableChildRunsAndClearedAfter() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            let seen = probe.seen
            #expect(seen.count == 1)
            #expect(seen.first?.0 == true)
            #expect(seen.first?.1.owned == true)
            #expect(rig.sleep.identities.count == 1)
            #expect(seen.first?.1.pending == rig.sleep.identities.first)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0), pending: nil))
        }

        @Test func pendingIsRecordedBeforeDisableChildRunsOnIdleTickAndClearedAfter() throws {
            let rig = try Rig(sleepState: true, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(1000))
            let seen = probe.seen
            #expect(seen.count == 1)
            #expect(seen.first?.0 == false)
            #expect(seen.first?.1.owned == true)
            #expect(seen.first?.1.pending == rig.sleep.identities.first)
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
        }

        @Test func pendingIsRecordedBeforeDisableChildRunsOnStopAndClearedAfter() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.controller.stop()
            let seen = probe.seen
            #expect(seen.map(\.0) == [true, false])
            #expect(seen.map(\.1.owned) == [true, true])
            #expect(rig.sleep.identities.count == 2)
            #expect(seen.map(\.1.pending) == rig.sleep.identities.map { Optional($0) })
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
        }

        @Test func pendingIsClearedAfterEveryFailedChild() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))

            // Failed enable.
            rig.sleep.failNext(1)
            rig.controller.tick(now: rig.at(0))
            #expect(rig.sleep.launched == [true])
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))

            // Successful enable, then failed disable on idle.
            rig.controller.tick(now: rig.at(30))
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(30), pending: nil))
            rig.provider.current = Fixtures.idle()
            rig.sleep.failNext(1)
            rig.controller.tick(now: rig.at(1000))
            #expect(rig.sleep.launched == [true, true, false])
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(30), pending: nil))

            // Failed disable on stop.
            rig.sleep.failNext(1)
            rig.controller.stop()
            #expect(rig.sleep.launched == [true, true, false, false])
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(30), pending: nil))
        }

        /// Makes `dir` unwritable (journal saves fail) or writable again.
        static func setWritable(_ dir: URL, _ writable: Bool) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: dir.path)
        }

        @Test func failedPendingRecordOnEnableKillsChildAndRevertsOwnership() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let dir = rig.dir
            defer { Self.setWritable(dir, true) }
            rig.sleep.beforeRecorded = { Self.setWritable(dir, false) }
            rig.sleep.afterRecordedThrew = { Self.setWritable(dir, true) }
            rig.controller.start(now: rig.at(0))
            let out = rig.controller.tick(now: rig.at(0))
            #expect(out.hold == true)
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.launched.isEmpty)
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
            #expect(rig.assertion.held == true)

            // Journal writable again: the next hold tick retries and succeeds.
            rig.sleep.beforeRecorded = nil
            rig.sleep.afterRecordedThrew = nil
            rig.controller.tick(now: rig.at(30))
            #expect(rig.sleep.launched == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(30), pending: nil))
        }

        @Test func failedPendingRecordOnDisableKillsChildAndKeepsOwnership() throws {
            let rig = try Rig(sleepState: true, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let dir = rig.dir
            defer { Self.setWritable(dir, true) }
            rig.controller.start(now: rig.at(5))
            rig.sleep.beforeRecorded = { Self.setWritable(dir, false) }
            rig.sleep.afterRecordedThrew = { Self.setWritable(dir, true) }
            let out = rig.controller.tick(now: rig.at(1000))
            #expect(out.hold == false)
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.launched.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0), pending: nil))
            #expect(rig.assertion.held == false)

            rig.sleep.beforeRecorded = nil
            rig.sleep.afterRecordedThrew = nil
            rig.controller.tick(now: rig.at(1030))
            #expect(rig.sleep.launched == [false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
        }

        // MARK: orphan guard (a crashed run's privileged child may still be running)

        static let orphan = ProcessIdentity(pid: 4242, startTime: 1_799_999_000_000_000)

        @Test func liveOrphanBlocksEverySleepCallOnHoldIdleAndStop() throws {
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                running: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            #expect(rig.sleep.calls.isEmpty)

            // Owned and the flag reads false: normally re-applied, but the orphan blocks it.
            let hold = rig.controller.tick(now: rig.at(10))
            #expect(hold.hold == true)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))

            // Idle while owned: normally cleared, but the orphan blocks it.
            rig.provider.current = Fixtures.idle()
            let idle = rig.controller.tick(now: rig.at(1000))
            #expect(idle.hold == false)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))

            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == false)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))
            // A running orphan may be mid-pmset: it is waited for, never killed.
            #expect(rig.probe.killed.isEmpty)
        }

        @Test func goneOrphanIsClearedThenIdleWhileOwnedDisables() throws {
            let rig = try Rig(
                sleepState: true,
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            let probe = JournalProbe()
            let store = rig.store
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(5))
            let out = rig.controller.tick(now: rig.at(1000))
            #expect(out.hold == false)
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.state == false)
            // The call recorded its own child, not the gone orphan.
            #expect(probe.seen.first?.1.pending == rig.sleep.identities.first)
            #expect(probe.seen.first?.1.pending != Self.orphan)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
        }

        @Test func goneOrphanIsClearedFromJournalEvenWhenTickMakesNoCall() throws {
            // Hold while owned and the flag reads true: no setSleepDisabled call is due.
            // The gone orphan must still be dropped from the journal.
            let rig = try Rig(
                sleepState: true, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            #expect(rig.probe.state(Self.orphan) == .gone)
            rig.controller.start(now: rig.at(5))
            let out = rig.controller.tick(now: rig.at(10))
            #expect(out.hold == true)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: nil))
            #expect(rig.probe.killed.isEmpty)
        }

        @Test func orphanExitingMidRunUnblocksReapplyOnNextHoldTick() throws {
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                running: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(10))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().pending == Self.orphan)

            rig.probe.set(Self.orphan, .gone)
            rig.controller.tick(now: rig.at(40))
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(40), pending: nil))
        }

        @Test func lateLandingEnableChildOfCrashedRunIsClearedOnlyAfterItExits() throws {
            // TLA+ counterexample: a crashed run recorded an enable child (owned=true, pending=X)
            // that has not landed yet. The restarted run is idle.
            let rig = try Rig(
                sleepState: false,
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                running: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(1000))
            // A clear now could be overtaken by the orphan's late enable: no call.
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0), pending: Self.orphan))

            // The orphan lands (flag true) and is still alive: still no call.
            rig.sleep.state = true
            rig.controller.tick(now: rig.at(1030))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)

            // The orphan exits: the next idle tick clears the flag lidwake owns.
            rig.probe.set(Self.orphan, .gone)
            rig.controller.tick(now: rig.at(1060))
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))

            rig.controller.tick(now: rig.at(1090))
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == false)
        }

        // MARK: stopped orphan (crash between record and resume: the child never ran pmset)

        @Test func stoppedOrphanIsKilledAndBlocksEverySleepCallUntilGone() throws {
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                stopped: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            #expect(rig.sleep.calls.isEmpty)

            // Owned and the flag reads false: normally re-applied, but the stopped orphan blocks it.
            let hold = rig.controller.tick(now: rig.at(10))
            #expect(hold.hold == true)
            #expect(!rig.probe.killed.isEmpty)
            #expect(rig.probe.killed.allSatisfy { $0 == Self.orphan })
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))

            // Still stopped (the kill has not taken effect yet): idle while owned is still blocked.
            rig.provider.current = Fixtures.idle()
            let idle = rig.controller.tick(now: rig.at(1000))
            #expect(idle.hold == false)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))

            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == false)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(10), pending: Self.orphan))
            #expect(rig.probe.killed.allSatisfy { $0 == Self.orphan })
        }

        @Test func stoppedOrphanReportedGoneUnblocksReapplyOnNextHoldTick() throws {
            let rig = try Rig(
                sleepState: false, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                stopped: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(10))
            #expect(!rig.probe.killed.isEmpty)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load().pending == Self.orphan)

            rig.probe.set(Self.orphan, .gone)
            rig.controller.tick(now: rig.at(40))
            #expect(rig.sleep.calls == [true])
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(40), pending: nil))
        }

        @Test func killedStoppedOrphanIsClearedThenIdleWhileOwnedDisables() throws {
            // The orphan was recorded for an enable that never ran; the flag is true from an
            // earlier successful enable that lidwake owns.
            let rig = try Rig(
                sleepState: true,
                journal: Journal(owned: true, lastActive: ControllerTests.t0, pending: Self.orphan),
                stopped: [Self.orphan])
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.probe.killTakesEffect = true
            let probe = JournalProbe()
            let store = rig.store
            let fakeProbe = rig.probe
            rig.sleep.onSet = { on, _ in probe.record(on, store.load()) }
            rig.controller.start(now: rig.at(5))
            rig.controller.tick(now: rig.at(1000))
            rig.controller.tick(now: rig.at(1030))
            #expect(rig.probe.killed.first == Self.orphan)
            #expect(fakeProbe.state(Self.orphan) == .gone)
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.state == false)
            // The clear recorded its own child, not the killed orphan.
            #expect(probe.seen.first?.1.pending == rig.sleep.identities.first)
            #expect(probe.seen.first?.1.pending != Self.orphan)
            #expect(rig.store.load() == Journal(owned: false, lastActive: rig.at(0), pending: nil))
            #expect(rig.assertion.held == false)
        }

        @Test func noKillWithoutPendingChild() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.provider.current = Fixtures.idle()
            rig.controller.tick(now: rig.at(1000))
            rig.controller.stop()
            #expect(rig.probe.killed.isEmpty)
        }

        // MARK: stop

        @Test func stopRestoresOwnedSleepAndReleasesAssertion() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.controller.stop()
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.sleep.state == false)
            #expect(rig.assertion.held == false)
            #expect(rig.store.load().owned == false)
        }

        @Test func stopIsIdempotent() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.controller.stop()
            rig.controller.stop()
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.assertion.held == false)
            #expect(rig.store.load().owned == false)
        }

        @Test func stopWhenNotOwnedOnlyReleasesAssertion() throws {
            let rig = try Rig(sleepState: false)
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == false)
            #expect(rig.assertion.releaseCalls >= 1)
            #expect(rig.store.load().owned == false)
        }

        @Test func stopFailureKeepsOwnedOnDiskAndReleasesAssertion() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.sleep.failNext(1)
            rig.controller.stop()
            #expect(rig.sleep.calls == [true, false])
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == true)
            #expect(rig.assertion.held == false)
            #expect(rig.assertion.releaseCalls >= 1)
        }

        @Test func secondStopAfterFailedStopRetries() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.sleep.failNext(1)
            rig.controller.stop()
            rig.controller.stop()
            #expect(rig.sleep.calls == [true, false, false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == false)

            rig.controller.stop()
            #expect(rig.sleep.calls == [true, false, false])
            #expect(rig.store.load().owned == false)
        }

        @Test func restartAfterFailedStopClearsOnIdleTick() throws {
            let rig = try Rig(sleepState: false, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            rig.sleep.failNext(1)
            rig.controller.stop()
            #expect(rig.store.load().owned == true)

            rig.provider.current = Fixtures.idle()
            let assertion = FakeAssertion()
            let restarted = Controller(
                provider: rig.provider, sleep: rig.sleep, assertion: assertion, store: rig.store,
                probe: rig.probe)
            restarted.start(now: rig.at(10))
            #expect(rig.store.load().owned == true)
            #expect(rig.sleep.calls == [true, false])

            restarted.tick(now: rig.at(1000))
            #expect(rig.sleep.calls == [true, false, false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)
            #expect(assertion.held == false)
        }

        @Test func stopWhileUserHoldsSleepDisabledLeavesIt() throws {
            let rig = try Rig(sleepState: true, inputs: Fixtures.working())
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(0))
            #expect(rig.assertion.held == true)
            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.assertion.held == false)
        }

        // MARK: start (crash reconcile)

        @Test func startWithoutJournalChangesNothing() throws {
            let rig = try Rig(sleepState: false)
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load() == Journal())
        }

        @Test func startOwnedAndStillDisabledKeepsStateAndLastActive() throws {
            let rig = try Rig(sleepState: true, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(10))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(0)))

            // lastActive from the journal drives settling on the next tick.
            let settling = rig.controller.tick(now: rig.at(20))
            #expect(settling.hold == true)
            #expect(settling.reason == .settling)
            #expect(settling.lastActive == rig.at(0))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == true)

            // Still owned: once settled, the controller restores sleep.
            let idle = rig.controller.tick(now: rig.at(400))
            #expect(idle.hold == false)
            #expect(rig.sleep.calls == [false])
            #expect(rig.sleep.state == false)
            #expect(rig.store.load().owned == false)
            #expect(rig.assertion.held == false)
        }

        @Test func startOwnedAndStillDisabledThenActiveMakesNoCall() throws {
            let rig = try Rig(
                sleepState: true, inputs: Fixtures.working(),
                journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(10))
            let out = rig.controller.tick(now: rig.at(20))
            #expect(out.hold == true)
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.assertion.held == true)
            #expect(rig.store.load() == Journal(owned: true, lastActive: rig.at(20)))
            rig.controller.stop()
            #expect(rig.sleep.calls == [false])
            #expect(rig.store.load().owned == false)
        }

        @Test(
            "start with owned journal keeps ownership and lastActive whatever SleepDisabled reads",
            arguments: [true, false, nil] as [Bool?]
        )
        func startOwnedKeepsOwnershipWhateverFlagReads(state: Bool?) throws {
            let rig = try Rig(sleepState: state, journal: Journal(owned: true, lastActive: ControllerTests.t0))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(10))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == state)
            #expect(rig.store.load() == Journal(owned: true, lastActive: ControllerTests.t0))
        }

        @Test func startOwnedWithoutLastActiveKeepsOwnership() throws {
            let rig = try Rig(sleepState: nil, journal: Journal(owned: true, lastActive: nil))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(10))
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.store.load() == Journal(owned: true, lastActive: nil))
        }

        @Test func startNotOwnedWithUserDisabledLeavesItAlone() throws {
            let rig = try Rig(sleepState: true, journal: Journal(owned: false, lastActive: nil))
            defer { withExtendedLifetime(rig) { rig.cleanup() } }
            rig.controller.start(now: rig.at(0))
            rig.controller.tick(now: rig.at(1000))
            rig.controller.stop()
            #expect(rig.sleep.calls.isEmpty)
            #expect(rig.sleep.state == true)
            #expect(rig.store.load().owned == false)
        }
    }
}
