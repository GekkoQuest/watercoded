import Foundation
import WatercodedCore

/// The normalized event vocabulary every provider adapter translates into.
///
/// Adding a provider means mapping its wire protocol onto these cases, nothing more.
public enum AgentEvent: Sendable, Hashable {
    /// The provider is ready; carries its own session identifier for later resumption.
    case sessionStarted(SessionInfo)
    /// A turn began (the agent received a message and is working).
    case turnStarted
    /// A chunk of assistant text for message `messageID`.
    case textDelta(messageID: String, text: String)
    /// The model began generating one response. A turn can contain several (one per tool round).
    case generationStarted
    /// The model finished a response. `outputTokens` is the provider's exact count, thinking included.
    case generationFinished(outputTokens: Int)
    /// The authoritative full text of an assistant message (replaces accumulated deltas).
    case messageCompleted(messageID: String, text: String)
    /// The agent invoked a tool.
    case toolCallStarted(ToolCall)
    /// Authoritative tool details arrived after the call began.
    case toolCallUpdated(callID: String, summary: String, input: JSONValue)
    /// A tool finished.
    case toolCallFinished(callID: String, output: String, isError: Bool)
    /// The agent needs the user's approval before continuing.
    case permissionRequested(PermissionRequest)
    /// Token and spend counters changed.
    case usageUpdated(UsageSnapshot)
    /// The subscription's rate-limit windows changed.
    case planUsageUpdated(PlanUsage)
    /// The provider compacted (summarized) the conversation to free context.
    case contextCompacted(preTokens: Int?, postTokens: Int?)
    /// The model reasoned before answering. `text` may be empty when the provider redacts it.
    case thinking(messageID: String, text: String, estimatedTokens: Int?)
    /// The agent's task list changed (full list, in order).
    case tasksUpdated([TaskItem])
    /// The agent finished planning and wants approval to build. Answer with
    /// ``AgentSession/respond(to:with:)``: allow to build, deny (with feedback) to keep planning.
    case planProposed(requestID: String, markdown: String)
    /// The commands the agent accepts as messages (e.g. `/compact`).
    case commandsAvailable([SlashCommand])
    /// What the agent loaded for this session (MCP servers, skills, instruction files…).
    case environmentReported(AgentEnvironment)
    /// The agent asked multiple-choice questions. Answer with ``AgentSession/answer(_:with:)``.
    case questionAsked(requestID: String, questions: [QuestionRecord.Question])
    /// A question delivered as a message while the agent continues working. Answer as ordinary
    /// conversation input, not as a response to a suspended provider RPC.
    case asyncQuestionAsked(requestID: String, questions: [QuestionRecord.Question])
    /// An MCP server asks the user for input (a short form, or a link to open). Answer with
    /// ``AgentSession/respondToForm(_:with:)``.
    case formRequested(FormRecord)
    /// A point the conversation can later be resumed or branched from (the provider's message ID).
    case checkpoint(String)
    /// Apply one relay record's events and replay boundary together, without a save between them.
    case relayBatch(events: [AgentEvent], checkpoint: RelayHandle)
    /// A non-fatal message worth showing inline (e.g. an automatic denial).
    case notice(Notice)
    /// The turn ended.
    case turnFinished(TurnOutcome)
    /// The session ended; no further events follow.
    case sessionEnded(SessionEnd)
}

public struct SessionInfo: Sendable, Hashable {
    public var providerSessionID: String
    public var model: String?
    /// How this session is paid for, when the provider reports it.
    public var billing: BillingMode?

    public init(providerSessionID: String, model: String?, billing: BillingMode? = nil) {
        self.providerSessionID = providerSessionID
        self.model = model
        self.billing = billing
    }
}

public struct ToolCall: Sendable, Hashable {
    public var callID: String
    public var name: String
    public var kind: ToolKind
    public var summary: String
    public var input: JSONValue
    /// The subagent call this call was made inside, if any.
    public var parentCallID: String?

    public init(
        callID: String,
        name: String,
        kind: ToolKind,
        summary: String,
        input: JSONValue,
        parentCallID: String? = nil
    ) {
        self.callID = callID
        self.name = name
        self.kind = kind
        self.summary = summary
        self.input = input
        self.parentCallID = parentCallID
    }
}

/// An approval the agent is waiting on.
public struct PermissionRequest: Sendable, Hashable, Identifiable {
    public typealias ID = String

    public var id: ID
    public var toolName: String
    public var kind: ToolKind
    /// One-line description, e.g. `Run "npm test"`.
    public var summary: String
    public var input: JSONValue
    /// What the call acts on (the shell command, or the file path), used to match approval rules.
    public var subject: String?
    /// A standing rule the provider suggests for calls like this one.
    public var suggestedRule: ApprovalRule?

    public init(
        id: ID,
        toolName: String,
        kind: ToolKind,
        summary: String,
        input: JSONValue,
        subject: String? = nil,
        suggestedRule: ApprovalRule? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.kind = kind
        self.summary = summary
        self.input = input
        self.subject = subject
        self.suggestedRule = suggestedRule
    }

    /// The rule to offer as "Always allow": the provider's suggestion, or a sensible default.
    public var proposedRule: ApprovalRule {
        if let suggestedRule {
            return suggestedRule
        }
        if kind == .shell, let subject {
            return ApprovalRule(
                toolName: toolName,
                pattern: ApprovalRule.suggested(forCommand: subject)
            )
        }
        return ApprovalRule(toolName: toolName)
    }
}

public enum PermissionDecision: Sendable, Hashable {
    case allow
    case deny(reason: String)
}

public enum TurnOutcome: Sendable, Hashable {
    case completed
    case interrupted
    case failed(message: String)
}

public enum SessionEnd: Sendable, Hashable {
    case exited(code: Int32)
    case failed(message: String)
}
