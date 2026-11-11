import AgentKit
import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

/// Talks to the real `claude` CLI. Opt-in because it spends (a tiny amount of) the user's usage:
///
/// ```
/// WATERCODED_LIVE_CLAUDE=1 swift test --filter ClaudeCodeLive
/// ```
@Suite(
    "Claude Code (live)",
    .enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CLAUDE"] == "1"),
    .timeLimit(.minutes(2))
)
struct ClaudeCodeLiveTests {
    @Test func `approves a tool call end to end`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = ClaudeCodeProvider()
        #expect(await provider.availability().isAvailable)
        let session = try await provider.startSession(SessionConfiguration(workingDirectory: folder, model: "haiku"))
        try await session
            .send(UserMessage(text: "Use the Bash tool to run exactly: echo live > live.txt . Then reply DONE."))

        var billing: BillingMode?
        var sawPlanUsage = false
        var sawSession = false
        var sawText = false
        var approved = false
        var outcome: TurnOutcome?
        for await event in session.events.flatMap(unbatch) {
            switch event {
            case let .sessionStarted(info):
                sawSession = true
                billing = info.billing
            case .planUsageUpdated: sawPlanUsage = true
            case .textDelta, .messageCompleted: sawText = true
            case let .permissionRequested(request):
                try await session.respond(to: request.id, with: .allow)
                approved = true
            case let .turnFinished(result): outcome = result
            default: break
            }
            if outcome != nil {
                break
            }
        }
        await session.terminate()

        #expect(sawSession)
        #expect(billing != nil, "the CLI should say whether it's on a subscription or an API key")
        if billing == .subscription {
            #expect(sawPlanUsage)
        }
        #expect(sawText)
        #expect(approved)
        #expect(outcome == .completed)
        let written = try String(contentsOf: folder.appending(path: "live.txt"), encoding: .utf8)
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "live")
    }

    @Test func `answers a question, approves a plan and switches mode live`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = try await ClaudeCodeProvider().startSession(
            SessionConfiguration(workingDirectory: folder, model: "haiku", permissionMode: .plan)
        )
        try await session.send(UserMessage(text: """
        First use the AskUserQuestion tool to ask me whether I prefer Red or Blue (two options). \
        Then, still in plan mode, call ExitPlanMode with a one-step plan to write my answer into color.txt, \
        and after approval write the file.
        """))

        var answered = false
        var planned = false
        var notices: [String] = []
        var outcome: TurnOutcome?
        for await event in session.events.flatMap(unbatch) {
            switch event {
            case let .questionAsked(id, questions):
                let answers = Dictionary(uniqueKeysWithValues: questions.map { (
                    $0.text,
                    $0.options.last?.label ?? "Blue"
                ) })
                try await session.answer(id, with: answers)
                answered = true
            case let .planProposed(id, markdown):
                #expect(!markdown.isEmpty)
                try await session.setPermissionMode(.acceptEdits) // live, no restart
                try await session.respond(to: id, with: .allow)
                planned = true
            case let .permissionRequested(request):
                try await session.respond(to: request.id, with: .allow)
            case let .notice(notice):
                notices.append(notice.text)
            case let .turnFinished(result):
                outcome = result
            default:
                break
            }
            if outcome != nil {
                break
            }
        }
        await session.terminate()

        #expect(answered)
        #expect(planned)
        #expect(outcome == .completed)
        #expect(!notices.contains { $0.contains("rejected a settings change") })
        let written = try? String(contentsOf: folder.appending(path: "color.txt"), encoding: .utf8)
        #expect(written?.localizedCaseInsensitiveContains("blue") == true)
    }

    @Test func `a background session survives detaching and keeps its pending approval`() async throws {
        let relay = try #require(Self.relayExecutable, "build the package first")
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-live-\(UUID().uuidString)")
        let relayDirectory = folder.appending(path: ".relay")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = ClaudeCodeProvider(relay: RelayCommand(executable: relay, arguments: []))
        let first = try await provider.startSession(
            SessionConfiguration(workingDirectory: folder, model: "haiku", relayDirectory: relayDirectory)
        )
        try await first
            .send(UserMessage(text: "Use the Bash tool to run exactly: echo relay > relay.txt . Then reply DONE."))
        var requestID: String?
        for await event in first.events.flatMap(unbatch) {
            if case let .permissionRequested(request) = event {
                requestID = request.id
                break
            }
        }
        let handle = try #require(await first.relayHandle())
        await first.detach() // the app quits; the agent waits in the background

        let second = try await provider.reattachSession(handle)
        var sawRestoredRequest = false
        var outcome: TurnOutcome?
        for await event in second.events.flatMap(unbatch) {
            switch event {
            case let .permissionRequested(request):
                sawRestoredRequest = request.id == requestID
                try await second.respond(to: request.id, with: .allow)
            case let .turnFinished(result):
                outcome = result
            default:
                break
            }
            if outcome != nil {
                break
            }
        }
        await second.terminate()

        #expect(sawRestoredRequest, "the pending approval is restored after reattaching")
        #expect(outcome == .completed)
        let written = try? String(contentsOf: folder.appending(path: "relay.txt"), encoding: .utf8)
        #expect(written?.trimmingCharacters(in: .whitespacesAndNewlines) == "relay")
    }

    @Test func `MCP forms reach the user and the answers reach the tool`() async throws {
        let server = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Support/elicitation-mcp-server.py")
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appending(path: "mcp.json")
        let servers: JSONValue = ["mcpServers": ["elicit": ["command": "python3", "args": [.string(server.path)]]]]
        try servers.compactString().write(to: config, atomically: true, encoding: .utf8)

        var provider = ClaudeCodeProvider()
        provider.extraArguments = ["--mcp-config", config.path]
        let session = try await provider.startSession(SessionConfiguration(workingDirectory: folder, model: "haiku"))
        try await session.send(UserMessage(
            text: "Call the mcp__elicit__ask_profile tool once, then reply with exactly what it returned."
        ))
        var form: FormRecord?
        var reply = ""
        var finished = false
        for await event in session.events.flatMap(unbatch) {
            switch event {
            case let .permissionRequested(request):
                try await session.respond(to: request.id, with: .allow)
            case let .formRequested(record):
                form = record
                try await session.respondToForm(record.requestID, with: .accept(["name": "Ada", "role": "dev"]))
            case let .messageCompleted(_, text):
                reply = text
            case .turnFinished:
                finished = true
            default:
                break
            }
            if finished {
                break
            }
        }
        await session.terminate()
        #expect(form?.fields.map(\.key) == ["name", "role", "subscribe"])
        #expect(reply.contains("Ada"))
    }

    static var relayExecutable: URL? {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/",
              !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
            directory.deleteLastPathComponent()
        }
        return ["out/Products/Debug", "debug"].map { directory.appending(path: ".build/\($0)/watercoded-relay") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Direct provider tests inspect domain events; the app applies relay batches atomically instead.
private func unbatch(_ event: AgentEvent) -> AsyncStream<AgentEvent> {
    AsyncStream { continuation in
        if case let .relayBatch(events, _) = event {
            for event in events {
                continuation.yield(event)
            }
        } else {
            continuation.yield(event)
        }
        continuation.finish()
    }
}
