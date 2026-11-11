import AgentKit
import Foundation
import WatercodedCore

/// Translates `codex app-server` notifications and server requests (JSON-RPC, protocol v2) into
/// ``AgentEvent``s. Pure apart from the state it keeps; ``CodexSession`` owns the process and I/O.
///
/// Verified against codex-cli 0.167.0 (see docs/adr/0011-codex-provider.md). A turn can end with
/// `turn/completed` or the thread becoming `idle`; accept either without finishing twice.
struct CodexWireTranslator {
    /// An approval Codex is waiting on: the JSON-RPC request to answer, and what kind it is.
    struct PendingApproval: Equatable {
        enum Kind: Equatable { case command, fileChange, mcpTool }

        let rpcID: JSONValue
        let kind: Kind
    }

    private(set) var threadID: String?
    /// The thread's model, needed to switch between plan and default collaboration modes.
    private(set) var model: String?
    /// The thread's working folder (for sandbox roots after reattaching).
    private(set) var cwd: String?
    private(set) var currentTurnID: String?
    private(set) var isTurnActive = false
    private var failure: String?
    private var interruptRequested = false
    /// Whether the model is producing output right now (for tokens-per-second timing).
    private var isGenerating = false
    private var usage = UsageSnapshot()
    private var totalOutputTokens: Int?
    private var pendingApprovals: [String: PendingApproval] = [:]
    /// File paths of in-progress file changes, so their approvals can say what they touch.
    private var fileChangePaths: [String: [String]] = [:]
    /// The plan a plan-mode turn produced, proposed when the turn ends.
    private var proposedPlan: String?
    private var pendingPlanID: String?
    /// Questions Codex is waiting on: the JSON-RPC request, and question text → Codex's question id.
    private var pendingQuestions: [String: (rpcID: JSONValue, ids: [String: String])] = [:]
    /// MCP forms waiting for the user: their JSON-RPC request.
    private var pendingForms: [String: JSONValue] = [:]

    // MARK: Driven by the session

    /// The session started a turn (or steered one). Starts generation timing.
    mutating func turnRequested() -> [AgentEvent] {
        if !isTurnActive {
            isTurnActive = true
            failure = nil
            interruptRequested = false
        }
        isGenerating = true
        return [.turnStarted, .generationStarted]
    }

    /// Restarts generation timing when the model resumes, at most once until it next reports usage.
    private mutating func resumeGenerating() -> [AgentEvent] {
        guard !isGenerating else { return [] }
        isGenerating = true
        return [.generationStarted]
    }

    mutating func interruptWasRequested() {
        interruptRequested = true
    }

    mutating func threadOpened(_ result: JSONValue) -> [AgentEvent] {
        guard let thread = result["thread"], let id = thread["id"]?.string else { return [] }
        threadID = id
        let model = result["model"]?.string ?? thread["model"]?.string
        self.model = model
        cwd = result["cwd"]?.string ?? thread["cwd"]?.string
        let instructions = result["instructionSources"]?.array?.compactMap(\.string) ?? []
        return [
            .sessionStarted(SessionInfo(providerSessionID: id, model: model)),
            .environmentReported(AgentEnvironment(
                version: thread["cliVersion"]?.string,
                model: model,
                memoryFiles: instructions
            ))
        ]
    }

    mutating func consumeApproval(_ requestID: String) -> PendingApproval? {
        pendingApprovals.removeValue(forKey: requestID)
    }

    /// Whether `requestID` is the plan proposed at the end of the last plan-mode turn.
    mutating func consumePlan(_ requestID: String) -> Bool {
        guard pendingPlanID == requestID else { return false }
        pendingPlanID = nil
        return true
    }

    mutating func consumeQuestion(_ requestID: String) -> (rpcID: JSONValue, ids: [String: String])? {
        pendingQuestions.removeValue(forKey: requestID)
    }

    mutating func consumeForm(_ requestID: String) -> JSONValue? {
        pendingForms.removeValue(forKey: requestID)
    }

    mutating func modelChanged(to model: String?) {
        if let model {
            self.model = model
        }
    }

    /// Server requests Watercoded answers through the UI. Anything else gets an error reply.
    static func handlesServerRequest(_ method: String) -> Bool {
        [
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput",
            "mcpServer/elicitation/request"
        ].contains(method)
    }

