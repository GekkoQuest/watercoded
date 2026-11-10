import AgentKit
import Foundation
import Observation
import ProcessKit
import WatercodedCore

/// Owns one Current: its agent session, transcript and live state.
///
/// Translates normalized ``AgentEvent``s into transcript entries and status, and persists
/// through the ``WorkspaceRepository``. UI observes it directly.
///
/// Split across files: commands (here), event handling (`+Events`) and turn bookkeeping
/// such as snapshots and summaries (`+Turns`).
@MainActor
@Observable
public final class CurrentController: Identifiable {
    /// Signals the UI uses for ambient feedback (e.g. water drops per tool call).
    public struct Activity: Hashable, Sendable {
        public var toolCallCount = 0
        public var lastToolKind: ToolKind?
        public var consecutiveToolErrors = 0
        /// Bumped whenever the working tree may have changed.
        public var fileChangeRevision = 0
        /// Bumped each time the user answers an approval, plan or question.
        public var approvalsAnswered = 0
        public var lastApprovalAllowed = false
        /// Bumped each time the provider compacts the conversation.
        public var compactions = 0
        /// Subagents currently running.
        public var activeSubagents = 0
    }

    public nonisolated let id: CurrentID
    public internal(set) var current: Current
    public internal(set) var transcript: [TranscriptItem]
    /// Assistant text still streaming in (not yet part of ``transcript``).
    public internal(set) var streamingText = ""
    /// Timing and token counts for the current or most recent turn.
    public internal(set) var turnStats: TurnStats?
    public internal(set) var pendingPermissions: [PermissionRequest] = []
    public internal(set) var pendingPlan: PlanRecord?
    public internal(set) var pendingQuestion: QuestionRecord?
    /// Questions the user can answer while the agent keeps working, or after its turn ends.
    public internal(set) var pendingAsyncQuestions: [QuestionRecord] = []
    /// An MCP server's form waiting for the user.
    public internal(set) var pendingForm: FormRecord?
    public internal(set) var isTurnActive = false
    public internal(set) var isSessionLive = false
    public internal(set) var activity = Activity()
    /// Draft text in the composer. Lives here so other views (e.g. "Ask about this hunk") can add to it.
    public var draft = ""
    /// Images waiting to be sent with the next message.
    public var draftImages: [ImageAttachment] = []
    /// Commands the agent accepts as messages (for `/` completion).
    public internal(set) var availableCommands: [SlashCommand] = []
    /// Review comments collected in the Changes inspector, sent together as one message.
    public internal(set) var reviewComments: [ReviewComment] = []

    @ObservationIgnored let provider: (any AgentProvider)?
    @ObservationIgnored let repository: any WorkspaceRepository
    @ObservationIgnored var session: (any AgentSession)?
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    /// Set once the Current is deleted. A deleted Current never writes to disk again, even if a view
    /// touches it on its way out (e.g. marking it viewed as its screen disappears).
    @ObservationIgnored private(set) var isDiscarded = false
    @ObservationIgnored var toolItemIndex: [String: Int] = [:]
    @ObservationIgnored var activeSubagentCalls = Set<String>()

    // Services injected by the Workspace.
    @ObservationIgnored var snapshotter: (@Sendable (URL, String, String) async -> String?)?
    @ObservationIgnored var summarizer: (any CurrentSummarizer)?
    @ObservationIgnored var additionalDirectories: () -> [URL] = { [] }
    /// Called when the Current is archived (answers a parent still waiting on it).
    @ObservationIgnored var onSettle: ((CurrentID) -> Void)?
    /// MCP servers Watercoded adds to this Current's agent (its `delegate` tool).
    @ObservationIgnored var mcpServers: () -> [MCPServer] = { [] }
    /// Waits for a reserved deletion before the session accesses its working folder.
    @ObservationIgnored var waitForWorktreeCleanup: () async -> Void = {}
    /// Recreates the channel's worktree from its branch if it was removed while the Current was archived.
    @ObservationIgnored var restoreChannel: (@Sendable (Channel) async throws -> Void)?
    /// Prepares a new worktree before the agent first starts; cleared once it has run.
    @ObservationIgnored var pendingSetup: (@Sendable () async -> WorktreePreparer.Outcome)?
    @ObservationIgnored var onAttention: ((CurrentController, AttentionEvent) -> Void)?
    @ObservationIgnored var approvalRules: () -> [ApprovalRule] = { [] }
    @ObservationIgnored var onApproved: ((PermissionRequest) -> Void)?
    @ObservationIgnored var onAlwaysAllow: ((ApprovalRule) -> Void)?
    /// Where to run this Current's agent in the background, or `nil` to tie it to the app.
    @ObservationIgnored var relayDirectory: () -> URL? = { nil }
    // Per-turn bookkeeping for the end-of-turn verification check.
    @ObservationIgnored var turnEditCount = 0
    @ObservationIgnored var turnChecks: [CheckResult] = []
    /// The provider's most recent checkpoint, saved on the turn when it ends.
    @ObservationIgnored var lastCheckpoint: String?
    /// The repository's check command, if one is set.
    @ObservationIgnored var verifySettings: () -> VerifySettings? = { nil }
    /// Whether Watercoded is running the repository's check right now.
    public internal(set) var isVerifying = false

