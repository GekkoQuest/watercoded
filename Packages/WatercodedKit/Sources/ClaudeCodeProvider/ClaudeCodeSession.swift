import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// One `claude` process speaking stream-json, either owned directly or running under a background
/// relay (see docs/adr/0009-background-sessions-via-relays.md).
actor ClaudeCodeSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>

    private let channel: any LineChannel
    private let relay: RelayedProcess?
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private var translator = ClaudeWireTranslator()
    private var requestCounter = 0
    private var recentStandardError: [String] = []
    private var ended = false
    private var detached = false

    // MARK: Starting

    static func launch(
        _ spec: ProcessSpec,
        relay: RelayCommand?,
        relayDirectory: URL?
    ) async throws -> ClaudeCodeSession {
        let session: ClaudeCodeSession
        if let relay, let relayDirectory {
            let process = try RelayedProcess.launch(relay: relay, directory: relayDirectory, spec: spec)
            session = ClaudeCodeSession(channel: process, relay: process)
        } else {
            let process = try LineStreamingProcess(
                executable: spec.executable,
                arguments: spec.arguments,
                currentDirectory: spec.workingDirectory,
                environment: spec.environment
            )
            session = ClaudeCodeSession(channel: process, relay: nil)
        }
        try await session.start(initialize: true)
        return session
    }

    /// Reconnects to a relay that kept running while the app was closed.
    ///
    /// Replays the whole log through a fresh translator to rebuild state (pending approvals and
    /// their inputs, the task list, whether a turn is running), publishes that state once, then
    /// continues live from where the app stopped reading.
    static func reattach(_ handle: RelayHandle) async throws -> ClaudeCodeSession {
        let process = try RelayedProcess(directory: handle.url, offset: handle.offset)
        let session = ClaudeCodeSession(channel: process, relay: process)
        await session.catchUp(through: handle.offset, in: handle.url)
        try await session.start(initialize: false)
        return session
    }

    private init(channel: any LineChannel, relay: RelayedProcess?) {
        self.channel = channel
        self.relay = relay
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    private func start(initialize: Bool) throws {
        if initialize {
            try write(ClaudeControlMessages.initialize(requestID: nextRequestID()))
        }
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
    }

    // MARK: AgentSession

    func send(_ message: UserMessage) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        continuation.yield(.turnStarted)
        try write(ClaudeControlMessages.userMessage(message.text, images: message.images))
    }

    func runCommand(_ command: SessionCommand) async throws -> String? {
        try await send(UserMessage(text: command.slashText))
        return nil
    }

    func respond(to requestID: PermissionRequest.ID, with decision: PermissionDecision) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        let input = translator.consumePermissionInput(for: requestID)
        try write(ClaudeControlMessages.permissionResponse(requestID: requestID, decision: decision, input: input))
    }

    func answer(_ requestID: String, with answers: [String: String]) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        let input = translator.consumePermissionInput(for: requestID)
        try write(ClaudeControlMessages.questionAnswer(requestID: requestID, input: input, answers: answers))
    }

    func respondToForm(_ requestID: String, with response: FormResponse) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        try write(ClaudeControlMessages.formResponse(requestID: requestID, response: response))
    }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        try write(ClaudeControlMessages.setPermissionMode(requestID: nextRequestID(), mode: mode))
    }

    func setModel(_ model: String?) async throws {
        guard !ended else { throw AgentError.sessionClosed }
        try write(ClaudeControlMessages.setModel(requestID: nextRequestID(), model: model == "default" ? nil : model))
    }

    func interrupt() async throws {
        guard !ended else { return }
        try write(ClaudeControlMessages.interrupt(requestID: nextRequestID()))
    }

    func terminate() async {
        guard !detached else { return }
        channel.terminate(grace: .seconds(3))
        // A replacement uses the same relay directory. Let the old host finish its cleanup first.
        _ = await channel.exitCode()
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
        var pending: [String: AgentEvent] = [:]
        var order: [String] = []
        var latest: [String: AgentEvent] = [:] // newest event of each kind worth restoring
        var turnActive = false

        for (record, end) in RelayLog.records(in: directory) where end <= offset {
            switch record {
            case let .output(line):
                guard let message = try? JSONValue(parsing: line) else { continue }
                for event in translator.translate(message) {
                    switch event {
                    case let .permissionRequested(request):
                        pending[request.id] = event
                        order.append(request.id)
                    case let .planProposed(id, _), let .questionAsked(id, _):
                        pending[id] = event
                        order.append(id)
                    case let .formRequested(form):
                        pending[form.requestID] = event
                        order.append(form.requestID)
                    case .sessionStarted: latest["session"] = event
                    case .environmentReported: latest["environment"] = event
                    case .commandsAvailable: latest["commands"] = event
                    case .usageUpdated: latest["usage"] = event
                    case .planUsageUpdated: latest["planUsage"] = event
                    case .tasksUpdated: latest["tasks"] = event
                    case .turnFinished: turnActive = false
                    default: break
                    }
                }
            case let .input(line):
                guard let message = try? JSONValue(parsing: line) else { continue }
                if message["type"]?.string == "user" {
                    turnActive = true
                } else if let answered = message["response"]?["request_id"]?.string {
                    pending[answered] = nil
                    _ = translator.consumePermissionInput(for: answered)
                }
            case .error, .exited:
                continue
            }
        }

        for key in ["session", "environment", "commands", "usage", "planUsage", "tasks"] {
            if let event = latest[key] {
                continuation.yield(event)
            }
        }
        if turnActive {
            continuation.yield(.turnStarted)
        }
        for id in order {
            if let event = pending.removeValue(forKey: id) {
                continuation.yield(event)
            }
        }
    }

    // MARK: Internals

    private func receive(line: String) {
        guard !line.isEmpty, let message = try? JSONValue(parsing: line) else { return }
        for event in translator.translate(message) {
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
        if exitCode == 0 || exitCode == SIGTERM || exitCode == SIGKILL {
            continuation.yield(.sessionEnded(.exited(code: exitCode)))
        } else {
            let detail = recentStandardError.suffix(5).joined(separator: "\n")
            continuation.yield(.sessionEnded(.failed(
                message: detail.isEmpty ? "claude exited with status \(exitCode)." : detail
            )))
        }
        continuation.finish()
    }

    private func write(_ message: JSONValue) throws {
        try channel.send(line: message.compactString())
    }

    private func nextRequestID() -> String {
        requestCounter += 1
        return "watercoded-\(UUID().uuidString.prefix(8))-\(requestCounter)"
    }
}
