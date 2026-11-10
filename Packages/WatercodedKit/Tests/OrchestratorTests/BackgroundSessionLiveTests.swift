import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import Orchestrator

/// Opt-in regression for quitting after a turn finishes, then continuing through the same relay.
@MainActor
@Suite("Idle background sessions (live)", .serialized, .timeLimit(.minutes(2)))
struct BackgroundSessionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CLAUDE"] == "1"))
    func `idle Claude sessions survive a workspace relaunch`() async throws {
        let relay = try relayCommand()
        try await checkRelaunch(provider: ClaudeCodeProvider(relay: relay))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WATERCODED_LIVE_CODEX"] == "1"))
    func `idle Codex sessions survive a workspace relaunch`() async throws {
        let relay = try relayCommand()
        try await checkRelaunch(provider: CodexProvider(relay: relay))
    }

    private func checkRelaunch(provider: any AgentProvider) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let registry = ProviderRegistry([provider])
        let workspace = Workspace(
            registry: registry, repository: fixture.storage,
            sessionsRoot: fixture.repository.deletingLastPathComponent().appending(path: "live-relays"),
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        let pool = try await workspace.addPool(at: fixture.repository)
        let channel = try await fixture.workspace.worktrees.makeCheckoutChannel(for: pool)
        let current = Current(
            poolID: pool.id,
            title: "Live relay",
            providerID: provider.descriptor.id,
            channel: channel
        )
        let controller = workspace.adopt(current, transcript: [])
        var restored: Workspace?
        do {
            await controller.send("Reply with just FIRST_OK. Do not use any tools.")
            try await waitUntil(timeout: .seconds(60)) { controller.current.status == .ashore }
            let handle = try #require(controller.current.relay)
            let pidURL = handle.url.appending(path: RelayFiles.pid)
            let pid = try String(contentsOf: pidURL, encoding: .utf8)
            await workspace.shutdown()
            let reopened = Workspace(
                registry: registry, repository: fixture.storage, sessionsRoot: workspace.sessionsRoot,
                delegationMailbox: fixture.workspace.delegationMailbox
            )
            restored = reopened
            await reopened.load()
            let resumed = try #require(reopened.controller(controller.id))
            #expect(resumed.isSessionLive)
            #expect(resumed.current.status == .ashore)
            try await send("SECOND_OK", to: resumed)
            #expect(try String(contentsOf: pidURL, encoding: .utf8) == pid, "Keep the original relay process")
            // Effort changes restart an idle agent. Reusing the directory must not race the old host's cleanup.
            await resumed.setEffort("low")
            try await send("THIRD_OK", to: resumed)
            #expect(try String(contentsOf: pidURL, encoding: .utf8) != pid)
            await resumed.stopSession()
            await reopened.shutdown()
        } catch {
            if let restored {
                for session in restored.currents {
                    await session.stopSession()
                }
                await restored.shutdown()
            }
            await controller.stopSession()
            await workspace.shutdown()
            throw error
        }
    }

    private func send(_ word: String, to controller: CurrentController) async throws {
        await controller.send("Reply with just \(word). Do not use any tools.")
        try await waitUntil(timeout: .seconds(60)) {
            controller.current.status == .ashore && controller.transcript.contains {
                if case let .assistant(text) = $0.content {
                    text.contains(word)
                } else {
                    false
                }
            }
        }
    }

    private func relayCommand() throws -> RelayCommand {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path != "/",
              !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
            directory.deleteLastPathComponent()
        }
        let binary = try #require(["out/Products/Debug", "debug"]
            .map { directory.appending(path: ".build/\($0)/watercoded-relay") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        return RelayCommand(executable: binary, arguments: [])
    }
}
