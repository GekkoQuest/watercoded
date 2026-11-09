import AgentKit
import Foundation
import WatercodedCore

/// Reads the sessions Claude Code saves under `~/.claude/projects/<encoded path>/<session>.jsonl`,
/// so existing Claude Code users can bring their history into Watercoded and keep going.
extension ClaudeCodeProvider: SessionImporting {
    public func importableSessions(in directory: URL) -> [ImportableSession] {
        let folder = projectsDirectory.appending(path: Self.encodedFolderName(for: directory))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { file -> ImportableSession? in
                let messages = Self.messages(in: file)
                guard let title = messages.first(where: { $0.role == "user" })?.text else { return nil }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return ImportableSession(
                    id: file.deletingPathExtension().lastPathComponent,
                    title: NewTitle.from(title),
                    updatedAt: modified ?? .distantPast,
                    messageCount: messages.count
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func transcript(ofSession id: String, in directory: URL) throws -> [TranscriptItem] {
        let file = projectsDirectory.appending(path: Self.encodedFolderName(for: directory))
            .appending(path: "\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { throw AgentError.unsupported("This session") }
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        for line in Self.lines(of: file) {
            guard let entry = try? JSONValue(parsing: line), entry["isSidechain"]?.bool != true,
                  let role = entry["type"]?.string, role == "user" || role == "assistant" else { continue }
            let date = entry["timestamp"]?.string.flatMap { try? Date($0, strategy: .iso8601) } ?? .now
            let content = entry["message"]?["content"]
            if let text = content?.string {
                if role == "user", let text = Self.visibleUserText(text) {
                    items.append(TranscriptItem(date: date, content: .user(text: text)))
                }
                continue
            }
            for block in content?.array ?? [] {
                switch block["type"]?.string {
                case "text":
                    guard let text = block["text"]?.string else { continue }
                    if role == "assistant" {
                        items.append(TranscriptItem(date: date, content: .assistant(text: text)))
                    } else if let visible = Self.visibleUserText(text) {
                        items.append(TranscriptItem(date: date, content: .user(text: visible)))
                    }
                case "tool_use":
                    guard let callID = block["id"]?.string else { continue }
                    let name = block["name"]?.string ?? "Tool"
                    let input = block["input"] ?? [:]
                    toolIndex[callID] = items.count
                    items.append(TranscriptItem(date: date, content: .toolCall(ToolCallRecord(
                        callID: callID,
                        name: name,
                        kind: ClaudeToolDescriber.kind(forTool: name),
                        summary: ClaudeToolDescriber.summary(forTool: name, input: input),
                        input: input.prettyString(),
                        status: .succeeded
                    ))))
                case "tool_result":
                    guard let callID = block["tool_use_id"]?.string, let index = toolIndex[callID],
                          case var .toolCall(record) = items[index].content else { continue }
                    record.output = ClaudeWireTranslator.flattenToolOutput(block["content"])
                    record.status = block["is_error"]?.bool == true ? .failed : .succeeded
                    items[index].content = .toolCall(record)
                default:
                    continue
                }
            }
        }
        return items
    }

    /// Claude Code names a project's folder after its path, with every non-alphanumeric
    /// character replaced by `-` (`/Users/me/app` → `-Users-me-app`).
    static func encodedFolderName(for directory: URL) -> String {
        String(directory.standardizedFileURL.path.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
    }

    /// Hides the CLI's own bookkeeping (command echoes, reminders, interrupted markers).
    static func visibleUserText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed
    }

    private static func lines(of file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func messages(in file: URL) -> [(role: String, text: String?)] {
        lines(of: file).compactMap { line in
            guard let entry = try? JSONValue(parsing: line), entry["isSidechain"]?.bool != true,
                  let role = entry["type"]?.string, role == "user" || role == "assistant" else { return nil }
            let content = entry["message"]?["content"]
            let text = content?.string ?? content?.array?.first(where: { $0["type"]?.string == "text" })?["text"]?
                .string
            let visible = role == "user" ? text.flatMap(visibleUserText) : text
            if role == "user", visible == nil {
                return nil
            } // tool results and bookkeeping
            return (role, visible)
        }
    }
}

/// Shortens a prompt into a list title.
enum NewTitle {
    static func from(_ prompt: String, maxLength: Int = 70) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        guard line.count > maxLength else { return line }
        let cut = line.prefix(maxLength)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }
}
