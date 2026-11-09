import Foundation
import WatercodedCore

/// A live conversation with an agent.
///
/// Sessions publish everything that happens on ``events`` as normalized ``AgentEvent``s. The
/// stream finishes after ``AgentEvent/sessionEnded(_:)``. All methods may be called from any
/// task; implementations are expected to be actors.
public protocol AgentSession: AnyObject, Sendable {
    var events: AsyncStream<AgentEvent> { get }

    /// Sends a user message. Providers with ``ProviderCapabilities/queueing`` accept this mid-turn.
    func send(_ message: UserMessage) async throws

    /// Answers a ``PermissionRequest`` previously published on ``events``.
    func respond(to requestID: PermissionRequest.ID, with decision: PermissionDecision) async throws

    /// Stops the current turn, keeping the session alive.
    func interrupt() async throws

    /// Ends the session and releases its process.
    func terminate() async

    /// Answers questions from ``AgentEvent/questionAsked(requestID:questions:)``:
    /// question text → chosen label(s). Requires ``ProviderCapabilities/questions``.
    func answer(_ requestID: String, with answers: [String: String]) async throws

    /// Tells a reattached background session the settings it was started with (permission mode, model, effort…),
    /// which a relay log doesn't carry. Sessions whose agent process kept its own settings can ignore this.
    func restoreSettings(_ configuration: SessionConfiguration) async

    /// Answers an ``AgentEvent/formRequested(_:)``.
    func respondToForm(_ requestID: String, with response: FormResponse) async throws

    /// Changes the permission mode without restarting. Requires ``ProviderCapabilities/liveSettings``.
    func setPermissionMode(_ mode: PermissionMode) async throws

    /// Switches model without restarting. Requires ``ProviderCapabilities/liveSettings``.
    func setModel(_ model: String?) async throws

    /// Where a background session can be reattached from, and how far it has been read.
    /// `nil` for sessions that live and die with the app.
    func relayHandle() async -> RelayHandle?

    /// Lets go of the session without stopping the agent (background sessions keep running);
    /// sessions that can't run in the background are terminated.
    func detach() async
}

extension AgentSession {
    public func answer(_ requestID: String, with answers: [String: String]) async throws {
        throw AgentError.unsupported("Answering questions")
    }

    public func setPermissionMode(_ mode: PermissionMode) async throws {
        throw AgentError.unsupported("Changing permissions mid-session")
    }

    public func respondToForm(_ requestID: String, with response: FormResponse) async throws {
        throw AgentError.unsupported("MCP forms")
    }

    public func restoreSettings(_ configuration: SessionConfiguration) async {}

    public func setModel(_ model: String?) async throws {
        throw AgentError.unsupported("Changing models mid-session")
    }

    public func relayHandle() async -> RelayHandle? {
        nil
    }

    public func detach() async {
        await terminate()
    }
}

/// Everything needed to start (or resume) a session.
public struct SessionConfiguration: Sendable, Hashable {
    public var workingDirectory: URL
    public var model: String?
    public var permissionMode: PermissionMode
    /// Reasoning effort, one of the provider's ``ProviderDescriptor/effortLevels``.
    public var effort: String?
    /// Provider session identifier to resume, if any.
    public var resumeSessionID: String?
    /// Extra directories the agent may access besides `workingDirectory`.
    public var additionalDirectories: [URL]
    /// When set (and the provider supports ``ProviderCapabilities/backgroundSessions``), the agent runs
    /// under a relay in this directory and keeps running if the app quits.
    public var relayDirectory: URL?
    /// Extra MCP servers for this session (e.g. Watercoded's own `delegate` tool).
    public var mcpServers: [MCPServer] = []
    /// With ``resumeSessionID``: start a *new* session holding the conversation up to this checkpoint.
    /// Requires ``ProviderCapabilities/branching``.
    public var branchAt: String?

    public init(
        workingDirectory: URL,
        model: String? = nil,
        permissionMode: PermissionMode = .ask,
        effort: String? = nil,
        resumeSessionID: String? = nil,
        additionalDirectories: [URL] = [],
        relayDirectory: URL? = nil,
        branchAt: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.resumeSessionID = resumeSessionID
        self.additionalDirectories = additionalDirectories
        self.relayDirectory = relayDirectory
        self.branchAt = branchAt
    }
}

/// A stdio MCP server to start with a session.
public struct MCPServer: Sendable, Hashable {
    public var name: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    /// The server's tools run without asking (only for Watercoded's own servers).
    public var isTrusted: Bool
    /// How long one tool call may take. Delegated work can take a while.
    public var toolTimeout: Duration

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isTrusted: Bool = false,
        toolTimeout: Duration = .seconds(120)
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.isTrusted = isTrusted
        self.toolTimeout = toolTimeout
    }
}

/// The user's answer to an MCP form (MCP elicitation actions).
public enum FormResponse: Sendable, Hashable {
    /// Submitted; for link forms, the user opened the link and continued. Values by field key.
    case accept([String: JSONValue])
    case decline
    case cancel

    /// The MCP `{action, content}` result both Claude Code and Codex forward to the server.
    public var payload: (action: String, content: JSONValue) {
        switch self {
        case let .accept(values): ("accept", .object(values))
        case .decline: ("decline", .null)
        case .cancel: ("cancel", .null)
        }
    }
}

/// A message from the user to the agent.
public struct UserMessage: Sendable, Hashable {
    public var text: String
    /// Images sent with the message. Requires ``ProviderCapabilities/images``.
    public var images: [ImageAttachment]

    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}
