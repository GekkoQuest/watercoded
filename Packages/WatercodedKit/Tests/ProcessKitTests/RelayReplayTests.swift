import Foundation
import Testing
@testable import ProcessKit

@Suite("Relay replay boundaries", .serialized, .timeLimit(.minutes(1)))
struct RelayReplayTests {
    @Test func `tracked output can resume before already queued later lines`() async throws {
        let relay = try #require(RelayTests.relayExecutable)
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RelayedProcess.launch(
            relay: RelayCommand(executable: relay, arguments: []), directory: directory,
            spec: ProcessSpec(
                executable: URL(filePath: "/bin/cat"),
                arguments: [],
                workingDirectory: directory,
                environment: ProcessInfo.processInfo.environment
            ),
            tracksOutput: true
        )
        try first.send(line: "one 🌊")
        try first.send(line: "two")
        var output = first.outputRecords.makeAsyncIterator()
        let record = try #require(await output.next())
        #expect(record.line == "one 🌊")
        // Allow the reader to run ahead of the event consumer.
        for _ in 0 ..< 100 where first.offset <= record.offset {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.offset > record.offset)
        first.detach()
        let resumed = try RelayedProcess(directory: directory, offset: record.offset, tracksOutput: true)
        var remaining = resumed.outputRecords.makeAsyncIterator()
        #expect(await remaining.next()?.line == "two")
        resumed.terminate()
        _ = await resumed.exitCode()
    }

    @Test func `large messages survive repeated client reconnections`() async throws {
        let relay = try #require(RelayTests.relayExecutable)
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-large-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var client = try RelayedProcess.launch(
            relay: RelayCommand(executable: relay, arguments: []), directory: directory,
            spec: ProcessSpec(
                executable: URL(filePath: "/bin/cat"),
                arguments: [],
                workingDirectory: directory,
                environment: ProcessInfo.processInfo.environment
            )
        )
        for index in 0 ..< 5 {
            let message = "\(index) " + String(repeating: "crash report 🌊\t", count: 20000)
            try client.send(line: message)
            var output = client.standardOutputLines.makeAsyncIterator()
            #expect(await output.next() == message)
            let offset = client.offset
            client.detach()
            client = try RelayedProcess(directory: directory, offset: offset)
        }
        try client.send(line: "followup")
        var output = client.standardOutputLines.makeAsyncIterator()
        #expect(await output.next() == "followup")
        client.terminate()
        _ = await client.exitCode()
    }

    @Test func `blocked input cannot block output and fails within a deadline`() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-blocked-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: RelayFiles.log)
        try Data().write(to: log)
        try "\(getpid())".write(to: directory.appending(path: RelayFiles.pid), atomically: true, encoding: .utf8)
        let fifo = directory.appending(path: RelayFiles.input).path
        #expect(mkfifo(fifo, 0o600) == 0)
        let reader = open(fifo, O_RDWR | O_NONBLOCK)
        defer { close(reader) }
        let client = try RelayedProcess(directory: directory, offset: 0)
        defer { client.detach() }
        let sending = Task.detached {
            do {
                try client.send(line: String(repeating: "x", count: 1_000_000))
                return false
            } catch { return true }
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        try Data("answer\n".utf8).write(to: log)
        var output = client.standardOutputLines.makeAsyncIterator()
        #expect(await output.next() == "answer")
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await sending.value)
        #expect(throws: (any Error).self) { try client.send(line: "must not append to a partial request") }
    }

    @Test func `bounded replay excludes partial records and handles lines spanning chunks`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-sequence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = "🌊" + String(repeating: "x", count: 100_000)
        let prefix = Data((first + "\n").utf8)
        let data = prefix + Data("second\nunfinished".utf8)
        try data.write(to: directory.appending(path: RelayFiles.log))
        let records = Array(RelayLog.sequence(in: directory, upTo: Int64(prefix.count + 3)))
        #expect(records.count == 1)
        #expect(records.first?.record == .output(first))
        #expect(records.first?.end == Int64(prefix.count))
        #expect(RelayLog.records(in: directory).count == 2)
        #expect(RelayLog.hasUnread(in: directory, after: Int64(prefix.count)))
        #expect(!RelayLog.hasUnread(in: directory, after: Int64(data.count)))
    }
}
