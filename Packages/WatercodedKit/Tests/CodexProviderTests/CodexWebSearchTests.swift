import AgentKit
import Testing
import WatercodedCore
@testable import CodexProvider

/// Synthetic items based on codex-cli 0.167.0's generated app-server protocol.
@Suite("Codex web searches")
struct CodexWebSearchTests {
    @Test func `completion supplies details missing at the start`() {
        var translator = CodexWireTranslator()
        let started = translator.translate([
            "method": "item/started",
            "params": ["item": ["type": "webSearch", "id": "w", "query": "", "action": nil]]
        ])
        guard case let .toolCallStarted(call)? = started.first else {
            Issue.record("Expected a web search")
            return
        }
        #expect(call.summary == "Searching the web")
        let action: JSONValue = ["type": "search", "query": "Swift news", "queries": ["Swift news", "Swift release"]]
        let completed = translator.translate([
            "method": "item/completed",
            "params": ["item": [
                "type": "webSearch",
                "id": "w",
                "query": "Swift news",
                "action": action,
                "results": nil
            ]]
        ])
        #expect(completed.contains(.toolCallUpdated(
            callID: "w", summary: "Swift news", input: ["query": "Swift news", "action": action]
        )))
        #expect(completed.contains(.toolCallFinished(
            callID: "w", output: "Codex did not provide search results for this call.", isError: false
        )))
    }

    @Test(arguments: [
        JSONValue.object(["type": "openPage", "url": "https://example.com"]),
        JSONValue.object(["type": "findInPage", "url": "https://example.com", "pattern": "Swift"]),
        JSONValue.object(["type": "search", "queries": ["Swift", "macOS"]])
    ])
    func `actions are preserved even without a top-level query`(action: JSONValue) throws {
        var translator = CodexWireTranslator()
        let events = translator.translate([
            "method": "item/started",
            "params": ["item": ["type": "webSearch", "id": "w", "query": "", "action": action]]
        ])
        let call = try #require(events.compactMap {
            if case let .toolCallStarted(call) = $0 {
                call
            } else {
                nil
            }
        }.first)
        #expect(call.kind == .web)
        #expect(call.input["action"] == action)
        #expect(call.summary == (action["url"]?.string ?? "Swift, macOS"))
    }

    @Test func `structured results pass through without losing unknown fields`() {
        var translator = CodexWireTranslator()
        let results: JSONValue = [["title": "Example", "url": "https://example.com", "newField": ["text": "Snippet"]]]
        let events = translator.translate([
            "method": "item/completed",
            "params": ["item": ["type": "webSearch", "id": "w", "query": "Example", "results": results]]
        ])
        #expect(events.contains(.toolCallFinished(callID: "w", output: results.prettyString(), isError: false)))
    }

    @Test(arguments: [JSONValue.null, JSONValue.array([])])
    func `missing results get an explanation`(results: JSONValue) {
        var translator = CodexWireTranslator()
        let events = translator.translate([
            "method": "item/completed",
            "params": ["item": ["type": "webSearch", "id": "w", "query": "Example", "results": results]]
        ])
        #expect(events.contains(.toolCallFinished(
            callID: "w", output: "Codex did not provide search results for this call.", isError: false
        )))
    }
}
