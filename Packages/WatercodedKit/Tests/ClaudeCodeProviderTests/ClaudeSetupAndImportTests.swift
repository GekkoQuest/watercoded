import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

// Lines below are verbatim-shaped CLI output; reflowing them would hide the structure.
// swiftlint:disable line_length

@Suite("Claude setup, rules and images")
struct ClaudeSetupTests {
    @Test func `init reports the agent's environment`() throws {
        var translator = ClaudeWireTranslator()
        let events = try translator
            .translate(
                JSONValue(
                    parsing: #"{"type":"system","subtype":"init","session_id":"s","model":"opus","claude_code_version":"2.1.319","mcp_servers":[{"name":"github","status":"connected"}],"tools":["Bash","Read"],"skills":["dataviz"],"plugins":[{"name":"docs"}],"memory_paths":{"project":"/repo/CLAUDE.md"},"agents":["general-purpose"]}"#
                )
            )
        guard case let .environmentReported(environment)? = events.last else { Issue.record("expected environment")
            return
        }
        #expect(environment.version == "2.1.319")
        #expect(environment.mcpServers == [AgentEnvironment.Server(name: "github", status: "connected")])
        #expect(environment.tools == ["Bash", "Read"])
        #expect(environment.plugins == ["docs"])
        #expect(environment.memoryFiles == ["/repo/CLAUDE.md"])
    }

    @Test func `initialize response lists commands`() throws {
        var translator = ClaudeWireTranslator()
        let events = try translator
            .translate(
                JSONValue(
                    parsing: #"{"type":"control_response","response":{"subtype":"success","request_id":"i","response":{"commands":[{"name":"compact","description":"Clear history","argumentHint":"","aliases":[]},{"name":"review","description":"Review a PR","argumentHint":"<pr>"}]}}}"#
                )
            )
        #expect(events == [.commandsAvailable([
            SlashCommand(name: "compact", summary: "Clear history"),
            SlashCommand(name: "review", summary: "Review a PR", argumentHint: "<pr>")
        ])])
    }

    @Test func `approval requests carry their subject and Claude's suggested rule`() throws {
        var translator = ClaudeWireTranslator()
        let events = try translator
            .translate(
                JSONValue(
                    parsing: #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm test --ci"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}}"#
                )
            )
        guard case let .permissionRequested(request)? = events.first else { Issue.record("expected a request")
            return
        }
        #expect(request.subject == "npm test --ci")
        #expect(request.suggestedRule == ApprovalRule(toolName: "Bash", pattern: "npm test *"))
        #expect(request.proposedRule.matches(toolName: "Bash", subject: "npm test --ci"))
    }

    @Test func `images are sent as base64 content blocks before the text`() {
        let image = ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]))
        let message = ClaudeControlMessages.userMessage("What's this?", images: [image])
        let content = message["message"]?["content"]?.array ?? []
        #expect(content.count == 2)
        #expect(content.first?["type"]?.string == "image")
        #expect(content.first?["source"]?["data"]?.string == Data([1, 2, 3]).base64EncodedString())
        #expect(content.last?["text"]?.string == "What's this?")
    }
}

@Suite("Claude session import")
struct ClaudeImportTests {
    @Test func `lists and reads sessions saved by the CLI`() throws {
        let projects = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let repository = URL(filePath: "/Users/me/Developer/my.app")
        #expect(ClaudeCodeProvider.encodedFolderName(for: repository) == "-Users-me-Developer-my-app")

        let folder = projects.appending(path: ClaudeCodeProvider.encodedFolderName(for: repository))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"abc","cwd":"/Users/me/Developer/my.app","timestamp":"2026-11-08T09:00:00Z","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"assistant","sessionId":"abc","timestamp":"2026-11-08T09:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/me/Developer/my.app/Login.swift"}}]}}"#,
            #"{"type":"user","sessionId":"abc","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"struct Login {}"}]}}"#,
            #"{"type":"assistant","sessionId":"abc","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent noise"}]}}"#,
            #"{"type":"user","sessionId":"abc","message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
            #"{"type":"attachment","sessionId":"abc"}"#
        ]
        try lines.joined(separator: "\n").write(
            to: folder.appending(path: "abc.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let provider = ClaudeCodeProvider(projectsDirectory: projects)
        let sessions = provider.importableSessions(in: repository)
        #expect(sessions.map(\.id) == ["abc"])
        #expect(sessions.first?.title == "Fix the login bug")
        #expect(sessions.first?.messageCount == 2)

        let transcript = try provider.transcript(ofSession: "abc", in: repository)
        #expect(transcript.count == 3)
        #expect(transcript[0].content == .user(text: "Fix the login bug"))
        #expect(transcript[1].content == .assistant(text: "Looking."))
        guard case let .toolCall(record) = transcript[2].content else { Issue.record("expected a tool call")
            return
        }
        #expect(record.output == "struct Login {}")
        #expect(record.summary == "my.app/Login.swift")
    }
}

// swiftlint:enable line_length
