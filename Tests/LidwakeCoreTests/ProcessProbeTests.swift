import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §6: LiveProcessProbe — `.gone` unless the pid exists AND its start time equals
    /// `startTime`; `.stopped` iff the process is stopped; `kill` sends SIGKILL only if the
    /// identity is not `.gone`.
    @Suite struct ProcessProbeTests {
        @Test func ownPidWithRealStartTimeIsRunning() throws {
            let start = try #require(processStartTime(getpid()))
            #expect(LiveProcessProbe().state(ProcessIdentity(pid: getpid(), startTime: start)) == .running)
        }

        @Test("own pid with a different start time is gone (pid reuse)", arguments: [-1, 1, 1_000_000] as [Int64])
        func ownPidWithWrongStartTimeIsGone(delta: Int64) throws {
            let start = try #require(processStartTime(getpid()))
            let wrong = UInt64(Int64(start) + delta)
            #expect(LiveProcessProbe().state(ProcessIdentity(pid: getpid(), startTime: wrong)) == .gone)
        }

        @Test func ownPidWithZeroStartTimeIsGone() {
            #expect(LiveProcessProbe().state(ProcessIdentity(pid: getpid(), startTime: 0)) == .gone)
        }

        @Test func sysctlHelperAgreesWithProcPidinfoForOwnPid() throws {
            let viaSysctl = try #require(sysctlProcessStartTime(getpid()))
            #expect(viaSysctl == processStartTime(getpid()))
        }

        /// The privileged pmset child runs as root. Its state must be readable as a normal user
        /// (spec §6: sysctl KERN_PROC_PID). Pid 1 (launchd) is the root process used here;
        /// it is only inspected, never signalled.
        @Test func rootOwnedPid1WithRealStartTimeIsRunning() throws {
            let start = try #require(sysctlProcessStartTime(1))
            #expect(LiveProcessProbe().state(ProcessIdentity(pid: 1, startTime: start)) == .running)
        }

        @Test("root-owned pid 1 with a different start time is gone", arguments: [-1, 1] as [Int64])
        func rootOwnedPid1WithWrongStartTimeIsGone(delta: Int64) throws {
            let start = try #require(sysctlProcessStartTime(1))
            let wrong = UInt64(Int64(start) + delta)
            #expect(LiveProcessProbe().state(ProcessIdentity(pid: 1, startTime: wrong)) == .gone)
        }

        @Test func runningChildIsRunningAndExitedChildIsGone() throws {
            let child = try SleepingChild()
            defer { child.stop() }
            let probe = LiveProcessProbe()
            #expect(probe.state(child.identity) == .running)
            child.stop()
            #expect(!child.process.isRunning)
            #expect(probe.state(child.identity) == .gone)
        }

        @Test func childStoppedWithSigstopIsStopped() throws {
            let child = try SleepingChild()
            defer { child.stop() }
            try child.suspend()
            let probe = LiveProcessProbe()
            #expect(eventually { probe.state(child.identity) == .stopped })
            #expect(child.process.isRunning)
        }

        @Test func killOnStoppedChildKillsIt() throws {
            let child = try SleepingChild()
            defer { child.stop() }
            try child.suspend()
            let probe = LiveProcessProbe()
            probe.kill(child.identity)
            // `#require` ends the test here if the child survived; the deferred `stop()` then
            // SIGKILLs and reaps it, so a wrong `kill` fails fast instead of hanging.
            try #require(eventually { !child.process.isRunning }, "child still alive 5 s after kill")
            child.process.waitUntilExit()
            #expect(child.process.terminationReason == .uncaughtSignal)
            #expect(child.process.terminationStatus == SIGKILL)
            #expect(probe.state(child.identity) == .gone)
        }

        @Test func killOnRunningChildKillsIt() throws {
            let child = try SleepingChild()
            defer { child.stop() }
            let probe = LiveProcessProbe()
            probe.kill(child.identity)
            // `#require` ends the test here if the child survived; the deferred `stop()` then
            // SIGKILLs and reaps it, so a wrong `kill` fails fast instead of hanging.
            try #require(eventually { !child.process.isRunning }, "child still alive 5 s after kill")
            child.process.waitUntilExit()
            #expect(child.process.terminationReason == .uncaughtSignal)
            #expect(child.process.terminationStatus == SIGKILL)
        }

        @Test("kill on a gone identity does not signal a live process with the same pid", arguments: [-1, 1] as [Int64])
        func killOnGoneIdentityLeavesReusedPidAlone(delta: Int64) throws {
            let child = try SleepingChild()
            defer { child.stop() }
            let probe = LiveProcessProbe()
            let stale = ProcessIdentity(
                pid: child.identity.pid, startTime: UInt64(Int64(child.identity.startTime) + delta))
            #expect(probe.state(stale) == .gone)
            probe.kill(stale)
            usleep(200_000)
            #expect(child.process.isRunning)
            #expect(probe.state(child.identity) == .running)
        }

        @Test func killOnGoneIdentityLeavesStoppedReusedPidAlone() throws {
            let child = try SleepingChild()
            defer { child.stop() }
            try child.suspend()
            let probe = LiveProcessProbe()
            let stale = ProcessIdentity(pid: child.identity.pid, startTime: child.identity.startTime + 1)
            probe.kill(stale)
            usleep(200_000)
            #expect(child.process.isRunning)
            #expect(probe.state(child.identity) == .stopped)
        }

        @Test func killOnExitedChildDoesNothing() throws {
            let child = try SleepingChild()
            child.stop()
            let probe = LiveProcessProbe()
            probe.kill(child.identity)
            #expect(probe.state(child.identity) == .gone)
        }
    }
}
