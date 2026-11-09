import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    func clearPendingInteractions() {
        pendingPermissions.removeAll()
        pendingPlan = nil
        pendingQuestion = nil
        pendingForm = nil
    }

    /// One flat dispatch over every agent event; each case delegates to a focused handler.
    func handle(_ event: AgentEvent) {
        switch event {
        case let .sessionStarted(info):
            update {
                $0.providerSessionID = info.providerSessionID
                $0.pendingBranchAt = nil // the branch now has its own session
                if let billing = info.billing {
                    $0.usage.billing = billing
                }
            }
            scheduleSave()
        case .turnStarted:
            isTurnActive = true
            turnStats = TurnStats()
            if current.status != .waiting {
                update { $0.status = .flowing }
            }
        case let .textDelta(_, text):
            streamingText += text
        case let .checkpoint(id):
            lastCheckpoint = id
        case .generationStarted, .generationFinished:
            recordGeneration(event)
        case let .messageCompleted(_, text):
            streamingText = ""
            append(.assistant(text: text))
        case let .thinking(_, text, tokens):
            flushStreamingText()
            append(.thinking(ThinkingRecord(text: text, estimatedTokens: tokens)))
        case let .toolCallStarted(call):
            handleToolStarted(call)
        case let .toolCallFinished(callID, output, isError):
            handleToolFinished(callID: callID, output: output, isError: isError)
        case let .permissionRequested(request):
            handlePermission(request)
        case let .commandsAvailable(commands):
            availableCommands = commands
        case let .environmentReported(environment):
            update { $0.environment = environment }
        case let .planProposed(requestID, markdown):
            handlePlan(requestID: requestID, markdown: markdown)
        case let .questionAsked(requestID, questions):
            handleQuestion(requestID: requestID, questions: questions)
        case let .formRequested(form):
            handleForm(form)
        case let .tasksUpdated(items):
            update { $0.tasks = items }
        case let .contextCompacted(pre, post):
            handleCompaction(pre: pre, post: post)
        case let .usageUpdated(usage):
            handleUsage(usage)
        case let .planUsageUpdated(plan):
            update { $0.usage.planUsage = plan }
        case let .notice(notice):
            append(.notice(notice))
        case let .turnFinished(outcome):
            handleTurnFinished(outcome)
        case let .sessionEnded(end):
            handleSessionEnded(end)
        }
    }

    private func handlePermission(_ request: PermissionRequest) {
        // Standing approvals for this repository answer immediately.
        if approvalRules().contains(where: { $0.matches(toolName: request.toolName, subject: request.subject) }) {
            Task { [session] in try? await session?.respond(to: request.id, with: .allow) }
            return
        }
        pendingPermissions.append(request)
        update { $0.status = .waiting }
        onAttention?(self, .approvalNeeded(request))
    }

    private func handleToolStarted(_ call: ToolCall) {
        flushStreamingText()
        let record = ToolCallRecord(
            callID: call.callID,
            name: call.name,
            kind: call.kind,
            summary: call.summary,
            input: call.input.prettyString(),
            parentCallID: call.parentCallID
        )
        append(.toolCall(record))
        toolItemIndex[call.callID] = transcript.count - 1
        activity.toolCallCount += 1
        activity.lastToolKind = call.kind
        if call.kind == .subagent {
            activeSubagentCalls.insert(call.callID)
            activity.activeSubagents = activeSubagentCalls.count
        }
    }

    private func handleToolFinished(callID: String, output: String, isError: Bool) {
        guard let index = toolItemIndex[callID], case var .toolCall(record) = transcript[index].content else { return }
        record.output = output
        record.status = isError ? .failed : .succeeded
        transcript[index].content = .toolCall(record)
        activity.consecutiveToolErrors = isError ? activity.consecutiveToolErrors + 1 : 0
        if record.kind == .edit || record.kind == .shell {
            activity.fileChangeRevision += 1
        }
        if record.kind == .edit, !isError {
            turnEditCount += 1
        }
        if activeSubagentCalls.remove(callID) != nil {
            activity.activeSubagents = activeSubagentCalls.count
        }
        // Test and build runs decide whether the water is clear or murky.
        if record.kind == .shell, CheckResult.isCheck(record.summary) {
            let check = CheckResult(command: record.summary, passed: !isError)
            turnChecks.append(check)
            update { $0.lastCheck = check }
        }
    }

    private func handlePlan(requestID: String, markdown: String) {
        flushStreamingText()
        let plan = PlanRecord(requestID: requestID, markdown: markdown)
        pendingPlan = plan
        append(.plan(plan))
        update { $0.status = .waiting }
        onAttention?(self, .planReady)
    }

    private func handleQuestion(requestID: String, questions: [QuestionRecord.Question]) {
        flushStreamingText()
        let record = QuestionRecord(requestID: requestID, questions: questions)
        pendingQuestion = record
        append(.question(record))
        update { $0.status = .waiting }
        onAttention?(self, .questionAsked(questions.first?.text ?? "The agent has a question."))
    }

    private func handleCompaction(pre: Int?, post: Int?) {
        activity.compactions += 1
        let compact: (Int) -> String = { $0.formatted(.number.notation(.compactName)) }
        let detail = if let pre, let post {
            " (\(compact(pre)) → \(compact(post)) tokens)"
        } else {
            ""
        }
        append(.notice(Notice(.info, "Context compacted\(detail).")))
    }

    private func handleUsage(_ usage: UsageSnapshot) {
        update {
            // Providers report counters; keep what we already learned about billing, limits and caching.
            let previous = $0.usage
            $0.usage = usage
            $0.usage.billing = usage.billing ?? previous.billing
            $0.usage.planUsage = usage.planUsage ?? previous.planUsage
            $0.usage.cacheTTL = usage.cacheTTL ?? previous.cacheTTL
            $0.usage.contextWindow = usage.contextWindow ?? previous.contextWindow
        }
    }

    private func handleTurnFinished(_ outcome: TurnOutcome) {
        flushStreamingText()
        isTurnActive = false
        turnStats?.endedAt = .now
        activity.fileChangeRevision += 1
        activeSubagentCalls.removeAll()
        activity.activeSubagents = 0
        update { $0.lastTurnEndedAt = .now }
        Task { await recordTurnEnd(outcome) }
        guard current.status != .settled else { return }
        switch outcome {
        case .completed:
            verifyTurn()
            update { $0.status = isAwaitingUser ? .waiting : .ashore }
        case .interrupted:
            append(.notice(Notice(.info, "Interrupted.")))
            update { $0.status = .ashore }
        case let .failed(message):
            fail(message)
        }
        onAttention?(self, .turnFinished(outcome))
        scheduleSave()
    }

    private func handleSessionEnded(_ end: SessionEnd) {
        flushStreamingText()
        session = nil
        eventTask = nil
        isSessionLive = false
        isTurnActive = false
        clearPendingInteractions()
        activeSubagentCalls.removeAll()
        activity.activeSubagents = 0
        if let relay = current.relay {
            update { $0.relay = nil }
            try? FileManager.default.removeItem(at: relay.url)
        }
        if case let .failed(message) = end, current.status != .settled {
            fail("The agent stopped unexpectedly: \(message)")
        } else if current.status == .flowing || current.status == .waiting {
            update { $0.status = .ashore }
        }
        scheduleSave()
    }

    /// Flags turns whose result wasn't checked: edits with no test or build run, or a failing last run.
    /// Facts only, no guessing from the agent's prose.
    private func verifyTurn() {
        defer {
            turnEditCount = 0
            turnChecks.removeAll()
        }
        if turnEditCount > 0, let settings = verifySettings(), settings.runsAfterEdits {
            // Watercoded checks the work itself rather than warning about what the agent did or didn't run.
            Task { await verify() }
        } else if let last = turnChecks.last, !last.passed {
            append(.notice(Notice(.error, "The last test or build this turn failed: `\(last.command)`.")))
        } else if turnEditCount > 0, turnChecks.isEmpty {
            let files = turnEditCount == 1 ? "a file" : "\(turnEditCount) files"
            append(.notice(Notice(.warning, "The agent edited \(files) but didn't run tests or a build this turn.")))
        }
    }

    func flushStreamingText() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""
        if !text.isEmpty {
            append(.assistant(text: text))
        }
    }

    /// Timing and output tokens for the turn stats line and the session's total.
    private func recordGeneration(_ event: AgentEvent) {
        switch event {
        case .generationStarted:
            turnStats?.generationStarted()
        case let .generationFinished(tokens):
            turnStats?.generationFinished(outputTokens: tokens)
            update { $0.outputTokens = ($0.outputTokens ?? 0) + tokens }
        default:
            break
        }
    }
}
