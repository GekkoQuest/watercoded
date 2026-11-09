import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import CodexProvider

@Suite("Codex session import")
struct CodexImportTests {
    /// A made-up rollout in Codex's format (no real account data).
    private func makeSessions(cwd: String, originator: String = "codex_cli_rs") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-sessions-\(UUID().uuidString)")
        let day = root.appending(path: "2026/11/09")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "01a1bf00-0000-7000-8000-000000000001"
        let lines: [JSONValue] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": .string(id),
                    "cwd": .string(cwd),
                    "originator": .string(originator),
                    "timestamp": "2026-11-09T08:00:00.000Z"
                ]
            ],
            [
                "type": "event_msg",
                "timestamp": "2026-11-09T08:00:01.000Z",
                "payload": ["type": "item_completed", "item": [
                    "type": "UserMessage", "id": "u1", "content": [[
                        "type": "text",
                        "text": "Fix the flaky login test\nIt fails on CI"
                    ]]
                ]]
            ],
            [
                "type": "event_msg",
                "timestamp": "2026-11-09T08:00:02.000Z",
                "payload": ["type": "item_completed", "item": [
                    "type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "npm test"],
                    "status": "completed", "exit_code": 1, "aggregated_output": "1 failing"
                ]]
            ],
            [
                "type": "event_msg",
                "timestamp": "2026-11-09T08:00:03.000Z",
                "payload": ["type": "item_completed", "item": [
                    "type": "AgentMessage", "id": "a1", "content": [[
                        "type": "Text",
                        "text": "Found it: a race in the fixture."
                    ]]
                ]]
            ],
            ["type": "response_item", "payload": ["type": "message", "role": "developer"]]
        ]
        try lines.map { $0.compactString() }.joined(separator: "\n")
            .write(
                to: day.appending(path: "rollout-2026-11-09T08-00-00-\(id).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        return root
    }

    @Test func `sessions run in a repository can be listed and imported`() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        let sessions = try makeSessions(cwd: repo.path)
        defer { try? FileManager.default.removeItem(at: sessions) }
        let provider = CodexProvider(sessionsDirectory: sessions)

        let listed = provider.importableSessions(in: repo)
        #expect(listed.count == 1)
        #expect(listed.first?.title == "Fix the flaky login test")
        #expect(listed.first?.messageCount == 2)
        #expect(provider.importableSessions(in: URL(filePath: "/somewhere/else")).isEmpty)

        let transcript = try provider.transcript(ofSession: "01a1bf00-0000-7000-8000-000000000001", in: repo)
        #expect(transcript.count == 3)
        #expect(transcript.first?.content == .user(text: "Fix the flaky login test\nIt fails on CI"))
        guard case let .toolCall(record) = transcript[1].content else {
            Issue.record("Expected the command")
            return
        }
        #expect(record.summary == "npm test")
        #expect(record.status == .failed)
        #expect(transcript.last?.content == .assistant(text: "Found it: a race in the fixture."))
    }

    @Test func `sessions Watercoded started aren't offered again`() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        let sessions = try makeSessions(cwd: repo.path, originator: "watercoded")
        defer { try? FileManager.default.removeItem(at: sessions) }
        #expect(CodexProvider(sessionsDirectory: sessions).importableSessions(in: repo).isEmpty)
    }
}
