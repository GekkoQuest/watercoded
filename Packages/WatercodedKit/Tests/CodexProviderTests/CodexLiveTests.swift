import AgentKit
import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import CodexProvider

/// Runs the real `codex` CLI (spends a few tokens). Enable with:
/// WATERCODED_LIVE_CODEX=1 swift test --filter CodexLive
@Suite(
    "Codex live",
    .enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CODEX"] == "1"),
    .serialized
)
struct CodexLiveTests {
    @Test func `a real session answers and finishes its turn`() async throws {
        let provider = CodexProvider()
        guard case .available = await provider.availability() else {
            Issue.record("Codex isn't installed and signed in")
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-codex-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = try await provider.startSession(SessionConfiguration(
            workingDirectory: folder,
            permissionMode: .ask
        ))
        try await session.send(UserMessage(text: "Reply with just the word OK."))
        var reply = ""
        var outcome: TurnOutcome?
        var sessionID: String?
        for await event in session.events {
            switch event {
            case let .sessionStarted(info): sessionID = info.providerSessionID
            case let .messageCompleted(_, text): reply = text
            case let .turnFinished(result): outcome = result
            default: break
            }
            if outcome != nil {
                break
            }
        }
        await session.terminate()
        #expect(sessionID != nil)
        #expect(reply.uppercased().contains("OK"))
        #expect(outcome == .completed)
    }

    @Test func `plan mode proposes a plan and Build implements it`() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-codex-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = try await CodexProvider().startSession(SessionConfiguration(
            workingDirectory: folder,
            permissionMode: .plan
        ))
        try await session.send(UserMessage(
            text: "Plan adding a file named hello.txt containing the word hi. Two steps at most. Don't ask questions."
        ))
        var built = false
        var buildStarted = false
        var outcome: TurnOutcome?
        for await event in session.events {
            switch event {
            case let .planProposed(id, markdown):
                #expect(!markdown.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "hello.txt").path))
                built = true
                try await session.respond(to: id, with: .allow) // Build
            case let .permissionRequested(request):
                try await session.respond(to: request.id, with: .allow)
            case let .questionAsked(id, questions):
                try await session.answer(id, with: Dictionary(uniqueKeysWithValues: questions.map {
                    ($0.text, $0.options.first?.label ?? "Yes")
                }))
            case .turnStarted where built:
                buildStarted = true
            case let .turnFinished(result) where buildStarted: // not the plan turn's own end
                outcome = result
            default:
                break
            }
            if outcome != nil {
                break
            }
        }
        await session.terminate()
        #expect(built)
        #expect(outcome == .completed)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "hello.txt").path))
    }

    @Test func `a background session survives detaching and keeps its pending approval`() async throws {
        let relay = try #require(Self.relayExecutable, "build the package first")
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-codex-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = CodexProvider(relay: RelayCommand(executable: relay, arguments: []))
        #expect(provider.descriptor.capabilities.contains(.backgroundSessions))
        let first = try await provider.startSession(SessionConfiguration(
            workingDirectory: folder, permissionMode: .ask, relayDirectory: folder.appending(path: ".relay")
        ))
        try await first.send(UserMessage(text: "Run the shell command `touch made-by-codex.txt`, then reply DONE."))
        var asked: PermissionRequest?
        for await event in first.events {
            if case let .permissionRequested(request) = event {
                asked = request
                break
            }
        }
        #expect(asked?.subject?.contains("touch") == true)
        let handle = try #require(await first.relayHandle())
        await first.detach() // as if Watercoded quit with the approval still waiting

        let second = try await provider.reattachSession(handle)
        var restored = false
        var outcome: TurnOutcome?
        for await event in second.events {
            switch event {
            case let .permissionRequested(request):
                restored = true
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
        #expect(restored, "the pending approval is restored after reattaching")
        #expect(outcome == .completed)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "made-by-codex.txt").path))
    }

    @Test(arguments: [PermissionMode.ask, .fullAccess])
    func `MCP tools run and their forms reach the user`(mode: PermissionMode) async throws {
        let server = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Support/elicitation-mcp-server.py")
        var provider = CodexProvider()
        provider.extraArguments = [
            "-c",
            "mcp_servers.elicit.command=\"python3\"",
            "-c",
            "mcp_servers.elicit.args=[\"\(server.path)\"]"
        ]
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-codex-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let session = try await provider.startSession(SessionConfiguration(
            workingDirectory: folder,
            permissionMode: mode
        ))
        try await session.send(UserMessage(
            text: "Call the ask_profile tool from the elicit MCP server once, then reply with exactly what it returned."
        ))
        var approvals = 0
        var form: FormRecord?
        var reply = ""
        var outcome: TurnOutcome?
        for await event in session.events {
            switch event {
            case let .permissionRequested(request):
                approvals += 1
                try await session.respond(to: request.id, with: .allow)
            case let .formRequested(record):
                form = record
                try await session.respondToForm(record.requestID, with: .accept(["name": "Ada", "role": "dev"]))
            case let .messageCompleted(_, text):
                reply = text
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
        #expect(form?.fields.map(\.key).contains("name") == true)
        #expect(mode == .fullAccess ? approvals == 0 : approvals >= 1) // Full Access never asks
        #expect(reply.contains("Ada"))
        #expect(outcome == .completed)
    }

    @Test func `the model catalog comes from the account`() async throws {
        let catalog = try #require(await CodexProvider().modelCatalog())
        #expect(!catalog.models.isEmpty)
        #expect(catalog.defaultModelID != nil)
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
