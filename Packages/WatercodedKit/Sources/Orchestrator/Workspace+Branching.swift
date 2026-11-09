import AgentKit
import Foundation
import WatercodedCore

/// Where a branch starts relative to the turn it's made from.
public enum BranchPoint: Sendable, Hashable {
    /// After the turn: its files and conversation, ready for a different next step.
    case after
    /// Before the turn: its message goes back into the composer to edit and send again.
    case before
}

extension Workspace {
    /// Whether a session can be branched at the turn started by `messageID`.
    public func canBranch(_ controller: CurrentController, at messageID: UUID, _ point: BranchPoint) -> Bool {
        guard controller.provider?.descriptor.capabilities.contains(.branching) == true,
              let (snapshot, previous) = turn(of: controller, startedBy: messageID) else { return false }
        switch point {
        case .after: return snapshot.afterCommit != nil && snapshot.checkpoint != nil
        // The first turn needs no conversation to resume; later ones need the previous turn's checkpoint.
        case .before: return previous == nil || previous?.checkpoint != nil
        }
    }

    /// Starts a new session in its own worktree from a turn of `controller`: the files as they were
    /// at that point (from the turn's snapshot) and the conversation up to it. The original is untouched.
    @discardableResult
    public func branch(_ controller: CurrentController, at messageID: UUID, _ point: BranchPoint) async throws
        -> CurrentController {
        guard let pool = pool(controller.current.poolID),
              let (snapshot, previous) = turn(of: controller, startedBy: messageID),
              canBranch(controller, at: messageID, point) else { throw WorkspaceError.cannotBranch }
        let source = controller.current
        let title = "\(source.title) (branch)"
        let base = point == .after ? snapshot.afterCommit : snapshot.beforeCommit
        let channel = try await worktrees.makeWorktreeChannel(for: pool, title: title, base: base)

        var branched = Current(
            poolID: pool.id,
            title: title,
            providerID: source.providerID,
            model: source.model,
            permissionMode: source.permissionMode,
            channel: channel
        )
        branched.effort = source.effort
        branched.titleSource = .user
        branched.status = .ashore
        let checkpoint = point == .after ? snapshot.checkpoint : previous?.checkpoint
        if let checkpoint {
            branched.providerSessionID = source.providerSessionID
            branched.pendingBranchAt = checkpoint
        }

        let transcript = Self.transcript(controller.transcript, upTo: messageID, in: source, point)
        try await repository.saveCurrent(branched)
        try await repository.saveTranscript(transcript, for: branched.id)
        let copy = adopt(branched, transcript: transcript)
        if point == .before, let index = controller.transcript.firstIndex(where: { $0.id == messageID }),
           case let .user(text) = controller.transcript[index].content {
            copy.draft = text
        }
        return copy
    }

    private func turn(of controller: CurrentController, startedBy messageID: UUID)
        -> (snapshot: TurnSnapshot, previous: TurnSnapshot?)? {
        let snapshots = controller.current.turnSnapshots ?? []
        guard let index = snapshots.firstIndex(where: { $0.userMessageID == messageID }) else { return nil }
        return (snapshots[index], index > 0 ? snapshots[index - 1] : nil)
    }

    /// The transcript before the turn's message (`.before`), or through the end of the turn (`.after`).
    static func transcript(
        _ items: [TranscriptItem],
        upTo messageID: UUID,
        in current: Current,
        _ point: BranchPoint
    ) -> [TranscriptItem] {
        guard let start = items.firstIndex(where: { $0.id == messageID }) else { return items }
        if point == .before {
            return Array(items[..<start])
        }
        // The turn ends where the next turn's message begins.
        let starters = Set((current.turnSnapshots ?? []).compactMap(\.userMessageID))
        let end = items[(start + 1)...].firstIndex { starters.contains($0.id) } ?? items.endIndex
        return Array(items[..<end])
    }
}
