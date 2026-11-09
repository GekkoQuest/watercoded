import AgentKit
import Delegation
import Foundation
import GitKit
import Observation
import ProcessKit
import WatercodedCore

/// Everything the user is working on: pools, their currents, and the services that run them.
@MainActor
@Observable
public final class Workspace {
    public private(set) var pools: [Pool] = []
    public private(set) var currents: [CurrentController] = []
    public private(set) var isLoaded = false

    public let registry: ProviderRegistry
    /// Writes titles and summaries (e.g. on-device). Optional; without it, titles come from prompts.
    @ObservationIgnored public var summarizer: (any CurrentSummarizer)?
    /// Called when a Current needs the user or finishes a turn (used for notifications).
    @ObservationIgnored public var onAttention: ((CurrentController, AttentionEvent) -> Void)?
    @ObservationIgnored let repository: any WorkspaceRepository
    @ObservationIgnored let git: GitClient
    @ObservationIgnored var pullRequestWatch: Task<Void, Never>?
    @ObservationIgnored var delegationWatch: Task<Void, Never>?
    /// Delegated sessions whose parent is waiting for their answer (child id → the parent's tool call).
    @ObservationIgnored var delegationWaiters: [CurrentID: CheckedContinuation<DelegationOutcome, Never>] = [:]
    /// The app binary, which serves the `delegate` MCP server (`--delegate-mcp`); `nil` turns delegation off.
    @ObservationIgnored public var delegationExecutable: URL?
    @ObservationIgnored let delegationMailbox: DelegationMailbox
    @ObservationIgnored let worktrees: WorktreeManager
    /// Where ``startDemo()`` keeps its sample repository.
    @ObservationIgnored let demoRoot: URL
    /// Where background (relayed) sessions keep their logs and input pipes.
    @ObservationIgnored let sessionsRoot: URL
    /// Run agents under background relays so they keep working after the app quits.
    @ObservationIgnored public var backgroundSessionsEnabled = true
    /// How often each kind of tool call was approved, per pool (for "Always allow?" suggestions).
    public private(set) var approvalCounts: [PoolID: [String: Int]] = [:]

    public init(
        registry: ProviderRegistry,
        repository: any WorkspaceRepository,
        git: GitClient = GitClient(),
        worktrees: WorktreeManager = WorktreeManager(),
        demoRoot: URL = Workspace.defaultDemoRoot,
        sessionsRoot: URL = Workspace.defaultSessionsRoot,
        delegationMailbox: DelegationMailbox = DelegationMailbox()
    ) {
        self.delegationMailbox = delegationMailbox
        self.registry = registry
        self.repository = repository
        self.git = git
        self.worktrees = worktrees
        self.demoRoot = demoRoot
        self.sessionsRoot = sessionsRoot
    }

