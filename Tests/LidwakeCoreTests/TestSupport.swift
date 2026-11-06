import Darwin
import Foundation
import Testing

import LidwakeCore

/// Root suite. `.serialized` applies to every nested suite, so tests that
/// count the process's open file descriptors never race with other tests.
@Suite(.serialized) struct LidwakeTests {}

// MARK: - Temporary paths

enum TempPaths {
    /// A fresh, empty directory under `FileManager.temporaryDirectory`.
    static func makeDirectory(_ label: String = "dir") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidwake-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short, unique path under `/tmp` (sun_path is limited to 104 bytes).
    static func shortTmpPath(_ suffix: String = "") -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        return "/tmp/lw-\(token)\(suffix)"
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - File descriptor counting

/// Number of open file descriptors of the current process (via libproc).
func openFDCount() -> Int {
    let pid = getpid()
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    precondition(needed > 0, "proc_pidinfo size query failed")
    let stride = MemoryLayout<proc_fdinfo>.stride
    var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 64)
    let used = buffer.withUnsafeMutableBytes { raw in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
    }
    precondition(used > 0, "proc_pidinfo list failed")
    return Int(used) / stride
}

// MARK: - AF_UNIX helpers

func withUnixAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for i in 0..<raw.count { raw[i] = 0 }
        raw.copyBytes(from: bytes)
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setTimeoutOption(_ fd: Int32, _ option: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Creates a socket file at `path` that nobody listens on (connect ⇒ ECONNREFUSED).
func makeStaleSocketFile(at path: String) throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    let rc = withUnixAddress(path) { bind(fd, $0, $1) }
    close(fd)
    guard rc == 0 else { throw POSIXError(.EIO) }
}

/// In-process AF_UNIX stream server used to drive `HerdrClient`.
final class UnixSocketServer: @unchecked Sendable {
    enum Mode: Sendable {
        /// Accept each connection, read the request line, write `response`, close.
        case respond(Data)
        /// Accept each connection, read the request line, write `partial`, keep it open until `stop()`.
        case stall(partial: Data)
        /// Listen but never accept (the kernel queues connections; nobody answers).
        case listenOnly
    }

