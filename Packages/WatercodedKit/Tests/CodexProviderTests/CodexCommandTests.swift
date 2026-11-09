import AgentKit
import Testing
import WatercodedCore
@testable import CodexProvider

@Suite("Codex native commands")
struct CodexCommandTests {
    @Test func `compaction uses the native RPC without a model prompt`() {
        let rpc = CodexRequests.command(.compact, threadID: "thread")
        #expect(rpc.method == "thread/compact/start")
        #expect(rpc.params == ["threadId": "thread"])
    }

    @Test func `goal changes preserve explicit user provenance`() {
        let set = CodexRequests.command(.goal(.set("Pass tests")), threadID: "thread")
        #expect(set.method == "thread/goal/set")
        #expect(set.params == ["threadId": "thread", "objective": "Pass tests", "status": "active", "origin": "user"])
        let get = CodexRequests.command(.goal(.status), threadID: "thread")
        #expect(get.method == "thread/goal/get")
        #expect(get.params == ["threadId": "thread"])
        let clear = CodexRequests.command(.goal(.clear), threadID: "thread")
        #expect(clear.method == "thread/goal/clear")
        #expect(clear.params == ["threadId": "thread", "origin": "user"])
    }

    @Test func `server initiated compaction has a complete turn lifecycle`() {
        var translator = CodexWireTranslator()
        let start: JSONValue = ["method": "turn/started", "params": ["turn": ["id": "compact-turn"]]]
        #expect(translator.translate(start) == [.turnStarted, .generationStarted])
        #expect(translator.translate(start).isEmpty)
        #expect(translator.currentTurnID == "compact-turn")
        let compact: JSONValue = [
            "method": "item/completed", "params": ["item": ["id": "compact", "type": "contextCompaction"]]
        ]
        #expect(translator.translate(compact) == [.contextCompacted(preTokens: nil, postTokens: nil)])
        let end: JSONValue = ["method": "thread/status/changed", "params": ["status": ["type": "idle"]]]
        #expect(translator.translate(end).contains(.turnFinished(.completed)))
        #expect(!translator.isTurnActive)
    }
}
