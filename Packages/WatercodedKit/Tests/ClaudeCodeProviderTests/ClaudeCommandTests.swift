import AgentKit
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

@Suite("Claude native commands")
struct ClaudeCommandTests {
    @Test func `commands use the documented noninteractive command surface`() {
        #expect(SessionCommand.compact.slashText == "/compact")
        #expect(SessionCommand.goal(.status).slashText == "/goal")
        #expect(SessionCommand.goal(.clear).slashText == "/goal clear")
        #expect(SessionCommand.goal(.set("Pass tests")).slashText == "/goal Pass tests")
    }

    @Test func `local command result text is visible`() {
        var translator = ClaudeWireTranslator()
        let result: JSONValue = ["type": "result", "subtype": "success", "result": "No goal set", "is_error": false]
        #expect(translator.translate(result).contains(.notice(Notice(.info, "No goal set"))))
    }

    @Test func `ordinary assistant results are not duplicated and next command output is visible`() {
        var translator = ClaudeWireTranslator()
        let assistant: JSONValue = [
            "type": "assistant", "message": ["id": "msg", "content": [["type": "text", "text": "Hello"]]]
        ]
        _ = translator.translate(assistant)
        let result: JSONValue = ["type": "result", "subtype": "success", "result": "Hello", "is_error": false]
        #expect(!translator.translate(result).contains(.notice(Notice(.info, "Hello"))))
        let command: JSONValue = ["type": "result", "subtype": "success", "result": "Goal cleared", "is_error": false]
        #expect(translator.translate(command).contains(.notice(Notice(.info, "Goal cleared"))))
    }
}
