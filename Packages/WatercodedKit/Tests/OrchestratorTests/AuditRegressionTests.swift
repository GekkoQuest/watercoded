import AgentKit
import ClaudeCodeProvider
import Foundation
import GitKit
import ProcessKit
import Testing
import WatercodedCore
@testable import Orchestrator

/// Reproductions from the repository testing pass, retained as regressions.
@MainActor
@Suite("Audit regressions", .serialized)
struct AuditRegressionTests {
    @Test func `tab filename survives diff`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let name = "has\ttab.txt"
        try "hello\n".write(to: f.repository.appending(path: name), atomically: true, encoding: .utf8)
        let diff = try await UnifiedDiff(parsing: GitClient().diff(in: f.repository, against: "HEAD"))
        #expect(diff.files.map(\.path) == [name])
    }

    @Test func `search finds renamed session`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let pool = try await f.workspace.addPool(at: f.repository)
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        let c = f.workspace.adopt(
            Current(poolID: pool.id, title: "UniqueRenamedTitle", providerID: "unknown", channel: channel),
            transcript: [TranscriptItem(content: .user(text: "ordinary prompt"))]
        )
        defer { c.discard() }
        let hit = try #require(f.workspace.search("uniquerenamedtitle").first)
        #expect(hit.currentID == c.id)
        #expect(hit.itemID == nil, "Title hits open the session without scrolling to an unrelated message")
        #expect(f.workspace.search("UniqueRenamedTitle", limit: 0).isEmpty)
    }

    @Test func `land first commit`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let folder = f.repository.deletingLastPathComponent().appending(path: "unborn-audit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = try await f.workspace.initializeRepositoryAndAddPool(at: folder)
        for args in [["config", "user.name", "Tests"], ["config", "user.email", "tests@tests.invalid"]] {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: args,
                currentDirectory: folder
            )
        }
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        let c = f.workspace.adopt(
            Current(poolID: pool.id, title: "First commit", providerID: "unknown", channel: channel),
            transcript: []
        )
        defer { c.discard() }
        try "new\n".write(to: folder.appending(path: "first.txt"), atomically: true, encoding: .utf8)
        _ = try await f.workspace.land(
            c.id,
            options: LandOptions(commitMessage: "First", destination: .commitOnly, removeWorktree: false)
        )
        #expect(c.current.status == .settled)
    }

    @Test func `shell edits trigger auto verify`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let pool = try await f.workspace.addPool(at: f.repository)
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        let c = f.workspace.adopt(
            Current(poolID: pool.id, title: "Shell edit", providerID: "unknown", channel: channel),
            transcript: []
        )
        defer { c.discard() }
        f.workspace.setVerifySettings(VerifySettings(command: "echo checked > verified-marker"), for: pool.id)
        c.handle(.turnStarted)
        c.handle(.toolCallStarted(ToolCall(
            callID: "shell",
            name: "Bash",
            kind: .shell,
            summary: "printf changed > README.md",
            input: [:]
        )))
        try "changed".write(to: f.repository.appending(path: "README.md"), atomically: true, encoding: .utf8)
        c.handle(.toolCallFinished(callID: "shell", output: "", isError: false))
        c.handle(.turnFinished(.completed))
        try await waitUntil { c.current.lastCheck?.passed == true }
        #expect(FileManager.default.fileExists(atPath: f.repository.appending(path: "verified-marker").path))
    }

    @Test func `failed review keeps comments`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let pool = try await f.workspace.addPool(at: f.repository)
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        let c = f.workspace.adopt(
            Current(poolID: pool.id, title: "Review", providerID: "missing-provider", channel: channel),
            transcript: []
        )
        defer { c.discard() }
        c.addReviewComment(ReviewComment(path: "README.md", lines: "1", excerpt: nil, text: "Please fix"))
        await c.sendReview()
        #expect(c.current.status == .stalled)
        #expect(c.reviewComments.count == 1)
    }

    @Test func `corrupt transcript is not overwritten`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let pool = try await f.workspace.addPool(at: f.repository)
        let storage = FileWorkspaceRepository(root: f.repository.appending(path: "storage"))
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        var current = Current(poolID: pool.id, title: "Corrupt", providerID: "unknown", channel: channel)
        let relay = f.repository.appending(path: "recovery-relay")
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        try "Recovery log".write(to: relay.appending(path: "log"), atomically: true, encoding: .utf8)
        current.relay = RelayHandle(directory: relay.path, offset: 0)
        try await storage.savePools([pool])
        try await storage.saveCurrent(current)
        let file = await storage.root.appending(path: "currents/\(current.id)/transcript.json")
        let original = "{\"schemaVersion\":1,\"value\":[broken but recoverable bytes"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(
            registry: f.registry,
            repository: storage,
            delegationMailbox: f.workspace.delegationMailbox
        )
        await workspace.load()
        let controller = try #require(workspace.controller(current.id))
        #expect(controller.transcriptLoadError != nil)
        #expect(controller.current.status == .stalled)
        #expect(await controller.submitPrompt("Do not lose the original") == false)
        controller.markViewed()
        await workspace.shutdown()
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == original)
        #expect(try String(contentsOf: relay.appending(path: "log"), encoding: .utf8) == "Recovery log")
        let recovered = [TranscriptItem(
            date: Date(timeIntervalSince1970: 0),
            content: .user(text: "Recovered history")
        )]
        try await storage.saveTranscript(recovered, for: current.id) // Simulate restoring a backup.
        let reopened = Workspace(
            registry: f.registry,
            repository: storage,
            delegationMailbox: f.workspace.delegationMailbox
        )
        await reopened.load()
        #expect(reopened.controller(current.id)?.transcriptLoadError == nil)
        #expect(reopened.controller(current.id)?.transcript == recovered)
        await reopened.shutdown()
    }

    @Test func `branched worktree gets setup`() async throws {
        let f = try await Fixture.make()
        defer { f.cleanUp() }
        let pool = try await f.workspace.addPool(at: f.repository)
        f.workspace.setWorktreeSetup(WorktreeSetup(copyPaths: [], script: "echo ready > setup-marker"), for: pool.id)
        await f.storage.savePools(f.workspace.pools)
        let workspace = Workspace(
            registry: ProviderRegistry([ClaudeCodeProvider()]),
            repository: f.storage,
            worktrees: f.workspace.worktrees,
            delegationMailbox: f.workspace.delegationMailbox
        )
        await workspace.load()
        #expect(workspace.pool(pool.id)?.worktreeSetup?.script == "echo ready > setup-marker")
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        let message = TranscriptItem(content: .user(text: "Original"))
        var current = Current(
            poolID: pool.id,
            title: "Branch setup",
            providerID: ClaudeCodeProvider.id,
            channel: channel
        )
        let snapshot = try await GitClient().snapshotWorkingTree(
            in: f.repository,
            ref: "refs/watercoded/audit/before",
            message: "Before"
        )
        var turn = TurnSnapshot(index: 1, startedAt: .now, beforeCommit: snapshot)
        turn.userMessageID = message.id
        current.turnSnapshots = [turn]
        let c = workspace.adopt(current, transcript: [message])
        let copy = try await workspace.branch(c, at: message.id, .before)
        defer { c.discard()
            copy.discard()
        }
        let setup = try #require(copy.pendingSetup)
        await copy.runSetup(setup)
        #expect(try String(contentsOf: copy.current.channel.url.appending(path: "setup-marker"), encoding: .utf8)
            == "ready\n")
        await workspace.shutdown()
    }

    @Test func `timeout bounds uncooperative process`() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 2"],
                timeout: .milliseconds(100)
            )
            Issue.record("Expected a timeout")
        } catch ProcessError.timedOut {
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1))
        }
    }
}