    // MARK: Incoming messages

    mutating func translate(_ message: JSONValue) -> [AgentEvent] {
        guard let method = message["method"]?.string else { return [] }
        let params = message["params"] ?? [:]
        if let rpcID = message["id"] {
            return translateServerRequest(method, id: rpcID, params: params)
        }
        switch method {
        case "turn/started":
            currentTurnID = params["turn"]?["id"]?.string ?? currentTurnID
            // Compaction and native goal continuations can start without a host turn/start request.
            return isTurnActive ? [] : turnRequested()
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string else { return [] }
            return [.textDelta(messageID: itemID, text: delta)]
        case "item/started":
            return itemStarted(params["item"])
        case "item/completed":
            return itemCompleted(params["item"])
        case "turn/plan/updated":
            return [.tasksUpdated(Self.tasks(from: params["plan"]))]
        case "thread/tokenUsage/updated":
            return tokenUsage(params["tokenUsage"])
        case "account/rateLimits/updated":
            return rateLimits(params["rateLimits"])
        case "error":
            return error(params)
        case "thread/status/changed":
            guard params["status"]?["type"]?.string == "idle", isTurnActive else { return [] }
            return finishTurn(status: nil)
        case "turn/completed":
            guard isTurnActive else { return [] }
            return finishTurn(status: params["turn"]?["status"]?.string)
        default:
            return []
        }
    }

    // MARK: Items

    private mutating func itemStarted(_ item: JSONValue?) -> [AgentEvent] {
        guard let item, let id = item["id"]?.string else { return [] }
        switch item["type"]?.string {
        case "agentMessage", "reasoning":
            return resumeGenerating()
        case "commandExecution":
            let command = Self.unwrapShell(item["command"]?.string ?? "")
            return [.toolCallStarted(ToolCall(
                callID: id, name: "Shell", kind: .shell, summary: command, input: ["command": .string(command)]
            ))]
        case "fileChange":
            let paths = item["changes"]?.array?.compactMap { $0["path"]?.string } ?? []
            fileChangePaths[id] = paths
            return [.toolCallStarted(ToolCall(
                callID: id, name: "Edit", kind: .edit, summary: Self.describe(paths),
                input: ["file_path": .string(paths.first ?? ""), "paths": .array(paths.map { .string($0) })]
            ))]
        case "mcpToolCall":
            let server = item["server"]?.string ?? "mcp"
            let tool = item["tool"]?.string ?? "tool"
            return [.toolCallStarted(ToolCall(
                callID: id, name: "\(server).\(tool)", kind: .mcp, summary: "\(server): \(tool)",
                input: item["arguments"] ?? [:]
            ))]
        case "dynamicToolCall":
            let tool = item["tool"]?.string ?? "tool"
            return [.toolCallStarted(ToolCall(
                callID: id, name: tool, kind: .other, summary: tool, input: item["arguments"] ?? [:]
            ))]
        case "webSearch":
            let details = Self.webSearchDetails(item)
            return [.toolCallStarted(ToolCall(
                callID: id, name: "Web search", kind: .web, summary: details.summary, input: details.input
            ))]
        case "collabAgentToolCall":
            let prompt = item["prompt"]?.string ?? "Delegating to another agent"
            return [.toolCallStarted(ToolCall(
                callID: id, name: "Agent", kind: .subagent, summary: String(prompt.prefix(200)), input: [:]
            ))]
        default:
            return []
        }
    }

