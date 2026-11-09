import AgentKit
import Delegation
import Foundation
import GitKit
import ProcessKit
import ReplayProvider
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Workspace", .serialized)
struct WorkspaceTests {
    @Test func `replay current runs to completion`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        workspace.summarizer = FakeSummarizer()
        await workspace.load()
        let pool = try await workspace.addPool(at: fixture.repository)

        let controller = try await workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id,
            prompt: "Fix the token refresh race",
            providerID: ReplayProvider.id
        ))
        #expect(controller.current.title == "Fix the token refresh race")
        #expect(controller.current.channel.kind == .worktree)

        // The demo asks a question, proposes a plan and requests two approvals.
        let kinds = try await answerEverything(controller)
        #expect(kinds == ["question", "plan", "permission", "permission"])

        let tools = toolCalls(controller)
        #expect(tools.map(\.name) == ["Read", "Grep", "Edit", "Bash"])
        #expect(tools.allSatisfy { $0.status == .succeeded })
        #expect(controller.transcript.first?.content == .user(text: "Fix the token refresh race"))
        #expect(controller.activity.approvalsAnswered == 4)
        #expect(controller.activity.compactions == 1)
        #expect(controller.current.usage.contextTokens == 12000) // after compaction
        #expect(controller.current.tasks?.completedCount == 3)
        #expect(controller.current.lastCheck?.passed == true) // `swift test` counts as a check
        #expect(controller.current.providerSessionID?.hasPrefix("replay-") == true)
        #expect(workspace.shore.isEmpty) // ready for review stays in its pool

        // The question and plan were recorded with their outcomes.
        #expect(controller.transcript.contains {
            if case let .question(record) = $0.content {
                record.answers != nil
            } else {
                false
            }
        })
        #expect(controller.transcript.contains {
            if case let .plan(record) = $0.content {
                record.status == .approved
            } else {
                false
            }
        })
        #expect(controller.transcript.contains {
            if case .thinking = $0.content {
                true
            } else {
                false
            }
        })

        // The turn was snapshotted, and the summarizer replaced the prompt-based title.
        try await waitUntil { controller.current.turnSnapshots?.first?.afterCommit != nil }
        try await waitUntil { controller.current.titleSource == .generated }
        try await waitUntil { controller.current.summary != nil } // written just after the title
        #expect(controller.current.title == "Generated title")
        #expect(controller.current.summary == "Generated summary")
    }

    @Test func `denied approval skips the tool and revised plans carry feedback`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Try something", providerID: ReplayProvider.id, isolation: .checkout
        ))

        var deniedFirst = false
        var revisedPlan = false
        try await answerEverything(controller) { controller in
            if controller.pendingPlan != nil, !revisedPlan {
                revisedPlan = true
                await controller.revisePlan(feedback: "Use a lock instead")
                return true
            }
            if let request = controller.pendingPermissions.first, !deniedFirst {
                deniedFirst = true
                await controller.decide(request.id, .deny(reason: "No"))
                return true
            }
            return false
        }

        #expect(toolCalls(controller).map(\.name) == ["Read", "Grep", "Bash"])
        #expect(controller.transcript.contains {
            if case let .plan(record) = $0.content {
                record.feedback == "Use a lock instead"
            } else {
                false
            }
        })
    }

    @Test func `persists and restores currents`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Persist me", providerID: ReplayProvider.id, isolation: .checkout
        ))
        try await waitUntil { controller.isAwaitingUser }
        await fixture.workspace.shutdown()

        let restored = Workspace(
            registry: fixture.registry, repository: fixture.storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        await restored.load()
        #expect(restored.pools.map(\.name) == [pool.name])
        let restoredController = try #require(restored.currents.first)
        #expect(restoredController.current.status == .ashore) // nothing survives a relaunch mid-flight
        #expect(restoredController.transcript.first?.content == .user(text: "Persist me"))
    }

    @Test func `a deleted current stays deleted even if touched afterwards`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Delete me", providerID: ReplayProvider.id, isolation: .checkout
        ))
        try await waitUntil { controller.isAwaitingUser }

        try await fixture.workspace.delete(controller.id, removingWorktree: false)
        controller.markViewed() // what the screen does as it disappears
        try await Task.sleep(for: .milliseconds(600)) // longer than the save debounce

        #expect(await fixture.storage.loadCurrents().isEmpty)
    }

    @Test func `archived worktrees can be removed and come back on reopen`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Work in a worktree", providerID: ReplayProvider.id, isolation: .worktree
        ))
        try await waitUntil { controller.isAwaitingUser }
        await controller.settle()

        let inventory = await fixture.workspace.worktreeInventory()
        let item = try #require(inventory.first)
        #expect(inventory.count == 1)
        #expect(item.use == .archived)
        #expect(item.sessionTitle == controller.current.title)

        try await fixture.workspace.removeWorktrees([item])
        #expect(!FileManager.default.fileExists(atPath: controller.current.channel.url.path))

        controller.reopen()
        await controller.send("Carry on")
        #expect(FileManager.default.fileExists(atPath: controller.current.channel.url.path))
    }

    @Test func `new worktrees get copied files and a setup script before the agent starts`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let root = fixture.repository
        try ".env\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "SECRET=1\n".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["-c", "user.name=T", "-c", "user.email=t@t.invalid", "commit", "-qam", "x", "--allow-empty"],
            currentDirectory: root
        )
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: root)
        #expect(await fixture.workspace.ignoredItems(in: pool.id) == [".env"])
        fixture.workspace.setWorktreeSetup(
            WorktreeSetup(copyPaths: [".env"], script: "echo ready > setup-ran"),
            for: pool.id
        )

        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Go", providerID: ReplayProvider.id, isolation: .worktree
        ))
        try await waitUntil { controller.isAwaitingUser }

        let worktree = controller.current.channel.url
        #expect(try String(contentsOf: worktree.appending(path: ".env"), encoding: .utf8) == "SECRET=1\n")
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "setup-ran").path))
        let setupCall = controller.transcript.compactMap { item -> ToolCallRecord? in
            if case let .toolCall(record) = item.content, record.name == "Worktree setup" {
                record
            } else {
                nil
            }
        }.first
        #expect(setupCall?.status == .succeeded)
        #expect(setupCall?.output?.contains("Copied .env") == true)
    }

    @Test func `verify runs the repository check and records the result`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Go", providerID: ReplayProvider.id, isolation: .checkout
        ))
        try await waitUntil { controller.isAwaitingUser }
        #expect(!controller.canVerify)

        fixture.workspace.setVerifySettings(
            VerifySettings(command: "test -f README.md", runsAfterEdits: false),
            for: pool.id
        )
        await controller.verify()
        #expect(controller.current.lastCheck?.passed == true)

        fixture.workspace.setVerifySettings(VerifySettings(command: "exit 3", runsAfterEdits: false), for: pool.id)
        await controller.verify()
        #expect(controller.current.lastCheck?.passed == false) // murky water
        #expect(controller.current.lastCheck?.command == "exit 3")
    }

    @Test func `demo creates a sample repository and reuses it`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()

        let first = try await fixture.workspace.startDemo()
        #expect(fixture.workspace.pools.map(\.name) == ["Watercoded Demo"])
        #expect(first.current.channel.kind == .worktree)
        #expect(FileManager.default
            .fileExists(atPath: first.current.channel.url.appending(path: "Sources/TokenStore.swift").path))
        try await waitUntil { first.isAwaitingUser }

        let second = try await fixture.workspace.startDemo()
        #expect(fixture.workspace.pools.count == 1)
        #expect(second.current.poolID == first.current.poolID)
        #expect(second.current.channel.path != first.current.channel.path)
    }

    @Test func `plain folders can be initialized as repositories`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let folder = fixture.repository.deletingLastPathComponent().appending(path: "plain")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await #expect(throws: GitError.self) { try await fixture.workspace.addPool(at: folder) }
        let pool = try await fixture.workspace.initializeRepositoryAndAddPool(at: folder)
        #expect(pool.name == "plain")
        #expect(await fixture.workspace.hasCommits(pool.id) == false)
    }

    @Test func `provider status prefers real agents over the demo`() async {
        let status = ProviderStatus(registry: ProviderRegistry([ReplayProvider(pace: 0)]))
        await status.refresh()
        #expect(status.availability(of: ReplayProvider.id)?.isAvailable == true)
        #expect(status.preferredProvider()?.id == ReplayProvider.id) // only the demo is registered
        #expect(status.preferredProvider()?.isDemo == true)
    }

    @Test func `finished currents can be saved and replayed`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let original = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Record me", providerID: ReplayProvider.id, isolation: .checkout
        ))
        try await answerEverything(original)

        let url = try fixture.workspace.saveReplayScript(for: original.id)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == fixture.scriptsDirectory.standardizedFileURL
            .path)
        let provider = try #require(fixture.registry.provider(for: ReplayProvider.id))
        let scriptName = url.deletingPathExtension().lastPathComponent
        #expect(provider.descriptor.models.contains { $0.id == scriptName })

        let replay = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Replay it", providerID: ReplayProvider.id, model: scriptName, isolation: .checkout
        ))
        try await answerEverything(replay)
        #expect(toolCalls(replay).map(\.name) == toolCalls(original).map(\.name))
    }

    @Test func `titles from prompts`() {
        #expect(NewCurrentRequest.title(fromPrompt: "Short") == "Short")
        #expect(NewCurrentRequest.title(fromPrompt: "\n") == "New Session")
        let long = NewCurrentRequest.title(fromPrompt: String(repeating: "word ", count: 30), maxLength: 20)
        #expect(long.hasSuffix("…"))
        #expect(long.count <= 21)
    }
}

