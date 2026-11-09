import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// One `codex app-server` process speaking JSON-RPC over stdio, holding one thread.
actor CodexSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>

    private let channel: any LineChannel
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

    static func launch(_ spec: ProcessSpec, configuration: SessionConfiguration) async throws -> CodexSession {
        let process = try LineStreamingProcess(
            executable: spec.executable,
            arguments: spec.arguments,
            currentDirectory: spec.workingDirectory,
            environment: spec.environment
        )
        let session = CodexSession(channel: process, configuration: configuration)
        do {
            try await session.start()
        } catch {
            await session.terminate()
            throw error
        }
        return session
    }

    private init(channel: any LineChannel, configuration: SessionConfiguration) {
        self.channel = channel
        self.configuration = configuration
        imageDirectory = FileManager.default.temporaryDirectory.appending(path: "watercoded-codex-images")
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    private func start() async throws {
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
        for event in translator.turnRequested() {
            continuation.yield(event)
        }
        var parameters: [String: JSONValue] = ["threadId": .string(threadID), "input": input]
        if let effort = configuration.effort {
            parameters["effort"] = .string(effort)
        }
        parameters.merge(pendingOverrides) { _, new in new }
        pendingOverrides.removeAll()
        _ = try await request("turn/start", .object(parameters))
    }

    func respond(to requestID: PermissionRequest.ID, with decision: PermissionDecision) async throws {
        guard !ended, let approval = translator.consumeApproval(requestID) else { return }
        try reply(to: approval.rpcID, result: CodexRequests.approvalResponse(decision))
    }

    func interrupt() async throws {
        guard !ended, let threadID = translator.threadID, let turnID = translator.currentTurnID,
              translator.isTurnActive else { return }
        translator.interruptWasRequested()
        _ = try await request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        configuration.permissionMode = mode
        pendingOverrides["approvalPolicy"] = .string(CodexRequests.policy(for: mode).approval)
        pendingOverrides["sandboxPolicy"] = CodexRequests.sandboxPolicy(
            for: mode,
            writableRoots: [configuration.workingDirectory] + configuration.additionalDirectories
        )
    }

    func setModel(_ model: String?) async throws {
        configuration.model = model
        pendingOverrides["model"] = model.flatMap { $0 == "default" ? nil : .string($0) } ?? .null
    }

    func terminate() async {
        channel.terminate(grace: .seconds(3))
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
        guard !ended else { return }
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

enum CodexError: Error, LocalizedError {
    case request(String)

    var errorDescription: String? {
        switch self {
        case let .request(message): "Codex: \(message)"
        }
    }
}