    private mutating func itemCompleted(_ item: JSONValue?) -> [AgentEvent] {
        guard let item, let id = item["id"]?.string else { return [] }
        let status = item["status"]?.string
        let failed = status == "failed" || status == "declined"
        switch item["type"]?.string {
        case "agentMessage":
            let questions = Self.asyncQuestions(item)
            if !questions.isEmpty {
                return [.asyncQuestionAsked(requestID: "codex-async-\(id)", questions: questions)]
            }
            return [.messageCompleted(messageID: id, text: item["text"]?.string ?? "")]
        case "plan":
            proposedPlan = item["text"]?.string
            return []
        case "reasoning":
            let parts = (item["summary"]?.array ?? []) + (item["content"]?.array ?? [])
            let text = parts.compactMap(\.string).joined(separator: "\n\n")
            return text.isEmpty ? [] : [.thinking(messageID: id, text: text, estimatedTokens: nil)]
        case "commandExecution":
            let exitCode = item["exitCode"]?.int
            var output = item["aggregatedOutput"]?.string ?? ""
            if status == "declined", output.isEmpty {
                output = "Declined."
            }
            // The model picks up again with the result.
            return [.toolCallFinished(callID: id, output: output, isError: failed || (exitCode ?? 0) != 0)]
                + resumeGenerating()
        case "fileChange":
            fileChangePaths[id] = nil
            let diffs = item["changes"]?.array?.compactMap { $0["diff"]?.string } ?? []
            let output = status == "declined" ? "Declined." : diffs.joined(separator: "\n")
            return [.toolCallFinished(callID: id, output: output, isError: failed)] + resumeGenerating()
        case "webSearch":
            return Self.webSearchCompleted(item, id: id, failed: failed) + resumeGenerating()
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            let output = item["result"].map { $0.compactString() } ?? item["contentItems"]
                .map { $0.compactString() } ?? ""
            return [.toolCallFinished(callID: id, output: output, isError: failed || item["success"]?.bool == false)]
                + resumeGenerating()
        case "contextCompaction":
            return [.contextCompacted(preTokens: nil, postTokens: nil)]
        default:
            return []
        }
    }

    // MARK: Approvals

    private mutating func translateServerRequest(_ method: String, id rpcID: JSONValue, params: JSONValue)
        -> [AgentEvent] {
        let requestID = "codex-\(rpcID.compactString())"
        switch method {
        case "item/commandExecution/requestApproval":
            pendingApprovals[requestID] = PendingApproval(rpcID: rpcID, kind: .command)
            let command = Self.unwrapShell(params["command"]?.string ?? "")
            return [.permissionRequested(PermissionRequest(
                id: requestID,
                toolName: "Shell",
                kind: .shell,
                summary: params["reason"]?.string ?? command,
                input: ["command": .string(command)],
                subject: command.isEmpty ? nil : command
            ))]
        case "item/fileChange/requestApproval":
            pendingApprovals[requestID] = PendingApproval(rpcID: rpcID, kind: .fileChange)
            let paths = params["itemId"]?.string.flatMap { fileChangePaths[$0] } ?? []
            return [.permissionRequested(PermissionRequest(
                id: requestID,
                toolName: "Edit",
                kind: .edit,
                summary: params["reason"]?.string ?? Self.describe(paths),
                input: ["file_path": .string(paths.first ?? ""), "paths": .array(paths.map { .string($0) })],
                subject: paths.first
            ))]
        case "item/tool/requestUserInput":
            return questions(params, rpcID: rpcID, requestID: requestID)
        case "mcpServer/elicitation/request":
            return elicitation(params, rpcID: rpcID, requestID: requestID)
        default:
            return []
        }
    }

    /// MCP elicitations. Codex also routes its own MCP tool-call approvals through these
    /// (`_meta.codex_approval_kind: mcp_tool_call`, an empty form), so those become ordinary approvals.
    /// Returns no events for modes Watercoded can't show (the session then declines).
    private mutating func elicitation(_ params: JSONValue, rpcID: JSONValue, requestID: String) -> [AgentEvent] {
        let server = params["serverName"]?.string
        let meta = params["_meta"]
        if meta?["codex_approval_kind"]?.string == "mcp_tool_call" {
            pendingApprovals[requestID] = PendingApproval(rpcID: rpcID, kind: .mcpTool)
            let tool = meta?["tool_name"]?.string ?? "tool"
            return [.permissionRequested(PermissionRequest(
                id: requestID,
                toolName: "\(server ?? "mcp").\(tool)",
                kind: .mcp,
                summary: params["message"]?.string ?? "Run \(tool)?",
                input: meta?["tool_params"] ?? [:]
            ))]
        }
        let message = params["message"]?.string ?? "An MCP server needs your input."
        let form: FormRecord
        switch params["mode"]?.string {
        case "form", "openai/form", "openaiForm":
            form = FormRecord(
                requestID: requestID, serverName: server, message: message,
                fields: FormRecord.fields(from: params["requestedSchema"])
            )
        case "url":
            guard let url = params["url"]?.string.flatMap(URL.init(string:)) else { return [] }
            form = FormRecord(requestID: requestID, serverName: server, message: message, url: url)
        default:
            return [] // e.g. openai/userVerification
        }
        pendingForms[requestID] = rpcID
        return [.formRequested(form)]
    }

