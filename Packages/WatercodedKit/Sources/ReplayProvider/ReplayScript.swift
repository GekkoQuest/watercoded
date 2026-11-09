import Foundation
import WatercodedCore

/// What a ``ReplaySession`` does for each user message. Codable, so scripts can be saved and shared.
public struct ReplayScript: Codable, Sendable, Hashable {
    public enum Step: Codable, Sendable, Hashable {
        case pause(seconds: Double)
        case think(tokens: Int)
        case say(String)
        case tool(name: String, kind: ToolKind, summary: String, output: String, failed: Bool = false)
        case askPermission(tool: String, kind: ToolKind, summary: String)
        case tasks([TaskItem])
        case proposePlan(markdown: String)
        case askQuestion([QuestionRecord.Question])
        case compact(pre: Int, post: Int)
        case usage(contextTokens: Int, costUSD: Double)
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }
}

extension ReplayScript {
    /// Shows off everything the UI renders: thinking, a task list, approvals, a question,
    /// a plan, subagent-free tool calls, a passing test run, and compaction.
    public static let standard = ReplayScript(steps: [
        .pause(seconds: 0.4),
        .think(tokens: 240),
        .say("I'll start by looking at how the token refresh is wired up."),
        .tasks([
            TaskItem(id: "1", title: "Find where tokens are refreshed", status: .inProgress),
            TaskItem(id: "2", title: "Serialize refreshes behind an actor"),
            TaskItem(id: "3", title: "Run the TokenStore tests")
        ]),
        .usage(contextTokens: 18000, costUSD: 0.01),
        .tool(name: "Read", kind: .read, summary: "Sources/TokenStore.swift", output: "final class TokenStore { … }"),
        .tool(name: "Grep", kind: .search, summary: "refresh()", output: "2 matches in 1 file"),
        .askQuestion([
            QuestionRecord.Question(
                text: "Should concurrent callers share one refresh, or each wait in line?",
                header: "Strategy",
                options: [
                    .init(label: "Share one refresh", detail: "Callers await the same in-flight request."),
                    .init(label: "Wait in line", detail: "Refreshes run one after another.")
                ]
            )
        ]),
        .proposePlan(markdown: """
        ## Plan
        1. Turn `TokenStore` into an `actor`.
        2. Keep the in-flight refresh in a `Task` so concurrent callers await the same one.
        3. Add a test that fires 10 concurrent `validToken()` calls and expects one refresh.
        """),
        .tasks([
            TaskItem(id: "1", title: "Find where tokens are refreshed", status: .completed),
            TaskItem(id: "2", title: "Serialize refreshes behind an actor", status: .inProgress),
            TaskItem(id: "3", title: "Run the TokenStore tests")
        ]),
        .usage(contextTokens: 31000, costUSD: 0.03),
        .askPermission(tool: "Edit", kind: .edit, summary: "Edit Sources/TokenStore.swift"),
        .tool(name: "Edit", kind: .edit, summary: "Sources/TokenStore.swift", output: "Applied 1 edit"),
        .tasks([
            TaskItem(id: "1", title: "Find where tokens are refreshed", status: .completed),
            TaskItem(id: "2", title: "Serialize refreshes behind an actor", status: .completed),
            TaskItem(id: "3", title: "Run the TokenStore tests", status: .inProgress)
        ]),
        .askPermission(tool: "Bash", kind: .shell, summary: "swift test --filter TokenStoreTests"),
        .tool(
            name: "Bash",
            kind: .shell,
            summary: "swift test --filter TokenStoreTests",
            output: "Executed 12 tests, with 0 failures"
        ),
        .tasks([
            TaskItem(id: "1", title: "Find where tokens are refreshed", status: .completed),
            TaskItem(id: "2", title: "Serialize refreshes behind an actor", status: .completed),
            TaskItem(id: "3", title: "Run the TokenStore tests", status: .completed)
        ]),
        .usage(contextTokens: 42000, costUSD: 0.05),
        .compact(pre: 42000, post: 12000),
        .say(
            "Done. `TokenStore` is now an actor, so concurrent refreshes share one request, "
                + "and all 12 tests pass."
        )
    ])

    /// Rebuilds a script from a finished Current: what the agent said and did, in order.
    /// Edits and commands ask for approval again so the replay feels like the original.
    public init(recording transcript: [TranscriptItem]) {
        var steps: [Step] = [.pause(seconds: 0.3)]
        for item in transcript {
            switch item.content {
            case .user, .userImages:
                continue
            case let .assistant(text):
                steps.append(.say(text))
            case let .thinking(record):
                steps.append(.think(tokens: record.estimatedTokens ?? 100))
            case let .toolCall(record) where record.parentCallID == nil:
                if record.kind == .edit || record.kind == .shell {
                    steps.append(.askPermission(tool: record.name, kind: record.kind, summary: record.summary))
                }
                steps.append(.tool(
                    name: record.name,
                    kind: record.kind,
                    summary: record.summary,
                    output: String((record.output ?? "").prefix(2000)),
                    failed: record.status == .failed
                ))
            case .toolCall:
                continue
            case let .plan(record):
                steps.append(.proposePlan(markdown: record.markdown))
            case let .question(record):
                steps.append(.askQuestion(record.questions))
            case .notice, .form:
                continue // forms came from an MCP server; a replay has none
            }
        }
        self.init(steps: steps)
    }
}
