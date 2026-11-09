import AgentKit
import WatercodedCore

extension CodexRequests {
    /// Shapes from codex-cli 0.167.0's generated app-server protocol (ADR 0011).
    static func command(_ command: SessionCommand, threadID: String) -> (method: String, params: JSONValue) {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        let method: String
        switch command {
        case .compact:
            method = "thread/compact/start"
        case .goal(.status):
            method = "thread/goal/get"
        case let .goal(.set(objective)):
            method = "thread/goal/set"
            params["objective"] = .string(objective)
            params["status"] = "active"
            params["origin"] = "user"
        case .goal(.clear):
            method = "thread/goal/clear"
            params["origin"] = "user"
        }
        return (method, .object(params))
    }

    static func goalSummary(_ result: JSONValue) -> String {
        guard let goal = result["goal"], let objective = goal["objective"]?.string else {
            return "No goal is set. Use /goal <objective> to start one."
        }
        return "Goal (\(goal["status"]?.string ?? "unknown")): \(objective)\n"
            + "Tokens used: \(goal["tokensUsed"]?.int ?? 0). Time used: \(goal["timeUsedSeconds"]?.int ?? 0) seconds."
    }
}