    /// Codex's `request_user_input` tool (mainly in plan mode): headed questions with labelled options.
    private mutating func questions(_ params: JSONValue, rpcID: JSONValue, requestID: String) -> [AgentEvent] {
        var ids: [String: String] = [:]
        let questions = (params["questions"]?.array ?? []).compactMap { question -> QuestionRecord.Question? in
            guard let text = question["question"]?.string, let id = question["id"]?.string else { return nil }
            ids[text] = id
            let options = (question["options"]?.array ?? []).compactMap { option -> QuestionRecord.Question.Option? in
                option["label"]?.string.map { QuestionRecord.Question.Option(
                    label: $0,
                    detail: option["description"]?.string
                ) }
            }
            return QuestionRecord.Question(text: text, header: question["header"]?.string, options: options)
        }
        guard !questions.isEmpty else { return [] }
        pendingQuestions[requestID] = (rpcID, ids)
        return [.questionAsked(requestID: requestID, questions: questions)]
    }

    // MARK: Usage and turn lifecycle

    private mutating func error(_ params: JSONValue) -> [AgentEvent] {
        let message = params["error"]?["message"]?.string ?? "Codex reported an error."
        if params["willRetry"]?.bool == true {
            return [.notice(Notice(.warning, "\(message) Retrying…"))]
        }
        failure = message
        return []
    }

    private mutating func finishTurn(status: String?) -> [AgentEvent] {
        isTurnActive = false
        isGenerating = false
        let outcome: TurnOutcome = if let failure {
            .failed(message: failure)
        } else if interruptRequested || status == "interrupted" {
            .interrupted
        } else if status == "failed" {
            .failed(message: "The turn failed.")
        } else {
            .completed
        }
        var events: [AgentEvent] = []
        if let currentTurnID {
            events.append(.checkpoint(currentTurnID)) // `thread/fork` can fork through this turn
        }
        if outcome == .completed, let plan = proposedPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty {
            // Like Codex's own "Implement this plan?": Build starts coding, feedback keeps planning.
            let id = "codex-plan-\(currentTurnID ?? UUID().uuidString)"
            pendingPlanID = id
            events.append(.planProposed(requestID: id, markdown: plan))
        }
        proposedPlan = nil
        events += [.usageUpdated(usage), .turnFinished(outcome)]
        failure = nil
        interruptRequested = false
        return events
    }
}

extension CodexWireTranslator {
    private mutating func tokenUsage(_ value: JSONValue?) -> [AgentEvent] {
        guard let last = value?["last"] else { return [] }
        if let window = value?["modelContextWindow"]?.int {
            usage.contextWindow = window
        }
        usage.contextTokens = last["totalTokens"]?.int ?? usage.contextTokens
        let tokens: Int
        if let total = value?["total"]?["outputTokens"]?.int {
            usage.outputTokens = total
            guard total != totalOutputTokens else { return [.usageUpdated(usage)] }
            tokens = totalOutputTokens.map { total >= $0 ? total - $0 : (last["outputTokens"]?.int ?? 0) }
                ?? (last["outputTokens"]?.int ?? 0)
            totalOutputTokens = total
        } else {
            tokens = last["outputTokens"]?.int ?? 0
        }
        isGenerating = false
        return [.generationFinished(outputTokens: tokens), .usageUpdated(usage)]
    }

    private mutating func rateLimits(_ value: JSONValue?) -> [AgentEvent] {
        guard let value else { return [] }
        if value["planType"]?.string != nil {
            usage.billing = .subscription
        }
        let windows = ["primary", "secondary"].compactMap { key -> PlanUsage.Window? in
            guard let window = value[key], let used = window["usedPercent"]?.double else { return nil }
            let minutes = window["windowDurationMins"]?.int
            return PlanUsage.Window(
                id: key,
                title: Self.windowTitle(minutes: minutes),
                utilization: used / 100,
                resetsAt: window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return windows.isEmpty ? [] : [.planUsageUpdated(PlanUsage(windows: windows))]
    }
}
