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
            return result(id, ["tools": [tool(agents: agents)]])
        case "tools/call":
            return result(id, call(message["params"]?["arguments"] ?? [:], parentID: parentID, mailbox: mailbox))
        case "ping":
            return result(id, [:])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    static func tool(agents: [String]) -> JSONValue {
        let description = """
        Hand a task to another coding agent (\(agents.joined(separator: ", "))), with any model it supports, when \
        the user asks for a specific agent or model, or a second opinion from one. It works in the same folder as \
        you, appears in Watercoded as its own session (the user answers its approvals there), and its final answer \
        is returned here when it finishes. Give it complete, self-contained instructions: it doesn't see this \
        conversation.
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
            "task": ["type": "string", "description": "Complete instructions for the other agent."]
        ]
        return [
            "name": .string(toolName),
            "description": .string(description),
            "inputSchema": ["type": "object", "properties": properties, "required": ["agent", "task"]]
        ]
    }

    private static func call(_ arguments: JSONValue, parentID: String, mailbox: DelegationMailbox) -> JSONValue {
        guard let agent = arguments["agent"]?.string, let task = arguments["task"]?.string,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolResult("`agent` and `task` are required.", isError: true)
        }
        let request = DelegationRequest(
            parentID: parentID, agent: agent,
            model: arguments["model"]?.string, effort: arguments["effort"]?.string, task: task
        )
        do {
            try mailbox.post(request)
        } catch {
            return toolResult("Couldn't reach Watercoded: \(error.localizedDescription)", isError: true)
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if getppid() == 1 {
                exit(0) // the agent that started this server is gone: nobody is waiting for the answer
            }
            if let response = mailbox.takeResponse(for: request.id) {
                if let error = response.error {
                    return toolResult(error, isError: true)
                }
                return toolResult(response.text ?? "(The agent finished without a reply.)", isError: false)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return toolResult("The delegated agent didn't finish in time. Check its session in Watercoded.", isError: true)
    }

    private static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}
