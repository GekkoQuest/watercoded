import AgentKit
import Foundation
import Testing
@testable import ClaudeCodeProvider

// The shape of `~/.claude/cache/model-catalog/*.json` written by claude 2.1.319, trimmed.
// swiftlint:disable line_length
private let catalogJSON = """
{"version":2,"fetchedAt":1794129885663,"catalog":{"surface":"cc","config":{"id":"cc",
"provider_alias_targets":{"opus":{"default":"claude-opus-5-5","per_provider":{"gateway":"claude-opus-4-7"}},"fable":{"default":"claude-fable-5-1"}},
"models":[
{"id":"claude-opus-5-5","name":"Opus 5.5","short_name":"Opus","section":"main","runtime":{"family":"opus","default_effort":"medium"}},
{"id":"claude-fable-5-1","name":"Fable 5.1","short_name":"Fable","section":"main","runtime":{"family":"fable","default_effort":"high"}},
{"id":"claude-opus-4-7","name":"Opus 4.7","short_name":"Opus","section":"overflow","runtime":{"family":"opus","default_effort":"xhigh"}},
{"id":"claude-secret-1","name":"Secret 1","section":"main","confidential":true},
{"id":"claude-masked-1","name":"Masked 1","section":"main"}
]}}}
"""
// swiftlint:enable line_length

@Suite("Claude model catalog")
struct ClaudeModelCatalogTests {
    private func catalog() throws -> ModelCatalog {
        try #require(ClaudeModelCatalog.parse(Data(catalogJSON.utf8), masked: ["claude-masked-1"])).catalog
    }

    @Test func `featured models are offered by alias with exact names`() throws {
        let choices = try catalog().choices
        #expect(choices.map(\.id) == ["opus", "fable"])
        #expect(choices.map(\.displayName) == ["Opus 5.5", "Fable 5.1"])
    }

    @Test func `aliases resolve to models and their default effort`() throws {
        let catalog = try catalog()
        #expect(catalog.model(named: "opus")?.name == "Opus 5.5")
        #expect(catalog.model(named: "opus")?.defaultEffort == "medium")
        #expect(catalog.model(named: "claude-opus-4-7")?.defaultEffort == "xhigh")
        #expect(catalog.model(named: "unknown") == nil)
    }

    @Test func `confidential and masked models are hidden`() throws {
        let ids = try catalog().models.map(\.id)
        #expect(!ids.contains("claude-secret-1"))
        #expect(!ids.contains("claude-masked-1"))
    }

    @Test func `unexpected shapes yield nil`() {
        #expect(ClaudeModelCatalog.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeModelCatalog.parse(Data("not json".utf8)) == nil)
    }
}

@Suite("Branching")
struct ClaudeBranchingTests {
    @Test func `a branch forks the session at the checkpoint`() {
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            resumeSessionID: "session-1",
            branchAt: "uuid-7"
        ))
        let resume = arguments.firstIndex(of: "--resume")
        #expect(resume.map { arguments[$0 + 1] } == "session-1")
        #expect(arguments.contains("--fork-session"))
        let at = arguments.firstIndex(of: "--resume-session-at")
        #expect(at.map { arguments[$0 + 1] } == "uuid-7")
    }

    @Test func `plain resumes don't fork`() {
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            resumeSessionID: "session-1"
        ))
        #expect(!arguments.contains("--fork-session"))
    }
}

@Suite("Claude MCP forms")
struct ClaudeFormTests {
    @Test func `elicitation control requests become forms and answers go back`() {
        var translator = ClaudeWireTranslator()
        // As forwarded by claude 2.1.319.
        let events = translator.translate([
            "type": "control_request", "request_id": "req-1",
            "request": [
                "subtype": "elicitation",
                "mcp_server_name": "elicit",
                "message": "Please fill in your profile.",
                "mode": "form",
                "property_order": ["name", "role"],
                "requested_schema": ["type": "object", "properties": [
                    "role": ["type": "string", "oneOf": [["const": "dev", "title": "Developer"]]],
                    "name": ["type": "string", "title": "Your name"]
                ], "required": ["name"]]
            ]
        ])
        guard case let .formRequested(form)? = events.first else {
            Issue.record("Expected a form")
            return
        }
        #expect(form.requestID == "req-1")
        #expect(form.fields.map(\.key) == ["name", "role"])
        let reply = ClaudeControlMessages.formResponse(requestID: "req-1", response: .accept(["name": "Ada"]))
        #expect(reply["response"]?["response"] == ["action": "accept", "content": ["name": "Ada"]])
        #expect(ClaudeControlMessages.formResponse(requestID: "r", response: .decline)["response"]?["response"]
            == ["action": "decline"])
    }
}
