import Foundation

/// The relay side: runs inside a detached process (`Watercoded --relay …` or `watercoded-relay …`),
/// owns the agent process, and keeps it alive after the app quits.
///
/// Usage: `--relay <session-directory> <working-directory> -- <executable> [arguments…]`.
/// The agent inherits the relay's environment.
public enum RelayHost {
    /// Parses `arguments` (everything after `--relay`) and runs until the agent exits. Never returns.
    public static func main(arguments: [String]) -> Never {
        guard arguments.count >= 4, let separator = arguments.firstIndex(of: "--"), separator == 2,
              arguments.count > separator + 1 else {
            FileHandle.standardError.write(Data("usage: --relay <dir> <cwd> -- <executable> [args…]\n".utf8))
            exit(64)
        }
        let directory = URL(filePath: arguments[0], directoryHint: .isDirectory)
        let workingDirectory = URL(filePath: arguments[1], directoryHint: .isDirectory)
        let executable = URL(filePath: arguments[separator + 1])
        let childArguments = Array(arguments[(separator + 2)...])
        do {
            let host = try Host(directory: directory)
            try host.start(executable: executable, arguments: childArguments, workingDirectory: workingDirectory)
        } catch {
            FileHandle.standardError.write(Data("relay failed: \(error)\n".utf8))
            exit(70)
        }
        dispatchMain()
    }

    private final class Host: @unchecked Sendable {
        private let directory: URL
        private let log: FileHandle
        private let queue = DispatchQueue(label: "watercoded.relay")
        private let process = Process()
        private let stdin = Pipe()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private var input: FileHandle?

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let logURL = directory.appending(path: RelayFiles.log)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
        }

        func start(executable: URL, arguments: [String], workingDirectory: URL) throws {
            // Survive the app quitting: own session, and ignore hangups and broken pipes.
            setsid()
            signal(SIGHUP, SIG_IGN)
            signal(SIGPIPE, SIG_IGN)

            let fifo = directory.appending(path: RelayFiles.input)
            unlink(fifo.path)
            guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            // Read-write keeps the pipe open between clients, so a client leaving isn't end-of-input.
            let fd = open(fifo.path, O_RDWR)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.input = input

            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [self] process in finish(process.terminationStatus) }

            let outputSplitter = LineSplitter()
            stdout.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                let lines = data.isEmpty ? (outputSplitter.flush().map { [$0] } ?? []) : outputSplitter.append(data)
                for line in lines {
                    append(line)
                }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            let errorSplitter = LineSplitter()
            stderr.fileHandleForReading.readabilityHandler = { [self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in errorSplitter.append(data) {
                    append(RelayRecord.metaLine("stderr", ["line": line]))
                }
            }
            let inputSplitter = LineSplitter()
            input.readabilityHandler = { [self] handle in
                for line in inputSplitter.append(handle.availableData) {
                    handleInput(line)
                }
            }

            try process.run()
            try "\(getpid())".write(to: directory.appending(path: RelayFiles.pid), atomically: true, encoding: .utf8)
        }

        private func handleInput(_ line: String) {
            switch line {
            case RelayRecord.terminateCommand:
                if process.isRunning {
                    process.terminate()
                }
            case RelayRecord.interruptCommand:
                if process.isRunning {
                    process.interrupt()
                }
            default:
                append(RelayRecord.metaLine("stdin", ["line": line]))
                try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
        }

        private func append(_ line: String) {
            queue.sync {
                try? log.write(contentsOf: Data((line + "\n").utf8))
            }
        }

        private func finish(_ status: Int32) {
            // Let the stdout handler drain before writing the final record.
            queue.asyncAfter(deadline: .now() + 0.2) { [self] in
                // Clean up first, so a client that sees the exit record never finds the relay still "alive".
                unlink(directory.appending(path: RelayFiles.input).path)
                try? FileManager.default.removeItem(at: directory.appending(path: RelayFiles.pid))
                try? log.write(contentsOf: Data((RelayRecord.metaLine("exit", ["code": Int(status)]) + "\n").utf8))
                try? log.close()
                exit(0)
            }
        }
    }
}
