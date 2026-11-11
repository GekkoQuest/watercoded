import Foundation

/// The client side of a relay: starts a detached relay for an agent, or reattaches to one that
/// kept running while the app was closed, and exposes it as a ``LineChannel``.
public final class RelayedProcess: LineChannel, @unchecked Sendable {
    public let standardOutputLines: AsyncStream<String>
    public let standardErrorLines: AsyncStream<String>
    public let directory: URL
    public let outputRecords: AsyncStream<RelayOutput>
    private let recordContinuation: AsyncStream<RelayOutput>.Continuation
    private let tracksOutput: Bool

    private let outputContinuation: AsyncStream<String>.Continuation
    private let errorContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var reader: FileHandle?
    private var source: (any DispatchSourceFileSystemObject)?
    private var livenessTimer: (any DispatchSourceTimer)?
    private var buffer = Data()
    private var consumed: Int64
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var writer: FileHandle?
    private let queue = DispatchQueue(label: "watercoded.relay.client")

    /// Starts a new relay in `directory` running `executable`, then attaches to it.
    public static func launch(
        relay: RelayCommand,
        directory: URL,
        spec: ProcessSpec,
        tracksOutput: Bool = false
    ) throws -> RelayedProcess {
        let executable = spec.executable
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = relay.executable
        process.arguments = relay.arguments + [directory.path, spec.workingDirectory.path, "--", executable.path]
            + spec.arguments
        process.environment = spec.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Wait for the relay to create its input pipe (normally a few milliseconds).
        let fifo = directory.appending(path: RelayFiles.input)
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: fifo.path) {
            if !process.isRunning {
                break
            }
            usleep(10000)
        }
        guard FileManager.default.fileExists(atPath: fifo.path) else {
            throw ProcessError.launchFailed(
                executable: executable.lastPathComponent,
                underlying: "the relay didn't start"
            )
        }
        return try RelayedProcess(directory: directory, offset: 0, tracksOutput: tracksOutput)
    }

    /// Attaches to an existing relay, delivering log lines after `offset`.
    public init(directory: URL, offset: Int64, tracksOutput: Bool = false) throws {
        self.tracksOutput = tracksOutput
        (outputRecords, recordContinuation) = AsyncStream.makeStream(of: RelayOutput.self)
        self.directory = directory
        consumed = offset
        (standardOutputLines, outputContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        (standardErrorLines, errorContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let reader = try FileHandle(forReadingFrom: directory.appending(path: RelayFiles.log))
        try reader.seek(toOffset: UInt64(offset))
        self.reader = reader
        startReading(reader)
        startLivenessChecks()
    }

    /// Bytes of the log delivered so far; persist it to reattach later without duplicates.
    public var offset: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return consumed
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil
    }

    public func send(line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard exitStatus == nil else { return }
        if writer == nil {
            writer = FileHandle(forWritingAtPath: directory.appending(path: RelayFiles.input).path)
        }
        guard let writer else {
            throw ProcessError.launchFailed(executable: "relay", underlying: "the background session has ended")
        }
        try writer.write(contentsOf: Data((line + "\n").utf8))
    }

    public func closeInput() {}

    public func interrupt() {
        try? send(line: RelayRecord.interruptCommand)
    }

    /// Stops the agent (the relay exits once it has).
    public func terminate(grace: Duration = .seconds(3)) {
        try? send(line: RelayRecord.terminateCommand)
    }

    /// Stops reading without stopping the agent (e.g. the app is quitting).
    public func detach() {
        queue.sync {
            source?.cancel()
            source = nil
            livenessTimer?.cancel()
            livenessTimer = nil
        }
        lock.lock()
        try? writer?.close()
        writer = nil
        lock.unlock()
    }

    public func exitCode() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: Reading

    private func startReading(_ reader: FileHandle) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: reader.fileDescriptor,
            eventMask: [.extend, .write],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source
        source.resume()
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        guard let reader, let data = try? reader.readToEnd(), !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex ..< newline]
            let length = Int64(lineData.count + 1)
            buffer.removeSubrange(buffer.startIndex ... newline)
            deliver(RelayRecord(logLine: String(decoding: lineData, as: UTF8.self)), length: length)
        }
    }

    private func deliver(_ record: RelayRecord, length: Int64) {
        lock.lock()
        consumed += length
        let end = consumed
        lock.unlock()
        switch record {
        case let .output(line):
            if tracksOutput {
                recordContinuation.yield(RelayOutput(line: line, offset: end))
            } else {
                outputContinuation.yield(line)
            }
        case let .error(line): errorContinuation.yield(line)
        case .input: break
        case let .exited(code): finish(code)
        }
    }

    /// Catches a relay that died without writing an exit record (e.g. it was killed).
    private func startLivenessChecks() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !hasExited else { return }
            drain()
            if !hasExited, !RelayLog.isAlive(in: directory) {
                drain()
                if !hasExited {
                    finish(-1)
                }
            }
        }
        livenessTimer = timer
        timer.resume()
    }

    private func finish(_ code: Int32) {
        lock.lock()
        guard exitStatus == nil else {
            lock.unlock()
            return
        }
        exitStatus = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        recordContinuation.finish()
        outputContinuation.finish()
        errorContinuation.finish()
        waiters.forEach { $0.resume(returning: code) }
        source?.cancel()
        livenessTimer?.cancel()
    }
}

/// How to start a relay: the executable and the arguments that switch it into relay mode.
public struct RelayCommand: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String] = ["--relay"]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// One output line and its exact replay boundary, before any later queued lines.
public struct RelayOutput: Sendable {
    public let line: String
    public let offset: Int64
}
