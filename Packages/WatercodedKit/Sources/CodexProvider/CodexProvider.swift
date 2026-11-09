import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// Runs the user's own `codex` CLI as an app server (JSON-RPC over stdio).
///
/// Like the Claude provider, Watercoded never sees Codex credentials: the CLI the user installed and
/// signed in to (ChatGPT or an API key) handles authentication. See docs/adr/0011-codex-provider.md.
public struct CodexProvider: AgentProvider {
    public static let id: ProviderID = "codex"

    private let executableName: String
    private let environment: ShellEnvironment
    /// How to start background relays; `nil` disables background sessions.
    private let relay: RelayCommand?
    /// Where Codex saves sessions (`~/.codex/sessions`), for importing them.
    let sessionsDirectory: URL

    public init(
        executableName: String = "codex",
        environment: ShellEnvironment = .shared,
        relay: RelayCommand? = nil,
        sessionsDirectory: URL = CodexProvider.homeDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    ) {
        self.executableName = executableName
        self.environment = environment
        self.relay = relay
        self.sessionsDirectory = sessionsDirectory
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: Self.id,
            displayName: "Codex",
            symbolName: "chevron.left.forwardslash.chevron.right",
            tintHue: 0.45,
            capabilities: ProviderCapabilities([
                .streamingText, .toolApprovals, .interrupt, .resume, .queueing, .liveSettings,
                .customModels, .images, .branching, .planMode, .questions
            ]).union(relay == nil ? [] : .backgroundSessions), // the app server keeps running after quit
            models: [AgentModel(id: "default", displayName: "Default", isDefault: true)],
            installHint: "Install the Codex CLI, then run `codex login` once in Terminal to sign in.",
            installURL: URL(string: "https://developers.openai.com/codex/cli"),
            effortLevels: ["low", "medium", "high", "xhigh", "max", "ultra"],
            // Keep in sync with ADR 0011, scripts/doctor.sh and the README's Requirements.
            testedVersion: "0.167.0"
        )
    }

    public func availability() async -> ProviderAvailability {
        guard let executable = await environment.locate(executableName) else { return .notInstalled }
        do {
            let version = try await ProcessRunner.run(
                executable: executable,
                arguments: ["--version"],
                environment: environment.environment(),
                timeout: .seconds(10)
            )
            guard version.succeeded else {
                return .unavailable(reason: version.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let login = try await ProcessRunner.run(
                executable: executable,
                arguments: ["login", "status"],
                environment: environment.environment(),
                timeout: .seconds(10)
            )
            let status = (login.standardOutput + login.standardError).lowercased()
            guard login.succeeded, !status.contains("not logged in") else {
                return .unavailable(reason: "Codex isn't signed in. Run `codex login` once in Terminal.")
            }
            // "codex-cli 0.167.0"
            return .available(version: version.standardOutput.split(separator: " ").last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        guard let executable = await environment.locate(executableName) else {
            throw AgentError.providerUnavailable(name: descriptor.displayName, reason: "the `codex` CLI wasn't found")
        }
        let spec = await ProcessSpec(
            executable: executable,
            arguments: ["app-server"],
            workingDirectory: configuration.workingDirectory,
            environment: environment.environment()
        )
        return try await CodexSession.launch(spec, configuration: configuration, relay: relay)
    }

    public func reattachSession(_ handle: RelayHandle) async throws -> any AgentSession {
        try await CodexSession.reattach(handle)
    }

    public func terminalResumeCommand(sessionID: String) -> [String]? {
        [executableName, "resume", sessionID]
    }

    /// `model` in `~/.codex/config.toml`, if set.
    public func configuredDefaultModel() async -> String? {
        Self.configValue("model")
    }

    /// `model_reasoning_effort` in `~/.codex/config.toml`, if set.
    public func configuredDefaultEffort() async -> String? {
        Self.configValue("model_reasoning_effort")
    }

    /// The models the user's account can use, from a short-lived app server (`model/list`).
    public func modelCatalog() async -> ModelCatalog? {
        guard let executable = await environment.locate(executableName) else { return nil }
        let spec = await ProcessSpec(
            executable: executable,
            arguments: ["app-server"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: environment.environment()
        )
        return await CodexModelList.fetch(spec)
    }

    // MARK: Config

    public static var homeDirectory: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    /// A top-level `key = "value"` from `config.toml` (before any `[table]`). Enough for the few
    /// plain string settings read here, without a TOML dependency.
    static func configValue(_ key: String, in text: String? = nil) -> String? {
        let contents = text ?? (try? String(contentsOf: homeDirectory.appending(path: "config.toml"), encoding: .utf8))
        for rawLine in (contents ?? "").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                break
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            let value = parts[1].split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