    let path: String
    private let mode: Mode
    private let listenFD: Int32
    private let lock = NSLock()
    private var _requests: [Data] = []
    private var heldFDs: [Int32] = []
    private var stopping = false
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)
    private var hasThread = false

    init(path: String = TempPaths.shortTmpPath(".sock"), mode: Mode) throws {
        self.path = path
        self.mode = mode
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnixAddress(path) { bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        listenFD = fd
        if case .listenOnly = mode { return }
        hasThread = true
        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    /// Request bytes received per connection (read up to and including the first newline).
    var requests: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    /// Stops the accept loop, waits for it, and closes every server-side fd.
    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        stopping = true
        lock.unlock()
        if hasThread { finished.wait() }
        lock.lock()
        let held = heldFDs
        heldFDs.removeAll()
        lock.unlock()
        for fd in held { close(fd) }
        close(listenFD)
        unlink(path)
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        defer { finished.signal() }
        while !isStopping {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 20)
            if ready <= 0 { continue }
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { continue }
            serve(conn)
        }
    }

    private func serve(_ conn: Int32) {
        var one: Int32 = 1
        _ = setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeoutOption(conn, SO_RCVTIMEO, seconds: 3)
        setTimeoutOption(conn, SO_SNDTIMEO, seconds: 5)
        let request = readLine(conn)
        lock.lock()
        _requests.append(request)
        lock.unlock()
        switch mode {
        case .respond(let response):
            writeAll(conn, response)
            close(conn)
        case .stall(let partial):
            writeAll(conn, partial)
            lock.lock()
            heldFDs.append(conn)
            lock.unlock()
        case .listenOnly:
            close(conn)
        }
    }

    private func readLine(_ fd: Int32) -> Data {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return collected
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

// MARK: - Fakes for Controller

struct FakeFailure: Error, Equatable {}

/// Records every call; `state` models the system's SleepDisabled flag.
/// Each call models the spec §6 protocol: a fresh fake child identity is handed to
/// `recorded` before the child "runs"; if `recorded` throws, the child is treated as
/// killed before it ran (state unchanged) and the error is rethrown.
final class FakeSleepControl: SleepControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: Bool?
    private var _calls: [Bool] = []
    private var _launched: [Bool] = []
    private var _identities: [ProcessIdentity] = []
    private var _failuresRemaining = 0
    private var nextPid: Int32 = 70_000
    private var _onSet: (@Sendable (Bool, ProcessIdentity) -> Void)?
    private var _beforeRecorded: (@Sendable () -> Void)?
    private var _afterRecordedThrew: (@Sendable () -> Void)?

    init(state: Bool?) { _state = state }

    var state: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }

    /// Arguments of every `setSleepDisabled` call, in order (including failed ones and
    /// ones whose `recorded` callback threw).
    var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    /// Arguments of the calls whose child was resumed (`recorded` returned normally).
    var launched: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _launched
    }

    /// The fake child identity handed to `recorded`, one per call, in order.
    var identities: [ProcessIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return _identities
    }

    /// The next `count` launched children exit nonzero: the call throws and leaves `state` unchanged.
    func failNext(_ count: Int) {
        lock.lock()
        _failuresRemaining = count
        lock.unlock()
    }

    func isSleepDisabled() -> Bool? { state }

    /// Called after `recorded` returned and before the child's result is known,
    /// with the call's argument and child identity (e.g. to inspect the journal then).
    var onSet: (@Sendable (Bool, ProcessIdentity) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSet }
        set { lock.lock(); _onSet = newValue; lock.unlock() }
    }

    /// Called right before `recorded` (e.g. to make the journal directory unwritable).
    var beforeRecorded: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _beforeRecorded }
        set { lock.lock(); _beforeRecorded = newValue; lock.unlock() }
    }

    /// Called when `recorded` threw, before the error is rethrown (the child is "killed").
    var afterRecordedThrew: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _afterRecordedThrew }
        set { lock.lock(); _afterRecordedThrew = newValue; lock.unlock() }
    }

    func setSleepDisabled(_ on: Bool, recorded: (ProcessIdentity) throws -> Void) throws {
        lock.lock()
        _calls.append(on)
        nextPid += 1
        let identity = ProcessIdentity(pid: nextPid, startTime: 1_700_000_000_000_000 + UInt64(nextPid))
        _identities.append(identity)
        let before = _beforeRecorded
        let afterThrew = _afterRecordedThrew
        lock.unlock()

        before?()
        do {
            try recorded(identity)
        } catch {
            afterThrew?()
            throw error
        }
        onSet?(on, identity)

        lock.lock()
        defer { lock.unlock() }
        _launched.append(on)
        if _failuresRemaining > 0 {
            _failuresRemaining -= 1
            throw FakeFailure()
        }
        _state = on
    }
}

/// `state` returns the state the test set for an identity; unknown identities are `.gone`.
/// `kill` is recorded. It changes the state to `.gone` only if `killTakesEffect` is true,
/// so a test decides when a killed child is reported gone.
final class FakeProcessProbe: ProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [Int32: (ProcessIdentity, ProcessState)] = [:]
    private var _killed: [ProcessIdentity] = []
    private var _killTakesEffect = false

    init(running: [ProcessIdentity] = [], stopped: [ProcessIdentity] = []) {
        for id in running { _states[id.pid] = (id, .running) }
        for id in stopped { _states[id.pid] = (id, .stopped) }
    }

    func set(_ id: ProcessIdentity, _ state: ProcessState) {
        lock.lock()
        _states[id.pid] = (id, state)
        lock.unlock()
    }

    /// Every `kill` call, in order.
    var killed: [ProcessIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return _killed
    }

    var killTakesEffect: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _killTakesEffect }
        set { lock.lock(); _killTakesEffect = newValue; lock.unlock() }
    }

    func state(_ id: ProcessIdentity) -> ProcessState {
        lock.lock()
        defer { lock.unlock() }
        guard let (known, state) = _states[id.pid], known == id else { return .gone }
        return state
    }

    func kill(_ id: ProcessIdentity) {
        lock.lock()
        defer { lock.unlock() }
        _killed.append(id)
        guard _killTakesEffect, let (known, _) = _states[id.pid], known == id else { return }
        _states[id.pid] = (id, .gone)
    }
}

