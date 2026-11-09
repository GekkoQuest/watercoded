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
    /// Answers a replay child's approvals, plans and questions as a user would, until cancelled.
    private func actAsUser(for child: CurrentController) -> Task<Void, Never> {
        Task { @MainActor in
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
    }

    private func startParent(_ fixture: Fixture) async throws -> CurrentController {
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let parent = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Lead the work", providerID: ReplayProvider.id, isolation: .worktree
        ))
        try await waitUntil { parent.isAwaitingUser }
        return parent
    }

    @Test func `a helper works in its own copy and its changes come back to the parent`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let parent = try await startParent(fixture)

        // The delegate server is offered only once the app knows where its binary is.
        #expect(fixture.workspace.mcpServers(for: parent).isEmpty)
        fixture.workspace.delegationExecutable = URL(filePath: "/Applications/Watercoded.app/Contents/MacOS/Watercoded")
        let server = try #require(fixture.workspace.mcpServers(for: parent).first)
        #expect(server.name == "watercoded" && server.isTrusted)
        #expect(server.arguments.contains(parent.id.rawValue.uuidString))

        // The parent has uncommitted work the helper should see.
        try "draft\n".write(
            to: parent.current.channel.url.appending(path: "draft.txt"),
            atomically: true,
            encoding: .utf8
        )
        let request = DelegationRequest(
            parentID: parent.id.rawValue.uuidString, agent: ReplayProvider.id.rawValue,
            model: nil, effort: nil, task: "Help with a part"
        )
        let answered = Task { await fixture.workspace.handle(request) }
        try await waitUntil(timeout: .seconds(10)) { !fixture.workspace.children(of: parent.id).isEmpty }
        let child = try #require(fixture.workspace.children(of: parent.id).first)
        #expect(child.current.channel.path != parent.current.channel.path) // its own folder
        #expect(FileManager.default.fileExists(atPath: child.current.channel.url.appending(path: "draft.txt").path))
        #expect(child.current.permissionMode == parent.current.permissionMode)
        let user = actAsUser(for: child)
        defer { user.cancel() }
        await answered.value
        let response = try #require(fixture.workspace.delegationMailbox.takeResponse(for: request.id))
        #expect(response.error == nil)

        // What a helper changes is applied to the parent's folder.
        try "from the helper\n".write(
            to: child.current.channel.url.appending(path: "helper.txt"),
            atomically: true,
            encoding: .utf8
        )
        let note = await fixture.workspace.applyDelegatedChanges(of: child)
        #expect(note?.contains("helper.txt") == true)
        #expect(try String(contentsOf: parent.current.channel.url.appending(path: "helper.txt"), encoding: .utf8)
            == "from the helper\n")

        // Deleting the helper removes its own copy, never the parent's folder.
        try await fixture.workspace.delete(child.id, removingWorktree: true)
        #expect(FileManager.default.fileExists(atPath: parent.current.channel.path))
        #expect(!FileManager.default.fileExists(atPath: child.current.channel.path))
    }

    @Test func `several helpers can run at once while the parent keeps going`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let parent = try await startParent(fixture)
        let requests = ["First part", "Second part"].map {
            DelegationRequest(
                parentID: parent.id.rawValue.uuidString,
                agent: ReplayProvider.id.rawValue,
                model: nil,
                effort: nil,
                task: $0,
                wait: false
            )
        }
        let handling = requests.map { request in Task { await fixture.workspace.handle(request) } }

        // Each answers straight away with an id to collect later.
        for request in requests {
            try await waitUntil(timeout: .seconds(10)) {
                fixture.workspace.delegationMailbox.takeResponse(for: request.id).map { started in
                    #expect(started.text?.contains("wait_for_delegations") == true)
                    return true
                } ?? false
            }
        }
        let children = fixture.workspace.children(of: parent.id)
        #expect(children.count == 2)
        #expect(Set(children.map(\.current.channel.path)).count == 2) // separate folders
        let users = children.map(actAsUser)
        defer { users.forEach { $0.cancel() } }
        for task in handling {
            await task.value
        }
        for request in requests {
            #expect(fixture.workspace.delegationMailbox.result(for: request.id)?.error == nil)
        }
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
