import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@Suite("Turn stats")
struct TurnStatsTests {
    @Test func `speed counts only time spent generating`() {
        let start = Date(timeIntervalSince1970: 0)
        var stats = TurnStats(startedAt: start)
        #expect(stats.tokensPerSecond == nil)

        stats.generationStarted(at: start)
        stats.generationFinished(outputTokens: 100, at: start.addingTimeInterval(2))
        // A 10-second tool run in between doesn't count against speed.
        stats.generationStarted(at: start.addingTimeInterval(12))
        stats.generationFinished(outputTokens: 200, at: start.addingTimeInterval(14))

        #expect(stats.outputTokens == 300)
        #expect(stats.tokensPerSecond == 75)
        #expect(stats.isActive)
    }
}

@Suite("Terminal hand-off")
struct TerminalHandOffTests {
    @Test func `shell quoting survives quotes and spaces`() {
        #expect(CurrentController.shellQuoted("a b") == "'a b'")
        #expect(CurrentController.shellQuoted("it's") == "'it'\\''s'")
    }
}

@MainActor
@Suite("Pull request changes")
struct PullRequestChangeTests {
    private let url = URL(string: "https://github.com/o/r/pull/1")!

    @Test func `only real changes notify`() {
        let open = PullRequestStatus(url: url, checks: .pending)
        var failing = open
        failing.checks = .failing
        failing.failingChecks = ["test"]
        #expect(Workspace.changes(from: open, to: failing) == [.checksFailed(["test"])])
        #expect(Workspace.changes(from: failing, to: failing).isEmpty)

        var reviewed = failing
        reviewed.reviewDecision = "CHANGES_REQUESTED"
        reviewed.commentCount = 3
        #expect(Workspace.changes(from: failing, to: reviewed) == [.changesRequested])

        var merged = reviewed
        merged.state = .merged
        #expect(Workspace.changes(from: reviewed, to: merged) == [.merged])
    }
}

@MainActor
@Suite("Branch transcripts")
struct BranchTranscriptTests {
    @Test func `branches keep the conversation up to the chosen point`() {
        let first = TranscriptItem(content: .user(text: "one"))
        let reply = TranscriptItem(content: .assistant(text: "done one"))
        let second = TranscriptItem(content: .user(text: "two"))
        let reply2 = TranscriptItem(content: .assistant(text: "done two"))
        let items = [first, reply, second, reply2]
        var current = Current(
            poolID: PoolID(), title: "T", providerID: ProviderID(rawValue: "x"), model: nil,
            permissionMode: .ask, channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "abc")
        )
        var turn1 = TurnSnapshot(index: 1, startedAt: .now, beforeCommit: "a")
        turn1.userMessageID = first.id
        var turn2 = TurnSnapshot(index: 2, startedAt: .now, beforeCommit: "b")
        turn2.userMessageID = second.id
        current.turnSnapshots = [turn1, turn2]

        #expect(Workspace.transcript(items, upTo: first.id, in: current, .after).map(\.id) == [first.id, reply.id])
        #expect(Workspace.transcript(items, upTo: second.id, in: current, .after).count == 4)
        #expect(Workspace.transcript(items, upTo: second.id, in: current, .before).map(\.id) == [first.id, reply.id])
        #expect(Workspace.transcript(items, upTo: first.id, in: current, .before).isEmpty)
    }
}
