import Foundation
import WatercodedCore

extension Workspace {
    /// Saves how a repository's new worktrees are prepared. Applies to sessions started afterwards.
    public func setWorktreeSetup(_ setup: WorktreeSetup, for pool: PoolID) {
        guard let index = pools.firstIndex(where: { $0.id == pool }) else { return }
        updatePool(at: index) { $0.worktreeSetup = setup.isEmpty ? nil : setup }
    }

    /// Top-level git-ignored items in the repository, offered as things to copy into new worktrees.
    public func ignoredItems(in pool: PoolID) async -> [String] {
        guard let pool = self.pool(pool) else { return [] }
        return await (try? git.ignoredTopLevelItems(in: pool.rootURL)) ?? []
    }

    /// Saves the repository's check command. `nil` or an empty command removes it.
    public func setVerifySettings(_ settings: VerifySettings?, for pool: PoolID) {
        guard let index = pools.firstIndex(where: { $0.id == pool }) else { return }
        let command = settings?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updatePool(at: index) {
            $0.verify = command.isEmpty ? nil : VerifySettings(
                command: command,
                runsAfterEdits: settings?.runsAfterEdits ?? true
            )
        }
    }
}
