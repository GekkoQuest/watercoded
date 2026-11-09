import Foundation

/// One agent conversation, bound to one ``Channel``. Plain name: session / thread.
public struct Current: Identifiable, Hashable, Codable, Sendable {
    public let id: CurrentID
    public let poolID: PoolID
    public var title: String
    public var providerID: ProviderID
    /// Provider-specific model identifier; `nil` means the provider's default.
    public var model: String?
    public var permissionMode: PermissionMode
    public var channel: Channel
    /// The provider's own session identifier, used to resume after relaunch.
    public var providerSessionID: String?
    public var status: CurrentStatus
    public var usage: UsageSnapshot
    /// Reasoning effort passed to the provider, if it supports one.
    public var effort: String?
    /// Where ``title`` came from; generated titles may be refreshed, user titles never are.
    public var titleSource: TitleSource?
    /// One-line description of where the work stands, refreshed after each turn.
    public var summary: String?
    /// The agent's task list, when it keeps one.
    public var tasks: [TaskItem]?
    /// Result of the most recent test or build command the agent ran.
    public var lastCheck: CheckResult?
    /// Working-tree snapshots taken at turn boundaries (the basis for per-turn diffs).
    public var turnSnapshots: [TurnSnapshot]?
    public var lastTurnEndedAt: Date?
    /// When the user last looked at this Current (drives the "while you were away" recap).
    public var lastViewedAt: Date?
    /// Set when the app quit while the agent was mid-turn and the session couldn't keep running.
    public var interruptedByQuit: Bool?
    /// The background relay running this Current's agent, if any.
    public var relay: RelayHandle?
    /// What the agent loaded (MCP servers, skills, instruction files), from its last session.
    public var environment: AgentEnvironment?
    /// The GitHub issue this Current was started from, closed by the pull request Land opens.
    public var issue: IssueReference?
    /// The Current that delegated work to this one (see `delegate`), if any. A child works in its parent's
    /// folder and is shown under it.
    public var parentID: CurrentID?
    /// For a delegated Current: the snapshot of the parent's folder it started from, so its changes can be
    /// applied back to the parent when it finishes.
    public var delegationBase: String?
    /// For a branched Current: the checkpoint its first session forks from. Cleared once it has.
    public var pendingBranchAt: String?
    /// The pull request Land opened, watched for checks, reviews and merging.
    public var pullRequest: PullRequestStatus?
    /// Output tokens generated across every turn of this Current, thinking included.
    public var outputTokens: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: CurrentID = CurrentID(),
        poolID: PoolID,
        title: String,
        providerID: ProviderID,
        model: String? = nil,
        permissionMode: PermissionMode = .ask,
        channel: Channel,
        providerSessionID: String? = nil,
        status: CurrentStatus = .draft,
        usage: UsageSnapshot = UsageSnapshot(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.poolID = poolID
        self.title = title
        self.providerID = providerID
        self.model = model
        self.permissionMode = permissionMode
        self.channel = channel
        self.providerSessionID = providerSessionID
        self.status = status
        self.usage = usage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TitleSource: String, Codable, Sendable {
    case prompt
    case generated
    case user
}

/// Lifecycle of a Current. Drives sidebar grouping and the vessel's water.
public enum CurrentStatus: String, Codable, Sendable, CaseIterable {
    /// Created, nothing sent yet.
    case draft
    /// The agent is working.
    case flowing
    /// The agent is blocked on the user (an approval or question).
    case waiting
    /// The agent finished a turn and handed back for review.
    case ashore
    /// The last turn failed or the session crashed.
    case stalled
    /// Done: merged, archived or dismissed.
    case settled

    public var needsAttention: Bool {
        self == .waiting || self == .ashore || self == .stalled
    }
}
