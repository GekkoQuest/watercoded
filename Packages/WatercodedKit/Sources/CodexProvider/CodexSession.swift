import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// One `codex app-server` process speaking JSON-RPC over stdio, holding one thread. Owned directly, or
/// run under a background relay so it keeps working after the app quits (ADR 0009, ADR 0011).
actor CodexSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>

    private let channel: any LineChannel
    private let relay: RelayedProcess?
    private var detached = false
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private var translator = CodexWireTranslator()
    private var nextID = 0
    private var responses: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var recentStandardError: [String] = []
    private var ended = false
    /// Settings changed mid-session, applied with the next `turn/start`.
    private var pendingOverrides: [String: JSONValue] = [:]
    private var configuration: SessionConfiguration
    private let imageDirectory: URL
    /// Whether turns run in Codex's plan mode. Starts from the permission mode; Build turns it off.
    private var planning: Bool

    static func launch(
        _ spec: ProcessSpec,
        configuration: SessionConfiguration,
        relay: RelayCommand?
    ) async throws -> CodexSession {
        let session: CodexSession
        if let relay, let directory = configuration.relayDirectory {
            let process = try RelayedProcess.launch(relay: relay, directory: directory, spec: spec)
            session = CodexSession(channel: process, relay: process, configuration: configuration)
        } else {
            let process = try LineStreamingProcess(
                executable: spec.executable,
                arguments: spec.arguments,
                currentDirectory: spec.workingDirectory,
                environment: spec.environment
            )
            session = CodexSession(channel: process, relay: nil, configuration: configuration)
        }
        do {
            try await session.start(handshake: true)
        } catch {
            await session.terminate()
            throw error
        }
        return session
    }

    /// Reconnects to an app server that kept running under a relay while the app was closed.
    ///
    /// Replays the log through a fresh translator to rebuild the thread, pending approvals, questions
    /// and plan, and whether a turn is running; publishes that state once, then continues live. The app
    /// server still holds the thread, so no `thread/resume` is needed.
    static func reattach(_ handle: RelayHandle) async throws -> CodexSession {
        let process = try RelayedProcess(directory: handle.url, offset: handle.offset)
        let placeholder = SessionConfiguration(workingDirectory: FileManager.default.temporaryDirectory)
        let session = CodexSession(channel: process, relay: process, configuration: placeholder)
        await session.catchUp(through: handle.offset, in: handle.url)
        try await session.start(handshake: false)
        return session
    }

    private init(channel: any LineChannel, relay: RelayedProcess?, configuration: SessionConfiguration) {
        self.channel = channel
        self.relay = relay
        self.configuration = configuration
        planning = configuration.permissionMode == .plan
        imageDirectory = FileManager.default.temporaryDirectory.appending(path: "watercoded-codex-images")
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    private func start(handshake: Bool) async throws {
        Task { [weak self, channel] in
            for await line in channel.standardOutputLines {
                await self?.receive(line: line)
            }
            let code = await channel.exitCode()
            await self?.finish(exitCode: code)
        }
        Task { [weak self, channel] in
            for await line in channel.standardErrorLines {
                await self?.recordStandardError(line)
            }
        }
        guard handshake else { return }
        _ = try await request("initialize", CodexRequests.initialize())
        try notify("initialized")
        let open = CodexRequests.openThread(configuration)
        let result = try await request(open.method, open.params)
        for event in translator.threadOpened(result) {
            continuation.yield(event)
        }
    }

    // MARK: AgentSession

    func send(_ message: UserMessage) async throws {
        guard !ended, let threadID = translator.threadID else { throw AgentError.sessionClosed }
        let input = try CodexRequests.input(for: message, imageDirectory: imageDirectory)
        if translator.isTurnActive, let turnID = translator.currentTurnID {
            // Mid-turn messages steer the running turn.
            _ = try await request("turn/steer", [
                "threadId": .string(threadID),
                "input": input,
                "expectedTurnId": .string(turnID)
            ])
            return
        }
        try await startTurn(threadID: threadID, input: input)
    }

    private func startTurn(threadID: String, input: JSONValue) async throws {
        for event in translator.turnRequested() {
            continuation.yield(event)
        }
        var parameters: [String: JSONValue] = ["threadId": .string(threadID), "input": input]
        if let effort = configuration.effort {
            parameters["effort"] = .string(effort)
        }
        if let model = translator.model {
            parameters["collaborationMode"] = CodexRequests.collaborationMode(
                planning: planning, model: model, effort: configuration.effort
            )
        }
        parameters.merge(pendingOverrides) { _, new in new }
        pendingOverrides.removeAll()
        _ = try await request("turn/start", .object(parameters))
    }

    func respond(to requestID: PermissionRequest.ID, with decision: PermissionDecision) async throws {
        guard !ended else { return }
        if translator.consumePlan(requestID), let threadID = translator.threadID {
            switch decision {
            case .allow:
                // Build: leave plan mode with Ask's permissions, as Codex's own "Implement this plan" does.
                planning = false
                let mode: PermissionMode = configuration.permissionMode == .plan ? .ask : configuration.permissionMode
                try await setPermissionMode(mode)
                try await startTurn(threadID: threadID, input: Self.text("Implement the plan."))
            case let .deny(reason):
                try await startTurn(threadID: threadID, input: Self.text(reason))
            }
            return
        }
        guard let approval = translator.consumeApproval(requestID) else { return }
        try reply(to: approval.rpcID, result: CodexRequests.approvalResponse(decision, kind: approval.kind))
    }

    func respondToForm(_ requestID: String, with response: FormResponse) async throws {
        guard !ended, let rpcID = translator.consumeForm(requestID) else { return }
        try reply(to: rpcID, result: CodexRequests.formResponse(response))
    }

    func answer(_ requestID: String, with answers: [String: String]) async throws {
        guard !ended, let question = translator.consumeQuestion(requestID) else { return }
        try reply(to: question.rpcID, result: CodexRequests.userInputResponse(answers, ids: question.ids))
    }

    private static func text(_ text: String) -> JSONValue {
        [["type": "text", "text": .string(text), "text_elements": []]]
    }

    func runCommand(_ command: SessionCommand) async throws -> String? {
        guard !ended, let threadID = translator.threadID else { throw AgentError.sessionClosed }
        let rpc = CodexRequests.command(command, threadID: threadID)
        let result = try await request(rpc.method, rpc.params)
        switch command {
        case .compact:
            return nil // Progress arrives as turn notifications and a contextCompaction item.
        case .goal(.status):
            return CodexRequests.goalSummary(result)
        case let .goal(.set(objective)):
            // Setting persisted goal state does not submit input. Start its first turn explicitly.
            try await send(UserMessage(text: objective))
            return CodexRequests.goalSummary(result)
        case .goal(.clear):
            return "Goal cleared."
        }
    }

    func interrupt() async throws {
        guard !ended, let threadID = translator.threadID, let turnID = translator.currentTurnID,
              translator.isTurnActive else { return }
        translator.interruptWasRequested()
        _ = try await request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        configuration.permissionMode = mode
        planning = mode == .plan
        pendingOverrides["approvalPolicy"] = .string(CodexRequests.policy(for: mode).approval)
        let folder = translator.cwd.map { URL(filePath: $0) } ?? configuration.workingDirectory
        pendingOverrides["sandboxPolicy"] = CodexRequests.sandboxPolicy(
            for: mode,
            writableRoots: [folder] + configuration.additionalDirectories
        )
    }

    func restoreSettings(_ configuration: SessionConfiguration) async {
        // Reattached: the placeholder configuration becomes the Current's real one. The app server already holds
        // the thread's sandbox and approval policy; these drive what Watercoded sends and auto-approves.
        self.configuration = configuration
        planning = configuration.permissionMode == .plan
    }

    func setModel(_ model: String?) async throws {
        configuration.model = model
        translator.modelChanged(to: model == "default" ? nil : model)
        pendingOverrides["model"] = model.flatMap { $0 == "default" ? nil : .string($0) } ?? .null
    }

    func relayHandle() async -> RelayHandle? {
        guard let relay, !ended else { return nil }
        return RelayHandle(directory: relay.directory.path, offset: relay.offset)
    }

    func detach() async {
        guard let relay else {
            await terminate()
            return
        }
        detached = true
        relay.detach()
    }

    // MARK: Reattaching

    private func catchUp(through offset: Int64, in directory: URL) {
        var latest: [String: AgentEvent] = [:] // newest event of each kind worth restoring
        var pending: [String: AgentEvent] = [:]
        var order: [String] = []

        for (record, end) in RelayLog.records(in: directory) where end <= offset {
            switch record {
            case let .output(line):
                guard let message = try? JSONValue(parsing: line) else { continue }
                if message["method"] == nil, let result = message["result"], result["thread"] != nil {
                    // Our thread/start (or resume, fork) response.
                    for event in translator.threadOpened(result) {
                        latest[event.restoreKey ?? "other"] = event
                    }
                    continue
                }
                for event in translator.translate(message) {
                    switch event {
                    case let .permissionRequested(request):
                        pending[request.id] = event
                        order.append(request.id)
                    case let .planProposed(id, _), let .questionAsked(id, _), let .asyncQuestionAsked(id, _):
                        pending[id] = event
                        order.append(id)
                    case let .formRequested(form):
                        pending[form.requestID] = event
                        order.append(form.requestID)
                    default:
                        if let key = event.restoreKey {
                            latest[key] = event
                        }
                    }
                }
            case let .input(line):
                if let answered = replayInput(line) {
                    pending[answered] = nil
                }
            case .error, .exited:
                continue
            }
        }

        for key in ["session", "environment", "usage", "planUsage", "tasks"] {
            if let event = latest[key] {
                continuation.yield(event)
            }
        }
        if translator.isTurnActive {
            continuation.yield(.turnStarted)
        }
        for id in order {
            if let event = pending.removeValue(forKey: id) {
                continuation.yield(event)
            }
        }
    }

    /// Replays one line Watercoded sent: keeps request ids unique, marks turns started, and returns the
    /// id of a Codex request it answered (so it's no longer pending).
    private func replayInput(_ line: String) -> String? {
        guard let message = try? JSONValue(parsing: line) else { return nil }
        if let id = message["id"]?.int, message["method"] != nil {
            nextID = max(nextID, id)
        }
        switch message["method"]?.string {
        case "turn/start":
            _ = translator.turnRequested()
            return nil
        case nil where message["id"] != nil:
            let requestID = "codex-\(message["id"]?.compactString() ?? "")"
            _ = translator.consumeApproval(requestID)
            _ = translator.consumeQuestion(requestID)
            _ = translator.consumeForm(requestID)
            return requestID
        default:
            return nil
        }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message: JSONValue = ["id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            responses[id] = continuation
            do {
                try channel.send(line: message.compactString())
            } catch {
                responses[id] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String) throws {
        try channel.send(line: JSONValue.object(["method": .string(method)]).compactString())
    }

    private func reply(to id: JSONValue, result: JSONValue) throws {
        try channel.send(line: JSONValue.object(["id": id, "result": result]).compactString())
    }

    private func replyError(to id: JSONValue, message: String) throws {
        let error: JSONValue = ["code": -32601, "message": .string(message)]
        try channel.send(line: JSONValue.object(["id": id, "error": error]).compactString())
    }

    private func receive(line: String) {
        guard !line.isEmpty, let message = try? JSONValue(parsing: line) else { return }
        if message["method"] == nil, let id = message["id"]?.int {
            // A response to one of our requests.
            guard let waiting = responses.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                waiting.resume(throwing: CodexError.request(error["message"]?.string ?? error.compactString()))
            } else {
                waiting.resume(returning: message["result"] ?? .null)
            }
            return
        }
        if let method = message["method"]?.string, let id = message["id"],
           !CodexWireTranslator.handlesServerRequest(method) {
            // Questions, MCP elicitations and the like aren't supported yet: decline so the turn continues.
            try? replyError(to: id, message: "Watercoded doesn't support \(method) yet.")
            continuation.yield(.notice(Notice(
                .info,
                "Codex asked for something Watercoded can't show yet (\(method))."
            )))
            return
        }
        let events = translator.translate(message)
        if message["method"]?.string == "mcpServer/elicitation/request", events.isEmpty, let id = message["id"] {
            // A kind of request Watercoded can't show (e.g. a verification challenge): decline it.
            try? reply(to: id, result: CodexRequests.formResponse(.decline))
            continuation.yield(.notice(Notice(
                .info,
                "An MCP server asked for something Watercoded can't show yet, so it was declined."
            )))
            return
        }
        for event in events {
            if configuration.permissionMode == .fullAccess, case let .permissionRequested(request) = event,
               let approval = translator.consumeApproval(request.id) {
                // Full Access: approve whatever Codex asks for, without showing it.
                try? reply(to: approval.rpcID, result: CodexRequests.approvalResponse(.allow, kind: approval.kind))
                continue
            }
            continuation.yield(event)
        }
    }

    private func recordStandardError(_ line: String) {
        recentStandardError.append(line)
        if recentStandardError.count > 20 {
            recentStandardError.removeFirst()
        }
    }

    private func finish(exitCode: Int32) {
        guard !ended, !detached else { return }
        ended = true
        for waiting in responses.values {
            waiting.resume(throwing: AgentError.sessionClosed)
        }
        responses.removeAll()
        if exitCode == 0 || exitCode == SIGTERM || exitCode == SIGKILL {
            continuation.yield(.sessionEnded(.exited(code: exitCode)))
        } else {
            let detail = recentStandardError.suffix(5).joined(separator: "\n")
            continuation.yield(.sessionEnded(.failed(
                message: detail.isEmpty ? "codex exited with status \(exitCode)." : detail
            )))
        }
        continuation.finish()
    }
}

extension CodexSession {
    func terminate() async {
        guard !detached else { return }
        channel.terminate(grace: .seconds(3))
        // A replacement uses the same relay directory. Let the old host finish its cleanup first.
        _ = await channel.exitCode()
    }
}

enum CodexError: Error, LocalizedError {
    case request(String)

    var errorDescription: String? {
        switch self {
        case let .request(message): "Codex: \(message)"
        }
    }
}

extension AgentEvent {
    /// Which piece of restored state this event carries after reattaching, if any.
    fileprivate var restoreKey: String? {
        switch self {
        case .sessionStarted: "session"
        case .environmentReported: "environment"
        case .usageUpdated: "usage"
        case .planUsageUpdated: "planUsage"
        case .tasksUpdated: "tasks"
        default: nil
        }
    }
}