    public static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".watercoded/sessions",
            directoryHint: .isDirectory
        )
    }

    public static var defaultDemoRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".watercoded/demo", directoryHint: .isDirectory)
    }

    // MARK: Loading

    public func load() async {
        guard !isLoaded else { return }
        pools = await (try? repository.loadPools()) ?? []
        let stored = await (try? repository.loadCurrents()) ?? []
        var controllers: [CurrentController] = []
        for current in stored.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let transcript = await (try? repository.loadTranscript(for: current.id)) ?? []
            controllers.append(makeController(current, transcript: transcript))
        }
        currents = controllers
        isLoaded = true
        startWatchingPullRequests()
        startWatchingDelegations()

        for controller in controllers
            where controller.current.status == .flowing || controller.current.status == .waiting {
            // Background sessions kept running: reconnect. Anything else stopped when the app quit.
            if await !controller.reattach() {
                controller.update {
                    $0.status = .ashore
                    if $0.relay == nil, $0.interruptedByQuit == nil {
                        $0.interruptedByQuit = true
                    }
                }
            }
        }
    }

    /// Agents that are mid-turn right now (used to warn before quitting).
    public var workingCount: Int {
        currents.count(where: \.isTurnActive)
    }

    /// Prepares for quitting: background sessions are detached (they keep running), others stop.
    public func shutdown() async {
        pullRequestWatch?.cancel()
        delegationWatch?.cancel()
        for controller in currents {
            await controller.prepareForQuit()
        }
    }

    // MARK: Queries

    public func pool(_ id: PoolID) -> Pool? {
        pools.first { $0.id == id }
    }

    public func controller(_ id: CurrentID) -> CurrentController? {
        currents.first { $0.id == id }
    }

    public func currents(in pool: PoolID, includeSettled: Bool = true) -> [CurrentController] {
        currents.filter { $0.current.poolID == pool && (includeSettled || $0.current.status != .settled) }
    }

    /// Currents blocked on the user (waiting for approval, or stalled), most recent first.
    /// Currents that are merely ready for review stay in their pool.
    public var shore: [CurrentController] {
        currents.filter { $0.current.status == .waiting || $0.current.status == .stalled }
            .sorted { $0.current.updatedAt > $1.current.updatedAt }
    }

    // MARK: Pools

    /// Adds the git repository containing `url`. Returns the existing pool if it's already added.
    @discardableResult
    public func addPool(at url: URL) async throws -> Pool {
        let root = try await git.topLevel(of: url)
        if let existing = pools.first(where: { $0.rootPath == root.path }) {
            return existing
        }
        let pool = Pool(name: root.lastPathComponent, rootPath: root.path)
        pools.append(pool)
        pools.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try await repository.savePools(pools)
        return pool
    }

    /// Runs `git init` in a plain folder, then adds it as a pool. Nothing is staged or committed:
    /// the agent works in the checkout until the user makes a first commit.
    @discardableResult
    public func initializeRepositoryAndAddPool(at url: URL) async throws -> Pool {
        try await git.initializeRepository(at: url)
        return try await addPool(at: url)
    }

    func updatePool(at index: Int, _ change: (inout Pool) -> Void) {
        change(&pools[index])
        let snapshot = pools
        Task { try? await repository.savePools(snapshot) }
    }

    /// Renames a pool (display only; the folder isn't touched).
    @discardableResult
    public func renamePool(_ id: PoolID, to name: String) -> Pool? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = pools.firstIndex(where: { $0.id == id }) else { return nil }
        pools[index].name = trimmed
        let snapshot = pools
        Task { try? await repository.savePools(snapshot) }
        return pools[index]
    }

    /// Removes a pool from the sidebar. Worktrees and branches stay on disk.
    public func removePool(_ id: PoolID) async {
        for controller in currents(in: id) {
            await controller.stopSession()
            try? await repository.deleteCurrent(controller.id)
        }
        currents.removeAll { $0.current.poolID == id }
        pools.removeAll { $0.id == id }
        try? await repository.savePools(pools)
    }

    // MARK: Currents

    /// Creates a Current (and its channel) and sends the first prompt.
    public func startCurrent(_ request: NewCurrentRequest) async throws -> CurrentController {
        guard let pool = pool(request.poolID) else { throw WorkspaceError.poolNotFound }
        guard let provider = registry.provider(for: request.providerID) else {
            throw AgentError.providerNotFound(request.providerID)
        }
        if case let .unavailable(reason) = await provider.availability() {
            throw AgentError.providerUnavailable(name: provider.descriptor.displayName, reason: reason)
        } else if case .notInstalled = await provider.availability() {
            throw AgentError.providerUnavailable(
                name: provider.descriptor.displayName,
                reason: provider.descriptor.installHint
            )
        }

        let title = request.title ?? NewCurrentRequest.title(fromPrompt: request.prompt)
        let channel = switch request.isolation {
        case .worktree: try await worktrees.makeWorktreeChannel(for: pool, title: title)
        case .checkout: try await worktrees.makeCheckoutChannel(for: pool)
        }
        var current = Current(
            poolID: pool.id,
            title: title,
            providerID: request.providerID,
            model: request.model,
            permissionMode: request.permissionMode,
            channel: channel
        )
        current.effort = request.effort
        current.issue = request.issue
        current.titleSource = request.title == nil ? .prompt : .user
        try await repository.saveCurrent(current)
        let controller = makeController(current, transcript: [])
        if channel.kind == .worktree, let setup = pool.worktreeSetup, !setup.isEmpty {
            let preparer = WorktreePreparer(environment: .shared)
            let worktree = channel.url
            let root = pool.rootURL
            controller.pendingSetup = { await preparer.prepare(worktree, from: root, with: setup) }
        }
        currents.insert(controller, at: 0)
        Task { await controller.send(request.prompt) }
        return controller
    }

    /// Deletes a Current's record; optionally removes its worktree checkout (the branch is kept).
    public func delete(_ id: CurrentID, removingWorktree: Bool) async throws {
        guard let controller = controller(id) else { return }
        abandonDelegation(id)
        await controller.stopSession()
        controller.discard()
        if let pool = pool(controller.current.poolID) {
            try? await git.deleteRefs(withPrefix: "refs/watercoded/\(id)/", in: pool.rootURL)
            // Never remove a folder from under a parent (helpers made before v0.6 shared their parent's folder).
            let parentFolder = controller.current.parentID.flatMap { self.controller($0) }?.current.channel.path
            if removingWorktree, controller.current.channel.path != parentFolder {
                try await worktrees.removeChannel(controller.current.channel, from: pool, force: true)
            }
        }
        currents.removeAll { $0.id == id }
        try await repository.deleteCurrent(id)
    }

    /// Whether the pool's repository has at least one commit (worktrees need one to branch from).
    public func hasCommits(_ id: PoolID) async -> Bool {
        guard let pool = pool(id) else { return false }
        return await (try? git.headCommitIfAny(in: pool.rootURL)) != nil
    }

    /// Adds a Current that was created outside ``startCurrent(_:)`` (e.g. imported).
    func adopt(_ current: Current, transcript: [TranscriptItem]) -> CurrentController {
        let controller = makeController(current, transcript: transcript)
        currents.insert(controller, at: 0)
        return controller
    }

    private func makeController(_ current: Current, transcript: [TranscriptItem]) -> CurrentController {
        let controller = CurrentController(
            current: current,
            transcript: transcript,
            provider: registry.provider(for: current.providerID),
            repository: repository
        )
        let git = git
        controller.snapshotter = { worktree, ref, message in
            try? await git.snapshotWorkingTree(in: worktree, ref: ref, message: message)
        }
        controller.summarizer = summarizer
        let poolID = current.poolID
        controller.additionalDirectories = { [weak self] in self?.pool(poolID)?.additionalDirectoryURLs ?? [] }
        if let pool = pool(poolID) {
            let worktrees = worktrees
            controller.restoreChannel = { channel in try await worktrees.restoreChannelIfNeeded(channel, in: pool) }
        }
        controller.onAttention = { [weak self] controller, event in
            self?.delegatedTurnEnded(controller, event)
            self?.onAttention?(controller, event)
        }
        controller.mcpServers = { [weak self] in self?.mcpServers(for: controller) ?? [] }
        controller.onSettle = { [weak self] id in self?.abandonDelegation(id) }
        controller.approvalRules = { [weak self] in self?.pool(poolID)?.approvalRules ?? [] }
        controller.verifySettings = { [weak self] in self?.pool(poolID)?.verify }
        controller.onAlwaysAllow = { [weak self] rule in self?.addApprovalRule(rule, to: poolID) }
        controller.onApproved = { [weak self] request in
            self?.approvalCounts[poolID, default: [:]][request.proposedRule.id, default: 0] += 1
        }
        let id = current.id
        controller.relayDirectory = { [weak self] in
            guard let self, backgroundSessionsEnabled else { return nil }
            return sessionsRoot.appending(path: id.description, directoryHint: .isDirectory)
        }
        return controller
    }

    // MARK: Approval rules

    /// How many times calls covered by `rule` were approved in `pool` this session.
    public func approvalCount(for rule: ApprovalRule, in pool: PoolID) -> Int {
        approvalCounts[pool]?[rule.id] ?? 0
    }

    public func addApprovalRule(_ rule: ApprovalRule, to pool: PoolID) {
        guard let index = pools.firstIndex(where: { $0.id == pool }) else { return }
        updatePool(at: index) {
            var rules = $0.approvalRules ?? []
            if !rules.contains(rule) {
                rules.append(rule)
            }
            $0.approvalRules = rules
        }
    }

    public func removeApprovalRule(_ rule: ApprovalRule, from pool: PoolID) {
        guard let index = pools.firstIndex(where: { $0.id == pool }) else { return }
        updatePool(at: index) {
            $0.approvalRules?.removeAll { $0 == rule }
            if $0.approvalRules?.isEmpty == true {
                $0.approvalRules = nil
            }
        }
    }
}

