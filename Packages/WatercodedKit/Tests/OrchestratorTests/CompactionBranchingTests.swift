import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Branching after compaction")
struct CompactionBranchingTests {
    @Test func `compaction cannot race a pending checkpoint save`() async throws {
        let message = TranscriptItem(content: .user(text: "Work"))
        var current = Current(
            poolID: PoolID(),
            title: "Race",
            providerID: ClaudeCodeProvider.id,
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
        var snapshot = TurnSnapshot(index: 1, startedAt: .now, beforeCommit: "before")
        snapshot.userMessageID = message.id
        current.turnSnapshots = [snapshot]
        let controller = CurrentController(
            current: current,
            transcript: [message],
            provider: ClaudeCodeProvider(),
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        controller.snapshotter = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return "after"
        }
        let saving = Task {
            await controller.recordTurnEnd(.completed, snapshot: snapshot, checkpoint: "old", generation: 0)
        }
        try await Task.sleep(for: .milliseconds(20))
        controller.handle(.contextCompacted(preTokens: nil, postTokens: nil))
        _ = await saving.value
        #expect(controller.current.turnSnapshots?.first?.checkpoint == nil)
        #expect(controller.current.turnSnapshots?.first?.checkpointInvalidatedByCompaction == true)
    }

    @Test func `legacy checkpoints migrate without invalidating newer turns again`() throws {
        let first = TranscriptItem(content: .user(text: "Before compaction"))
        let second = TranscriptItem(content: .user(text: "After compaction"))
        var current = Current(
            poolID: PoolID(),
            title: "Legacy",
            providerID: ClaudeCodeProvider.id,
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
        current.turnSnapshots = [first, second].enumerated().map { index, item in
            var turn = TurnSnapshot(
                index: index + 1,
                startedAt: Date(timeIntervalSince1970: Double(index * 2)),
                beforeCommit: "before",
                afterCommit: "after"
            )
            turn.userMessageID = item.id
            turn.checkpoint = "checkpoint-\(index)"
            turn.checkpointInvalidatedByCompaction = nil // A snapshot saved by an older app.
            return turn
        }
        let notice = TranscriptItem(
            date: Date(timeIntervalSince1970: 1),
            content: .notice(Notice(.info, "Context compacted."))
        )
        let controller = CurrentController(
            current: current,
            transcript: [first, notice, second],
            provider: ClaudeCodeProvider(),
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        #expect(controller.current.turnSnapshots?.first?.checkpoint == nil)
        #expect(controller.current.turnSnapshots?.last?.checkpoint == "checkpoint-1")
        let saved = try JSONDecoder().decode(Current.self, from: JSONEncoder().encode(controller.current))
        let restored = CurrentController(
            current: saved,
            transcript: controller.transcript,
            provider: ClaudeCodeProvider(),
            repository: InMemoryWorkspaceRepository()
        )
        defer { restored.discard() }
        #expect(restored.current.turnSnapshots?.last?.checkpoint == "checkpoint-1")
    }

    @Test(arguments: [false, true])
    func `only providers retaining checkpoints can branch older turns`(retainsHistory: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let provider: any AgentProvider = retainsHistory ? CodexProvider() : ClaudeCodeProvider()
        let workspace = Workspace(
            registry: ProviderRegistry([provider]),
            repository: fixture.storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        let pool = try await workspace.addPool(at: fixture.repository)
        var current = try await Current(
            poolID: pool.id,
            title: "History",
            providerID: provider.descriptor.id,
            channel: fixture.workspace.worktrees.makeCheckoutChannel(for: pool)
        )
        let first = TranscriptItem(content: .user(text: "First"))
        let second = TranscriptItem(content: .user(text: "Second"))
        current.turnSnapshots = [first, second].enumerated().map { index, item in
            var turn = TurnSnapshot(index: index + 1, startedAt: .now, beforeCommit: "before", afterCommit: "after")
            turn.userMessageID = item.id
            turn.checkpoint = "checkpoint-\(index)"
            return turn
        }
        let controller = workspace.adopt(current, transcript: [first, second])
        defer { controller.discard() }
        controller.lastCheckpoint = "checkpoint-1"
        #expect(workspace.canBranch(controller, at: first.id, .after))
        controller.handle(.contextCompacted(preTokens: 1000, postTokens: 100))
        #expect(workspace.canBranch(controller, at: first.id, .after) == retainsHistory)
        #expect(workspace.canBranch(controller, at: second.id, .before) == retainsHistory)
        #expect(
            workspace.canBranch(controller, at: first.id, .before),
            "The first turn needs no conversation checkpoint"
        )
        #expect(controller.current.turnSnapshots?.first?.afterCommit == "after", "File history remains available")
        if !retainsHistory {
            #expect(controller.lastCheckpoint == nil)
            #expect(workspace.branchingUnavailableReason(controller, at: first.id, .after)?
                .contains("compaction") == true)
            await #expect(throws: AgentError.self) { try await workspace.branch(controller, at: first.id, .after) }
            // Simulate restoring saved history, then a new completed turn after compaction.
            let restored = workspace.adopt(controller.current, transcript: controller.transcript)
            defer { restored.discard() }
            #expect(!workspace.canBranch(restored, at: first.id, .after))
            let newer = TranscriptItem(content: .user(text: "After compaction"))
            var turn = TurnSnapshot(index: 3, startedAt: .now, beforeCommit: "before", afterCommit: "after")
            turn.userMessageID = newer.id
            turn.checkpoint = "new-checkpoint"
            restored.update { $0.turnSnapshots?.append(turn) }
            #expect(workspace.canBranch(restored, at: newer.id, .after))
        }
    }
}