    init(
        current: Current,
        transcript: [TranscriptItem],
        provider: (any AgentProvider)?,
        repository: any WorkspaceRepository
    ) {
        id = current.id
        self.current = current
        self.transcript = transcript
        self.provider = provider
        self.repository = repository
        pendingAsyncQuestions = transcript.compactMap { item in
            guard case let .question(record) = item.content, record.isAsynchronous,
                  !record.isAnswered else { return nil }
            return record
        }
        for (index, item) in transcript.enumerated() {
            if case let .toolCall(record) = item.content {
                toolItemIndex[record.callID] = index
            }
        }
    }

    public var providerDescriptor: ProviderDescriptor? {
        provider?.descriptor
    }

    public var capabilities: ProviderCapabilities {
        provider?.descriptor.capabilities ?? []
    }

    /// Anything the agent is waiting on the user for.
    public var isAwaitingUser: Bool {
        !pendingPermissions.isEmpty || pendingPlan != nil || pendingQuestion != nil || pendingForm != nil
    }

    /// All actionable question cards, including questions that do not block the agent.
    public var pendingQuestions: [QuestionRecord] {
        [pendingQuestion].compactMap(\.self) + pendingAsyncQuestions
    }

    /// Whether the provider's prompt cache has probably expired, making the next turn slower and
    /// costlier because the whole context is read again.
    public func isPromptCacheCold(at now: Date = .now) -> Bool {
        guard !isTurnActive, current.status != .settled, let ended = current.lastTurnEndedAt else { return false }
        return now.timeIntervalSince(ended) > (current.usage.cacheTTL ?? 300)
    }

    // MARK: Conversation

    /// Sends a message (with optional images), starting or resuming the agent session if needed.
    public func send(_ text: String, images: [ImageAttachment] = []) async {
        _ = await sendMessage(text, images: images)
    }

