import Foundation
import WatercodedCore

/// A source of agent sessions: Claude Code, Codex, an ACP agent, a replay script…
///
/// Providers are self-contained modules that depend only on `AgentKit` and `WatercodedCore`.
/// The app registers them in a ``ProviderRegistry``; orchestration and UI never branch on a
/// specific provider. Anything provider-shaped is expressed through ``ProviderCapabilities``.
public protocol AgentProvider: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Whether the provider can run right now (CLI installed, signed in…). Cheap to call repeatedly.
    func availability() async -> ProviderAvailability

    /// Starts a new session, or resumes one when `configuration.resumeSessionID` is set.
    func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession

    /// Reconnects to a background session that kept running while the app was closed.
    /// Requires ``ProviderCapabilities/backgroundSessions``.
    func reattachSession(_ handle: RelayHandle) async throws -> any AgentSession

    /// The model the agent uses when none is chosen, as the user configured it (an alias like `opus`
    /// or a full ID), or `nil` when the agent picks its own default.
    func configuredDefaultModel() async -> String?

    /// The effort the user configured for when none is chosen, or `nil` for the model's own default.
    func configuredDefaultEffort() async -> String?

    /// The models the agent currently offers, or `nil` to use ``ProviderDescriptor/models``.
    func modelCatalog() async -> ModelCatalog?

    /// The shell command that resumes `sessionID` in the agent's own CLI (e.g. `["claude", "--resume", id]`),
    /// or `nil` when the provider has no terminal form.
    func terminalResumeCommand(sessionID: String) -> [String]?
}

extension AgentProvider {
    public func configuredDefaultModel() async -> String? {
        nil
    }

    public func configuredDefaultEffort() async -> String? {
        nil
    }

    public func modelCatalog() async -> ModelCatalog? {
        nil
    }

    public func terminalResumeCommand(sessionID: String) -> [String]? {
        nil
    }

    public func reattachSession(_ handle: RelayHandle) async throws -> any AgentSession {
        throw AgentError.unsupported("Background sessions")
    }
}

/// Static facts about a provider.
public struct ProviderDescriptor: Sendable, Identifiable, Hashable {
    public let id: ProviderID
    public let displayName: String
    /// SF Symbol shown next to the provider's name.
    public let symbolName: String
    /// Hue (0...1) used to tint this provider's water.
    public let tintHue: Double
    public let capabilities: ProviderCapabilities
    public let models: [AgentModel]
    /// Shown when the provider isn't installed.
    public let installHint: String
    /// Where to get the provider (shown as a link when it isn't installed).
    public let installURL: URL?
    /// A scripted provider for demos. The UI offers it separately from real agents.
    public let isDemo: Bool
    /// Reasoning effort levels the provider accepts, lowest first. Empty when unsupported.
    public let effortLevels: [String]
    /// The CLI version Watercoded was tested against. The UI warns when the installed version differs,
    /// because providers that rely on undocumented wire formats can break on other versions.
    public let testedVersion: String?

    public init(
        id: ProviderID,
        displayName: String,
        symbolName: String,
        tintHue: Double,
        capabilities: ProviderCapabilities,
        models: [AgentModel],
        installHint: String,
        installURL: URL? = nil,
        isDemo: Bool = false,
        effortLevels: [String] = [],
        testedVersion: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.tintHue = tintHue
        self.capabilities = capabilities
        self.models = models
        self.installHint = installHint
        self.installURL = installURL
        self.isDemo = isDemo
        self.effortLevels = effortLevels
        self.testedVersion = testedVersion
    }

    public var defaultModel: AgentModel? {
        models.first(where: \.isDefault) ?? models.first
    }
}

/// What a provider supports. The UI only offers actions the provider can perform.
public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Streams assistant text token by token.
    public static let streamingText = Self(rawValue: 1 << 0)
    /// Asks the host to approve tool calls.
    public static let toolApprovals = Self(rawValue: 1 << 1)
    /// Can stop the current turn without ending the session.
    public static let interrupt = Self(rawValue: 1 << 2)
    /// Can resume a previous session by identifier.
    public static let resume = Self(rawValue: 1 << 3)
    /// Supports a read-only planning mode.
    public static let planMode = Self(rawValue: 1 << 4)
    /// Reports spend in USD.
    public static let costReporting = Self(rawValue: 1 << 5)
    /// Accepts new messages while a turn is running.
    public static let queueing = Self(rawValue: 1 << 6)
    /// Changes permission mode and model without restarting the session.
    public static let liveSettings = Self(rawValue: 1 << 7)
    /// Asks the user multiple-choice questions.
    public static let questions = Self(rawValue: 1 << 8)
    /// Accepts a custom model name not in ``ProviderDescriptor/models``.
    public static let customModels = Self(rawValue: 1 << 9)
    /// Accepts images in user messages.
    public static let images = Self(rawValue: 1 << 10)
    /// Can keep running after the app quits and be reattached later.
    public static let backgroundSessions = Self(rawValue: 1 << 11)
    /// Can start a new session from any ``AgentEvent/checkpoint(_:)`` of an existing one.
    public static let branching = Self(rawValue: 1 << 12)
    /// Can explicitly compact conversation history.
    public static let compaction = Self(rawValue: 1 << 13)
    /// Can set, inspect and clear a native persistent goal.
    public static let goals = Self(rawValue: 1 << 14)
    /// Checkpoints from before compaction remain valid for conversation forks.
    public static let branchingAcrossCompaction = Self(rawValue: 1 << 15)
}

/// A model a provider can run.
public struct AgentModel: Sendable, Hashable, Identifiable {
    /// Value passed to the provider (alias or full model name).
    public let id: String
    public let displayName: String
    public let isDefault: Bool

    public init(id: String, displayName: String, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

public enum ProviderAvailability: Sendable, Hashable {
    case available(version: String?)
    case notInstalled
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self {
            true
        } else {
            false
        }
    }
}
