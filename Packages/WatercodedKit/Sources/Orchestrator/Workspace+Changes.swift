import AgentKit
import Foundation
import GitKit
import WatercodedCore

/// Which changes to show for a Current.
public enum ChangeScope: Hashable, Sendable {
    /// Staged, unstaged and untracked changes against the latest commit.
    case uncommitted
    /// Everything since the Current started, including committed work.
    case session
    /// One turn, by its 1-based index.
    case turn(Int)
}

extension Workspace {
    /// The diff of a Current's channel for `scope`.
    public func diff(for id: CurrentID, scope: ChangeScope = .session) async throws -> UnifiedDiff {
        guard let current = controller(id)?.current else { return UnifiedDiff(files: []) }
        let channel = current.channel
        switch scope {
        case .uncommitted:
            return try await UnifiedDiff(parsing: git.diff(in: channel.url, against: "HEAD"))
        case .session:
            return try await UnifiedDiff(parsing: git.diff(in: channel.url, against: channel.baseCommit))
        case let .turn(index):
            guard let snapshot = current.turnSnapshots?.first(where: { $0.index == index }) else {
                return UnifiedDiff(files: [])
            }
            // A turn still in progress is compared with the live working tree.
            let text = try await git.diff(in: channel.url, from: snapshot.beforeCommit, to: snapshot.afterCommit)
            return UnifiedDiff(parsing: text)
        }
    }

    /// Restores a file to the selected live comparison baseline.
    public func revert(_ file: FileDiff, in id: CurrentID, scope: ChangeScope = .session) async throws {
        guard let controller = controller(id) else { return }
        let channel = controller.current.channel
        let base: String
        switch scope {
        case .uncommitted:
            // A commit may have landed since the inspector loaded this patch.
            guard try await diff(for: id, scope: .uncommitted).files.contains(file) else {
                controller.noteFilesChanged()
                return
            }
            base = "HEAD"
        case .session: base = channel.baseCommit
        case .turn: throw AgentError.unsupported("Reverting a historical turn")
        }
        try await git.revertFile(file, to: base, in: channel.url)
        controller.noteFilesChanged()
    }

    /// Undoes one hunk of a file's changes.
    public func revert(
        _ hunk: Hunk, of file: FileDiff, in id: CurrentID, scope: ChangeScope = .session
    ) async throws {
        guard let controller = controller(id) else { return }
        if scope == .uncommitted {
            guard try await diff(for: id, scope: .uncommitted).files.contains(file) else {
                controller.noteFilesChanged()
                return
            }
        }
        try await git.revertHunk(hunk, of: file, in: controller.current.channel.url)
        controller.noteFilesChanged()
    }

    // MARK: Pools

    /// Extra folders agents in `pool` may access. Applies to sessions started after the change.
    public func setAdditionalDirectories(_ urls: [URL], for pool: PoolID) async {
        guard let index = pools.firstIndex(where: { $0.id == pool }) else { return }
        let paths = urls.map(\.path)
        updatePool(at: index) { $0.additionalDirectories = paths.isEmpty ? nil : paths }
        for controller in currents(in: pool) where controller.isSessionLive && !controller.isTurnActive {
            await controller.stopSession()
        }
    }

    // MARK: Replay

    /// Whether a registered provider can save Currents as replay scripts.
    public var canRecordReplays: Bool {
        registry.recorder != nil
    }

    /// Saves a Current as a replay script; it then appears as a model of the replay provider.
    @discardableResult
    public func saveReplayScript(for id: CurrentID) throws -> URL {
        guard let controller = controller(id), let recorder = registry.recorder else {
            throw AgentError.unsupported("Saving replay scripts")
        }
        return try recorder.record(controller.transcript, named: controller.current.title)
    }
}

extension CurrentController {
    /// Tells observers the working tree changed outside the agent (e.g. the user reverted a file).
    func noteFilesChanged() {
        activity.fileChangeRevision += 1
    }
}