/// Parameters for ``Workspace/startCurrent(_:)``.
public struct NewCurrentRequest: Sendable, Hashable {
    public var poolID: PoolID
    public var prompt: String
    public var title: String?
    public var providerID: ProviderID
    public var model: String?
    public var effort: String?
    public var permissionMode: PermissionMode
    public var isolation: Channel.Kind
    /// The GitHub issue this work resolves, if it was started from one.
    public var issue: IssueReference?

    public init(
        poolID: PoolID,
        prompt: String,
        title: String? = nil,
        providerID: ProviderID,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode = .ask,
        isolation: Channel.Kind = .worktree,
        issue: IssueReference? = nil
    ) {
        self.poolID = poolID
        self.prompt = prompt
        self.title = title
        self.providerID = providerID
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.isolation = isolation
        self.issue = issue
    }

    /// First line of the prompt, shortened at a word boundary.
    public static func title(fromPrompt prompt: String, maxLength: Int = 60) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed.isEmpty ? "New Session" : trimmed }
        let cut = trimmed.prefix(maxLength)
        let boundary = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<boundary]) + "…"
    }
}

public enum WorkspaceError: Error, LocalizedError, Sendable {
    case poolNotFound
    case cannotBranch

    public var errorDescription: String? {
        switch self {
        case .poolNotFound: "That project is no longer in the workspace."
        case .cannotBranch: "This turn can't be branched from: it predates branching support or has no snapshot."
        }
    }
}
