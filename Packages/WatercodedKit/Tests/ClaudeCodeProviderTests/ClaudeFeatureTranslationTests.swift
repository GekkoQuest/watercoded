import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

// The JSON lines below are verbatim CLI output; reflowing them would make them harder to compare.
// swiftlint:disable line_length

/// Message shapes recorded from claude 2.1.319 (`CLAUDE_CODE_ENABLE_TODO_TOOLS=1`).
@Suite("Claude feature translation")
struct ClaudeFeatureTranslationTests {
    private func translate(_ lines: [String]) throws -> [AgentEvent] {
        var translator = ClaudeWireTranslator()
        return try lines.flatMap { try translator.translate(JSONValue(parsing: $0)) }
    }

    @Test func `compaction drops the context to the post-compaction size`() throws {
        let events = try translate([
            #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":35323,"post_tokens":8243}}"#
        ])
        #expect(events.first == .contextCompacted(preTokens: 35323, postTokens: 8243))
        guard case let .usageUpdated(usage)? = events.last else { Issue.record("expected usage")
            return
        }
        #expect(usage.contextTokens == 8243)
    }

    @Test func `thinking blocks carry the streamed token estimate`() throws {
        let events = try translate([
            #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":327}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"","signature":"x"}]}}"#
        ])
        #expect(events == [.thinking(messageID: "m1", text: "", estimatedTokens: 327)])
    }

    @Test func `exit plan mode becomes a plan proposal`() throws {
        let events = try translate([
            ##"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Plan\n1. Do it"}}}"##
        ])
        #expect(events == [.planProposed(requestID: "r1", markdown: "# Plan\n1. Do it")])
    }

    @Test func `ask user question becomes a question with options`() throws {
        let events = try translate([
            #"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which color?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]}]}}}"#
        ])
        guard case let .questionAsked(id, questions)? = events.first else { Issue.record("expected a question")
            return
        }
        #expect(id == "q1")
        #expect(questions.first?.text == "Which color?")
        #expect(questions.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(questions.first?.options.first?.detail == "Warm")
    }

    @Test func `question answers are sent as updatedInput answers`() {
        let input: JSONValue = ["questions": [["question": "Which color?"]]]
        let message = ClaudeControlMessages.questionAnswer(
            requestID: "q1",
            input: input,
            answers: ["Which color?": "Blue"]
        )
        let updated = message["response"]?["response"]?["updatedInput"]
        #expect(message["response"]?["response"]?["behavior"]?.string == "allow")
        #expect(updated?["answers"]?["Which color?"]?.string == "Blue")
        #expect(updated?["questions"] != nil)
    }

    @Test func `task create and update rebuild the task list`() throws {
        let events = try translate([
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"c1","name":"TaskCreate","input":{"subject":"alpha","description":"Task alpha"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"Task #1 created successfully: alpha"}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"c2","name":"TaskCreate","input":{"subject":"beta"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c2","content":"Task #2 created successfully: beta"}]}}"#,
            #"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"c3","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"c3","content":"Updated task #1 status"}]}}"#
        ])
        let lists = events.compactMap {
            if case let .tasksUpdated(items) = $0 {
                items
            } else {
                nil
            }
        }
        #expect(lists.count == 3)
        #expect(lists.last == [
            TaskItem(id: "1", title: "alpha", status: .completed),
            TaskItem(id: "2", title: "beta", status: .pending)
        ])
    }

    @Test func `todo write replaces the whole list`() throws {
        let events = try translate([
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"c1","name":"TodoWrite","input":{"todos":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"}]}}]}}"#
        ])
        guard case let .tasksUpdated(items)? = events.first else { Issue.record("expected tasks")
            return
        }
        #expect(items.map(\.status) == [.completed, .inProgress])
    }

    @Test func `subagent calls are linked to their parent and their prose is not shown`() throws {
        let events = try translate([
            #"{"type":"assistant","parent_tool_use_id":"task1","message":{"id":"s1","content":[{"type":"text","text":"internal"},{"type":"tool_use","id":"c9","name":"Read","input":{"file_path":"/a/b.swift"}}],"usage":{"input_tokens":99999}}}"#
        ])
        #expect(events.count == 1)
        guard case let .toolCallStarted(call)? = events.first else { Issue.record("expected a tool call")
            return
        }
        #expect(call.parentCallID == "task1")
    }

    @Test func `cache lifetime comes from the cache write type`() {
        #expect(ClaudeWireTranslator.cacheTTL(from: ["cache_creation": ["ephemeral_1h_input_tokens": 12980]]) == 3600)
        #expect(ClaudeWireTranslator.cacheTTL(from: ["cache_creation": ["ephemeral_5m_input_tokens": 10]]) == 300)
        #expect(ClaudeWireTranslator.cacheTTL(from: [:]) == nil)
    }

    @Test func `rejected settings changes surface as notices`() throws {
        let events = try translate([
            #"{"type":"control_response","response":{"subtype":"error","request_id":"r","error":"bad mode"}}"#,
            #"{"type":"control_response","response":{"subtype":"success","request_id":"r2","response":{"mode":"plan"}}}"#
        ])
        #expect(events.count == 1)
    }

    @Test func `live settings and effort use the CLI's names`() {
        let mode = ClaudeControlMessages.setPermissionMode(requestID: "1", mode: .acceptEdits)
        #expect(mode["request"]?["subtype"]?.string == "set_permission_mode")
        #expect(mode["request"]?["mode"]?.string == "acceptEdits")
        let model = ClaudeControlMessages.setModel(requestID: "2", model: nil)
        #expect(model["request"]?["model"] == .null)
        let arguments = ClaudeCodeArguments.make(for: SessionConfiguration(
            workingDirectory: URL(filePath: "/tmp"),
            effort: "high"
        ))
        #expect(arguments.joined(separator: " ").contains("--effort high"))
        #expect(ClaudeCodeArguments.environment(base: [:])["CLAUDE_CODE_ENABLE_TODO_TOOLS"] == "1")
    }
}

// swiftlint:enable line_length
