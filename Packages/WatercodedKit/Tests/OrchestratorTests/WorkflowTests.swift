import AgentKit
import Foundation
import GitKit
import ReplayProvider
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Workflows", .serialized)
struct WorkflowTests {
    @Test func `land commits and merges a Current's work`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let (workspace, controller) = try await fixture.finishedDemo()
        try "agent work\n".write(
            to: controller.current.channel.url.appending(path: "WORK.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await workspace.land(controller.id, options: LandOptions(
            commitMessage: "Add work notes", destination: .merge(into: "main"), removeWorktree: true
        ))
        #expect(result.commit != nil)
        #expect(result.merged)
        #expect(controller.current.status == .settled)
        #expect(FileManager.default.fileExists(atPath: fixture.repository.appending(path: "WORK.md").path))
        #expect(!FileManager.default.fileExists(atPath: controller.current.channel.path), "worktree removed")

        await #expect(throws: GitError.nothingToLand) {
            let second = try await workspace.startCurrent(NewCurrentRequest(
                poolID: controller.current.poolID, prompt: "Nothing", providerID: ReplayProvider.id
            ))
            try await answerAll(second)
            _ = try await workspace.land(
                second.id,
                options: LandOptions(commitMessage: "x", destination: .commitOnly, removeWorktree: false)
            )
        }
    }

    @Test func `standing approval rules answer matching requests`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        fixture.workspace.addApprovalRule(ApprovalRule(toolName: "Bash", pattern: "swift test *"), to: pool.id)

        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Go", providerID: ReplayProvider.id, isolation: .checkout
        ))
        let kinds = try await answerAll(controller)
        #expect(kinds == ["question", "plan", "permission"], "the Bash approval was answered by the rule")
        #expect(toolNames(controller).contains("Bash"))
        #expect(fixture.workspace.approvalCount(for: ApprovalRule(toolName: "Edit"), in: pool.id) == 1)
    }

    @Test func `edits without a test run are flagged`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let script = ReplayScript(steps: [
            .tool(name: "Edit", kind: .edit, summary: "App.swift", output: "ok"),
            .say("All done, everything works.")
        ])
        try FileManager.default.createDirectory(at: fixture.scriptsDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(script).write(to: fixture.scriptsDirectory.appending(path: "untested.json"))
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Edit", providerID: ReplayProvider.id, model: "untested", isolation: .checkout
        ))
        try await answerAll(controller)
        #expect(controller.transcript.contains {
            if case let .notice(notice) = $0
                .content {
                notice.level == .warning && notice.text.contains("didn't run tests")
            } else {
                false
            }
        })
    }

    @Test func `search, export, review and re-run`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let (workspace, controller) = try await fixture.finishedDemo()

        let hits = workspace.search("tokenstore")
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.currentID == controller.id })

        let markdown = await workspace.markdown(for: controller.id)
        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("## Verification"))
        #expect(markdown.contains("swift test"))

        controller.addReviewComment(ReviewComment(path: "A.swift", lines: "3–4", excerpt: "+x", text: "Rename this"))
        controller.addReviewComment(ReviewComment(path: "B.swift", lines: "", excerpt: nil, text: "Add a test"))
        let message = ReviewComment.message(for: controller.reviewComments, summary: "Looks close")
        #expect(message.contains("1. `A.swift` (lines 3–4)"))
        #expect(message.contains("2. `B.swift`\nAdd a test"))
        #expect(message.contains("Looks close"))

        let rerun = try await workspace.rerun(controller.id, providerID: ReplayProvider.id, model: "standard")
        try await waitUntil { !rerun.transcript.isEmpty }
        #expect(rerun.transcript.first?.content == .user(text: "Fix the TokenStore race"))
        #expect(rerun.current.title.hasSuffix("(standard)"))
        #expect(rerun.current.channel.path != controller.current.channel.path)
    }

    @Test func `outside sessions can be imported`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let candidates = fixture.workspace.importCandidates(for: pool.id)
        #expect(candidates.map(\.session.title) == ["Imported work"])

        let imported = try await fixture.workspace.importSession(candidates[0], into: pool.id)
        #expect(imported.current.providerSessionID == "outside-1")
        #expect(imported.transcript.first?.content == .user(text: "Imported work"))
        #expect(
            fixture.workspace.importCandidates(for: pool.id).isEmpty,
            "already-imported sessions aren't offered again"
        )
    }

    @Test func `quitting mid-turn offers to resume`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Long task", providerID: ReplayProvider.id, isolation: .checkout
        ))
        try await waitUntil { controller.isAwaitingUser }
        await fixture.workspace.shutdown()
        #expect(controller.current.interruptedByQuit == true)

        let relaunched = Workspace(
            registry: fixture.registry, repository: fixture.storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        await relaunched.load()
        let restored = try #require(relaunched.currents.first)
        #expect(restored.current.interruptedByQuit == true)
        #expect(restored.current.status == .ashore)
    }
}

// MARK: - Helpers

extension Fixture {
    /// Runs the demo script to completion in a worktree.
    func finishedDemo() async throws -> (Workspace, CurrentController) {
        await workspace.load()
        let pool = try await workspace.addPool(at: repository)
        let controller = try await workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Fix the TokenStore race", providerID: ReplayProvider.id
        ))
        try await answerAll(controller)
        return (workspace, controller)
    }
}

@MainActor
@discardableResult
func answerAll(_ controller: CurrentController) async throws -> [String] {
    var kinds: [String] = []
    while true {
        try await waitUntil { controller.isAwaitingUser || controller.current.status == .ashore }
        if controller.current.status == .ashore, !controller.isAwaitingUser {
            return kinds
        }
        if let question = controller.pendingQuestion {
            kinds.append("question")
            await controller.answer(Dictionary(uniqueKeysWithValues: question.questions.map { (
                $0.text,
                $0.options[0].label
            ) }))
        } else if controller.pendingPlan != nil {
            kinds.append("plan")
            await controller.approvePlan()
        } else if let request = controller.pendingPermissions.first {
            kinds.append("permission")
            await controller.decide(request.id, .allow)
        }
    }
}

@MainActor
func toolNames(_ controller: CurrentController) -> [String] {
    controller.transcript.compactMap {
        if case let .toolCall(record) = $0.content {
            record.name
        } else {
            nil
        }
    }
}

/// A provider that only offers one outside session to import.
struct FakeImporter: SessionImporting {
    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "fake-importer", displayName: "Fake", symbolName: "tray", tintHue: 0.3,
            capabilities: [], models: [], installHint: ""
        )
    }

    func availability() async -> ProviderAvailability {
        .available(version: nil)
    }

    func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        throw AgentError.unsupported("Sessions")
    }

    func importableSessions(in directory: URL) -> [ImportableSession] {
        [ImportableSession(id: "outside-1", title: "Imported work", updatedAt: .now, messageCount: 2)]
    }

    func transcript(ofSession id: String, in directory: URL) throws -> [TranscriptItem] {
        [TranscriptItem(content: .user(text: "Imported work")), TranscriptItem(content: .assistant(text: "Done."))]
    }
}
