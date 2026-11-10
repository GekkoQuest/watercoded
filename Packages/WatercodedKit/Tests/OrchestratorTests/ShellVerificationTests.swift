import AgentKit
import Foundation
import GitKit
import ProcessKit
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Verification of shell changes", .serialized)
struct ShellVerificationTests {
    @Test(arguments: ["read", "write", "commit", "failed write"])
    func `verification follows actual file changes`(operation: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let channel = try await fixture.workspace.worktrees.makeCheckoutChannel(for: pool)
        let controller = fixture.workspace.adopt(
            Current(poolID: pool.id, title: "Shell", providerID: "unknown", channel: channel), transcript: []
        )
        defer { controller.discard() }
        fixture.workspace.setVerifySettings(VerifySettings(command: "echo checked > verified-marker"), for: pool.id)
        await controller.recordTurnStart()
        controller.handle(.turnStarted)
        controller.handle(.toolCallStarted(ToolCall(
            callID: "shell",
            name: "Bash",
            kind: .shell,
            summary: "A command",
            input: [:]
        )))
        let script = operation == "read" ? "cat README.md" : "echo changed > README.md"
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            currentDirectory: fixture.repository
        )
        #expect(result.succeeded)
        if operation == "commit" {
            try await GitClient().commitAll(in: fixture.repository, message: "Agent commit")
        }
        controller.handle(.toolCallFinished(callID: "shell", output: "", isError: operation == "failed write"))
        controller.handle(.turnFinished(.completed))
        if operation == "read" {
            try await waitUntil { controller.current.turnSnapshots?.last?.afterCommit != nil }
            try await Task.sleep(for: .milliseconds(200))
            #expect(controller.current.lastCheck == nil)
        } else {
            try await waitUntil { controller.current.lastCheck?.passed == true }
            #expect(FileManager.default.fileExists(atPath: fixture.repository.appending(path: "verified-marker").path))
        }
    }
}
