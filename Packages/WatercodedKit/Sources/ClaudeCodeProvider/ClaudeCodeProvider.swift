import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// Runs the user's own `claude` CLI in stream-json mode.
///
/// Watercoded never sees or stores Claude credentials: the CLI the user installed and signed in
/// to handles authentication itself (see docs/adr/0003-cli-adapters-own-credentials.md).
public struct ClaudeCodeProvider: AgentProvider {
    public static let id: ProviderID = "claude-code"

    private let executableName: String
    private let environment: ShellEnvironment
    /// How to start background relays; `nil` disables background sessions.
    private let relay: RelayCommand?
    /// Where Claude Code keeps its sessions (`~/.claude/projects`).
    let projectsDirectory: URL
    /// Extra `claude` arguments (tests use `--mcp-config` to add an MCP server).
    var extraArguments: [String] = []

    public init(
        executableName: String = "claude",
        environment: ShellEnvironment = .shared,
        relay: RelayCommand? = nil,
        projectsDirectory: URL = ClaudeCodeProvider.defaultProjectsDirectory
    ) {
        self.executableName = executableName
        self.environment = environment
        self.relay = relay
        self.projectsDirectory = projectsDirectory
    }

    static var configDirectory: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    public static var defaultProjectsDirectory: URL {
        configDirectory.appending(path: "projects", directoryHint: .isDirectory)
    }

    /// `ANTHROPIC_MODEL` from the user's shell, else `model` in the user's Claude settings.
    /// Project settings can override this per repository; this is the user-wide default.
    public func configuredDefaultModel() async -> String? {
        await setting(environment: "ANTHROPIC_MODEL", key: "model")
    }

    /// `CLAUDE_CODE_EFFORT_LEVEL` from the user's shell, else `effortLevel` in the user's Claude settings.
    public func configuredDefaultEffort() async -> String? {
        await setting(environment: "CLAUDE_CODE_EFFORT_LEVEL", key: "effortLevel")
    }

    public func terminalResumeCommand(sessionID: String) -> [String]? {
        [executableName, "--resume", sessionID]
    }

    public func modelCatalog() async -> ModelCatalog? {
        ClaudeModelCatalog.load(from: Self.configDirectory.appending(path: "cache/model-catalog"))
    }

    private func setting(environment variable: String, key: String) async -> String? {
        if let value = await environment.environment()[variable], !value.isEmpty {
            return value
        }
        let url = Self.configDirectory.appending(path: "settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = settings[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
            displayName: "Claude Code",
            symbolName: "sparkle",
            tintHue: 0.07,
            capabilities: ProviderCapabilities([
                .streamingText, .toolApprovals, .interrupt, .resume, .planMode, .costReporting, .queueing,
                .liveSettings, .questions, .customModels, .branching
            ]).union(relay == nil ? [] : .backgroundSessions), // keeps running after quit, under a relay
            models: [
                AgentModel(id: "default", displayName: "Default", isDefault: true),
                AgentModel(id: "opus", displayName: "Opus"),
                AgentModel(id: "sonnet", displayName: "Sonnet"),
                AgentModel(id: "haiku", displayName: "Haiku")
            ],
            installHint: "Install the Claude Code CLI, then run `claude` once in Terminal to sign in.",
            installURL: URL(string: "https://code.claude.com/docs/en/setup"),
            effortLevels: ["low", "medium", "high", "xhigh", "max"],
            // Keep in sync with ADR 0008, scripts/doctor.sh and the README's Requirements.
            testedVersion: "2.1.319"
        )
    }

    public func availability() async -> ProviderAvailability {
        guard let executable = await environment.locate(executableName) else { return .notInstalled }
        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: ["--version"],
                environment: environment.environment(),
                timeout: .seconds(10)
            )
            guard result.succeeded else {
                return .unavailable(reason: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let version = result.standardOutput.split(separator: " ").first.map(String.init)
            return .available(version: version)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let executable = await environment.locate(executableName) else {
            throw AgentError.providerUnavailable(name: descriptor.displayName, reason: "the `claude` CLI wasn't found")
        }
        let spec = await ProcessSpec(
            executable: executable,
            arguments: ClaudeCodeArguments.make(for: configuration) + extraArguments,
            workingDirectory: configuration.workingDirectory,
            environment: ClaudeCodeArguments.environment(base: environment.environment())
        )
        return try await ClaudeCodeSession.launch(spec, relay: relay, relayDirectory: configuration.relayDirectory)
    }

    public func reattachSession(_ handle: RelayHandle) async throws -> any AgentSession {
        try await ClaudeCodeSession.reattach(handle)
    }
}
