import Foundation
import ReplayProvider
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Worktree cleanup")
struct WorktreeCleanupTests {
    @Test(arguments: [false, true])
    func `reopening during cleanup waits before accessing the worktree`(removalFails: Bool) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        await fixture.workspace.load()
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = try await fixture.workspace.startCurrent(NewCurrentRequest(
            poolID: pool.id, prompt: "Work", providerID: ReplayProvider.id, isolation: .worktree
        ))
        try await waitUntil { controller.isAwaitingUser }
        await controller.settle()
        let items = await fixture.workspace.worktreeInventory()
        let item = try #require(items.first)
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let probe = CleanupProbe()
        controller.snapshotter = { _, _, _ in
            await MainActor.run {
                #expect(probe.finished, "Snapshots must not read a folder while cleanup can still delete it")
                probe.snapshotStarted = true
            }
            return nil
        }
        let cleanup = Task {
            try await fixture.workspace.removeWorktrees([item], removing: { url in
                probe.started = true
                defer { probe.finished = true }
                for await _ in release.stream {
                    break
                }
                if removalFails {
                    throw CleanupFailure.expected
                }
                try await fixture.workspace.worktrees.removeWorktree(at: url)
            })
        }
        try await waitUntil { probe.started }
        controller.reopen()
        let send = Task { await controller.send("Carry on") }
        try await waitUntil { controller.current.status == .flowing }
        #expect(!probe.snapshotStarted)
        #expect(!controller.isSessionLive)

        release.continuation.yield(())
        let result = await cleanup.result
        if removalFails {
            guard case .failure = result else {
                Issue.record("Cleanup should report the removal failure")
                return
            }
        } else {
            _ = try result.get()
        }
        await send.value
        try await waitUntil { controller.isAwaitingUser }
        #expect(probe.snapshotStarted)
        #expect(controller.isSessionLive)
        #expect(FileManager.default.fileExists(atPath: controller.current.channel.url.path))
        #expect(fixture.workspace.worktreeRemovals.isEmpty)
        await controller.settle()
    }
}

@MainActor
private final class CleanupProbe {
    var started = false
    var finished = false
    var snapshotStarted = false
}

private enum CleanupFailure: Error {
    case expected
}
