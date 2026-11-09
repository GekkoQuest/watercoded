import Foundation

/// The outcome of a process that ran to completion.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool {
        exitCode == 0
    }
}

public enum ProcessError: Error, LocalizedError, Sendable {
    case launchFailed(executable: String, underlying: String)
    case timedOut(executable: String)
    case nonZeroExit(command: String, exitCode: Int32, standardError: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, underlying):
            "Couldn't launch \(executable): \(underlying)"
        case let .timedOut(executable):
            "\(executable) didn't finish in time."
        case let .nonZeroExit(command, exitCode, standardError):
            "\(command) failed (exit \(exitCode)): \(standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Runs short-lived commands (git, `--version` probes) and collects their output.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes while the process runs: a child blocks once a pipe's buffer (~64 KB) fills,
        // so reading only after exit would deadlock on large output such as big diffs.
        let output = PipeCollector(stdout.fileHandleForReading)
        let errors = PipeCollector(stderr.fileHandleForReading)

        let box = ProcessBox(process)
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        box.process.terminationHandler = { process in
                            box.markFinished()
                            continuation.resume(returning: process.terminationStatus)
                        }
                        do {
                            try box.launch()
                        } catch {
                            box.process.terminationHandler = nil
                            continuation
                                .resume(throwing: error is CancellationError ? error : ProcessError.launchFailed(
                                    executable: executable.lastPathComponent,
                                    underlying: error.localizedDescription
                                ))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next().flatMap(\.self)
                group.cancelAll()
                guard let first else {
                    box.terminate()
                    throw ProcessError.timedOut(executable: executable.lastPathComponent)
                }
                return first
            }
        } onCancel: {
            box.terminate()
        }

        return await ProcessResult(
            exitCode: exitCode,
            standardOutput: String(decoding: output.data(), as: UTF8.self),
            standardError: String(decoding: errors.data(), as: UTF8.self)
        )
    }
}

/// Owns a `Process` across the launch path, the termination handler and cancellation, which run
/// on different threads. `Process.terminate()` raises an Objective-C exception (crashing the app)
/// if the process was never launched, so every transition goes through this lock.
final class ProcessBox: @unchecked Sendable {
    private enum State {
        case idle
        case running
        case finished
        case cancelled
    }

    let process: Process
    private let lock = NSLock()
    private var state = State.idle

    init(_ process: Process) {
        self.process = process
    }

    /// Launches the process, unless it was cancelled first (then throws `CancellationError`).
    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .idle else { throw CancellationError() }
        try process.run()
        state = .running
    }

    func markFinished() {
        lock.lock()
        state = .finished
        lock.unlock()
    }

    /// Safe at any moment: before launch it prevents the launch; while running it sends SIGTERM;
    /// after exit it does nothing.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle: state = .cancelled
        case .running: if process.isRunning {
                process.terminate()
            }
        case .finished, .cancelled: break
        }
    }
}

/// Accumulates everything written to a pipe; ``data()`` waits for end-of-file.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var waiters: [CheckedContinuation<Data, Never>] = []

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.lock()
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                isFinished = true
                let result = buffer
                let pending = waiters
                waiters.removeAll()
                lock.unlock()
                pending.forEach { $0.resume(returning: result) }
            } else {
                buffer.append(chunk)
                lock.unlock()
            }
        }
    }

    func data() async -> Data {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let result = buffer
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
