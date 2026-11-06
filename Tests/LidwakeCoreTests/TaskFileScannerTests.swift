import Darwin
import Foundation
import LidwakeCore
import Testing

extension LidwakeTests {
    /// Spec §4: TaskFileScanner (libproc scan of open vnodes).
    @Suite struct TaskFileScannerTests {
        /// Unique base under `/tmp` (a symlink to `/private/tmp` on macOS).
        struct Sandbox {
            let base: String  // e.g. /tmp/lw-xxxx (non-canonical form)

            init() throws {
                base = TempPaths.shortTmpPath("-scan")
                try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            }

            func path(_ relative: String) -> String { base + "/" + relative }

            /// Creates the file (and parent directories) and returns an open read handle on it.
            func openFile(_ relative: String) throws -> FileHandle {
                try Self.openFile(atPath: path(relative))
            }

            static func openFile(atPath full: String) throws -> FileHandle {
                let parent = (full as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                #expect(FileManager.default.createFile(atPath: full, contents: Data("x".utf8)))
                return try FileHandle(forReadingFrom: URL(fileURLWithPath: full))
            }

            func makeDirectory(_ relative: String) throws {
                try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
            }

            func scanner(root relative: String) -> TaskFileScanner {
                TaskFileScanner(root: URL(fileURLWithPath: path(relative)))
            }

            func cleanup() { TempPaths.remove(base) }
        }

        @Test func openOutputFileInNestedTasksDirIsDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try box.makeDirectory("claude-501")
            let scanner = box.scanner(root: "claude-501")
            let handle = try box.openFile("claude-501/a/b/tasks/x.output")
            defer { try? handle.close() }
            #expect(scanner.hasOpenTaskOutput())
        }

        @Test func rootCreatedAfterInitIsDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            let scanner = box.scanner(root: "claude-501")
            #expect(!FileManager.default.fileExists(atPath: box.path("claude-501")))
            #expect(!scanner.hasOpenTaskOutput())
            let handle = try box.openFile("claude-501/proj/sess/tasks/late.output")
            defer { try? handle.close() }
            #expect(scanner.hasOpenTaskOutput())
        }

        @Test func rootRecreatedIsDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try box.makeDirectory("claude-501")
            let scanner = box.scanner(root: "claude-501")
            let first = try box.openFile("claude-501/proj/sess/tasks/first.output")
            #expect(scanner.hasOpenTaskOutput())
            try first.close()

            try FileManager.default.removeItem(atPath: box.path("claude-501"))
            #expect(!scanner.hasOpenTaskOutput())

