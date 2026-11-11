import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Idle agent exit")
struct IdleAgentExitTests {
    private func current() -> Current {
        Current(
            poolID: PoolID(),
            title: "Exit",
            providerID: "test",
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "HEAD"),
            providerSessionID: "existing-session",
            status: .ashore
        )
    }

    @Test func `an idle agent exit preserves completed work without requesting attention`() {
        let controller = CurrentController(
            current: current(),
            transcript: [],
            provider: nil,
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        controller.handle(.sessionEnded(.failed(message: "Connection failed")))
        #expect(controller.current.status == .ashore)
        #expect(!controller.isAwaitingUser)
        #expect(controller.current.providerSessionID == "existing-session")
        #expect(!controller.transcript.contains {
            if case let .notice(notice) = $0.content {
                notice.level == .error
            } else {
                false
            }
        })
    }

    @Test func `an active turn still reports a failed agent`() {
        let controller = CurrentController(
            current: current(),
            transcript: [],
            provider: nil,
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        controller.handle(.turnStarted)
        controller.handle(.sessionEnded(.failed(message: "Connection failed")))
        #expect(controller.current.status == .stalled)
    }

    @Test(arguments: [false, true])
    func `recovery repairs completed idle failures and preserves unfinished work`(unfinished: Bool) {
        var current = current()
        current.status = .stalled
        current.lastTurnEndedAt = Date(timeIntervalSince1970: 10)
        current.turnSnapshots = [TurnSnapshot(
            index: 1,
            startedAt: .distantPast,
            beforeCommit: "before",
            afterCommit: unfinished ? nil : "after"
        )]
        let items = [
            TranscriptItem(date: Date(timeIntervalSince1970: 9), content: .assistant(text: "Done")),
            TranscriptItem(date: Date(timeIntervalSince1970: 20), content: .notice(Notice(
                .error, "The agent stopped unexpectedly: codex exited with status -1."
            )))
        ]
        let controller = CurrentController(
            current: current,
            transcript: items,
            provider: nil,
            repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        #expect(controller.current.status == (unfinished ? .stalled : .ashore))
        #expect(controller.transcript.count == items.count)
    }
}
