import AgentKit
import Foundation
import WatercodedCore

/// Builds the JSON-RPC parameters Watercoded sends to `codex app-server`.
enum CodexRequests {
    static func initialize() -> JSONValue {
        [
            "clientInfo": ["name": "watercoded", "title": "Watercoded", "version": "1"],
            // Plan mode (`collaborationMode`) is part of the experimental API.
            "capabilities": ["experimentalApi": true, "requestAttestation": false]
        ]
    }

    /// Codex's approval policy and sandbox for a Watercoded permission mode.
    ///
    /// - Ask: asks before edits (read-only sandbox) and before commands it doesn't know are safe.
    /// - Accept Edits: edits the workspace freely; commands run sandboxed to it and ask to go further.
    /// - Full Access: no sandbox. The policy stays `on-request` because `never` makes Codex refuse MCP tool
    ///   calls outright; the session approves anything Codex asks for itself instead.
    /// - Plan: read-only, so exploring never needs approval and nothing can change.
    static func policy(for mode: PermissionMode) -> (approval: String, sandbox: String) {
        switch mode {
        case .plan: ("on-request", "read-only")
        case .ask: ("untrusted", "read-only")
        case .acceptEdits: ("on-request", "workspace-write")
        case .fullAccess: ("on-request", "danger-full-access")
        }
    }

    /// The same sandbox, as the policy object `turn/start` takes for mid-session changes.
    static func sandboxPolicy(for mode: PermissionMode, writableRoots: [URL]) -> JSONValue {
        switch policy(for: mode).sandbox {
        case "danger-full-access":
            ["type": "dangerFullAccess"]
        case "workspace-write":
            [
                "type": "workspaceWrite",
                "writableRoots": .array(writableRoots.map { .string($0.path) }),
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            ]
        default:
            ["type": "readOnly", "networkAccess": false]
        }
    }

    /// Parameters shared by `thread/start`, `thread/resume` and `thread/fork`.
    static func threadParameters(_ configuration: SessionConfiguration) -> [String: JSONValue] {
        let policy = policy(for: configuration.permissionMode)
        var parameters: [String: JSONValue] = [
            "cwd": .string(configuration.workingDirectory.path),
            "approvalPolicy": .string(policy.approval),
            "sandbox": .string(policy.sandbox)
        ]
        if let model = configuration.model, model != "default" {
            parameters["model"] = .string(model)
        }
        if !configuration.additionalDirectories.isEmpty {
            parameters["config"] = ["sandbox_workspace_write": [
                "writable_roots": .array(configuration.additionalDirectories.map { .string($0.path) })
            ]]
        }
        return parameters
    }

    /// The `thread/*` request that opens this session: a new thread, a resumed one, or a fork.
    static func openThread(_ configuration: SessionConfiguration) -> (method: String, params: JSONValue) {
        var parameters = threadParameters(configuration)
        guard let threadID = configuration.resumeSessionID else {
            return ("thread/start", .object(parameters))
        }
        parameters["threadId"] = .string(threadID)
        if let turnID = configuration.branchAt {
            parameters["lastTurnId"] = .string(turnID) // fork through this turn, inclusive
            return ("thread/fork", .object(parameters))
        }
        return ("thread/resume", .object(parameters))
    }

    /// User input items: the text, plus images written to temporary files (`localImage`).
    static func input(for message: UserMessage, imageDirectory: URL) throws -> JSONValue {
        var items: [JSONValue] = [["type": "text", "text": .string(message.text), "text_elements": []]]
        if !message.images.isEmpty {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        for image in message.images {
            let ext = image.mediaType.split(separator: "/").last.map(String.init) ?? "png"
            let url = imageDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try image.data.write(to: url)
            items.append(["type": "localImage", "path": .string(url.path)])
        }
        return .array(items)
    }

    /// Codex's collaboration mode for a turn: `plan` to plan without changing anything, else `default`.
    static func collaborationMode(planning: Bool, model: String, effort: String?) -> JSONValue {
        [
            "mode": planning ? "plan" : "default",
            "settings": [
                "model": .string(model),
                "reasoning_effort": effort.map(JSONValue.string) ?? .null,
                "developer_instructions": .null
            ]
        ]
    }

    /// Answers to `request_user_input`: Codex's question id → the chosen label.
    static func userInputResponse(_ answers: [String: String], ids: [String: String]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (question, answer) in answers {
            guard let id = ids[question] else { continue }
            result[id] = ["answers": [.string(answer)]]
        }
        return ["answers": .object(result)]
    }

    static func approvalResponse(
        _ decision: PermissionDecision,
        kind: CodexWireTranslator.PendingApproval.Kind = .command
    )
        -> JSONValue {
        if kind == .mcpTool { // answered as an MCP elicitation
            return formResponse(decision == .allow ? .accept([:]) : .decline)
        }
        switch decision {
        case .allow: return ["decision": "accept"]
        case .deny: return ["decision": "decline"]
        }
    }

    static func formResponse(_ response: FormResponse) -> JSONValue {
        let payload = response.payload
        return ["action": .string(payload.action), "content": payload.content, "_meta": .null]
    }
}
