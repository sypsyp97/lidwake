import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §9: black-box tests of the built `lidwake` executable, run as a subprocess.
    /// Every run gets a fresh `LIDWAKE_STATE_DIR`. Only `--dry-run` is used for `run`.
    @Suite struct CLIProcessTests {
        struct Failure: Error, CustomStringConvertible {
            let description: String
        }

        /// `lidwake` sits next to the test bundle (e.g. `.build/debug/lidwake`).
        /// Swift Testing may load the bundle without registering it in `Bundle.allBundles`,
        /// so the bundle that contains this test code and the package's `.build/debug` are tried too.
        static func executableURL(filePath: String = #filePath) throws -> URL {
            var candidates: [URL] = []
            let bundles = Bundle.allBundles + [Bundle(for: Run.self)]
            for bundle in bundles where bundle.bundlePath.hasSuffix(".xctest") {
                candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("lidwake"))
            }
            let packageRoot = URL(fileURLWithPath: filePath)
                .deletingLastPathComponent()  // LidwakeCoreTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()
            candidates.append(packageRoot.appendingPathComponent(".build/debug/lidwake"))
            guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw Failure(
                    description:
                        "lidwake executable not found; tried \(candidates.map(\.path)); build it first (swift build)")
            }
            return url
        }

        /// A launched `lidwake` process with stdout/stderr captured to files.
        final class Run {
            let process = Process()
            let stateDir: URL
            private let outURL: URL
            private let errURL: URL

            init(_ args: [String], stateDir: URL) throws {
                self.stateDir = stateDir
                let logs = try TempPaths.makeDirectory("cli-logs")
                outURL = logs.appendingPathComponent("stdout")
                errURL = logs.appendingPathComponent("stderr")
                FileManager.default.createFile(atPath: outURL.path, contents: nil)
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                process.executableURL = try CLIProcessTests.executableURL()
                process.arguments = args
                let home = logs.appendingPathComponent("home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                var env = ProcessInfo.processInfo.environment
                env["LIDWAKE_STATE_DIR"] = stateDir.path
                // macOS takes NSHomeDirectory()/homeDirectoryForCurrentUser from CFFIXED_USER_HOME, not HOME.
                env["HOME"] = home.path
                env["CFFIXED_USER_HOME"] = home.path
                process.environment = env
                process.standardInput = FileHandle.nullDevice
                let out = try FileHandle(forWritingTo: outURL)
                let err = try FileHandle(forWritingTo: errURL)
                defer {
                    try? out.close()
                    try? err.close()
                }
                process.standardOutput = out
                process.standardError = err
                try process.run()
            }

            deinit {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                TempPaths.remove(outURL.deletingLastPathComponent())
            }

            /// Waits up to `seconds` for exit. On timeout kills the process and returns false.
            func wait(seconds: TimeInterval) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while process.isRunning && Date() < deadline { usleep(10_000) }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    return false
                }
                process.waitUntilExit()
                return true
            }

            var stderr: String { (try? String(contentsOf: errURL, encoding: .utf8)) ?? "" }
            var stdout: String { (try? String(contentsOf: outURL, encoding: .utf8)) ?? "" }

            /// True iff the process exited normally (not by a signal) with status 0.
            var exitedCleanly: Bool {
                process.terminationReason == .exit && process.terminationStatus == 0
            }
        }

        /// Runs `lidwake args` to completion with a fresh or given state dir.
        @discardableResult
        static func runToEnd(_ args: [String], stateDir: URL, timeout: TimeInterval = 10) throws -> Run {
            let run = try Run(args, stateDir: stateDir)
            let finished = run.wait(seconds: timeout)
            #expect(finished, "lidwake \(args.joined(separator: " ")) did not exit within \(timeout) s")
            return run
        }

        static func forceFile(_ dir: URL) -> String { dir.appendingPathComponent("force").path }

        static func lockFile(_ dir: URL) -> URL { dir.appendingPathComponent("lock") }
        static func dryRunLockFile(_ dir: URL) -> URL {
            dir.appendingPathComponent("dry-run", isDirectory: true).appendingPathComponent("lock")
        }

        /// An exclusive non-blocking `flock` held by this test process (file and parent created if missing).
        /// `release()` (or deinit) unlocks and closes it.
        final class HeldLock {
            private var fd: Int32

            init(_ url: URL) throws {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw Failure(description: "open \(url.path): errno \(errno)") }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    let code = errno
                    close(fd)
                    fd = -1
                    throw Failure(description: "flock \(url.path): errno \(code)")
                }
            }

            func release() {
                guard fd >= 0 else { return }
                flock(fd, LOCK_UN)
                close(fd)
                fd = -1
            }

            deinit { release() }
        }

        /// True iff another open file description holds a `flock` on `url`.
        /// A missing file counts as not locked. If the lock is free the probe takes and drops it at once.
        static func isLockedElsewhere(_ url: URL) -> Bool {
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return false
            }
            return errno == EWOULDBLOCK
        }

        /// Starts `run --dry-run --interval 0.05` (no `--ticks`) and waits until it has created its lock file
        /// and is still running. The lock file is not probed while the process may still be taking it.
        static func startLongDryRun(stateDir: URL) throws -> Run {
            let run = try Run(["run", "--dry-run", "--interval", "0.05"], stateDir: stateDir)
            let lock = dryRunLockFile(stateDir)
            try #require(
                eventually { FileManager.default.fileExists(atPath: lock.path) || !run.process.isRunning },
                "dry run created no \(lock.path) within 5 s")
            usleep(300_000)
            try #require(
                run.process.isRunning,
                "dry run without --ticks exited (status \(run.process.terminationStatus)); stderr: \(run.stderr)")
            try #require(
                FileManager.default.fileExists(atPath: lock.path),
                "dry run created no \(lock.path); stderr: \(run.stderr)")
            return run
        }

        /// Asserts `run` exited normally with status 75 and wrote a message on stderr.
        static func expectLockedOut(_ run: Run, _ what: String) {
            #expect(run.process.terminationReason == .exit, "\(what): killed by signal \(run.process.terminationStatus)")
            #expect(run.process.terminationStatus == 75, "\(what): status \(run.process.terminationStatus), stderr: \(run.stderr)")
            #expect(
                !run.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(what): empty stderr")
        }

        @Test func executableIsBuiltNextToTestBundle() throws {
            _ = try Self.executableURL()
        }

        @Test func onCreatesForceFile() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Self.runToEnd(["on"], stateDir: dir)
            #expect(run.exitedCleanly, "stderr: \(run.stderr)")
            #expect(FileManager.default.fileExists(atPath: Self.forceFile(dir)))
        }

        @Test func offRemovesForceFile() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let on = try Self.runToEnd(["on"], stateDir: dir)
            #expect(on.exitedCleanly, "stderr: \(on.stderr)")
            #expect(FileManager.default.fileExists(atPath: Self.forceFile(dir)))
            let off = try Self.runToEnd(["off"], stateDir: dir)
            #expect(off.exitedCleanly, "stderr: \(off.stderr)")
            #expect(!FileManager.default.fileExists(atPath: Self.forceFile(dir)))
        }

        @Test func offTwiceIsIdempotent() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            try Data("x".utf8).write(to: URL(fileURLWithPath: Self.forceFile(dir)))
            for _ in 0..<2 {
                let off = try Self.runToEnd(["off"], stateDir: dir)
                #expect(off.exitedCleanly, "stderr: \(off.stderr)")
                #expect(!FileManager.default.fileExists(atPath: Self.forceFile(dir)))
            }
        }

        @Test func dryRunWithTicksExitsZero() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Self.runToEnd(
                ["run", "--dry-run", "--ticks", "3", "--interval", "0.05"], stateDir: dir, timeout: 10)
            #expect(run.exitedCleanly, "status \(run.process.terminationStatus), stderr: \(run.stderr)")
        }

        @Test("SIGTERM / SIGINT during dry run ⇒ clean exit 0", arguments: [SIGTERM, SIGINT])
        func signalStopsDryRunCleanly(signal: Int32) throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Run(["run", "--dry-run", "--interval", "0.05"], stateDir: dir)
            // Give the process time to install its signal handling and run a few ticks.
            usleep(1_000_000)
            #expect(run.process.isRunning, "run without --ticks exited on its own; stderr: \(run.stderr)")
            kill(run.process.processIdentifier, signal)
            let finished = run.wait(seconds: 5)
            #expect(finished, "did not exit within 5 s after signal \(signal)")
            #expect(
                run.process.terminationReason == .exit,
                "terminated by an uncaught signal \(run.process.terminationStatus)")
            #expect(run.process.terminationStatus == 0, "stderr: \(run.stderr)")
        }

        @Test func restoreWithoutJournalExitsZeroAndLeavesNoOwnership() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(run.exitedCleanly, "stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load() == Journal())
        }

        @Test func restoreWithUnownedJournalExitsZeroAndKeepsJournal() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let journal = Journal(owned: false, lastActive: Date(timeIntervalSince1970: 1_800_000_000))
            try JournalStore(directory: dir).save(journal)
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(run.exitedCleanly, "stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load() == journal)
        }

        @Test func restoreWithLivePendingChildExits75AndChangesNothing() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let child = try SleepingChild()
            defer { child.stop() }
            // owned=false keeps a faulty restore away from sudo/pmset; a live pending child must win anyway.
            let journal = Journal(
                owned: false, lastActive: Date(timeIntervalSince1970: 1_800_000_000), pending: child.identity)
            try JournalStore(directory: dir).save(journal)
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(run.process.terminationReason == .exit)
            #expect(run.process.terminationStatus == 75, "stderr: \(run.stderr)")
            #expect(run.stderr.contains("pmset still running"), "stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load() == journal)
            #expect(child.process.isRunning)
            #expect(LiveProcessProbe().state(child.identity) == .running)
        }

        @Test func restoreWithStoppedPendingChildKillsItAndExitsZero() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let child = try SleepingChild()
            defer { child.stop() }
            try child.suspend()
            // owned=false keeps restore away from sudo/pmset once the stopped child is gone.
            let journal = Journal(
                owned: false, lastActive: Date(timeIntervalSince1970: 1_800_000_000), pending: child.identity)
            try JournalStore(directory: dir).save(journal)
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            // `#require` ends the test here if the child survived; the deferred `stop()` then
            // SIGKILLs and reaps it, so a restore that does not kill fails fast instead of hanging.
            try #require(eventually { !child.process.isRunning }, "stopped pending child was not killed")
            child.process.waitUntilExit()
            #expect(child.process.terminationReason == .uncaughtSignal)
            #expect(child.process.terminationStatus == SIGKILL)
            #expect(run.exitedCleanly, "status \(run.process.terminationStatus), stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load().owned == false)
        }

        @Test func restoreWithExitedPendingChildAndUnownedJournalExitsZero() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let child = try SleepingChild()
            child.stop()
            let journal = Journal(
                owned: false, lastActive: Date(timeIntervalSince1970: 1_800_000_000), pending: child.identity)
            try JournalStore(directory: dir).save(journal)
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(run.exitedCleanly, "status \(run.process.terminationStatus), stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load().owned == false)
        }

        @Test func hugeIntervalIsUsageErrorWithoutCrash() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Self.runToEnd(["run", "--dry-run", "--ticks", "1", "--interval", "1e300"], stateDir: dir)
            #expect(run.process.terminationReason == .exit, "killed by signal \(run.process.terminationStatus)")
            #expect(run.process.terminationStatus == 64, "stderr: \(run.stderr)")
            #expect(!run.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        @Test func restoreWhileLockHeldExits75AndChangesNothing() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            // A stopped pending child would be killed by an unlocked restore: it shows that restore did nothing.
            let child = try SleepingChild()
            defer { child.stop() }
            try child.suspend()
            let journal = Journal(
                owned: false, lastActive: Date(timeIntervalSince1970: 1_800_000_000), pending: child.identity)
            try JournalStore(directory: dir).save(journal)
            let journalURL = dir.appendingPathComponent("journal.json")
            let journalBytes = try Data(contentsOf: journalURL)

            let lock = try HeldLock(Self.lockFile(dir))
            let locked = try Self.runToEnd(["restore"], stateDir: dir)
            Self.expectLockedOut(locked, "restore with lock held")
            #expect(try Data(contentsOf: journalURL) == journalBytes, "journal.json changed")
            #expect(child.process.isRunning, "pending child was killed although the lock was held")
            #expect(processStatus(child.process.processIdentifier) == UInt32(SSTOP))

            lock.release()
            let free = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(free.exitedCleanly, "status \(free.process.terminationStatus), stderr: \(free.stderr)")
            #expect(eventually { !child.process.isRunning }, "restore after release did not kill the stopped child")
            #expect(JournalStore(directory: dir).load().owned == false)
            #expect(FileManager.default.fileExists(atPath: Self.lockFile(dir).path), "restore removed the lock file")
        }

        @Test func dryRunWhileDryRunLockHeldExits75() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let args = ["run", "--dry-run", "--ticks", "1", "--interval", "0.05"]
            let lock = try HeldLock(Self.dryRunLockFile(dir))
            let locked = try Self.runToEnd(args, stateDir: dir)
            Self.expectLockedOut(locked, "dry run with dry-run lock held")
            let dryDir = dir.appendingPathComponent("dry-run", isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dryDir.path)
            #expect(entries == ["lock"], "locked-out dry run wrote into dry-run/: \(entries.sorted())")

            lock.release()
            let free = try Self.runToEnd(args, stateDir: dir)
            #expect(free.exitedCleanly, "status \(free.process.terminationStatus), stderr: \(free.stderr)")
            #expect(
                FileManager.default.fileExists(atPath: Self.dryRunLockFile(dir).path), "dry run removed its lock file")
        }

        @Test func secondDryRunExits75AndFirstKeepsRunning() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let first = try Self.startLongDryRun(stateDir: dir)
            #expect(Self.isLockedElsewhere(Self.dryRunLockFile(dir)), "running dry run does not hold dry-run/lock")
            #expect(!Self.isLockedElsewhere(Self.lockFile(dir)), "dry run holds the real agent's lock")

            let second = try Self.runToEnd(["run", "--dry-run", "--interval", "0.05"], stateDir: dir)
            Self.expectLockedOut(second, "second dry run")
            #expect(first.process.isRunning, "first dry run stopped; stderr: \(first.stderr)")

            kill(first.process.processIdentifier, SIGTERM)
            #expect(first.wait(seconds: 5), "first dry run did not exit within 5 s after SIGTERM")
            #expect(first.exitedCleanly, "status \(first.process.terminationStatus), stderr: \(first.stderr)")
        }

        @Test func lockIsReleasedWhenHolderIsKilled() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let first = try Self.startLongDryRun(stateDir: dir)
            kill(first.process.processIdentifier, SIGKILL)
            #expect(first.wait(seconds: 5), "dry run did not die within 5 s after SIGKILL")
            #expect(first.process.terminationReason == .uncaughtSignal)
            #expect(!Self.isLockedElsewhere(Self.dryRunLockFile(dir)), "lock still held after SIGKILL")

            let next = try Self.runToEnd(["run", "--dry-run", "--ticks", "1", "--interval", "0.05"], stateDir: dir)
            #expect(next.exitedCleanly, "status \(next.process.terminationStatus), stderr: \(next.stderr)")
        }

        @Test func onOffStatusIgnoreHeldLocks() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            // `status` has no specified exit status: compare it with an unlocked run in the same state.
            let baseline = try Self.runToEnd(["status"], stateDir: dir)
            #expect(baseline.process.terminationReason == .exit)

            let realLock = try HeldLock(Self.lockFile(dir))
            let dryLock = try HeldLock(Self.dryRunLockFile(dir))
            defer {
                realLock.release()
                dryLock.release()
            }
            let on = try Self.runToEnd(["on"], stateDir: dir)
            #expect(on.exitedCleanly, "status \(on.process.terminationStatus), stderr: \(on.stderr)")
            #expect(FileManager.default.fileExists(atPath: Self.forceFile(dir)))

            let status = try Self.runToEnd(["status"], stateDir: dir)
            #expect(status.process.terminationReason == .exit)
            #expect(status.process.terminationStatus != 75, "stderr: \(status.stderr)")
            #expect(
                status.process.terminationStatus == baseline.process.terminationStatus,
                "status with locks held: \(status.process.terminationStatus), without: \(baseline.process.terminationStatus)")

            let off = try Self.runToEnd(["off"], stateDir: dir)
            #expect(off.exitedCleanly, "status \(off.process.terminationStatus), stderr: \(off.stderr)")
            #expect(!FileManager.default.fileExists(atPath: Self.forceFile(dir)))
        }

        @Test func dryRunIgnoresRealAgentLock() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let lock = try HeldLock(Self.lockFile(dir))
            defer { lock.release() }
            let run = try Self.runToEnd(["run", "--dry-run", "--ticks", "1", "--interval", "0.05"], stateDir: dir)
            #expect(run.exitedCleanly, "status \(run.process.terminationStatus), stderr: \(run.stderr)")
        }

        @Test func restoreIgnoresDryRunLock() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let lock = try HeldLock(Self.dryRunLockFile(dir))
            defer { lock.release() }
            let run = try Self.runToEnd(["restore"], stateDir: dir)
            #expect(run.exitedCleanly, "status \(run.process.terminationStatus), stderr: \(run.stderr)")
            #expect(JournalStore(directory: dir).load() == Journal())
        }

        @Test func unknownCommandFailsWithMessageOnStderr() throws {
            let dir = try TempPaths.makeDirectory("cli-state")
            defer { TempPaths.remove(dir) }
            let run = try Self.runToEnd(["frobnicate"], stateDir: dir)
            #expect(run.process.terminationReason == .exit)
            #expect(run.process.terminationStatus == 64)
            #expect(!run.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
