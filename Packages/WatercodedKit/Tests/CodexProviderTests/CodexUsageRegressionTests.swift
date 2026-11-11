import AgentKit
import Testing
import WatercodedCore
@testable import CodexProvider

@Suite("Codex cumulative usage")
struct CodexUsageRegressionTests {
    @Test func `repeated usage does not count the previous response twice`() {
        var translator = CodexWireTranslator()
        func update(total: Int, last: Int) -> JSONValue {
            ["method": "thread/tokenUsage/updated", "params": ["tokenUsage": [
                "total": ["outputTokens": .number(Double(total))],
                "last": ["outputTokens": .number(Double(last)), "totalTokens": 1000]
            ]]]
        }
        let first = translator.translate(update(total: 588, last: 588))
        let repeated = translator.translate(update(total: 588, last: 588))
        let next = translator.translate(update(total: 901, last: 313))
        #expect(first.contains(.generationFinished(outputTokens: 588)))
        #expect(!repeated.contains {
            if case .generationFinished = $0 {
                true
            } else {
                false
            }
        })
        #expect(next.contains(.generationFinished(outputTokens: 313)))
    }

    @Test func `replaying cumulative history establishes a baseline for subsequent output`() {
        var translator = CodexWireTranslator()
        let replay: JSONValue = ["method": "thread/tokenUsage/updated", "params": ["tokenUsage": [
            "total": ["outputTokens": 10000], "last": ["outputTokens": 100]
        ]]]
        _ = translator.translate(replay)
        let events = translator.translate(replay)
        #expect(!events.contains {
            if case .generationFinished = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func `unused diff notifications are disabled during initialization`() {
        let capabilities = CodexRequests.initialize()["capabilities"]
        #expect(capabilities?["optOutNotificationMethods"]?.array == [.string("turn/diff/updated")])
    }
}
