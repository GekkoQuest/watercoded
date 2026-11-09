import Foundation
import WatercodedCore

/// The `watercoded` MCP server Watercoded gives each agent: one tool, `delegate`, that hands a task to
/// another agent (any provider and model) as a session of its own, and returns its final answer.
///
/// Runs as the app binary in a special mode (`Watercoded --delegate-mcp <current-id>`), speaking MCP over
/// stdio, and talks to the app through a ``DelegationMailbox``.
public enum DelegateMCPServer {
    public static let serverName = "watercoded"
    public static let toolName = "delegate"
    /// How long a delegated task may run before the tool gives up waiting.
    public static let timeout: Duration = .seconds(6 * 60 * 60)

    /// - Parameter agents: the provider ids the app can run (e.g. `claude-code`, `codex`), offered in the tool.
    public static func run(parentID: String, agents: [String], mailbox: DelegationMailbox = DelegationMailbox()) {
        while let line = readLine() {
            guard let message = try? JSONValue(parsing: line) else { continue }
            if let reply = handle(message, parentID: parentID, agents: agents, mailbox: mailbox) {
                print(reply.compactString())
                fflush(stdout)
            }
        }
    }

    /// The reply to one JSON-RPC message, or `nil` for notifications.
    static func handle(
        _ message: JSONValue,
        parentID: String,
        agents: [String],
        mailbox: DelegationMailbox
    ) -> JSONValue? {
        guard let id = message["id"] else { return nil }
        switch message["method"]?.string {
        case "initialize":
            return result(id, [
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(serverName), "version": "1"]
            ])
        case "tools/list":
            return result(id, ["tools": .array(tools(agents: agents))])
        case "tools/call":
            let arguments = message["params"]?["arguments"] ?? [:]
            let reply: JSONValue = switch message["params"]?["name"]?.string {
            case waitToolName: waitFor(ids(arguments), mailbox: mailbox)
            case checkToolName: check(ids(arguments), mailbox: mailbox)
            default: delegate(arguments, parentID: parentID, mailbox: mailbox)
            }
            return result(id, reply)
        case "ping":
            return result(id, [:])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    static let waitToolName = "wait_for_delegations"
    static let checkToolName = "check_delegations"

    static func tools(agents: [String]) -> [JSONValue] {
        let description = """
        Hand a task to another coding agent (\(agents.joined(separator: ", "))), with any model it supports, when \
        the user asks for a specific agent or model, a second opinion, or parallel help. The helper works in its own \
        copy of your folder (including your uncommitted changes) and appears in Watercoded as its own session; the \
        user answers its approvals there. When it finishes, its changes are applied to your folder (or, if you \
        changed the same lines meanwhile, left for you to merge, with instructions) and its final answer is \
        returned. By default this waits for the answer. Set wait to false to start several helpers at once and keep \
        working, then collect their answers with wait_for_delegations. Give each helper complete, self-contained \
        instructions: it doesn't see this conversation.
        """
        let properties: JSONValue = [
            "agent": [
                "type": "string",
                "enum": .array(agents.map { .string($0) }),
                "description": "Which agent, e.g. codex (OpenAI GPT models) or claude-code (Anthropic Claude models)."
            ],
            "model": [
                "type": "string",
                "description": "Model id or alias, e.g. gpt-6.1-sol or opus. Omit for the agent's default."
            ],
            "effort": ["type": "string", "description": "Reasoning effort, e.g. low, medium or high. Optional."],
            "task": ["type": "string", "description": "Complete instructions for the other agent."],
            "wait": [
                "type": "boolean",
                "description": "Wait for the answer (default). false returns a delegation id right away."
            ]
        ]
        let idsSchema: JSONValue = [
            "type": "object",
            "properties": ["ids": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Delegation ids returned by delegate with wait false."
            ]],
            "required": ["ids"]
        ]
        return [
            [
                "name": .string(toolName),
                "description": .string(description),
                "inputSchema": ["type": "object", "properties": properties, "required": ["agent", "task"]]
            ],
            [
                "name": .string(waitToolName),
                "description": "Waits until the given delegations finish and returns each helper's answer.",
                "inputSchema": idsSchema
            ],
            [
                "name": .string(checkToolName),
                "description": "Returns which delegations have finished (with answers), without waiting.",
                "inputSchema": idsSchema
            ]
        ]
    }

    private static func delegate(_ arguments: JSONValue, parentID: String, mailbox: DelegationMailbox) -> JSONValue {
        guard let agent = arguments["agent"]?.string, let task = arguments["task"]?.string,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolResult("`agent` and `task` are required.", isError: true)
        }
        let request = DelegationRequest(
            parentID: parentID, agent: agent,
            model: arguments["model"]?.string, effort: arguments["effort"]?.string, task: task,
            wait: arguments["wait"]?.bool
        )
        do {
            try mailbox.post(request)
        } catch {
            return toolResult("Couldn't reach Watercoded: \(error.localizedDescription)", isError: true)
        }
        // With wait false the app answers as soon as the helper has started.
        guard let response = poll({ mailbox.takeResponse(for: request.id) }) else {
            return toolResult(
                "The delegated agent didn't finish in time. Check its session in Watercoded.",
                isError: true
            )
        }
        return render(response)
    }

    private static func waitFor(_ ids: [String], mailbox: DelegationMailbox) -> JSONValue {
        guard !ids.isEmpty else { return toolResult("Pass the ids delegate returned.", isError: true) }
        let finished = poll { () -> [DelegationResponse]? in
            let results = ids.compactMap { mailbox.result(for: $0) }
            return results.count == ids.count ? results : nil
        }
        guard let finished else {
            return toolResult(
                "Not every delegation finished in time. Check their sessions in Watercoded.",
                isError: true
            )
        }
        return toolResult(finished.map(describe).joined(separator: "\n\n"), isError: false)
    }

    private static func check(_ ids: [String], mailbox: DelegationMailbox) -> JSONValue {
        let lines = ids.map { id in
            mailbox.result(for: id).map(describe) ?? "## \(id)\nStill working."
        }
        return toolResult(lines.joined(separator: "\n\n"), isError: false)
    }

    /// Polls until `value` returns something, the agent that started this server goes away, or the timeout.
    private static func poll<T>(_ value: () -> T?) -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if getppid() == 1 {
                exit(0) // the agent that started this server is gone: nobody is waiting for the answer
            }
            if let found = value() {
                return found
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private static func ids(_ arguments: JSONValue) -> [String] {
        arguments["ids"]?.array?.compactMap(\.string) ?? arguments["ids"]?.string.map { [$0] } ?? []
    }

    private static func describe(_ response: DelegationResponse) -> String {
        "## \(response.id)\n" + (response.error.map { "Failed: \($0)" } ?? response.text ?? "(No answer.)")
    }

    private static func render(_ response: DelegationResponse) -> JSONValue {
        if let error = response.error {
            return toolResult(error, isError: true)
        }
        return toolResult(response.text ?? "(The agent finished without a reply.)", isError: false)
    }

    private static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}
