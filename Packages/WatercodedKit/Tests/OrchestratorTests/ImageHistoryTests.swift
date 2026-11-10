import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Image history")
struct ImageHistoryTests {
    @Test func `sent images reach the provider and remain in saved history`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-image-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FileWorkspaceRepository(root: root)
        let session = ImageCaptureSession()
        let current = Current(
            poolID: PoolID(),
            title: "Image",
            providerID: "image-test",
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
        let controller = CurrentController(
            current: current,
            transcript: [],
            provider: ImageCaptureProvider(session: session),
            repository: storage
        )
        defer { controller.discard() }
        let image = ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]), filename: "screenshot.png")
        #expect(await controller.submitPrompt("Look at this", images: [image]))
        #expect(await session.received?.images == [image])
        await controller.flush()
        let saved = try await storage.loadTranscript(for: controller.id)
        #expect(saved.first?.content == .userImages(count: 1))
        #expect(saved.first?.images == [image])
        let restored = CurrentController(current: current, transcript: saved, provider: nil, repository: storage)
        defer { restored.discard() }
        #expect(restored.transcript.first?.images == [image])
        await controller.stopSession()
    }

    @Test func `image records stay with the right turn when branching`() {
        let image = ImageAttachment(mediaType: "image/png", data: Data([1]), filename: "screen.png")
        let first = TranscriptItem(content: .user(text: "First"))
        let reply = TranscriptItem(content: .assistant(text: "Done"))
        let attachments = TranscriptItem(content: .userImages(count: 1), images: [image])
        let second = TranscriptItem(content: .user(text: "Second"))
        let items = [first, reply, attachments, second]
        var current = Current(
            poolID: PoolID(),
            title: "Turns",
            providerID: "image-test",
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
        current.turnSnapshots = [first, second].enumerated().map { index, item in
            var snapshot = TurnSnapshot(index: index + 1, startedAt: .now, beforeCommit: "before", afterCommit: "after")
            snapshot.userMessageID = item.id
            return snapshot
        }
        #expect(Workspace.transcript(items, upTo: first.id, in: current, .after) == [first, reply])
        #expect(Workspace.transcript(items, upTo: second.id, in: current, .before) == [first, reply])
        #expect(Workspace.transcript(items, upTo: second.id, in: current, .after) == items)
        #expect(Workspace.images(before: second.id, in: items) == [image])
        #expect(Workspace.images(before: first.id, in: items).isEmpty)
    }
}

private struct ImageCaptureProvider: AgentProvider {
    let session: ImageCaptureSession
    let descriptor = ProviderDescriptor(
        id: "image-test",
        displayName: "Image",
        symbolName: "",
        tintHue: 0,
        capabilities: [.images],
        models: [],
        installHint: ""
    )
    func availability() async -> ProviderAvailability {
        .available(version: nil)
    }

    func startSession(_: SessionConfiguration) async throws -> any AgentSession {
        session
    }
}

private actor ImageCaptureSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    var received: UserMessage?
    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ message: UserMessage) async throws {
        received = message
    }

    func respond(to _: String, with _: PermissionDecision) async throws {}
    func interrupt() async throws {}
    func terminate() async {
        continuation.finish()
    }
}