    /// Whether input reached the provider, so failed async answers can keep their question card.
    func sendMessage(_ text: String, images: [ImageAttachment] = []) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        defer { scheduleSave() }
        if !images.isEmpty {
            append(.userImages(count: images.count))
        }
        let message = trimmed.isEmpty ? "(See the attached image.)" : trimmed
        append(.user(text: message))
        update {
            $0.status = .flowing
            $0.interruptedByQuit = nil
        }
        // Claim the session as active before yielding, so cleanup cannot start after this check.
        // An already reserved deletion must finish before snapshots, restoration or agent startup.
        await waitForWorktreeCleanup()
        if !isTurnActive {
            await recordTurnStart()
        }
        do {
            let session = try await ensureSession()
            try await session.send(UserMessage(text: message, images: images))
            return true
        } catch {
            fail(error.localizedDescription)
            return false
        }
    }

    public func decide(_ requestID: PermissionRequest.ID, _ decision: PermissionDecision) async {
        guard let request = pendingPermissions.first(where: { $0.id == requestID }) else { return }
        pendingPermissions.removeAll { $0.id == requestID }
        if decision == .allow {
            onApproved?(request)
        }
        await resolve(requestID, allowed: decision == .allow) {
            try await $0.respond(to: requestID, with: decision)
        }
    }

    /// Allows this request and every future one matching `rule` in this Current's repository.
    public func alwaysAllow(_ requestID: PermissionRequest.ID, rule: ApprovalRule) async {
        onAlwaysAllow?(rule)
        await decide(requestID, .allow)
    }

    /// Approves the proposed plan: the agent starts building.
    public func approvePlan() async {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        updatePlan(plan.requestID) { $0.status = .approved }
        await resolve(plan.requestID, allowed: true) {
            try await $0.respond(to: plan.requestID, with: .allow)
        }
    }

    /// Sends the plan back with feedback: the agent keeps planning.
    public func revisePlan(feedback: String) async {
        guard let plan = pendingPlan else { return }
        pendingPlan = nil
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        updatePlan(plan.requestID) {
            $0.status = .revised
            $0.feedback = trimmed.isEmpty ? nil : trimmed
        }
        let reason = trimmed.isEmpty ? "Keep planning." : "Keep planning. Feedback: \(trimmed)"
        await resolve(plan.requestID, allowed: false) {
            try await $0.respond(to: plan.requestID, with: .deny(reason: reason))
        }
    }

    public func interrupt() async {
        do {
            try await session?.interrupt()
        } catch {
            append(.notice(Notice(.error, error.localizedDescription)))
        }
    }

    // MARK: Lifecycle

    // MARK: Session

    func stopSession() async {
        eventTask?.cancel()
        eventTask = nil
        await session?.terminate()
        session = nil
        isSessionLive = false
        isTurnActive = false
        clearPendingInteractions()
        update { $0.restartSessionWhenIdle = nil }
        if let relay = current.relay {
            update { $0.relay = nil }
            try? FileManager.default.removeItem(at: relay.url)
        }
    }

    /// The app is quitting: background sessions keep running (their position is saved so the app
    /// can reattach); others stop, and an interrupted turn is marked so it can be resumed.
    func prepareForQuit() async {
        if let session, let handle = await session.relayHandle() {
            update { $0.relay = handle }
            eventTask?.cancel()
            await session.detach()
        } else {
            if isTurnActive {
                update { $0.interruptedByQuit = true }
            }
            await stopSession()
        }
        await flush()
    }

    /// Reconnects to a background session that kept running while the app was closed.
    /// Returns `false` (and clears the stale handle) when there's nothing to reattach to.
    func reattach() async -> Bool {
        guard let handle = current.relay else { return false }
        guard let provider else {
            update { $0.relay = nil }
            return false
        }
        let hasUnread = RelayLog.records(in: handle.url).last.map { $0.end > handle.offset } ?? false
        guard RelayLog.isAlive(in: handle.url) || hasUnread else {
            update { $0.relay = nil }
            try? FileManager.default.removeItem(at: handle.url)
            return false
        }
        do {
            let session = try await provider.reattachSession(handle)
            // The relay log has the conversation, not the settings: hand them back (plan mode, effort, Full Access…).
            await session.restoreSettings(sessionConfiguration(for: provider))
            attach(session)
            return true
        } catch {
            update { $0.relay = nil }
            return false
        }
    }

    /// Writes pending changes immediately.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard !isDiscarded else { return }
        if let session, let handle = await session.relayHandle() {
            update { $0.relay = handle }
        }
        guard !isDiscarded else { return }
        try? await repository.saveCurrent(current)
        guard !isDiscarded else { return }
        try? await repository.saveTranscript(transcript, for: id)
    }

    func ensureSession(startingTurn: Bool = false) async throws -> any AgentSession {
        if current.restartSessionWhenIdle == true, !isTurnActive || startingTurn {
            await stopSession()
            if startingTurn {
                isTurnActive = true
            }
        }
        if let session {
            return session
        }
        guard let provider else { throw AgentError.providerNotFound(current.providerID) }
        try await restoreChannel?(current.channel)
        if let setup = pendingSetup {
            pendingSetup = nil
            await runSetup(setup)
        }
        let session = try await provider.startSession(sessionConfiguration(for: provider))
        attach(session)
        if let handle = await session.relayHandle() {
            update { $0.relay = handle }
        }
        return session
    }

    /// Everything the provider needs to start (or, after reattaching, to be reminded of) this Current's session.
    private func sessionConfiguration(for provider: any AgentProvider) -> SessionConfiguration {
        var configuration = SessionConfiguration(
            workingDirectory: current.channel.url,
            model: current.model,
            permissionMode: current.permissionMode,
            effort: current.effort,
            resumeSessionID: provider.descriptor.capabilities.contains(.resume) ? current.providerSessionID : nil,
            additionalDirectories: additionalDirectories(),
            relayDirectory: provider.descriptor.capabilities.contains(.backgroundSessions) ? relayDirectory() : nil,
            branchAt: current.pendingBranchAt
        )
        configuration.mcpServers = mcpServers()
        return configuration
    }

    private func attach(_ session: any AgentSession) {
        self.session = session
        isSessionLive = true
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled, let self else { return }
                handle(event)
            }
        }
    }

    /// Bookkeeping shared by approvals, plans and questions.
    func resolve(
        _ requestID: String,
        allowed: Bool,
        reply: (any AgentSession) async throws -> Void
    ) async {
        activity.lastApprovalAllowed = allowed
        activity.approvalsAnswered += 1
        if !isAwaitingUser, current.status == .waiting {
            update { $0.status = isTurnActive ? .flowing : .ashore }
        }
        guard let session else { return }
        do {
            try await reply(session)
        } catch {
            append(.notice(Notice(.error, error.localizedDescription)))
        }
    }

    // MARK: Helpers

    func fail(_ message: String) {
        append(.notice(Notice(.error, message)))
        update { $0.status = .stalled }
    }

    func append(_ content: TranscriptItem.Content) {
        transcript.append(TranscriptItem(content: content))
    }

    func update(_ change: (inout Current) -> Void) {
        var copy = current
        change(&copy)
        guard copy != current else { return }
        copy.updatedAt = .now
        current = copy
    }

    private func updatePlan(_ requestID: String, _ change: (inout PlanRecord) -> Void) {
        guard let index = transcript.lastIndex(where: {
            if case let .plan(record) = $0.content {
                record.requestID == requestID
            } else {
                false
            }
        }), case var .plan(record) = transcript[index].content else { return }
        change(&record)
        transcript[index].content = .plan(record)
    }

    /// Stops all future saves, including one already scheduled. Called when the Current is deleted.
    func discard() {
        isDiscarded = true
        saveTask?.cancel()
        saveTask = nil
    }

    /// Coalesces bursts of changes into one write.
    func scheduleSave() {
        guard !isDiscarded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await flush()
        }
    }
}