            try box.makeDirectory("claude-501")
            let second = try box.openFile("claude-501/proj/sess/tasks/second.output")
            defer { try? second.close() }
            #expect(scanner.hasOpenTaskOutput())
        }

        @Test func tasksDirDirectlyUnderRootIsDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            let handle = try box.openFile("claude-501/tasks/y.output")
            defer { try? handle.close() }
            #expect(box.scanner(root: "claude-501").hasOpenTaskOutput())
        }

        @Test func closedFileIsNotDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try box.makeDirectory("claude-501")
            let scanner = box.scanner(root: "claude-501")
            let handle = try box.openFile("claude-501/p/s/tasks/x.output")
            #expect(scanner.hasOpenTaskOutput())
            try handle.close()
            #expect(!scanner.hasOpenTaskOutput())
        }

        @Test func emptyRootIsNotDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try FileManager.default.createDirectory(atPath: box.path("claude-501"), withIntermediateDirectories: true)
            #expect(!box.scanner(root: "claude-501").hasOpenTaskOutput())
        }

        @Test func nonexistentRootIsNotDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            #expect(!box.scanner(root: "does-not-exist").hasOpenTaskOutput())
        }

        @Test(
            "open files that do not match the pattern are ignored",
            arguments: [
                "claude-501/a/notasks/x.output",
                "claude-501/a/mytasks/x.output",
                "claude-501/a/tasks-old/x.output",
                "claude-501/a/Tasks/x.output",
                "claude-501/a/tasks/sub/x.output",
                "claude-501/a/tasks/x.log",
                "claude-501/a/tasks/x.output.bak",
                "claude-501/a/tasks/x.outputs",
                "claude-501/a/tasks/x.txt",
                "claude-501/a/tasks/output",
                "claude-501/x.output",
                "elsewhere/tasks/x.output",
            ]
        )
        func nonMatchingOpenFilesAreIgnored(relative: String) throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try FileManager.default.createDirectory(atPath: box.path("claude-501"), withIntermediateDirectories: true)
            let handle = try box.openFile(relative)
            defer { try? handle.close() }
            #expect(!box.scanner(root: "claude-501").hasOpenTaskOutput())
        }

        @Test func siblingDirectorySharingRootPrefixIsNotUnderRoot() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try FileManager.default.createDirectory(atPath: box.path("claude-501"), withIntermediateDirectories: true)
            let handle = try box.openFile("claude-5010/tasks/x.output")
            defer { try? handle.close() }
            #expect(!box.scanner(root: "claude-501").hasOpenTaskOutput())
            // Control: the same open file is found when the scan root really contains it.
            #expect(box.scanner(root: "claude-5010").hasOpenTaskOutput())
        }

        @Test func rootGivenViaTmpSymlinkMatchesCanonicalVnodePaths() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            #expect(box.base.hasPrefix("/tmp/"))
            let handle = try box.openFile("claude-501/proj/sess/tasks/t.output")
            defer { try? handle.close() }
            #expect(TaskFileScanner(root: URL(fileURLWithPath: box.path("claude-501"))).hasOpenTaskOutput())
            let privateForm = "/private" + box.path("claude-501")
            #expect(TaskFileScanner(root: URL(fileURLWithPath: privateForm)).hasOpenTaskOutput())
        }

        @Test func rootUnderFoundationTemporaryDirectoryWorks() throws {
            let dir = try TempPaths.makeDirectory("scan")
            defer { TempPaths.remove(dir) }
            let root = dir.appendingPathComponent("claude-501", isDirectory: true)
            let handle = try Sandbox.openFile(atPath: root.appendingPathComponent("p/s/tasks/z.output").path)
            defer { try? handle.close() }
            #expect(TaskFileScanner(root: root).hasOpenTaskOutput())
        }

        @Test func rootThatIsItselfASymlinkIsResolved() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try FileManager.default.createDirectory(atPath: box.path("real"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.path("link"), withDestinationPath: box.path("real"))
            let handle = try box.openFile("real/s/tasks/x.output")
            defer { try? handle.close() }
            #expect(box.scanner(root: "link").hasOpenTaskOutput())
        }

        @Test func fileHeldOpenByAnotherProcessOfSameUserIsDetected() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            let target = box.path("claude-501/proj/sess/tasks/child.output")
            try FileManager.default.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let scanner = box.scanner(root: "claude-501")
            #expect(!scanner.hasOpenTaskOutput())

            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "exec /bin/sleep 30 >> \"$0\"", target]
            try child.run()
            defer {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }

            var seen = false
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if scanner.hasOpenTaskOutput() {
                    seen = true
                    break
                }
                usleep(20_000)
            }
            #expect(seen)

            child.terminate()
            child.waitUntilExit()
            #expect(!scanner.hasOpenTaskOutput())
        }

        @Test func repeatedScansDoNotGrowOpenFileDescriptors() throws {
            let box = try Sandbox()
            defer { box.cleanup() }
            try box.makeDirectory("claude-501")
            let scanner = box.scanner(root: "claude-501")
            let handle = try box.openFile("claude-501/a/tasks/x.output")
            defer { try? handle.close() }
            _ = scanner.hasOpenTaskOutput()
            let before = openFDCount()
            var hits = 0
            for _ in 0..<50 where scanner.hasOpenTaskOutput() { hits += 1 }
            let after = openFDCount()
            #expect(hits == 50)
            #expect(after == before)
        }
    }
}
