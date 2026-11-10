import Foundation
import Testing
@testable import WatercodedCore

@Suite("Slug")
struct SlugTests {
    @Test(arguments: [
        ("Fix the auth token refresh!", "fix-the-auth-token-refresh"),
        ("  Café — déjà vu  ", "cafe-deja-vu"),
        ("🚀🚀", "current"),
        ("ALLCAPS and 123 numbers", "allcaps-and-123-numbers")
    ])
    func `makes slugs`(input: String, expected: String) {
        #expect(Slug.make(from: input) == expected)
    }

    @Test func `truncates at word boundary`() {
        let slug = Slug.make(from: "one two three four five six seven eight nine ten", maxLength: 20)
        #expect(slug == "one-two-three-four")
        #expect(slug.count <= 20)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func `round trips mixed values`() throws {
        let text = #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#
        let value = try JSONValue(parsing: text)
        #expect(value["a"]?.int == 1)
        #expect(value["b"]?[0]?.bool == true)
        #expect(value["b"]?[1] == .null)
        #expect(value["c"]?["d"]?.double == 2.5)
        #expect(try JSONValue(parsing: value.compactString()) == value)
    }

    @Test func `encodes whole numbers as integers`() {
        let value: JSONValue = ["count": 3]
        #expect(value.compactString() == #"{"count":3}"#)
    }
}

@Suite("UsageSnapshot")
struct UsageSnapshotTests {
    @Test func `fraction uses known window`() {
        #expect(UsageSnapshot(contextTokens: 50000, contextWindow: 100_000).contextFraction == 0.5)
    }

    @Test func `fraction defaults to 200 k and clamps`() {
        #expect(UsageSnapshot(contextTokens: 100_000).contextFraction == 0.5)
        #expect(UsageSnapshot(contextTokens: 900_000).contextFraction == 1)
    }
}

@Suite("Approval rules")
struct ApprovalRuleTests {
    @Test func `prefix rules match the command and its arguments only`() {
        let rule = ApprovalRule(toolName: "Bash", pattern: "npm test *")
        #expect(rule.matches(toolName: "Bash", subject: "npm test"))
        #expect(rule.matches(toolName: "Bash", subject: "npm test --watch=false"))
        #expect(!rule.matches(toolName: "Bash", subject: "npm testing"))
        #expect(!rule.matches(toolName: "Bash", subject: "rm -rf /; npm test"))
        #expect(!rule.matches(toolName: "Edit", subject: "npm test"))
    }

    @Test(arguments: [
        "npm test && touch other", "npm test; touch other", "npm test | sh",
        "npm test $(touch other)", "npm test `touch other`", "npm test > other",
        "npm test\ntouch other", "npm test <(touch other)", "npm test & touch other",
        "npm test --flag=\"$(touch other)\"", "npm test \\\n touch other"
    ])
    func `prefix approvals require review for shell syntax`(command: String) {
        for tool in ["Bash", "Shell"] {
            let rule = ApprovalRule(toolName: tool, pattern: "npm test *")
            #expect(!rule.matches(toolName: tool, subject: command))
        }
    }

    @Test func `tool-wide and exact rules`() {
        #expect(ApprovalRule(toolName: "Read").matches(toolName: "Read", subject: "/any/file"))
        let exact = ApprovalRule(toolName: "Bash", pattern: "make lint")
        #expect(exact.matches(toolName: "Bash", subject: "make lint"))
        #expect(!exact.matches(toolName: "Bash", subject: "make lint --fix"))
    }

    @Test func `parses Claude Code rule syntax`() {
        #expect(ApprovalRule(claudeRule: "Bash(npm test:*)") == ApprovalRule(toolName: "Bash", pattern: "npm test *"))
        #expect(ApprovalRule(claudeRule: "Edit") == ApprovalRule(toolName: "Edit"))
    }

    @Test(arguments: [
        ("npm test --watch=false", "npm test *"),
        ("swift test --filter Foo", "swift test *"),
        ("ls -la", "ls *"),
        ("./script.sh arg", "./script.sh *"),
    ])
    func `suggests a rule from a command`(command: String, expected: String) {
        #expect(ApprovalRule.suggested(forCommand: command) == expected)
    }
}
