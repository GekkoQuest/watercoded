import AgentKit
import Foundation
import WatercodedCore

/// Translates `claude --output-format stream-json` lines into normalized ``AgentEvent``s.
///
/// Pure and synchronous so it can be tested against recorded transcripts. Unknown message
/// types are ignored, which keeps sessions working as the CLI adds new ones.
struct ClaudeWireTranslator {
    /// Inputs of pending permission requests, needed to answer them (`updatedInput`).
    private(set) var pendingPermissionInputs: [String: JSONValue] = [:]
    private var announcedToolCalls = Set<String>()
    private var streamingMessageID: String?
    private var usage = UsageSnapshot()
    private var tasks = ClaudeTaskTracker()
    private var thinkingEstimate: Int?

    /// The main conversation's assistant lines carry the `uuid` that `--resume-session-at` accepts.
    private static func checkpoint(_ line: JSONValue) -> [AgentEvent] {
        guard line["parent_tool_use_id"]?.string == nil, let uuid = line["uuid"]?.string else { return [] }
        return [.checkpoint(uuid)]
    }

    mutating func translate(_ message: JSONValue) -> [AgentEvent] {
        switch message["type"]?.string {
        case "system": translateSystem(message)
        case "stream_event":
            // Subagents stream too; only the main conversation's text is shown live.
            message["parent_tool_use_id"]?.string == nil ? translateStreamEvent(message["event"]) : []
        case "assistant":
            translateAssistant(message["message"], parentCallID: message["parent_tool_use_id"]?.string)
                + Self.checkpoint(message)
        case "user": translateUser(message["message"])
        case "control_response": translateControlResponse(message["response"])
        case "control_request": translateControlRequest(message)
        case "result": translateResult(message)
        case "rate_limit_event": translateRateLimit(message["rate_limit_info"])
        default: []
        }
    }

    mutating func consumePermissionInput(for requestID: String) -> JSONValue {
        pendingPermissionInputs.removeValue(forKey: requestID) ?? [:]
    }

    // MARK: Message types

    private mutating func translateSystem(_ message: JSONValue) -> [AgentEvent] {
        switch message["subtype"]?.string {
        case "compact_boundary":
            let metadata = message["compact_metadata"]
            let post = metadata?["post_tokens"]?.int
            var events: [AgentEvent] = [.contextCompacted(preTokens: metadata?["pre_tokens"]?.int, postTokens: post)]
            if let post {
                usage.contextTokens = post
                events.append(.usageUpdated(usage))
            }
            return events
        case "thinking_tokens":
            thinkingEstimate = message["estimated_tokens"]?.int ?? thinkingEstimate
            return []
        case "init":
            guard let sessionID = message["session_id"]?.string else { return [] }
            return [
                .sessionStarted(SessionInfo(
                    providerSessionID: sessionID,
                    model: message["model"]?.string,
                    billing: Self.billing(apiKeySource: message["apiKeySource"]?.string)
                )),
                .environmentReported(Self.environment(fromInit: message))
            ]
        case "permission_denied":
            let text = message["message"]?.string ?? "A tool call was denied."
            return [.notice(Notice(.warning, text))]
        default:
            return []
        }
    }

    private mutating func translateStreamEvent(_ event: JSONValue?) -> [AgentEvent] {
        guard let event else { return [] }
        switch event["type"]?.string {
        case "message_start":
            streamingMessageID = event["message"]?["id"]?.string
            return [.generationStarted]
        case "message_delta":
            // Carries the response's final output token count (thinking included).
            guard let tokens = event["usage"]?["output_tokens"]?.int else { return [] }
            return [.generationFinished(outputTokens: tokens)]
        case "content_block_delta":
            guard event["delta"]?["type"]?.string == "text_delta",
                  let text = event["delta"]?["text"]?.string,
                  let messageID = streamingMessageID
            else { return [] }
            return [.textDelta(messageID: messageID, text: text)]
        default:
            return []
        }
    }

