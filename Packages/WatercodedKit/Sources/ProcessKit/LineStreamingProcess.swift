import Foundation

/// A long-lived child process spoken to in newline-delimited text (JSON Lines).
///
/// - stdout and stderr are delivered as complete lines on ``standardOutputLines`` /
///   ``standardErrorLines``; both streams finish when the process closes them.
/// - ``send(line:)`` writes one line to stdin.
/// - ``exitCode()`` suspends until the process exits.
///
/// Thread safety: all mutable state is guarded by `lock`; `Process` and `FileHandle`
/// writes are safe to call from any thread.
public final class LineStreamingProcess: @unchecked Sendable {
    public let standardOutputLines: AsyncStream<String>
    public let standardErrorLines: AsyncStream<String>
    public var processIdentifier: Int32 {
        process.processIdentifier
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var stdinClosed = false

    /// Writing to a pipe whose reader has exited raises SIGPIPE, which terminates the whole app by
    /// default. Ignoring it turns that into an ordinary `EPIPE` error from `write`, handled below.
    private static let ignoreBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Launches the process immediately.
    public init(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws {
        Self.ignoreBrokenPipes
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        standardOutputLines = Self.lines(from: stdout.fileHandleForReading)
        standardErrorLines = Self.lines(from: stderr.fileHandleForReading)

        process.terminationHandler = { [weak self] process in
            self?.didExit(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(
                executable: executable.lastPathComponent,
                underlying: error.localizedDescription
            )
        }
    }

    /// Writes `line` followed by a newline to stdin.
    public func send(line: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stdinClosed, exitStatus == nil else { return }
        try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes stdin, signalling end of input.
    public func closeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdin.fileHandleForWriting.close()
    }

    /// Sends SIGINT.
    public func interrupt() {
        if process.isRunning {
            process.interrupt()
        }
    }

    /// Sends SIGTERM, escalating to SIGKILL after `grace`.
    public func terminate(grace: Duration = .seconds(3)) {
        guard process.isRunning else { return }
        closeInput()
        process.terminate()
        let pid = process.processIdentifier
        Task.detached { [weak self] in
            try? await Task.sleep(for: grace)
            if self?.hasExited == false {
                kill(pid, SIGKILL)
            }
        }
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil
    }

    /// Suspends until the process exits and returns its status.
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

    private func didExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }

    /// Splits a file handle's bytes into lines, delivered in order.
    private static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let splitter = LineSplitter()
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = splitter.flush() {
                        continuation.yield(rest)
                    }
                    continuation.finish()
                } else {
                    for line in splitter.append(data) {
                        continuation.yield(line)
                    }
                }
            }
        }
    }
}

/// Accumulates bytes and emits complete UTF-8 lines. Called serially by `readabilityHandler`.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines
    }

    func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}
