import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §3: HerdrClient over an AF_UNIX socket served in-process.
    @Suite struct HerdrClientTests {
        static let expectedRequest = Data(#"{"id":"lidwake","method":"session.snapshot","params":{}}"#.utf8 + [UInt8(ascii: "\n")])
        static let sampleLine = #"{"id":"lidwake","result":{"snapshot":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"working"}]}}}"#

        @Test func maxResponseBytesIsFourMiB() {
            #expect(HerdrClient.maxResponseBytes == 4 * 1024 * 1024)
        }

        @Test func sendsExactRequestLineAndReturnsResponseWithoutNewline() throws {
            let server = try UnixSocketServer(mode: .respond(Data((Self.sampleLine + "\n").utf8)))
            defer { server.stop() }
            let client = HerdrClient(socketPath: server.path, timeout: 2)
            let data = try client.snapshot()
            #expect(data == Data(Self.sampleLine.utf8))
            server.stop()
            #expect(server.requests == [Self.expectedRequest])
        }

        @Test func responseIsUsableBySnapshotParser() throws {
            let server = try UnixSocketServer(mode: .respond(Data((Self.sampleLine + "\n").utf8)))
            defer { server.stop() }
            let data = try HerdrClient(socketPath: server.path).snapshot()
            #expect(try HerdrSnapshot.workingAgentCount(data) == 1)
        }

        @Test func eachCallUsesOneFreshConnection() throws {
            let server = try UnixSocketServer(mode: .respond(Data((Self.sampleLine + "\n").utf8)))
            defer { server.stop() }
            let client = HerdrClient(socketPath: server.path, timeout: 2)
            for _ in 0..<3 {
                #expect(try client.snapshot() == Data(Self.sampleLine.utf8))
            }
            server.stop()
            #expect(server.requests == Array(repeating: Self.expectedRequest, count: 3))
        }

        @Test func responseEndingAtEOFWithoutNewlineIsReturnedWhole() throws {
            let body = Data(Self.sampleLine.utf8)
            let server = try UnixSocketServer(mode: .respond(body))
            defer { server.stop() }
            #expect(try HerdrClient(socketPath: server.path, timeout: 2).snapshot() == body)
        }

        @Test func readingStopsAtFirstNewline() throws {
            let server = try UnixSocketServer(mode: .respond(Data("first-line\nsecond-line\n".utf8)))
            defer { server.stop() }
            #expect(try HerdrClient(socketPath: server.path, timeout: 2).snapshot() == Data("first-line".utf8))
        }

        @Test func emptyLineYieldsEmptyData() throws {
            let server = try UnixSocketServer(mode: .respond(Data("\n".utf8)))
            defer { server.stop() }
            #expect(try HerdrClient(socketPath: server.path, timeout: 2).snapshot() == Data())
        }

        @Test func largeResponseAcrossManyReadsIsComplete() throws {
            let body = Data(repeating: UInt8(ascii: "a"), count: 1_000_003)
            let server = try UnixSocketServer(mode: .respond(body + Data("\n".utf8)))
            defer { server.stop() }
            let data = try HerdrClient(socketPath: server.path, timeout: 5).snapshot()
            #expect(data.count == body.count)
            #expect(data == body)
        }

        @Test func responseOfExactlyMaxBytesIsAccepted() throws {
            let body = Data(repeating: UInt8(ascii: "b"), count: HerdrClient.maxResponseBytes)
            let withNewline = try UnixSocketServer(mode: .respond(body + Data("\n".utf8)))
            defer { withNewline.stop() }
            #expect(try HerdrClient(socketPath: withNewline.path, timeout: 5).snapshot().count == body.count)

            let atEOF = try UnixSocketServer(mode: .respond(body))
            defer { atEOF.stop() }
            #expect(try HerdrClient(socketPath: atEOF.path, timeout: 5).snapshot().count == body.count)
        }

        @Test func responseOverMaxBytesThrowsTooLarge() throws {
            let body = Data(repeating: UInt8(ascii: "c"), count: HerdrClient.maxResponseBytes + 1)
            let atEOF = try UnixSocketServer(mode: .respond(body))
            defer { atEOF.stop() }
            #expect(throws: HerdrError.tooLarge) {
                try HerdrClient(socketPath: atEOF.path, timeout: 5).snapshot()
            }

            let bigLine = try UnixSocketServer(
                mode: .respond(Data(repeating: UInt8(ascii: "d"), count: HerdrClient.maxResponseBytes + 4096) + Data("\n".utf8)))
            defer { bigLine.stop() }
            #expect(throws: HerdrError.tooLarge) {
                try HerdrClient(socketPath: bigLine.path, timeout: 5).snapshot()
            }
        }

        @Test func serverThatNeverAcceptsTimesOutWithinBound() throws {
            let server = try UnixSocketServer(mode: .listenOnly)
            defer { server.stop() }
            let timeout: TimeInterval = 0.5
            let client = HerdrClient(socketPath: server.path, timeout: timeout)
            let start = Date()
            #expect(throws: HerdrError.timeout) { try client.snapshot() }
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < timeout + 1)
        }

        @Test func serverThatReadsButNeverAnswersTimesOut() throws {
            let server = try UnixSocketServer(mode: .stall(partial: Data()))
            defer { server.stop() }
            let timeout: TimeInterval = 0.5
            let start = Date()
            #expect(throws: HerdrError.timeout) {
                try HerdrClient(socketPath: server.path, timeout: timeout).snapshot()
            }
            #expect(Date().timeIntervalSince(start) < timeout + 1)
        }

        @Test func partialLineThenSilenceTimesOut() throws {
            let server = try UnixSocketServer(mode: .stall(partial: Data(#"{"id":"lidwake","res"#.utf8)))
            defer { server.stop() }
            let timeout: TimeInterval = 0.5
            let start = Date()
            #expect(throws: HerdrError.timeout) {
                try HerdrClient(socketPath: server.path, timeout: timeout).snapshot()
            }
            #expect(Date().timeIntervalSince(start) < timeout + 1)
        }

        @Test func nonexistentSocketThrowsConnectENOENT() {
            let path = TempPaths.shortTmpPath(".missing")
            TempPaths.remove(path)
            #expect(throws: HerdrError.connect(ENOENT)) {
                try HerdrClient(socketPath: path, timeout: 1).snapshot()
            }
        }

        @Test func socketFileWithoutListenerThrowsConnectECONNREFUSED() throws {
            let path = TempPaths.shortTmpPath(".stale")
            try makeStaleSocketFile(at: path)
            defer { TempPaths.remove(path) }
            #expect(throws: HerdrError.connect(ECONNREFUSED)) {
                try HerdrClient(socketPath: path, timeout: 1).snapshot()
            }
        }

        @Test func repeatedCallsIncludingFailuresDoNotLeakFileDescriptors() throws {
            let missingPath = TempPaths.shortTmpPath(".missing")
            TempPaths.remove(missingPath)
            let line = Data((Self.sampleLine + "\n").utf8)
            let oversized = Data(repeating: UInt8(ascii: "e"), count: HerdrClient.maxResponseBytes + 1)

            // Warm-up: one call of each kind, so one-time lazy allocations are not counted.
            do {
                let ok = try UnixSocketServer(mode: .respond(line))
                let silent = try UnixSocketServer(mode: .listenOnly)
                let big = try UnixSocketServer(mode: .respond(oversized))
                _ = try? HerdrClient(socketPath: ok.path, timeout: 2).snapshot()
                _ = try? HerdrClient(socketPath: silent.path, timeout: 0.1).snapshot()
                _ = try? HerdrClient(socketPath: big.path, timeout: 5).snapshot()
                _ = try? HerdrClient(socketPath: missingPath, timeout: 1).snapshot()
                ok.stop()
                silent.stop()
                big.stop()
            }

            let before = openFDCount()

            let ok = try UnixSocketServer(mode: .respond(line))
            let silent = try UnixSocketServer(mode: .listenOnly)
            let big = try UnixSocketServer(mode: .respond(oversized))
            let okClient = HerdrClient(socketPath: ok.path, timeout: 2)
            let silentClient = HerdrClient(socketPath: silent.path, timeout: 0.1)
            let bigClient = HerdrClient(socketPath: big.path, timeout: 5)
            let missingClient = HerdrClient(socketPath: missingPath, timeout: 1)

            var successes = 0
            var timeouts = 0
            var tooLarge = 0
            var connectFailures = 0
            for i in 0..<100 {
                switch i % 20 {
                case 0..<10:
                    if (try? okClient.snapshot()) != nil { successes += 1 }
                case 10..<16:
                    do { _ = try missingClient.snapshot() } catch let e as HerdrError {
                        if case .connect = e { connectFailures += 1 }
                    } catch {}
                case 16..<19:
                    do { _ = try silentClient.snapshot() } catch let e as HerdrError {
                        if e == .timeout { timeouts += 1 }
                    } catch {}
                default:
                    do { _ = try bigClient.snapshot() } catch let e as HerdrError {
                        if e == .tooLarge { tooLarge += 1 }
                    } catch {}
                }
            }

            ok.stop()
            silent.stop()
            big.stop()
            let after = openFDCount()

            #expect(successes == 50)
            #expect(connectFailures == 30)
            #expect(timeouts == 15)
            #expect(tooLarge == 5)
            #expect(after == before)
        }
    }
}
