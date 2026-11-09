import AgentKit
import Foundation
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

    @Test func `the model catalog comes from the account`() async throws {
        let catalog = try #require(await CodexProvider().modelCatalog())
        #expect(!catalog.models.isEmpty)
        #expect(catalog.defaultModelID != nil)
    }
}
