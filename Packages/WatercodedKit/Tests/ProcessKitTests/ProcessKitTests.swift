import Darwin
import Foundation
import Testing
@testable import ProcessKit

@Suite("LineSplitter")
struct LineSplitterTests {
    @Test func `splits across chunks`() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("hel".utf8)).isEmpty)
        #expect(splitter.append(Data("lo\nwor".utf8)) == ["hello"])
        #expect(splitter.append(Data("ld\r\n\n".utf8)) == ["world", ""])
        #expect(splitter.flush() == nil)
    }

    @Test func `flushes trailing partial line`() {
        let splitter = LineSplitter()
        _ = splitter.append(Data("tail".utf8))
        #expect(splitter.flush() == "tail")
    }
}

@Suite("ShellEnvironment")
struct ShellEnvironmentTests {
    @Test func `merges paths without duplicates`() {
        let merged = ShellEnvironment.mergedPath(primary: "/a:/b", current: "/b:/c")
        let entries = merged.split(separator: ":").map(String.init)
        #expect(Array(entries.prefix(3)) == ["/a", "/b", "/c"])
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(Set(entries).count == entries.count)
    }

    @Test func `locates system executables`() async {
        #expect(await ShellEnvironment().locate("ls") != nil)
        #expect(await ShellEnvironment().locate("definitely-not-a-real-binary-xyz") == nil)
    }
}

@Suite("Processes")
struct ProcessTests {
    @Test func `runner collects output and status`() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )
        #expect(result.exitCode == 3)
        #expect(result.standardOutput == "out\n")
        #expect(result.standardError == "err\n")
    }

    @Test func `runner times out`() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .milliseconds(200)
            )
        }
    }

    @Test func `streaming process echoes lines`() async throws {
        let process = try LineStreamingProcess(
            executable: URL(filePath: "/bin/cat"),
            arguments: [],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        try process.send(line: #"{"n":1}"#)
        try process.send(line: #"{"n":2}"#)
        process.closeInput()

        var lines: [String] = []
        for await line in process.standardOutputLines {
            lines.append(line)
        }
        #expect(lines == [#"{"n":1}"#, #"{"n":2}"#])
        #expect(await process.exitCode() == 0)
    }
}

@Suite("Broken pipes")
struct BrokenPipeTests {
    @Test func `writing to an exited process throws instead of killing the app`() async throws {
        let process = try LineStreamingProcess(
            executable: URL(filePath: "/usr/bin/true"),
            arguments: [],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        _ = await process.exitCode()
        // Before the fix this raised SIGPIPE and terminated the test runner.
        for _ in 0 ..< 3 {
            try? process.send(line: "hello")
        }
        #expect(process.hasExited)
    }
}

@Suite("Process cancellation and large output")
struct ProcessRobustnessTests {
    @Test func `cancellation escalates for commands ignoring termination`() async throws {
        let ready = FileManager.default.temporaryDirectory.appending(path: "watercoded-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let task = Task {
            try await ProcessRunner.run(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 30", "test", ready.path]
            )
        }
        defer { task.cancel() }
        let pid = try await waitForPID(in: ready)
        defer { kill(pid, SIGKILL) }
        // Measure cancellation after startup, with room for CI scheduling. Without termination,
        // the command runs for 30 seconds, so this still catches a broken cancellation path.
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func `termination kills a ready process that ignores SIGTERM`() async throws {
        let ready = FileManager.default.temporaryDirectory.appending(path: "watercoded-kill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 30", "test", ready.path]
        let box = ProcessBox(process)
        let exit = Task { try await box.exitCode() }
        defer { box.terminate() }
        _ = try await waitForPID(in: ready)
        box.terminate()
        #expect(try await exit.value == SIGKILL)
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test func `timeout also bounds pipe draining after the process exits`() async {
        let child = FileManager.default.temporaryDirectory.appending(path: "watercoded-pipe-\(UUID().uuidString)")
        defer {
            if let text = try? String(contentsOf: child, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: child)
        }
        let start = ContinuousClock.now
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.run(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "sleep 30 & echo $! > \"$1\"; exit 0", "test", child.path],
                timeout: .milliseconds(100)
            )
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func `cancelling before launch never crashes`() async {
        // Regression: terminate() on an unlaunched Process raised "task not launched" and killed the app.
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try? await ProcessRunner.run(executable: URL(filePath: "/bin/sleep"), arguments: ["5"])
        }.value
        #expect(result == nil)
    }

    @Test func `cancelling while running terminates the process`() async {
        let task = Task { try await ProcessRunner.run(executable: URL(filePath: "/bin/sleep"), arguments: ["5"]) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try? await task.value
        #expect(result.map { !$0.succeeded } ?? true)
    }

    @Test func `output larger than the pipe buffer doesn't deadlock`() async throws {
        // 1 MB on stdout and 256 KB on stderr; reading only after exit would hang until the timeout.
        let script = "head -c 1048576 /dev/zero | tr '\\\\0' a; head -c 262144 /dev/zero | tr '\\\\0' b >&2"
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: .seconds(10)
        )
        #expect(result.standardOutput.count == 1_048_576)
        #expect(result.standardError.count == 262_144)
    }

    private func waitForPID(in file: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProcessError.timedOut(executable: "test process startup")
    }
}

@Suite("Background relay", .serialized)
struct RelayTests {
    /// The `watercoded-relay` executable SwiftPM built next to the tests.
    static var relayExecutable: URL? {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/",
              !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
            directory.deleteLastPathComponent()
        }
        let candidates = ["out/Products/Debug", "debug", "arm64-apple-macosx/debug"].map {
            directory.appending(path: ".build/\($0)/watercoded-relay")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func next(_ iterator: inout AsyncStream<String>.Iterator) async -> String? {
        await iterator.next()
    }

    @Test func `relayed agents survive detaching and resume without duplicates`() async throws {
        let relay = try #require(Self.relayExecutable, "build the package first")
        let directory = FileManager.default.temporaryDirectory.appending(path: "watercoded-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try RelayedProcess.launch(
            relay: RelayCommand(executable: relay, arguments: []),
            directory: directory,
            spec: ProcessSpec(
                executable: URL(filePath: "/bin/cat"),
                arguments: [],
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
        )
        var lines = first.standardOutputLines.makeAsyncIterator()
        try first.send(line: "one")
        #expect(await next(&lines) == "one")
        let offset = first.offset
        first.detach() // the app quits; the agent keeps running

        #expect(RelayLog.isAlive(in: directory))
        let second = try RelayedProcess(directory: directory, offset: offset)
        var resumed = second.standardOutputLines.makeAsyncIterator()
        try second.send(line: "two")
        #expect(await next(&resumed) == "two", "only output after the saved offset is delivered")

        // The log records input too, so a reattaching client can tell what was already answered.
        let records = RelayLog.records(in: directory).map(\.record)
        #expect(records.contains(.input("one")))
        #expect(records.contains(.output("one")))

        second.terminate()
        #expect(await second.exitCode() != -1)
        #expect(!RelayLog.isAlive(in: directory))
    }

    @Test func `relay termination escalates when an agent ignores SIGTERM`() async throws {
        let relay = try #require(Self.relayExecutable, "build the package first")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-stubborn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try RelayedProcess.launch(
            relay: RelayCommand(executable: relay, arguments: []), directory: directory,
            spec: ProcessSpec(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"],
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
        )
        var lines = process.standardOutputLines.makeAsyncIterator()
        #expect(await next(&lines) == "ready")
        process.terminate()
        #expect(await process.exitCode() == SIGKILL)
        #expect(!RelayLog.isAlive(in: directory))
    }
}
