import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Durable session checkpoints")
struct SessionCheckpointTests {
    private func current() -> Current {
        Current(
            poolID: PoolID(),
            title: "Checkpoint",
            providerID: "test",
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
    }

    @Test func `queued relay output cannot advance a saved conversation`() async {
        let storage = InMemoryWorkspaceRepository()
        var current = current()
        current.relay = RelayHandle(directory: "/tmp/relay", offset: 0)
        let controller = CurrentController(current: current, transcript: [], provider: nil, repository: storage)
        defer { controller.discard() }
        controller.handle(.relayBatch(events: [
            .toolCallStarted(ToolCall(callID: "tool", name: "Shell", kind: .shell, summary: "test", input: [:])),
            .textDelta(messageID: "message", text: "Partial response")
        ], checkpoint: RelayHandle(directory: "/tmp/relay", offset: 100)))
        // The process may already have read later records; only the applied batch is durable.
        await controller.flush()
        #expect(await storage.loadCurrents().first?.relay?.offset == 100)
        #expect(await storage.loadTranscript(for: current.id).count == 1)
        #expect(await storage.loadStreamingText(for: current.id) == "Partial response")
        controller.handle(.relayBatch(events: [
            .toolCallFinished(callID: "tool", output: "Done", isError: false),
            .messageCompleted(messageID: "message", text: "Full response")
        ], checkpoint: RelayHandle(directory: "/tmp/relay", offset: 200)))
        await controller.flush()
        #expect(await storage.loadCurrents().first?.relay?.offset == 200)
        #expect(await storage.loadStreamingText(for: current.id).isEmpty)
        let transcript = await storage.loadTranscript(for: current.id)
        #expect(transcript.count == 2)
        #expect(transcript.last?.content == .assistant(text: "Full response"))
    }

    @Test func `authoritative provider usage repairs previously overcounted output`() {
        let storage = InMemoryWorkspaceRepository()
        var current = current()
        current.outputTokens = 290_674
        let controller = CurrentController(current: current, transcript: [], provider: nil, repository: storage)
        defer { controller.discard() }
        controller.handle(.usageUpdated(UsageSnapshot(outputTokens: 289_773)))
        #expect(controller.current.outputTokens == 289_773)
    }

    @Test func `manifest keeps transcript images streaming text and replay boundary together`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "checkpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileWorkspaceRepository(root: root)
        var current = current()
        current.relay = RelayHandle(directory: "/tmp/relay", offset: 123)
        let image = ImageAttachment(mediaType: "image/png", data: Data(repeating: 42, count: 1_000_000))
        let items = [TranscriptItem(
            date: Date(timeIntervalSince1970: 0),
            content: .userImages(count: 1),
            images: [image]
        )]
        try await storage.saveSession(current, transcript: items, streamingText: "In progress")
        let directory = root.appending(path: "currents/\(current.id)")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let transcript = try #require(files.first { $0.lastPathComponent.hasPrefix("transcript-") })
        #expect(try Data(contentsOf: transcript).count < 2000)
        let bytes = try Data(contentsOf: transcript)
        let images = directory.appending(path: "attachments")
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 1)

        // A crash before publishing a new manifest can leave an unreferenced transcript. Ignore it.
        try Data("incomplete".utf8).write(to: directory.appending(path: "transcript-orphan.json"))
        let reopened = FileWorkspaceRepository(root: root)
        #expect(try await reopened.loadTranscript(for: current.id) == items)
        #expect(try await reopened.loadCurrents().first?.relay?.offset == 123)
        #expect(try await reopened.loadStreamingText(for: current.id) == "In progress")

        current.title = "Renamed"
        try await reopened.saveSession(current, transcript: nil, streamingText: "More progress")
        #expect(try Data(contentsOf: transcript) == bytes)
        #expect(try await reopened.loadTranscript(for: current.id) == items)
        #expect(try await reopened.loadStreamingText(for: current.id) == "More progress")
        // A later metadata-only save also preserves the transcript reference.
        try await reopened.saveCurrent(current)
        #expect(try await reopened.loadTranscript(for: current.id) == items)
        let attachment = try #require(FileManager.default.contentsOfDirectory(
            at: images, includingPropertiesForKeys: nil
        ).first)
        try FileManager.default.removeItem(at: attachment)
        await #expect(throws: (any Error).self) { try await reopened.loadTranscript(for: current.id) }
    }

    @Test func `legacy embedded image history migrates without losing attachments`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "checkpoint-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileWorkspaceRepository(root: root)
        let current = current()
        let image = ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]))
        let items = [TranscriptItem(
            date: Date(timeIntervalSince1970: 0),
            content: .userImages(count: 1),
            images: [image]
        )]
        // Saving before the metadata exists exercises the original embedded format.
        try await storage.saveTranscript(items, for: current.id)
        try await storage.saveCurrent(current)
        #expect(try await storage.loadTranscript(for: current.id) == items)
        try await storage.saveSession(current, transcript: items, streamingText: "")
        let reopened = FileWorkspaceRepository(root: root)
        #expect(try await reopened.loadTranscript(for: current.id) == items)
    }
}