// MARK: - Helpers

/// Answers whatever the agent waits on until the turn ends. `override` may handle an interaction
/// itself (returning `true`); otherwise questions get their first option, and plans and approvals
/// are accepted. Returns the kinds of interactions seen, in order.
@MainActor
@discardableResult
private func answerEverything(
    _ controller: CurrentController,
    override: (CurrentController) async -> Bool = { _ in false }
) async throws -> [String] {
    var kinds: [String] = []
    while true {
        try await waitUntil { controller.isAwaitingUser || controller.current.status == .ashore }
        if controller.current.status == .ashore, !controller.isAwaitingUser {
            return kinds
        }
        if controller.pendingQuestion != nil {
            kinds.append("question")
        } else if controller.pendingPlan != nil {
            kinds.append("plan")
        } else {
            kinds.append("permission")
        }
        if await override(controller) {
            continue
        }
        if let question = controller.pendingQuestion {
            let answers = Dictionary(uniqueKeysWithValues: question.questions.map { ($0.text, $0.options[0].label) })
            await controller.answer(answers)
        } else if controller.pendingPlan != nil {
            await controller.approvePlan()
        } else if let request = controller.pendingPermissions.first {
            await controller.decide(request.id, .allow)
        }
    }
}

@MainActor
private func toolCalls(_ controller: CurrentController) -> [ToolCallRecord] {
    controller.transcript.compactMap {
        if case let .toolCall(record) = $0.content {
            record
        } else {
            nil
        }
    }
}

