import Foundation
import GitKit
import ProcessKit
import WatercodedCore

/// A worktree folder on disk and what, if anything, still uses it.
public struct WorktreeInfo: Identifiable, Hashable, Sendable {
    public enum Use: Hashable, Sendable {
        /// An open session works in it.
        case active
        /// Its session is archived; nothing runs there until it's reopened.
        case archived
        /// No session refers to it (deleted, or left behind).
        case unused
    }

    public let url: URL
    public let sizeBytes: Int64?
    public let modified: Date?
    public let sessionTitle: String?
    public let use: Use

    public var id: URL {
        url
    }

    /// Open sessions' worktrees are never offered for removal.
    public var isRemovable: Bool {
        use != .active
    }
}

extension Workspace {
    /// Every worktree under the worktrees folder, largest first, with its size and owner.
    public func worktreeInventory() async -> [WorktreeInfo] {
        var items: [WorktreeInfo] = []
        for url in worktrees.existingWorktrees() {
            // Delegated sessions share their parent's folder, so look at every session using it.
            let owners = currents.filter {
                $0.current.channel.kind == .worktree && Self.samePath($0.current.channel.url, url)
            }
            let owner = owners.first { $0.current.parentID == nil } ?? owners.first
            let use: WorktreeInfo.Use = if owners.isEmpty {
                .unused
            } else if owners.allSatisfy({ $0.current.status == .settled }) {
                .archived
            } else {
                .active
            }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            await items.append(WorktreeInfo(
                url: url,
                sizeBytes: Self.diskUsage(of: url),
                modified: modified,
                sessionTitle: owner?.current.title,
                use: use
            ))
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// Removes worktrees that no open session uses. Branches and their commits are kept.
    /// Ownership is checked again now, not trusted from when the list was measured: a session reopened since
    /// then keeps its worktree. Returns the worktrees kept for that reason.
    @discardableResult
    public func removeWorktrees(_ items: [WorktreeInfo]) async throws -> [WorktreeInfo] {
        let worktrees = worktrees
        return try await removeWorktrees(items, removing: { try await worktrees.removeWorktree(at: $0) })
    }

    /// Shares one reservation between cleanup callers and sessions that are reopening.
    func removeWorktrees(
        _ items: [WorktreeInfo],
        removing remove: @escaping @MainActor (URL) async throws -> Void
    ) async throws -> [WorktreeInfo] {
        var kept: [WorktreeInfo] = []
        for item in items where item.isRemovable {
            let inUse = currents.contains {
                $0.current.status != .settled && $0.current.channel.kind == .worktree
                    && Self.samePath($0.current.channel.url, item.url)
            }
            if inUse {
                kept.append(item)
                continue
            }
            let path = Self.worktreePath(item.url)
            if let removal = worktreeRemovals[path] {
                try await removal.value
                continue
            }
            let removal = Task { try await remove(item.url) }
            worktreeRemovals[path] = removal
            defer { worktreeRemovals[path] = nil }
            try await removal.value
        }
        return kept
    }

    func waitForWorktreeCleanup(at url: URL) async {
        // A failed cleanup can leave the folder intact; let normal restoration/startup handle it.
        try? await worktreeRemovals[Self.worktreePath(url)]?.value
    }

    private static func worktreePath(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        worktreePath(lhs) == worktreePath(rhs)
    }

    private static func diskUsage(of url: URL) async -> Int64? {
        guard let result = try? await ProcessRunner.run(
                  executable: URL(filePath: "/usr/bin/du"),
                  arguments: ["-sk", url.path],
                  timeout: .seconds(30)
              ), result.succeeded,
              let kilobytes = result.standardOutput.split(separator: "\t").first.flatMap({ Int64($0) })
        else { return nil }
        return kilobytes * 1024
    }
}
