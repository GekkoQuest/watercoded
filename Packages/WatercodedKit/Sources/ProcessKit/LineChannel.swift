import Foundation

/// A line-oriented connection to an agent process, whether the app owns it directly
/// (``LineStreamingProcess``) or it runs under a background relay (``RelayedProcess``).
public protocol LineChannel: AnyObject, Sendable {
    var standardOutputLines: AsyncStream<String> { get }
    var standardErrorLines: AsyncStream<String> { get }
    var hasExited: Bool { get }
    func send(line: String) throws
    func closeInput()
    func interrupt()
    func terminate(grace: Duration)
    func exitCode() async -> Int32
}

extension LineStreamingProcess: LineChannel {}

/// What to run: an executable, its arguments, where, and with which environment.
public struct ProcessSpec: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}
