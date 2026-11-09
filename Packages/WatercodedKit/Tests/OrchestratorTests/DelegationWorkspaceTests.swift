import AgentKit
import Delegation
import Foundation
import GitKit
import ReplayProvider
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Delegation", .serialized)
struct DelegationWorkspaceTests {
    @Test func `a session can delegate to another agent and gets its answer`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let parent = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Lead the work", providerID: ReplayProvider.id, isolation: .worktree
        ))
        try await waitUntil { parent.isAwaitingUser }

        // The delegate server is offered only once the app knows where its binary is.
        #expect(fixture.workspace.mcpServers(for: parent).isEmpty)
        fixture.workspace.delegationExecutable = URL(filePath: "/Applications/Watercoded.app/Contents/MacOS/Watercoded")
        let server = try #require(fixture.workspace.mcpServers(for: parent).first)
        #expect(server.name == "watercoded" && server.isTrusted)
        #expect(server.arguments.contains(parent.id.rawValue.uuidString))

        let request = DelegationRequest(
            parentID: parent.id.rawValue.uuidString, agent: ReplayProvider.id.rawValue,
            model: nil, effort: nil, task: "Help with a part"
        )
        let answered = Task { await fixture.workspace.handle(request) }
        try await waitUntil(timeout: .seconds(10)) { !fixture.workspace.children(of: parent.id).isEmpty }
        let child = try #require(fixture.workspace.children(of: parent.id).first)
        #expect(child.current.channel.path == parent.current.channel.path) // works in the parent's folder
        #expect(child.current.permissionMode == parent.current.permissionMode)
        // The replay asks for approvals along the way: answer them as a user would until the child finishes.
        let user = Task { @MainActor in
            while !Task.isCancelled {
                if let pending = child.pendingPermissions.first {
                    await child.decide(pending.id, .allow)
                } else if child.pendingPlan != nil {
                    await child.approvePlan()
                } else if let question = child.pendingQuestion {
                    await child.answer(Dictionary(uniqueKeysWithValues: question.questions.map {
                        ($0.text, $0.options.first?.label ?? "Yes")
                    }))
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { user.cancel() }
        try await waitUntil(timeout: .seconds(20)) { answered.isCancelled || child.current.lastTurnEndedAt != nil }
        await answered.value
        let response = try #require(fixture.workspace.delegationMailbox.takeResponse(for: request.id))
        #expect(response.error == nil)
        #expect(response.text?.contains("Help with a part") == true || response.text?.isEmpty == false)

        // Deleting the child leaves the parent's worktree alone.
        try await fixture.workspace.delete(child.id, removingWorktree: true)
        #expect(FileManager.default.fileExists(atPath: parent.current.channel.path))
    }

    @Test func `unknown agents are refused with the list of real ones`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let parent = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Lead", providerID: ReplayProvider.id, isolation: .checkout
        ))
        let request = DelegationRequest(
            parentID: parent.id.rawValue.uuidString,
            agent: "nope",
            model: nil,
            effort: nil,
            task: "x"
        )
        await fixture.workspace.handle(request)
        let response = try #require(fixture.workspace.delegationMailbox.takeResponse(for: request.id))
        #expect(response.error?.contains("nope") == true)
    }
}
