import Foundation

/// How much an agent may do without asking. Providers map these onto their own modes.
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Ask before edits and commands (default).
    case ask
    /// File edits are allowed; commands still ask.
    case acceptEdits
    /// Read-only: the agent explores and proposes a plan.
    case plan
    /// Everything is allowed. Shown with a warning chip.
    case fullAccess

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept Edits"
        case .plan: "Plan"
        case .fullAccess: "Full Access"
        }
    }
}

/// Normalized classification of a tool call, used for icons and water effects.
public enum ToolKind: String, Codable, Sendable, CaseIterable {
    case read
    case edit
    case shell
    case search
    case web
    case subagent
    case mcp
    case other

    public var symbolName: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .shell: "terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .subagent: "person.2"
        case .mcp: "puzzlepiece.extension"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// Token usage and spend for a Current.
public struct UsageSnapshot: Hashable, Codable, Sendable {
    /// Tokens currently occupying the context window (prompt + cache).
    public var contextTokens: Int
    /// Size of the model's context window, when known.
    public var contextWindow: Int?
    /// Cumulative cost reported by the provider, in USD. For subscription plans this is only an
    /// API-list-price estimate; nothing is billed per token. Check ``billing`` before showing it.
    public var costUSD: Double
    /// How the session is paid for, when the provider says.
    public var billing: BillingMode?
    /// Subscription rate-limit windows (e.g. 5-hour and weekly), when the provider reports them.
    public var planUsage: PlanUsage?
    /// How long the provider keeps the prompt cache warm, when known.
    public var cacheTTL: TimeInterval?

    public init(
        contextTokens: Int = 0,
        contextWindow: Int? = nil,
        costUSD: Double = 0,
        billing: BillingMode? = nil,
        planUsage: PlanUsage? = nil,
        cacheTTL: TimeInterval? = nil
    ) {
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUSD = costUSD
        self.billing = billing
        self.planUsage = planUsage
        self.cacheTTL = cacheTTL
    }

    /// Fraction of the context window in use (0...1). Assumes 200k when the window is unknown.
    public var contextFraction: Double {
        let window = Double(contextWindow ?? 200_000)
        guard window > 0 else { return 0 }
        return min(1, max(0, Double(contextTokens) / window))
    }
}

/// How an agent session is paid for.
public enum BillingMode: String, Hashable, Codable, Sendable {
    /// A subscription plan (e.g. Claude Pro/Max): usage counts against plan limits, not dollars.
    case subscription
    /// An API key: usage is billed per token.
    case apiKey
}

/// Usage of a subscription's rate-limit windows.
public struct PlanUsage: Hashable, Codable, Sendable {
    public struct Window: Hashable, Codable, Sendable, Identifiable {
        /// Provider identifier, e.g. `five_hour`.
        public var id: String
        /// Display name, e.g. "5-hour limit".
        public var title: String
        /// 0...1
        public var utilization: Double
        public var resetsAt: Date?

        public init(id: String, title: String, utilization: Double, resetsAt: Date?) {
            self.id = id
            self.title = title
            self.utilization = utilization
            self.resetsAt = resetsAt
        }
    }

    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }
}

/// One entry in an agent's task list.
public struct TaskItem: Hashable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case completed
    }

    public var id: String
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}

extension [TaskItem] {
    public var completedCount: Int {
        count { $0.status == .completed }
    }

    public var current: TaskItem? {
        first { $0.status == .inProgress }
    }
}

/// The outcome of a test or build command.
public struct CheckResult: Hashable, Codable, Sendable {
    public var command: String
    public var passed: Bool
    public var date: Date

    public init(command: String, passed: Bool, date: Date = .now) {
        self.command = command
        self.passed = passed
        self.date = date
    }

    /// Whether a shell command looks like a test or build run.
    public static func isCheck(_ command: String) -> Bool {
        let patterns = [
            "swift test", "swift build", "xcodebuild", "npm test", "npm run test", "npm run build", "pnpm test",
            "pnpm run test", "pnpm build", "yarn test", "yarn build", "bun test", "cargo test", "cargo build",
            "go test", "go build", "pytest", "python -m pytest", "mvn test", "gradle test", "./gradlew test",
            "make test", "make check", "rspec", "phpunit", "dotnet test", "vitest", "jest", "tsc"
        ]
        let normalized = command.lowercased()
        return patterns.contains { normalized.contains($0) }
    }
}

/// A working-tree snapshot around one turn, stored as commits under `refs/watercoded/`.
public struct TurnSnapshot: Hashable, Codable, Sendable, Identifiable {
    /// The provider discarded the conversation checkpoint during compaction; file history still exists.
    public var checkpointInvalidatedByCompaction: Bool?
    public var index: Int
    public var startedAt: Date
    public var beforeCommit: String
    public var afterCommit: String?
    /// The transcript item of the user message that started this turn.
    public var userMessageID: UUID?
    /// Where the provider's conversation stood when the turn ended, for branching from it.
    public var checkpoint: String?
    public var id: Int {
        index
    }

    public init(index: Int, startedAt: Date, beforeCommit: String, afterCommit: String? = nil) {
        checkpointInvalidatedByCompaction = false
        self.index = index
        self.startedAt = startedAt
        self.beforeCommit = beforeCommit
        self.afterCommit = afterCommit
    }
}
