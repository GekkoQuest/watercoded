import Darwin
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
        defer { output.finish()
            errors.finish()
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
                group.addTask {
                    let exitCode = try await box.exitCode()
                    // Pipe draining is part of the deadline too: a descendant can keep a pipe open
                    // after the command itself exits.
                    return await ProcessResult(
                        exitCode: exitCode,
                        standardOutput: String(decoding: output.data(), as: UTF8.self),
                        standardError: String(decoding: errors.data(), as: UTF8.self)
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                let first = try await group.next().flatMap(\.self)
                try Task.checkCancellation()
                guard let first else {
                    box.terminate()
                    output.finish()
                    errors.finish()
                    throw ProcessError.timedOut(executable: executable.lastPathComponent)
                }
                return first
            }
        } onCancel: {
            box.terminate()
            output.finish()
            errors.finish()
        }
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

    func exitCode() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                self.markFinished()
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try launch()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error is CancellationError ? error : ProcessError.launchFailed(
                    executable: process.executableURL?.lastPathComponent ?? "command",
                    underlying: error.localizedDescription
                ))
            }
        }
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
        case .running:
            signal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if state == .running {
                    signal(SIGKILL)
                }
            }
        case .finished, .cancelled: break
        }
    }

    /// Foundation normally gives the child its own process group. Signal that group so a shell's
    /// subprocesses stop too; never signal the app's own group if that isolation is absent.
    private func signal(_ value: Int32) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        Darwin.kill(target, value)
    }
}

/// Accumulates everything written to a pipe; ``data()`` waits for end-of-file.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private var waiters: [CheckedContinuation<Data, Never>] = []

    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] handle in
            let chunk = (try? handle.read(upToCount: 65536)) ?? Data()
            if chunk.isEmpty {
                finish()
            } else {
                lock.lock()
                if !isFinished {
                    buffer.append(chunk)
                }
                lock.unlock()
            }
        }
    }

    /// Releases pipe waiters on EOF, timeout or cancellation, even if a descendant holds a writer.
    func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock()
            return
        }
        isFinished = true
        let result = buffer
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        handle.readabilityHandler = nil
        try? handle.close()
        pending.forEach { $0.resume(returning: result) }
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
