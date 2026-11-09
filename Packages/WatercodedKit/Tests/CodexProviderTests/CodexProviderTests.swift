import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import CodexProvider

/// Fixtures are recorded from codex-cli 0.167.0's app server (paths and plan redacted).
private func translate(fixture name: String) throws -> [AgentEvent] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    var translator = CodexWireTranslator()
    var events = translator.turnRequested()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        events += try translator.translate(JSONValue(parsing: String(line)))
    }
    return events
}

@Suite("Codex wire translation")
struct CodexWireTranslationTests {
    @Test func `a simple turn streams, completes and leaves a checkpoint`() throws {
        let events = try translate(fixture: "simple-turn")
        #expect(events.contains(.messageCompleted(
            messageID: "msg_08627dddd5dac4bb016af17e4def1887d19b5f7b4d472fef8b", text: "OK"
        )) || events.contains {
            if case .messageCompleted(_, "OK") = $0 {
                true
            } else {
                false
            }
        })
        // The turn ends on the thread going idle (this CLI version never sends turn/completed).
        #expect(events.last == .turnFinished(.completed))
        #expect(events.contains {
            if case .checkpoint = $0 {
                true
            } else {
                false
            }
        })
        let usage = events.compactMap {
            if case let .usageUpdated(usage) = $0 {
                usage
            } else {
                nil
            }
        }.last
        #expect((usage?.contextTokens ?? 0) > 0)
        #expect(usage?.billing == .subscription)
        #expect(events.contains {
            if case let .planUsageUpdated(plan) = $0 {
                !plan.windows.isEmpty
            } else {
                false
            }
        })
    }

    @Test func `command approvals surface and declines are recorded`() throws {
        let events = try translate(fixture: "declined-command")
        let request = events.compactMap {
            if case let .permissionRequested(request) = $0 {
                request
            } else {
                nil
            }
        }
        .first
        #expect(request?.toolName == "Shell")
        #expect(request?.kind == .shell)
        #expect(request?.subject == "touch probe.txt")
        let finished = events.compactMap {
            if case let .toolCallFinished(_, output, isError) = $0 {
                (output, isError)
            } else {
                nil
            }
        }.first
        #expect(finished?.1 == true)
        #expect(finished?.0 == "Declined.")
        #expect(events.contains {
            if case .messageCompleted(_, "DECLINED") = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func `approval answers go back to the request that asked`() {
        var translator = CodexWireTranslator()
        let request: JSONValue = [
            "id": 7, "method": "item/commandExecution/requestApproval",
            "params": ["threadId": "t", "turnId": "u", "itemId": "i", "command": "/bin/zsh -lc 'npm test'"]
        ]
        let events = translator.translate(request)
        guard case let .permissionRequested(permission)? = events.first else {
            Issue.record("No permission request")
            return
        }
        #expect(permission.subject == "npm test")
        #expect(translator.consumeApproval(permission.id) == .init(rpcID: 7, kind: .command))
        #expect(translator.consumeApproval(permission.id) == nil)
        #expect(CodexRequests.approvalResponse(.allow) == ["decision": "accept"])
        #expect(CodexRequests.approvalResponse(.deny(reason: "no")) == ["decision": "decline"])
    }

    @Test func `errors fail the turn and interrupts are reported as such`() {
        var translator = CodexWireTranslator()
        _ = translator.turnRequested()
        _ = translator.translate([
            "method": "error",
            "params": ["error": ["message": "Quota exceeded"], "willRetry": false]
        ])
        #expect(translator.translate(["method": "thread/status/changed", "params": ["status": ["type": "idle"]]])
            .last == .turnFinished(.failed(message: "Quota exceeded")))

        _ = translator.turnRequested()
        translator.interruptWasRequested()
        #expect(translator.translate(["method": "thread/status/changed", "params": ["status": ["type": "idle"]]])
            .last == .turnFinished(.interrupted))
    }

    @Test func `a plan-mode turn ends by proposing its plan`() throws {
        let events = try translate(fixture: "plan-turn")
        let proposal = events.compactMap {
            if case let .planProposed(id, markdown) = $0 {
                (id, markdown)
            } else {
                nil
            }
        }.first
        #expect(proposal?.1.contains("README.md") == true)
        // The proposal comes before the turn ends, so the session waits on the plan card.
        let planIndex = events.firstIndex {
            if case .planProposed = $0 {
                true
            } else {
                false
            }
        }
        let endIndex = events.lastIndex {
            if case .turnFinished = $0 {
                true
            } else {
                false
            }
        }
        #expect(try planIndex != nil && endIndex != nil && #require(planIndex) < #require(endIndex))
    }

    @Test func `questions map to cards and answers go back by id`() {
        var translator = CodexWireTranslator()
        let events = translator.translate([
            "id": 9, "method": "item/tool/requestUserInput",
            "params": ["threadId": "t", "turnId": "u", "itemId": "i", "isBlocking": true, "questions": [
                [
                    "id": "q1",
                    "header": "Scope",
                    "question": "Which part?",
                    "isOther": true,
                    "isSecret": false,
                    "options": [
                        ["label": "UI", "description": "Just the views"],
                        ["label": "All", "description": "Everything"]
                    ]
                ]
            ]]
        ])
        guard case let .questionAsked(requestID, questions)? = events.first else {
            Issue.record("No question")
            return
        }
        #expect(questions.first?.header == "Scope")
        #expect(questions.first?.options.map(\.label) == ["UI", "All"])
        #expect(questions.first?.options.first?.detail == "Just the views")
        let pending = translator.consumeQuestion(requestID)
        #expect(pending?.rpcID == 9)
        #expect(CodexRequests.userInputResponse(["Which part?": "UI"], ids: pending?.ids ?? [:])
            == ["answers": ["q1": ["answers": ["UI"]]]])
    }

    @Test func `plan mode is read-only and switches collaboration mode`() {
        #expect(CodexRequests.policy(for: .plan) == ("on-request", "read-only"))
        #expect(CodexRequests.collaborationMode(planning: true, model: "m", effort: nil)["mode"] == "plan")
        #expect(CodexRequests
            .collaborationMode(planning: false, model: "m", effort: "low")["settings"]?["model"] == "m")
    }

    @Test func `plans become the task list`() {
        let tasks = CodexWireTranslator.tasks(from: [
            ["step": "Read the code", "status": "completed"],
            ["step": "Fix the bug", "status": "inProgress"],
            ["step": "Run tests", "status": "pending"]
        ])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
        #expect(tasks.map(\.title) == ["Read the code", "Fix the bug", "Run tests"])
    }

    @Test func `shell wrappers are unwrapped for display and rules`() {
        #expect(CodexWireTranslator.unwrapShell("/bin/zsh -lc 'git status'") == "git status")
        #expect(CodexWireTranslator.unwrapShell("/bin/zsh -lc 'echo '\\''hi'\\'''") == "echo 'hi'")
        #expect(CodexWireTranslator.unwrapShell("ls -la") == "ls -la")
        // Codex's own quoting of a nested single quote, seen live.
        #expect(CodexWireTranslator.unwrapShell(#"/bin/zsh -lc 'tr -d '"'"' '"'"''"#) == "tr -d ' '")
        #expect(CodexWireTranslator.unwrapShell(#"/bin/zsh -lc "echo \"hi\"""#) == #"echo "hi""#)
        #expect(CodexWireTranslator.unwrapShell("/bin/zsh -lc 'a' extra") == "/bin/zsh -lc 'a' extra")
        #expect(CodexWireTranslator.windowTitle(minutes: 10080) == "Weekly limit")
        #expect(CodexWireTranslator.windowTitle(minutes: 300) == "5-hour limit")
    }
}

