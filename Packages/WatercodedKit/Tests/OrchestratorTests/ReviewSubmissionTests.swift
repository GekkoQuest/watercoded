import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Review submission")
struct ReviewSubmissionTests {
    @Test func `accepted reviews clear only submitted comments and cannot be sent twice`() async throws {
        let session = ReviewSession()
        let current = Current(
            poolID: PoolID(),
            title: "Review",
            providerID: "review-test",
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD")
        )
        let controller = CurrentController(
            current: current,
            transcript: [],
            provider: ReviewProvider(session: session),
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        controller.addReviewComment(ReviewComment(path: "one", lines: "1", excerpt: nil, text: "First"))
        let sending = Task { await controller.sendReview(summary: "Summary") }
        try await waitUntil { controller.isSendingReview }
        let newer = ReviewComment(path: "two", lines: "2", excerpt: nil, text: "Newer")
        controller.addReviewComment(newer)
        #expect(await controller.sendReview() == false)
        await session.release()
        #expect(await sending.value)
        #expect(controller.reviewComments == [newer])
        #expect(!controller.isSendingReview)
        #expect(await session.messages.count == 1)
        #expect(await session.messages.first?.contains("Summary") == true)
        await controller.stopSession()
    }
}

private struct ReviewProvider: AgentProvider {
    let session: ReviewSession
    let descriptor = ProviderDescriptor(
        id: "review-test",
        displayName: "Review",
        symbolName: "",
        tintHue: 0,
        capabilities: [],
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

private actor ReviewSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent> = AsyncStream { _ in }
    private let gate: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    var messages: [String] = []

    init() {
        (gate, continuation) = AsyncStream.makeStream()
    }

    func send(_ message: UserMessage) async throws {
        messages.append(message.text)
        for await _ in gate {
            break
        }
    }

    func release() {
        continuation.yield(())
        continuation.finish()
    }

    func respond(to _: String, with _: PermissionDecision) async throws {}
    func interrupt() async throws {}
    func terminate() async {
        continuation.finish()
    }
}