// MARK: - Real process helpers

/// Start time of `pid` (PROC_PIDTBSDINFO: pbi_start_tvsec * 1e6 + pbi_start_tvusec), or nil if the
/// process cannot be inspected. For processes of this user it equals the spec §6 value
/// (sysctl KERN_PROC_PID p_starttime sec * 1e6 + usec).
func processStartTime(_ pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard n == size else { return nil }
    return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
}

/// Start time of `pid` as spec §6 defines it: sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)
/// kp_proc.p_starttime sec * 1e6 + usec, or nil if no such process. Works for root-owned
/// processes (e.g. pid 1) as a normal user, unlike PROC_PIDTBSDINFO.
func sysctlProcessStartTime(_ pid: Int32) -> UInt64? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
    guard rc == 0, size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
}

/// A `/bin/sleep` child of this test process with its real identity. `stop()` kills and reaps it.
final class SleepingChild {
    let process = Process()
    let identity: ProcessIdentity

    init(seconds: Int = 30) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        guard let start = processStartTime(pid) else {
            kill(pid, SIGKILL)
            process.waitUntilExit()
            throw POSIXError(.ESRCH)
        }
        identity = ProcessIdentity(pid: pid, startTime: start)
    }

    /// Sends SIGSTOP and waits (up to 5 s) until the kernel reports the child as stopped
    /// (PROC_PIDTBSDINFO pbi_status == SSTOP). Throws if it does not stop in time.
    func suspend() throws {
        kill(process.processIdentifier, SIGSTOP)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if processStatus(process.processIdentifier) == UInt32(SSTOP) { return }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    deinit { stop() }
}

/// `pbi_status` of `pid` (SRUN, SSTOP, ...), or nil if the process cannot be inspected.
func processStatus(_ pid: Int32) -> UInt32? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard n == size else { return nil }
    return info.pbi_status
}

/// Polls `condition` every 10 ms until it is true or `timeout` passes; returns the last result.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

final class FakeAssertion: AssertionHolder, @unchecked Sendable {
    private let lock = NSLock()
    private var _held = false
    private var _holdCalls = 0
    private var _releaseCalls = 0

    var held: Bool { lock.lock(); defer { lock.unlock() }; return _held }
    var holdCalls: Int { lock.lock(); defer { lock.unlock() }; return _holdCalls }
    var releaseCalls: Int { lock.lock(); defer { lock.unlock() }; return _releaseCalls }

    func hold() throws {
        lock.lock()
        _holdCalls += 1
        _held = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        _releaseCalls += 1
        _held = false
        lock.unlock()
    }
}

final class FakeInputsProvider: InputsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: Inputs

    init(_ initial: Inputs) { _current = initial }

    var current: Inputs {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }

    func inputs() -> Inputs { current }
}

enum Fixtures {
    static let acPower = PowerState(onBattery: false, chargePercent: 100)
    static let lowBattery = PowerState(onBattery: true, chargePercent: 10)

    static func idle(power: PowerState = acPower) -> Inputs {
        Inputs(forced: false, herdrWorking: false, backgroundTask: false, power: power)
    }

    static func working(power: PowerState = acPower) -> Inputs {
        Inputs(forced: false, herdrWorking: true, backgroundTask: false, power: power)
    }

    static func forced(power: PowerState = acPower) -> Inputs {
        Inputs(forced: true, herdrWorking: false, backgroundTask: false, power: power)
    }
}
