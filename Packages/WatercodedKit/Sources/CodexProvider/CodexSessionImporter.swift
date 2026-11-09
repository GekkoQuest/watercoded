import AgentKit
import Foundation
import WatercodedCore

/// Reads the sessions Codex saves under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, so sessions run in
/// Terminal can be brought into Watercoded and continued (`thread/resume` with the session's id).
///
/// Each file starts with a `session_meta` line (`id`, `cwd`, `originator`) and records finished items as
/// `event_msg` / `item_completed` (`UserMessage`, `AgentMessage`, `Plan`, `CommandExecution`, …).
extension CodexProvider: SessionImporting {
    public func importableSessions(in directory: URL) -> [ImportableSession] {
        Self.sessionFiles(in: sessionsDirectory)
            .compactMap { file -> ImportableSession? in
                guard let meta = Self.meta(of: file), Self.samePath(meta.cwd, directory),
                      meta.originator != "watercoded" // started by Watercoded: already here
                else { return nil }
                let items = Self.items(in: file)
                let messages = items.filter { ["UserMessage", "AgentMessage"].contains($0.item["type"]?.string ?? "") }
                guard let first = items.lazy.compactMap({ Self.userText($0.item) }).first else { return nil }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return ImportableSession(
                    id: meta.id,
                    title: Self.title(from: first),
                    updatedAt: modified ?? meta.date ?? .distantPast,
                    messageCount: messages.count
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func transcript(ofSession id: String, in directory: URL) throws -> [TranscriptItem] {
        guard let file = Self.sessionFiles(in: sessionsDirectory).first(where: {
            $0.lastPathComponent.hasSuffix("-\(id).jsonl") && Self.meta(of: $0)?.id == id
        }) else { throw AgentError.unsupported("This session") }

        return Self.items(in: file).compactMap { entry -> TranscriptItem? in
            let item = entry.item
            switch item["type"]?.string {
            case "UserMessage":
                return Self.userText(item).map { TranscriptItem(date: entry.date, content: .user(text: $0)) }
            case "AgentMessage":
                let text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined()
                return text.isEmpty ? nil : TranscriptItem(date: entry.date, content: .assistant(text: text))
            case "Plan":
                guard let markdown = item["text"]?.string, !markdown.isEmpty else { return nil }
                return TranscriptItem(date: entry.date, content: .plan(PlanRecord(
                    requestID: item["id"]?.string ?? UUID().uuidString, markdown: markdown, status: .approved
                )))
            case "CommandExecution":
                let argv = item["command"]?.array?.compactMap(\.string) ?? []
                // ["/bin/zsh", "-lc", "<script>"] → the script.
                let command = argv.count == 3 && argv[1].hasSuffix("c") ? argv[2] : argv.joined(separator: " ")
                let failed = item["status"]?.string != "completed" || (item["exit_code"]?.int ?? 0) != 0
                return TranscriptItem(date: entry.date, content: .toolCall(ToolCallRecord(
                    callID: item["id"]?.string ?? UUID().uuidString,
                    name: "Shell",
                    kind: .shell,
                    summary: command,
                    input: JSONValue.object(["command": .string(command)]).prettyString(),
                    output: item["aggregated_output"]?.string,
                    status: failed ? .failed : .succeeded
                )))
            default:
                return nil
            }
        }
    }

    // MARK: Reading session files

    static func sessionFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    struct Meta {
        var id: String
        var cwd: String
        var originator: String?
        var date: Date?
    }

    static func meta(of file: URL) -> Meta? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The first line is the session_meta record; it can be large (base instructions), so read generously.
        guard let data = try? handle.read(upToCount: 1 << 20),
              let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let line = try? JSONValue(parsing: Data(firstLine)),
              line["type"]?.string == "session_meta",
              let payload = line["payload"], let id = payload["id"]?.string, let cwd = payload["cwd"]?.string
        else { return nil }
        return Meta(
            id: id,
            cwd: cwd,
            originator: payload["originator"]?.string,
            date: payload["timestamp"]?.string.flatMap { try? Date($0, strategy: .iso8601) }
        )
    }

    /// Finished items, in order, with their timestamps.
    static func items(in file: URL) -> [(date: Date, item: JSONValue)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { raw in
            guard let line = try? JSONValue(parsing: String(raw)), line["type"]?.string == "event_msg",
                  line["payload"]?["type"]?.string == "item_completed",
                  let item = line["payload"]?["item"] else { return nil }
            let date = line["timestamp"]?.string.flatMap { try? Date($0, strategy: .iso8601) } ?? .now
            return (date, item)
        }
    }

    static func userText(_ item: JSONValue) -> String? {
        guard item["type"]?.string == "UserMessage" else { return nil }
        let text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func title(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// `/var/…` and `/private/var/…` are the same folder on macOS.
    static func samePath(_ path: String, _ url: URL) -> Bool {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