private struct FakeSummarizer: CurrentSummarizer {
    func title(forPrompt prompt: String, reply: String) async -> String? {
        "Generated title"
    }

    func summary(forPrompt prompt: String, reply: String) async -> String? {
        "Generated summary"
    }
}

@MainActor
struct Fixture {
    let repository: URL
    let registry: ProviderRegistry
    let storage: InMemoryWorkspaceRepository
    let workspace: Workspace
    let scriptsDirectory: URL
    private let base: URL

    static func make() async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-orchestrator-\(UUID().uuidString)")
        let repo = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "hello\n".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let git = URL(filePath: "/usr/bin/git")
        let identity = ["-c", "user.name=Tests", "-c", "user.email=tests@watercoded.invalid"]
        for arguments in [
            ["init", "-q", "-b", "main"], ["config", "user.name", "Tests"], [
                "config",
                "user.email",
                "tests@watercoded.invalid"
            ],
            ["add", "."], identity + ["commit", "-q", "-m", "Initial"]
        ] {
            _ = try await ProcessRunner.run(executable: git, arguments: arguments, currentDirectory: repo)
        }
        let scripts = base.appending(path: "replays")
        let registry = ProviderRegistry([ReplayProvider(pace: 0, scriptsDirectory: scripts), FakeImporter()])
        let storage = InMemoryWorkspaceRepository()
        let workspace = Workspace(
            registry: registry,
            repository: storage,
            worktrees: WorktreeManager(root: base.appending(path: "worktrees")),
            demoRoot: base.appending(path: "demo"),
            // Never the real ~/.watercoded/delegation: a running app would see the tests' requests.
            delegationMailbox: DelegationMailbox(root: base.appending(path: "delegation"))
        )
        return Fixture(
            repository: repo,
            registry: registry,
            storage: storage,
            workspace: workspace,
            scriptsDirectory: scripts,
            base: base
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
