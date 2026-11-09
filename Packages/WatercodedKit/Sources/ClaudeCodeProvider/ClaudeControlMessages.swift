import AgentKit
import Foundation
import WatercodedCore

/// Outgoing stream-json messages (stdin → `claude`).
enum ClaudeControlMessages {
    static func userMessage(_ text: String, images: [ImageAttachment] = []) -> JSONValue {
        var content: [JSONValue] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": .string(image.mediaType),
                    "data": .string(image.data.base64EncodedString())
                ]
            ]
        }
        content.append(["type": "text", "text": .string(text)])
        return ["type": "user", "message": ["role": "user", "content": .array(content)]]
    }

    /// Must be sent first; enables host-side permission prompts.
    static func initialize(requestID: String) -> JSONValue {
        controlRequest(requestID: requestID, request: ["subtype": "initialize", "hooks": .null])
    }

    static func interrupt(requestID: String) -> JSONValue {
        controlRequest(requestID: requestID, request: ["subtype": "interrupt"])
    }

    static func setPermissionMode(requestID: String, mode: PermissionMode) -> JSONValue {
        controlRequest(requestID: requestID, request: [
            "subtype": "set_permission_mode",
            "mode": .string(ClaudeCodeArguments.modeName(mode))
        ])
    }

    /// `model: nil` returns to the default model.
    static func setModel(requestID: String, model: String?) -> JSONValue {
        controlRequest(requestID: requestID, request: [
            "subtype": "set_model",
            "model": model.map(JSONValue.string) ?? .null
        ])
    }

    /// Answers an `AskUserQuestion` request: the original input plus `answers` (question → label).
    static func questionAnswer(requestID: String, input: JSONValue, answers: [String: String]) -> JSONValue {
        var updated = input.object ?? [:]
        updated["answers"] = .object(answers.mapValues(JSONValue.string))
        return permissionResponse(requestID: requestID, decision: .allow, input: .object(updated))
    }

    /// Reply to an `elicitation` control request: the MCP `{action, content}` result.
    static func formResponse(requestID: String, response: FormResponse) -> JSONValue {
        let payload = response.payload
        var result: [String: JSONValue] = ["action": .string(payload.action)]
        if payload.content != .null {
            result["content"] = payload.content
        }
        return [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": .object(result)]
        ]
    }

    /// Reply to a `can_use_tool` control request.
    static func permissionResponse(requestID: String, decision: PermissionDecision, input: JSONValue) -> JSONValue {
        let response: JSONValue = switch decision {
        case .allow: ["behavior": "allow", "updatedInput": input]
        case let .deny(reason): ["behavior": "deny", "message": .string(reason)]
        }
        return [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response]
        ]
    }

    private static func controlRequest(requestID: String, request: JSONValue) -> JSONValue {
        ["type": "control_request", "request_id": .string(requestID), "request": request]
    }
}
