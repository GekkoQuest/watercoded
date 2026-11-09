import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

/// Fixtures are real `claude` 2.1.x stream-json transcripts (paths and signatures redacted).
@Suite("Claude wire translation")
struct ClaudeWireTranslatorTests {
    private func translate(fixture name: String) throws -> [AgentEvent] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        var translator = ClaudeWireTranslator()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .flatMap { try translator.translate(JSONValue(parsing: String($0))) }
    }

    @Test func `approval transcript`() throws {
        let events = try translate(fixture: "bash-approval")

        guard case let .sessionStarted(info) = events.first else { Issue.record("expected sessionStarted first")
            return
        }
        #expect(info.providerSessionID == "1eaf1769-8726-4dbf-8e63-c785809a1277")
        #expect(info.model == "claude-haiku-5-5")

        let requests = events.compactMap {
            if case let .permissionRequested(request) = $0 {
                request
            } else {
                nil
            }
        }
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "Bash")
        #expect(requests.first?.kind == .shell)
        #expect(requests.first?.input["command"]?.string == "echo hi > probe.txt")

        let tools = events.compactMap {
            if case let .toolCallStarted(call) = $0 {
                call
            } else {
                nil
            }
        }
        #expect(tools.map(\.summary) == ["echo hi > probe.txt"])
        #expect(events.contains {
            if case .toolCallFinished(_, _, false) = $0 {
                true
            } else {
                false
            }
        })

        guard case .turnFinished(.completed) = events.last else { Issue.record("expected a completed turn last")
            return
        }
        let usage = events.compactMap {
            if case let .usageUpdated(usage) = $0 {
                usage
            } else {
                nil
            }
        }.last
        #expect(usage?.contextWindow == 1_000_000)
        #expect((usage?.costUSD ?? 0) > 0)
    }

    @Test func `assistant lines become checkpoints for branching`() throws {
        let events = try translate(fixture: "partial-messages")
        let checkpoints = events.compactMap {
            if case let .checkpoint(id) = $0 {
                id
            } else {
                nil
            }
        }
        #expect(!checkpoints.isEmpty)
        #expect(checkpoints.allSatisfy { UUID(uuidString: $0) != nil })
    }

    @Test func `each response reports its exact output tokens`() throws {
        let events = try translate(fixture: "partial-messages")
        let tokens = events.compactMap {
            if case let .generationFinished(outputTokens) = $0 {
                outputTokens
            } else {
                nil
            }
        }
        #expect(tokens == [88, 344])
        #expect(events.count(where: { $0 == .generationStarted }) == tokens.count)
    }

    @Test func `partial messages stream text deltas`() throws {
        let events = try translate(fixture: "partial-messages")
        let deltas = events.compactMap {
            if case let .textDelta(_, text) = $0 {
                text
            } else {
                nil
            }
        }
        let completed = events.compactMap {
            if case let .messageCompleted(_, text) = $0 {
                text
            } else {
                nil
            }
        }
        #expect(deltas.count > 5)
        #expect(completed.count == 1)
        #expect(deltas.joined() == completed.first)
        // The CLI denied the write on its own (no host prompt), so it surfaces as a notice.
        #expect(events.contains {
            if case .notice = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func `ignores unknown messages`() {
        var translator = ClaudeWireTranslator()
        #expect(translator.translate(["type": "brand_new_type", "x": 1]).isEmpty)
        #expect(translator.translate(["no_type": true]).isEmpty)
    }
}

@Suite("Claude command line and control messages")
struct ClaudeProtocolTests {
    @Test(arguments: [
        (PermissionMode.ask, ["--permission-mode", "default"]),
        (.acceptEdits, ["--permission-mode", "acceptEdits"]),
        (.plan, ["--permission-mode", "plan"]),
        (.fullAccess, ["--permission-mode", "bypassPermissions"])
    ])
    func `maps permission modes`(mode: PermissionMode, expected: [String]) {
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            permissionMode: mode
        ))
        #expect(arguments.contains("--permission-prompt-tool"))
        #expect(arguments.joined(separator: " ").contains(expected.joined(separator: " ")))
    }

    @Test func `includes model and resume`() {
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            model: "opus",
            resumeSessionID: "abc"
        ))
        #expect(arguments.joined(separator: " ").contains("--model opus"))
        #expect(arguments.joined(separator: " ").contains("--resume abc"))
    }

    @Test func `omits default model`() {
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            model: "default"
        ))
        #expect(!arguments.contains("--model"))
    }

    @Test func `permission responses match the control protocol`() {
        let allow = ClaudeControlMessages.permissionResponse(
            requestID: "r1",
            decision: .allow,
            input: ["command": "ls"]
        )
        #expect(allow["type"]?.string == "control_response")
        #expect(allow["response"]?["request_id"]?.string == "r1")
        #expect(allow["response"]?["response"]?["behavior"]?.string == "allow")
        #expect(allow["response"]?["response"]?["updatedInput"]?["command"]?.string == "ls")

        let deny = ClaudeControlMessages.permissionResponse(requestID: "r2", decision: .deny(reason: "no"), input: [:])
        #expect(deny["response"]?["response"]?["behavior"]?.string == "deny")
        #expect(deny["response"]?["response"]?["message"]?.string == "no")
    }

    @Test func `classifies tools`() {
        #expect(ClaudeToolDescriber.kind(forTool: "Read") == .read)
        #expect(ClaudeToolDescriber.kind(forTool: "MultiEdit") == .edit)
        #expect(ClaudeToolDescriber.kind(forTool: "mcp__github__create_issue") == .mcp)
        #expect(ClaudeToolDescriber
            .summary(forTool: "Read", input: ["file_path": "/a/b/Sources/App.swift"]) == "Sources/App.swift")
    }
}

@Suite("Claude billing and plan usage")
struct ClaudeBillingTests {
    @Test func `subscription sign-in is detected from apiKeySource`() {
        var translator = ClaudeWireTranslator()
        let events = translator.translate([
            "type": "system", "subtype": "init", "session_id": "s1", "model": "opus", "apiKeySource": "none"
        ])
        guard case let .sessionStarted(info)? = events.first else { Issue.record("expected sessionStarted")
            return
        }
        #expect(info.billing == .subscription)
        #expect(ClaudeWireTranslator.billing(apiKeySource: "ANTHROPIC_API_KEY") == .apiKey)
        #expect(ClaudeWireTranslator.billing(apiKeySource: nil) == nil)
    }

    @Test func `rate limit events become plan usage`() throws {
        var translator = ClaudeWireTranslator()
        let line = #"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{
          "seven_day":{"utilization":0.08,"resetsAt":1794711600,"status":"allowed"},
          "five_hour":{"utilization":0.01,"resetsAt":1794143400,"status":"allowed"}}}}
        """#
        let events = try translator.translate(JSONValue(parsing: line))
        guard case let .planUsageUpdated(plan)? = events.first else { Issue.record("expected plan usage")
            return
        }
        #expect(plan.windows.map(\.title) == ["5-hour limit", "Weekly limit"])
        #expect(plan.windows.first?.utilization == 0.01)
        #expect(plan.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_794_143_400))
    }
}
