import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import CodexProvider

@Suite("Codex questions")
struct CodexQuestionTests {
    @Test func `async question metadata becomes a card instead of plain text`() throws {
        // Same item shape as the dropped request_user_input_async question from 0.167.0.
        let url = try #require(Bundle.module.url(
            forResource: "async-question", withExtension: "jsonl", subdirectory: "Fixtures"
        ))
        var translator = CodexWireTranslator()
        _ = translator.turnRequested()
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").flatMap {
            try translator.translate(JSONValue(parsing: String($0)))
        }
        #expect(events.first == .asyncQuestionAsked(
            requestID: "codex-async-async-question",
            questions: [.init(text: "Which part should we work on next?", options: [
                .init(label: "Question boxes"), .init(label: "Slash commands")
            ])]
        ))
        #expect(events.contains(.messageCompleted(messageID: "follow-up", text: "Here is the question.")))
        #expect(events.contains(.turnFinished(.completed)))
        // No suspended server request exists for an async question.
        #expect(translator.consumeQuestion("codex-async-async-question") == nil)
    }

    @Test func `async free text questions need no options and malformed metadata preserves prose`() {
        var translator = CodexWireTranslator()
        let freeText = translator.translate([
            "method": "item/completed", "params": ["item": [
                "type": "agentMessage", "id": "free-text", "text": "Your preference?",
                "delivery": "async", "questions": [["title": "Your preference?", "options": .null]]
            ]]
        ])
        #expect(freeText == [.asyncQuestionAsked(
            requestID: "codex-async-free-text", questions: [.init(text: "Your preference?", options: [])]
        )])
        let malformed = translator.translate([
            "method": "item/completed", "params": ["item": [
                "type": "agentMessage", "id": "bad", "text": "Readable fallback", "questions": [["title": ""]]
            ]]
        ])
        #expect(malformed == [.messageCompleted(messageID: "bad", text: "Readable fallback")])
    }
}