    private mutating func translateAssistant(_ message: JSONValue?, parentCallID: String?) -> [AgentEvent] {
        guard let message else { return [] }
        let messageID = message["id"]?.string ?? UUID().uuidString
        var events: [AgentEvent] = []

        var text = ""
        for block in message["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                text += block["text"]?.string ?? ""
            case "thinking" where parentCallID == nil:
                events.append(.thinking(
                    messageID: messageID,
                    text: block["thinking"]?.string ?? "",
                    estimatedTokens: thinkingEstimate
                ))
                thinkingEstimate = nil
            case "tool_use":
                guard let callID = block["id"]?.string, announcedToolCalls.insert(callID).inserted else { continue }
                let name = block["name"]?.string ?? "Tool"
                let input = block["input"] ?? [:]
                if tasks.toolStarted(callID: callID, name: name, input: input) {
                    events.append(.tasksUpdated(tasks.items))
                }
                events.append(.toolCallStarted(ToolCall(
                    callID: callID,
                    name: name,
                    kind: ClaudeToolDescriber.kind(forTool: name),
                    summary: ClaudeToolDescriber.summary(forTool: name, input: input),
                    input: input,
                    parentCallID: parentCallID
                )))
            default:
                continue
            }
        }

        // A subagent's own prose and token counts belong to the subagent, not the main conversation.
        guard parentCallID == nil else { return events }
        if !text.isEmpty {
            events.insert(.messageCompleted(messageID: messageID, text: text), at: 0)
        }
        if let tokens = Self.contextTokens(from: message["usage"]) {
            usage.contextTokens = tokens
            usage.cacheTTL = Self.cacheTTL(from: message["usage"]) ?? usage.cacheTTL
            events.append(.usageUpdated(usage))
        }
        return events
    }

    private mutating func translateUser(_ message: JSONValue?) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for block in message?["content"]?.array ?? [] {
            guard block["type"]?.string == "tool_result", let callID = block["tool_use_id"]?.string else { continue }
            let output = Self.flattenToolOutput(block["content"])
            let isError = block["is_error"]?.bool ?? false
            events.append(.toolCallFinished(callID: callID, output: output, isError: isError))
            if tasks.toolFinished(callID: callID, output: output, isError: isError) {
                events.append(.tasksUpdated(tasks.items))
            }
        }
        return events
    }

    private mutating func translateControlRequest(_ message: JSONValue) -> [AgentEvent] {
        guard let requestID = message["request_id"]?.string,
              let request = message["request"],
              request["subtype"]?.string == "can_use_tool"
        else { return [] }
        let toolName = request["tool_name"]?.string ?? "Tool"
        let input = request["input"] ?? [:]
        pendingPermissionInputs[requestID] = input

        switch toolName {
        case "ExitPlanMode":
            return [.planProposed(requestID: requestID, markdown: input["plan"]?.string ?? "")]
        case "AskUserQuestion":
            let questions = Self.questions(from: input)
            if !questions.isEmpty {
                return [.questionAsked(requestID: requestID, questions: questions)]
            }
        default:
            break
        }

        let summary = request["description"]?.string ?? ClaudeToolDescriber.summary(forTool: toolName, input: input)
        return [.permissionRequested(PermissionRequest(
            id: requestID,
            toolName: toolName,
            kind: ClaudeToolDescriber.kind(forTool: toolName),
            summary: summary,
            input: input,
            subject: input["command"]?.string ?? input["file_path"]?.string ?? input["url"]?.string,
            suggestedRule: Self.suggestedRule(from: request["permission_suggestions"])
        ))]
    }

    private mutating func translateResult(_ message: JSONValue) -> [AgentEvent] {
        if let cost = message["total_cost_usd"]?.double {
            usage.costUSD += cost
        }
        if let window = message["modelUsage"]?.object?.values.compactMap({ $0["contextWindow"]?.int }).max() {
            usage.contextWindow = window
        }

        let outcome: TurnOutcome
        if message["is_error"]?.bool == true || message["subtype"]?.string?.hasPrefix("error") == true {
            let detail = message["result"]?.string ?? message["subtype"]?.string ?? "unknown error"
            outcome = .failed(message: detail)
        } else if message["terminal_reason"]?.string == "interrupted" || message["stop_reason"]?
            .string == "interrupted" {
            outcome = .interrupted
        } else {
            outcome = .completed
        }
        return [.usageUpdated(usage), .turnFinished(outcome)]
    }

    private func translateRateLimit(_ info: JSONValue?) -> [AgentEvent] {
        guard let windows = info?["unifiedWindows"]?.object, !windows.isEmpty else { return [] }
        let parsed = windows.keys.sorted(by: Self.windowOrder).compactMap { key -> PlanUsage.Window? in
            guard let window = windows[key], let utilization = window["utilization"]?.double else { return nil }
            return PlanUsage.Window(
                id: key,
                title: Self.windowTitle(key),
                utilization: utilization,
                resetsAt: window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return parsed.isEmpty ? [] : [.planUsageUpdated(PlanUsage(windows: parsed))]
    }

    private func translateControlResponse(_ response: JSONValue?) -> [AgentEvent] {
        if let commands = response?["response"]?["commands"]?.array {
            return [.commandsAvailable(commands.compactMap { command in
                guard let name = command["name"]?.string else { return nil }
                let hint = command["argumentHint"]?.string
                return SlashCommand(
                    name: name,
                    summary: command["description"]?.string ?? "",
                    argumentHint: hint?.isEmpty == false ? hint : nil
                )
            })]
        }
        guard response?["subtype"]?.string == "error" else { return [] }
        let detail = response?["error"]?.string ?? "unknown error"
        return [.notice(Notice(.warning, "The agent rejected a settings change: \(detail)"))]
    }

    // MARK: Helpers

    /// The first "add rule" suggestion Claude Code offers, in Watercoded's rule form.
    static func suggestedRule(from suggestions: JSONValue?) -> ApprovalRule? {
        for suggestion in suggestions?.array ?? [] where suggestion["type"]?.string == "addRules" {
            guard let rule = suggestion["rules"]?[0], let tool = rule["toolName"]?.string else { continue }
            let content = rule["ruleContent"]?.string
            return ApprovalRule(toolName: tool, pattern: content.map { $0.replacingOccurrences(of: ":*", with: " *") })
        }
        return nil
    }

    static func environment(fromInit message: JSONValue) -> AgentEnvironment {
        func names(_ value: JSONValue?) -> [String] {
            (value?.array ?? []).compactMap { $0.string ?? $0["name"]?.string ?? $0["path"]?.string }
        }
        let memory: [String] = if let object = message["memory_paths"]?.object {
            object.values.compactMap(\.string).sorted()
        } else {
            names(message["memory_paths"])
        }
        return AgentEnvironment(
            version: message["claude_code_version"]?.string,
            model: message["model"]?.string,
            mcpServers: (message["mcp_servers"]?.array ?? []).compactMap { server in
                server["name"]?.string.map { AgentEnvironment.Server(
                    name: $0,
                    status: server["status"]?.string ?? "unknown"
                ) }
            },
            tools: names(message["tools"]),
            skills: names(message["skills"]),
            plugins: names(message["plugins"]),
            memoryFiles: memory,
            agents: names(message["agents"])
        )
    }

    static func questions(from input: JSONValue) -> [QuestionRecord.Question] {
        (input["questions"]?.array ?? []).compactMap { question in
            guard let text = question["question"]?.string else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option -> QuestionRecord.Question.Option? in
                guard let label = option["label"]?.string else { return nil }
                return QuestionRecord.Question.Option(label: label, detail: option["description"]?.string)
            }
            return QuestionRecord.Question(
                text: text,
                header: question["header"]?.string,
                options: options,
                allowsMultiple: question["multiSelect"]?.bool ?? false
            )
        }
    }

    /// The prompt cache lives 1 hour when the CLI writes 1-hour cache entries, otherwise 5 minutes.
    static func cacheTTL(from usage: JSONValue?) -> TimeInterval? {
        let creation = usage?["cache_creation"]
        if (creation?["ephemeral_1h_input_tokens"]?.int ?? 0) > 0 {
            return 3600
        }
        if (creation?["ephemeral_5m_input_tokens"]?.int ?? 0) > 0 {
            return 300
        }
        return nil
    }

    /// `apiKeySource` is "none" when the CLI is signed in with a Claude subscription.
    static func billing(apiKeySource: String?) -> BillingMode? {
        guard let apiKeySource else { return nil }
        return apiKeySource == "none" ? .subscription : .apiKey
    }

    static func windowTitle(_ key: String) -> String {
        switch key {
        case "five_hour": "5-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func windowOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = ["five_hour", "seven_day", "seven_day_opus"]
        return (order.firstIndex(of: lhs) ?? order.count, lhs) < (order.firstIndex(of: rhs) ?? order.count, rhs)
    }

    /// Prompt tokens in context = fresh input + cache reads + cache writes.
    static func contextTokens(from usage: JSONValue?) -> Int? {
        guard let usage else { return nil }
        let parts = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .compactMap { usage[$0]?.int }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    static func flattenToolOutput(_ content: JSONValue?) -> String {
        switch content {
        case let .string(text)?:
            return text
        case let .array(blocks)?:
            return blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        case let other?:
            return other.prettyString()
        case nil:
            return ""
        }
    }
}
