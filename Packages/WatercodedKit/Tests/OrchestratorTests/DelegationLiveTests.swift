import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Delegation
import Foundation
import GitKit
import Testing
import WatercodedCore
@testable import Orchestrator

/// Real agents delegating to each other through the app binary's `delegate` MCP server, in both directions.
/// Spends a little usage on both plans. Build the app first (`make build`), then:
/// WATERCODED_LIVE_DELEGATION=1 swift test --filter DelegationLive
@MainActor
@Suite(
    "Delegation live",
    .enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_DELEGATION"] == "1"),
    .serialized
)
struct DelegationLiveTests {
    static var appBinary: URL? {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/",
              !FileManager.default.fileExists(atPath: directory.appending(path: "project.yml").path) {
            directory.deleteLastPathComponent()
        }
        let binary = directory
            .appending(path: ".build/xcode/Build/Products/Debug/Watercoded.app/Contents/MacOS/Watercoded")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    struct Route: Sendable, CustomTestStringConvertible {
        var parent: String
        var parentModel: String
        var child: String
        var childModel: String
        var testDescription: String {
            "\(parent) → \(child)"
        }
    }

    @Test(arguments: [
        Route(parent: "claude-code", parentModel: "haiku", child: "codex", childModel: ""),
        Route(parent: "codex", parentModel: "", child: "claude-code", childModel: "haiku")
    ])
    func `an agent delegates to another provider and uses its answer`(route: Route) async throws {
        let binary = try #require(Self.appBinary, "run `make build` first")
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let workspace = Workspace(
            registry: ProviderRegistry([ClaudeCodeProvider(), CodexProvider()]),
            repository: InMemoryWorkspaceRepository(),
            worktrees: WorktreeManager(root: fixture.repository.deletingLastPathComponent()
                .appending(path: "live-worktrees")),
            delegationMailbox: DelegationMailbox(
                root: fixture.repository.deletingLastPathComponent().appending(path: "live-delegation")
            )
        )
        workspace.backgroundSessionsEnabled = false
        workspace.delegationExecutable = binary
        await workspace.load()
        let pool = try await workspace.addPool(at: fixture.repository)

        let modelNote = route.childModel.isEmpty ? "" : ", model \(route.childModel)"
        let parent = try await workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id,
            prompt: """
            Use the watercoded delegate tool to ask agent \(route.child)\(modelNote) to reply with exactly the \
            word PINEAPPLE. Then reply with exactly the word it answered, nothing else.
            """,
            providerID: ProviderID(rawValue: route.parent),
            model: route.parentModel.isEmpty ? nil : route.parentModel,
            permissionMode: .fullAccess,
            isolation: .worktree
        ))
        do {
            try await waitUntil(timeout: .seconds(300)) {
                parent.current.lastTurnEndedAt != nil && !parent.isTurnActive
            }
        } catch {
            await workspace.shutdown() // never leave agents running after a failed test
            throw error
        }
        let child = try #require(workspace.children(of: parent.id).first, "no delegated session was started")
        #expect(child.current.providerID.rawValue == route.child)
        #expect(child.current.channel.path == parent.current.channel.path)
        let reply = parent.transcript.compactMap {
            if case let .assistant(text) = $0.content {
                text
            } else {
                nil
            }
        }
        .last
        #expect(reply?.contains("PINEAPPLE") == true)
        await workspace.shutdown()
    }
}
