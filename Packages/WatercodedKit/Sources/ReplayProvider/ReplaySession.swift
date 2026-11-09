import AgentKit
import Foundation
import WatercodedCore

/// Plays a ``ReplayScript``. Waits for real decisions on approvals, plans and questions.
actor ReplaySession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>

    private enum Reply {
        case decision(PermissionDecision)
        case answers([String: String])
    }

    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let script: ReplayScript
    private let pace: Double
    private var turn: Task<Void, Never>?
    private var pending: (id: String, continuation: CheckedContinuation<Reply, Never>)?
    private var sequence = 0
    private var ended = false

    init(script: ReplayScript, pace: Double) {
        self.script = script
        self.pace = pace
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
        continuation.yield(.sessionStarted(SessionInfo(
            providerSessionID: "replay-\(UUID().uuidString.prefix(8))",
            model: "replay"
        )))
    }

    func send(_ message: UserMessage) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        guard turn == nil else { return } // one scripted turn at a time
        continuation.yield(.turnStarted)
        turn = Task { await self.play() }
    }

    func respond(to requestID: PermissionRequest.ID, with decision: PermissionDecision) async throws {
        resume(requestID, with: .decision(decision))
    }

    func answer(_ requestID: String, with answers: [String: String]) async throws {
        resume(requestID, with: .answers(answers))
    }

    func interrupt() async throws {
        turn?.cancel()
        if let pending {
            self.pending = nil
            pending.continuation.resume(returning: .decision(.deny(reason: "Interrupted")))
        }
    }

    func terminate() async {
        guard !ended else { return }
        try? await interrupt()
        ended = true
        continuation.yield(.sessionEnded(.exited(code: 0)))
        continuation.finish()
    }

    // MARK: Playback

    private func resume(_ requestID: String, with reply: Reply) {
        guard let pending, pending.id == requestID else { return }
        self.pending = nil
        pending.continuation.resume(returning: reply)
    }

    private func wait(for event: (String) -> AgentEvent) async -> Reply {
        let id = nextID("request")
        return await withCheckedContinuation { waiter in
            pending = (id, waiter)
            continuation.yield(event(id))
        }
    }

    private func play() async {
        var skipNextTool = false
        for step in script.steps {
            if Task.isCancelled {
                break
            }
            if case .tool = step, skipNextTool {
                skipNextTool = false // the user denied the approval that guarded this tool
                continue
            }
            if await perform(step) == .skipNextTool {
                skipNextTool = true
            }
        }
        continuation.yield(.turnFinished(Task.isCancelled ? .interrupted : .completed))
        turn = nil
    }

    private enum StepOutcome {
        case done
        case skipNextTool
    }

    private func perform(_ step: ReplayScript.Step) async -> StepOutcome {
        switch step {
        case let .pause(seconds):
            await sleep(seconds)
        case let .think(tokens):
            await sleep(0.4)
            continuation.yield(.thinking(messageID: nextID("thinking"), text: "", estimatedTokens: tokens))
        case let .say(text):
            await stream(text)
        case let .tool(name, kind, summary, output, failed):
            await runTool(name: name, kind: kind, summary: summary, output: output, failed: failed)
        case let .askPermission(tool, kind, summary):
            let reply = await wait { .permissionRequested(PermissionRequest(
                id: $0, toolName: tool, kind: kind, summary: summary, input: [:],
                subject: kind == .shell ? summary : nil
            )) }
            if case .decision(.deny) = reply {
                return .skipNextTool
            }
        case let .tasks(items):
            continuation.yield(.tasksUpdated(items))
        case let .proposePlan(markdown):
            if case .decision(.deny) = await wait(for: { .planProposed(requestID: $0, markdown: markdown) }) {
                await stream("Understood, I'll keep planning.")
            }
        case let .askQuestion(questions):
            if case let .answers(answers) = await wait(for: { .questionAsked(requestID: $0, questions: questions) }),
               let first = answers.values.first {
                await stream("Going with “\(first)”.")
            }
        case let .compact(pre, post):
            continuation.yield(.contextCompacted(preTokens: pre, postTokens: post))
            continuation.yield(.usageUpdated(UsageSnapshot(contextTokens: post, contextWindow: 200_000)))
        case let .usage(tokens, cost):
            continuation.yield(.usageUpdated(UsageSnapshot(
                contextTokens: tokens,
                contextWindow: 200_000,
                costUSD: cost
            )))
        }
        return .done
    }

    private func runTool(name: String, kind: ToolKind, summary: String, output: String, failed: Bool) async {
        let id = nextID("tool")
        continuation.yield(.toolCallStarted(ToolCall(callID: id, name: name, kind: kind, summary: summary, input: [:])))
        await sleep(0.5)
        continuation.yield(.toolCallFinished(callID: id, output: output, isError: failed))
    }

    private func stream(_ text: String) async {
        let id = nextID("message")
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        continuation.yield(.generationStarted)
        for word in words {
            if Task.isCancelled {
                return
            }
            continuation.yield(.textDelta(messageID: id, text: word + " "))
            await sleep(0.035)
        }
        continuation.yield(.generationFinished(outputTokens: words.count * 4 / 3)) // ~1.3 tokens per word
        continuation.yield(.messageCompleted(messageID: id, text: text))
    }

    private func sleep(_ seconds: Double) async {
        if pace > 0 {
            try? await Task.sleep(for: .seconds(seconds * pace))
        }
    }

    private func nextID(_ prefix: String) -> String {
        sequence += 1
        return "\(prefix)-\(sequence)"
    }
}
