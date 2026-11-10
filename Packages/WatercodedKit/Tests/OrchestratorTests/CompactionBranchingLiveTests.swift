import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Branching after compaction (live)", .serialized, .timeLimit(.minutes(2)))
struct CompactionBranchingLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CLAUDE"] == "1"))
    func `claude disables discarded checkpoints and can branch newer turns`() async throws {
        try await check(provider: ClaudeCodeProvider(), model: "haiku", retainsHistory: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CODEX"] == "1"))
    func `codex keeps older checkpoints usable after compaction`() async throws {
        try await check(provider: CodexProvider(), model: nil, retainsHistory: true)
    }

    private func check(provider: any AgentProvider, model: String?, retainsHistory: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let workspace = Workspace(
            registry: ProviderRegistry([provider]),
            repository: fixture.storage,
            worktrees: fixture.workspace.worktrees,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        let pool = try await workspace.addPool(at: fixture.repository)
        let current = try await Current(
            poolID: pool.id,
            title: "Compaction regression",
            providerID: provider.descriptor.id,
            model: model,
            channel: fixture.workspace.worktrees.makeCheckoutChannel(for: pool)
        )
        let controller = workspace.adopt(current, transcript: [])
        do {
            await controller.send("Remember SILVER_OTTER_482. Reply only OK. Do not use tools.")
            try await waitUntil(timeout: .seconds(60)) {
                controller.current.status == .ashore && controller.current.turnSnapshots?.last?.checkpoint != nil
            }
            let original = try #require(controller.current.turnSnapshots?.first?.userMessageID)
            #expect(workspace.canBranch(controller, at: original, .after))
            #expect(await controller.submitPrompt("/compact"))
            try await waitUntil(timeout: .seconds(60)) {
                controller.activity.compactions > 0 && !controller.isTurnActive
            }
            #expect(workspace.canBranch(controller, at: original, .after) == retainsHistory)
            if !retainsHistory {
                await #expect(throws: AgentError.self) { try await workspace.branch(controller, at: original, .after) }
            }
            await controller.send("Reply only SILVER_OTTER_482. Do not use tools.")
            try await waitUntil(timeout: .seconds(60)) {
                controller.current.status == .ashore && controller.current.turnSnapshots?.count == 2
                    && controller.current.turnSnapshots?.last?.checkpoint != nil
            }
            let newer = try #require(controller.current.turnSnapshots?.last?.userMessageID)
            let chosen = retainsHistory ? original : newer
            let branch = try await workspace.branch(controller, at: chosen, .after)
            #expect(branch.current.channel.path != controller.current.channel.path)
            await branch.send("What token did I ask you to remember? Reply only with the token. Do not use tools.")
            try await waitUntil(timeout: .seconds(60)) {
                branch.current.status == .ashore && branch.transcript.contains {
                    if case let .assistant(text) = $0.content {
                        return text.contains("SILVER_OTTER_482")
                    }
                    return false
                }
            }
            #expect(branch.current.providerSessionID != controller.current.providerSessionID)
            await stop(workspace)
        } catch {
            await stop(workspace)
            throw error
        }
    }

    private func stop(_ workspace: Workspace) async {
        for session in workspace.currents {
            await session.stopSession()
        }
        await workspace.shutdown()
    }
}
