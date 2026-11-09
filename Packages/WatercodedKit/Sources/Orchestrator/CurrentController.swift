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
        !pendingPermissions.isEmpty || pendingPlan != nil || pendingQuestion != nil
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        if !images.isEmpty {
            append(.userImages(count: images.count))
        }
        let message = trimmed.isEmpty ? "(See the attached image.)" : trimmed
        append(.user(text: message))
        update {
            $0.status = .flowing
            $0.interruptedByQuit = nil
        }
        if !isTurnActive {
            await recordTurnStart()
        }
        do {
            let session = try await ensureSession()
            try await session.send(UserMessage(text: message, images: images))
        } catch {
            fail(error.localizedDescription)
        }
        scheduleSave()
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

    /// Answers the pending question (question text → chosen label or labels).
    public func answer(_ answers: [String: String]) async {
        guard let question = pendingQuestion else { return }
        pendingQuestion = nil
        if let index = transcript.lastIndex(where: {
            if case let .question(record) = $0.content {
                record.requestID == question.requestID
            } else {
                false
            }
        }), case var .question(record) = transcript[index].content {
            record.answers = answers
            transcript[index].content = .question(record)
        }
        await resolve(question.requestID, allowed: true) {
            try await $0.answer(question.requestID, with: answers)
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

    /// Ends the session and marks the Current as done.
    public func settle() async {
        await stopSession()
        update { $0.status = .settled }
        scheduleSave()
    }

    // MARK: Settings

    /// Changes permissions. Applied live when the provider supports it, otherwise on the next message.
    public func setPermissionMode(_ mode: PermissionMode) async {
        guard mode != current.permissionMode else { return }
        update { $0.permissionMode = mode }
        await applyLive { try await $0.setPermissionMode(mode) }
        scheduleSave()
    }

    /// Changes the model (`nil` = provider default). Applied live when possible.
    public func setModel(_ model: String?) async {
        guard model != current.model else { return }
        update { $0.model = model }
        await applyLive { try await $0.setModel(model) }
        scheduleSave()
    }

    /// Changes reasoning effort. Takes effect from the next message (the agent restarts).
    public func setEffort(_ effort: String?) async {
        guard effort != current.effort else { return }
        update { $0.effort = effort }
        await stopSession()
        scheduleSave()
    }

    // MARK: Session

    func stopSession() async {
        eventTask?.cancel()
        eventTask = nil
        await session?.terminate()
        session = nil
        isSessionLive = false
        isTurnActive = false
        clearPendingInteractions()
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
        guard let handle = current.relay, let provider else { return false }
        let hasUnread = RelayLog.records(in: handle.url).last.map { $0.end > handle.offset } ?? false
        guard RelayLog.isAlive(in: handle.url) || hasUnread else {
            update { $0.relay = nil }
            try? FileManager.default.removeItem(at: handle.url)
            return false
        }
        do {
            let session = try await provider.reattachSession(handle)
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
        try? await repository.saveCurrent(current)
        try? await repository.saveTranscript(transcript, for: id)
    }

    private func ensureSession() async throws -> any AgentSession {
        if let session {
            return session
        }
        guard let provider else { throw AgentError.providerNotFound(current.providerID) }
        try await restoreChannel?(current.channel)
        if let setup = pendingSetup {
            pendingSetup = nil
            await runSetup(setup)
        }
        let configuration = SessionConfiguration(
            workingDirectory: current.channel.url,
            model: current.model,
            permissionMode: current.permissionMode,
            effort: current.effort,
            resumeSessionID: provider.descriptor.capabilities.contains(.resume) ? current.providerSessionID : nil,
            additionalDirectories: additionalDirectories(),
            relayDirectory: provider.descriptor.capabilities.contains(.backgroundSessions) ? relayDirectory() : nil,
            branchAt: current.pendingBranchAt
        )
        let session = try await provider.startSession(configuration)
        attach(session)
        if let handle = await session.relayHandle() {
            update { $0.relay = handle }
        }
        return session
    }

    private func attach(_ session: any AgentSession) {
        self.session = session
        isSessionLive = true
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// Runs a live settings change; if the provider can't, restarts so the next message picks it up.
    private func applyLive(_ change: (any AgentSession) async throws -> Void) async {
        guard let session else { return }
        if capabilities.contains(.liveSettings) {
            do {
                try await change(session)
                return
            } catch {
                // Fall back to a restart below.
            }
        }
        await stopSession()
    }

    /// Bookkeeping shared by approvals, plans and questions.
    private func resolve(
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

    func clearPendingInteractions() {
        pendingPermissions.removeAll()
        pendingPlan = nil
        pendingQuestion = nil
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
