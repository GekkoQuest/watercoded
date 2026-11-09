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
    public func removeWorktrees(_ items: [WorktreeInfo]) async throws {
        for item in items where item.isRemovable {
            try await worktrees.removeWorktree(at: item.url)
        }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
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
