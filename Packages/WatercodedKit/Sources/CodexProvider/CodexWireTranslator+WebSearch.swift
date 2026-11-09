import AgentKit
import WatercodedCore

extension CodexWireTranslator {
    /// Search items may start with an empty query; completion carries the authoritative details.
    static func webSearchDetails(_ item: JSONValue) -> (summary: String, input: JSONValue) {
        var input: [String: JSONValue] = [:]
        let query = item["query"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if let query {
            input["query"] = .string(query)
        }
        let action = item["action"]
        if let action, action != .null {
            input["action"] = action
        }
        let queries = action?["queries"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        let actionQuery = action?["query"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let querySummary: String? = queries.isEmpty ? nil : queries.joined(separator: ", ")
        let summary = query ?? actionQuery ?? querySummary ?? action?["url"]?.string ?? "Searching the web"
        return (summary, .object(input))
    }

    static func webSearchCompleted(_ item: JSONValue, id: String, failed: Bool) -> [AgentEvent] {
        let details = Self.webSearchDetails(item)
        let results = item["results"]?.array
        let output = if let results, !results.isEmpty {
            JSONValue.array(results).prettyString()
        } else {
            "Codex did not provide search results for this call."
        }
        return [
            .toolCallUpdated(callID: id, summary: details.summary, input: details.input),
            .toolCallFinished(callID: id, output: output, isError: failed)
        ]
    }
}