@Suite("Codex requests")
struct CodexRequestTests {
    private let base = SessionConfiguration(workingDirectory: URL(filePath: "/tmp/work"), permissionMode: .ask)

    @Test func `sessions start, resume or fork a thread`() {
        #expect(CodexRequests.openThread(base).method == "thread/start")

        var resume = base
        resume.resumeSessionID = "thread-1"
        let resumed = CodexRequests.openThread(resume)
        #expect(resumed.method == "thread/resume")
        #expect(resumed.params["threadId"] == "thread-1")

        var fork = resume
        fork.branchAt = "turn-3"
        let forked = CodexRequests.openThread(fork)
        #expect(forked.method == "thread/fork")
        #expect(forked.params["lastTurnId"] == "turn-3")
    }

    @Test func `permission modes map to approval policies and sandboxes`() {
        #expect(CodexRequests.policy(for: .ask) == ("untrusted", "read-only"))
        #expect(CodexRequests.policy(for: .acceptEdits) == ("on-request", "workspace-write"))
        #expect(CodexRequests.policy(for: .fullAccess) == ("never", "danger-full-access"))
        #expect(CodexRequests.sandboxPolicy(for: .fullAccess, writableRoots: [])["type"] == "dangerFullAccess")
        #expect(CodexRequests.threadParameters(base)["sandbox"] == "read-only")
    }

    @Test func `the model list becomes a catalog with a default`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "model-list",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let catalog = try #require(CodexModelList.parse(JSONValue(parsing: Data(contentsOf: url))))
        let defaultID = try #require(catalog.defaultModelID)
        #expect(catalog.model(named: defaultID) != nil)
        #expect(catalog.models.allSatisfy { !$0.name.isEmpty })
        #expect(catalog.models.contains { $0.defaultEffort != nil })
        // Each model lists only the efforts it accepts (GPT-6-Luna has no "ultra").
        #expect(catalog.model(named: "gpt-6-luna")?.effortLevels?.contains("ultra") == false)
        #expect(catalog.model(named: "gpt-6.1-sol")?.effortLevels?.contains("ultra") == true)
    }

    @Test func `config values are read from the top of config toml`() {
        let toml = """
        model = "gpt-6.1-sol"   # my favourite
        model_reasoning_effort = 'high'

        [profiles.fast]
        model = "other"
        """
        #expect(CodexProvider.configValue("model", in: toml) == "gpt-6.1-sol")
        #expect(CodexProvider.configValue("model_reasoning_effort", in: toml) == "high")
        #expect(CodexProvider.configValue("missing", in: toml) == nil)
    }
}
