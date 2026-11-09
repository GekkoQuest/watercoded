import Foundation
import WatercodedCore

/// Maps Claude Code tool names and inputs onto normalized kinds and one-line summaries.
enum ClaudeToolDescriber {
    static func kind(forTool name: String) -> ToolKind {
        if name.hasPrefix("mcp__") {
            return .mcp
        }
        switch name {
        case "Read", "NotebookRead": return .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return .edit
        case "Bash", "BashOutput", "KillShell", "Monitor": return .shell
        case "Grep", "Glob", "LS", "LSP", "ToolSearch": return .search
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent", "SendMessage": return .subagent
        default: return .other
        }
    }

    static func summary(forTool name: String, input: JSONValue) -> String {
        let text: String? = switch kind(forTool: name) {
        case .shell: input["command"]?.string
        case .read, .edit: input["file_path"]?.string.map(shortPath) ?? input["notebook_path"]?.string.map(shortPath)
        case .search: input["pattern"]?.string ?? input["query"]?.string
        case .web: input["url"]?.string ?? input["query"]?.string
        case .subagent: input["description"]?.string ?? input["prompt"]?.string
        case .mcp: name.split(separator: "__").last.map(String.init)
        case .other: input["description"]?.string
        }
        let line = (text ?? name).split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? name
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    /// `/a/b/c/Sources/App/File.swift` → `App/File.swift`.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}
