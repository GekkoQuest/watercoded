import Foundation
import WatercodedCore

/// Creates and removes the isolated worktrees ("Channels") Currents run in.
///
/// Layout: `<root>/<pool-slug>-<pool-id-prefix>/<current-slug>`, on branch `watercoded/<current-slug>`.
/// The root defaults to `~/.watercoded/worktrees`, a path without spaces, because some build tools
/// still break on paths like `~/Library/Application Support`.
public struct WorktreeManager: Sendable {
    public static let branchPrefix = "watercoded/"

    public let root: URL
    private let git: GitClient

    public init(root: URL = WorktreeManager.defaultRoot, git: GitClient = GitClient()) {
        self.root = root
        self.git = git
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".watercoded", directoryHint: .isDirectory)
            .appending(path: "worktrees", directoryHint: .isDirectory)
    }

    /// Creates a new worktree on a fresh branch from `base` (default: the pool's current `HEAD`). With `files`, the
    /// worktree's files are then set to that snapshot, uncommitted, so the branch keeps `base`'s history.
    public func makeWorktreeChannel(
        for pool: Pool,
        title: String,
        base: String? = nil,
        files snapshot: String? = nil
    ) async throws -> Channel {
        var start = base
        if start == nil {
            start = try await git.headCommit(in: pool.rootURL)
        }
        guard let base = start else { throw GitError.nothingToLand }
        let slug = Slug.make(from: title)
        let poolFolder = root
            .appending(path: "\(Slug.make(from: pool.name))-\(pool.id.description.prefix(6).lowercased())")
        try FileManager.default.createDirectory(at: poolFolder, withIntermediateDirectories: true)

        let name = try await uniqueName(slug, in: poolFolder, repository: pool.rootURL)
        let path = poolFolder.appending(path: name, directoryHint: .isDirectory)
        let branch = Self.branchPrefix + name
        try await git.addWorktree(repository: pool.rootURL, path: path, branch: branch, base: base)
        if let snapshot {
            try await git.checkOutFiles(of: snapshot, in: path)
        }
        return Channel(kind: .worktree, path: path.path, branch: branch, baseCommit: base)
    }

    /// Uses the pool's own checkout (no isolation). Works in repositories with no commits yet:
    /// changes are then shown relative to the empty tree.
    public func makeCheckoutChannel(for pool: Pool) async throws -> Channel {
        let base = try await git.headCommitIfAny(in: pool.rootURL) ?? GitClient.emptyTree
        let branch = try await git.currentBranch(in: pool.rootURL) ?? "HEAD"
        return Channel(kind: .checkout, path: pool.rootPath, branch: branch, baseCommit: base)
    }

    /// Every worktree folder under ``root`` (`<root>/<pool>/<current>`).
    public func existingWorktrees() -> [URL] {
        let manager = FileManager.default
        let pools = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return pools.flatMap { pool in
            ((try? manager.contentsOfDirectory(at: pool, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    /// Removes a worktree folder Watercoded created, finding its repository from the worktree itself.
    /// The branch (and its commits) are kept. If the repository is gone, the folder is just deleted.
    public func removeWorktree(at path: URL) async throws {
        if let common = try? await git.commonGitDirectory(in: path) {
            try await git.removeWorktree(repository: common.deletingLastPathComponent(), path: path, force: true)
        } else if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        let parent = path.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Recreates a worktree channel's folder from its branch if it was removed (by Land or a cleanup).
    public func restoreChannelIfNeeded(_ channel: Channel, in pool: Pool) async throws {
        guard channel.kind == .worktree, !FileManager.default.fileExists(atPath: channel.url.path) else { return }
        try FileManager.default.createDirectory(
            at: channel.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await git.addWorktree(repository: pool.rootURL, path: channel.url, existingBranch: channel.branch)
    }

    /// Removes a worktree channel's checkout. The branch (and its commits) are kept.
    public func removeChannel(_ channel: Channel, from pool: Pool, force: Bool = false) async throws {
        guard channel.kind == .worktree else { return }
        try await git.removeWorktree(repository: pool.rootURL, path: channel.url, force: force)
    }

    private func uniqueName(_ slug: String, in folder: URL, repository: URL) async throws -> String {
        var candidate = slug
        var suffix = 2
        while true {
            let pathTaken = FileManager.default.fileExists(atPath: folder.appending(path: candidate).path)
            let branchTaken = try await git.branchExists(Self.branchPrefix + candidate, in: repository)
            if !pathTaken, !branchTaken {
                return candidate
            }
            candidate = "\(slug)-\(suffix)"
            suffix += 1
        }
    }
}
