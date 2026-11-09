import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider
@testable import CodexProvider
@testable import Orchestrator

@MainActor
@Suite("Question cards")
struct QuestionFlowTests {
    @Test func `codex async metadata reaches an actionable card after the turn finishes`() async {
        let provider = QuestionProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        var translator = CodexWireTranslator()
        _ = translator.turnRequested()
        controller.handle(.turnStarted)
        for event in translator.translate([
            "method": "item/completed", "params": ["item": [
                "type": "agentMessage", "id": "question", "delivery": "async", "text": "Choose",
                "questions": [["title": "Which color?", "options": ["Red", "Blue"]]]
            ]]
        ]) {
            controller.handle(event)
        }
        #expect(controller.pendingAsyncQuestions.count == 1)
        #expect(controller.pendingQuestion == nil)
        #expect(!controller.isAwaitingUser, "An async question must not stop independent work")
        #expect(controller.current.status == .flowing)
        controller.handle(.turnFinished(.completed))
        let question = controller.pendingAsyncQuestions[0]
        #expect(question.questions[0].options.map(\.label) == ["Red", "Blue"])
        await controller.answer(["Which color?": "Blue"], requestID: question.requestID)
        #expect(controller.pendingAsyncQuestions.isEmpty)
        #expect(await provider.session.messages.map(\.text) == ["Which color?\nBlue"])
        #expect(await provider.session.rpcAnswers.isEmpty, "Async replies are input, not JSON-RPC responses")
        let stored = controller.transcript.compactMap { item -> QuestionRecord? in
            guard case let .question(record) = item.content else { return nil }
            return record
        }
        #expect(stored.first?.answers == ["Which color?": "Blue"])
        await controller.stopSession()
    }

    @Test func `multiple async cards remain independent and replay does not duplicate them`() async {
        let provider = QuestionProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        let first = AgentEvent.asyncQuestionAsked(requestID: "one", questions: [.init(text: "First?", options: [])])
        controller.handle(first)
        controller.handle(.asyncQuestionAsked(requestID: "two", questions: [.init(text: "Second?", options: [])]))
        controller.handle(first)
        #expect(controller.pendingAsyncQuestions.map(\.requestID) == ["one", "two"])
        #expect(controller.transcript.count == 2)
        await controller.answer(["Second?": "My own answer"], requestID: "two")
        #expect(controller.pendingAsyncQuestions.map(\.requestID) == ["one"])
        #expect(await provider.session.messages.map(\.text) == ["Second?\nMy own answer"])
        await controller.stopSession()
    }

    @Test func `claude questions remain blocking and use the permission response answer path`() async {
        let provider = QuestionProvider()
        let controller = makeController(provider)
        controller.session = provider.session
        defer { controller.discard() }
        var translator = ClaudeWireTranslator()
        let events = translator.translate([
            "type": "control_request", "request_id": "claude-question", "request": [
                "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [[
                    "question": "Pick features", "multiSelect": true,
                    "options": [["label": "Search"], ["label": "Export"]]
                ]]]
            ]
        ])
        for event in events {
            controller.handle(event)
        }
        #expect(controller.isAwaitingUser)
        #expect(controller.current.status == .waiting)
        #expect(controller.pendingQuestion?.questions.first?.allowsMultiple == true)
        await controller.answer(["Pick features": "Search, Export"], requestID: "claude-question")
        #expect(controller.pendingQuestion == nil)
        #expect(!controller.isAwaitingUser)
        #expect(await provider.session.messages.isEmpty)
        #expect(await provider.session.rpcAnswers == [["Pick features": "Search, Export"]])
    }

    @Test func `async cards survive restoration and failed answer delivery`() async throws {
        let provider = QuestionProvider(session: QuestionSession(failsToSend: true))
        let record = QuestionRecord(
            requestID: "saved", questions: [.init(text: "Your preference?", options: [])], isAsynchronous: true
        )
        let restored = try JSONDecoder().decode(QuestionRecord.self, from: JSONEncoder().encode(record))
        let controller = makeController(provider, transcript: [TranscriptItem(content: .question(restored))])
        defer { controller.discard() }
        #expect(controller.pendingAsyncQuestions == [record])
        await controller.answer(["Your preference?": "Custom"], requestID: "saved")
        #expect(controller.pendingAsyncQuestions == [record], "A failed send must leave the card answerable")
        await controller.stopSession()
    }

    @Test func `old question transcripts still decode as blocking`() throws {
        let data = Data(#"{"requestID":"old","questions":[],"answers":null}"#.utf8)
        #expect(try !JSONDecoder().decode(QuestionRecord.self, from: data).isAsynchronous)
    }

    private func makeController(_ provider: QuestionProvider, transcript: [TranscriptItem] = []) -> CurrentController {
        CurrentController(
            current: Current(
                poolID: PoolID(), title: "Questions", providerID: provider.descriptor.id, model: nil,
                permissionMode: .ask,
                channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "abc")
            ), transcript: transcript, provider: provider,
            repository: FileWorkspaceRepository(root: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString))
        )
    }
}

private struct QuestionProvider: AgentProvider {
    var session = QuestionSession()
    let descriptor = ProviderDescriptor(
        id: ProviderID(rawValue: "questions"), displayName: "Questions", symbolName: "questionmark", tintHue: 0,
        capabilities: [.questions, .queueing], models: [], installHint: ""
    )

    func availability() async -> ProviderAvailability {
        .available(version: nil)
    }

    func startSession(_: SessionConfiguration) async throws -> any AgentSession {
        session
    }
}

private actor QuestionSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    let failsToSend: Bool
    var messages: [UserMessage] = []
    var rpcAnswers: [[String: String]] = []

    init(failsToSend: Bool = false) {
        self.failsToSend = failsToSend
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ message: UserMessage) async throws {
        if failsToSend {
            throw AgentError.sessionClosed
        }
        messages.append(message)
    }

    func answer(_: String, with answers: [String: String]) async throws {
        rpcAnswers.append(answers)
    }

    func respond(to _: PermissionRequest.ID, with _: PermissionDecision) async throws {}
    func interrupt() async throws {}
    func terminate() async {
        continuation.finish()
    }
}
