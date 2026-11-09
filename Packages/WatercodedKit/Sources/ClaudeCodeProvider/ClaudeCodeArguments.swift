import AgentKit
import Foundation
import WatercodedCore

/// Builds the `claude` command line for a session.
enum ClaudeCodeArguments {
    static func make(for configuration: SessionConfiguration) -> [String] {
        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Route approvals to us over the stdio control protocol.
            "--permission-prompt-tool", "stdio"
        ]

        arguments += ["--permission-mode", modeName(configuration.permissionMode)]
        // Allows switching to Full Access later without a restart. It doesn't grant anything by itself:
        // the active mode above still decides, and Full Access always asks the user to confirm first.
        arguments.append("--allow-dangerously-skip-permissions")

        if let effort = configuration.effort {
            arguments += ["--effort", effort]
        }

        if let model = configuration.model, model != "default" {
            arguments += ["--model", model]
        }
        if let resume = configuration.resumeSessionID {
            arguments += ["--resume", resume]
            if let checkpoint = configuration.branchAt {
                // A new session with the conversation up to (and including) this assistant message.
                arguments += ["--fork-session", "--resume-session-at", checkpoint]
            }
        }
        for directory in configuration.additionalDirectories {
            arguments += ["--add-dir", directory.path]
        }
        return arguments
    }

    /// Claude Code's name for a permission mode (CLI flag and `set_permission_mode`).
    static func modeName(_ mode: PermissionMode) -> String {
        switch mode {
        case .ask: "default"
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .fullAccess: "bypassPermissions"
        }
    }

    /// Environment for the CLI: the user's environment plus features Watercoded renders.
    static func environment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["CLAUDE_CODE_ENABLE_TODO_TOOLS"] = "1" // task list → progress ticks on the vessel
        return environment
    }
}
