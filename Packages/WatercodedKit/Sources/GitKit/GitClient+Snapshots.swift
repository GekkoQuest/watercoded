import Foundation

extension GitClient {
    /// Identity for Watercoded's internal snapshot commits, so they work even when the user
    /// hasn't configured git (and never look like the user's own commits).
    static let snapshotIdentity = [
        "GIT_AUTHOR_NAME": "Watercoded", "GIT_AUTHOR_EMAIL": "snapshots@watercoded.invalid",
        "GIT_COMMITTER_NAME": "Watercoded", "GIT_COMMITTER_EMAIL": "snapshots@watercoded.invalid"
    ]

    /// Records the working tree (tracked and untracked files, honoring `.gitignore`) as a commit
    /// stored at `ref`, without touching the branch, the index or the stash. Returns the commit.
    ///
    /// Works by staging into a temporary copy of the index, so it's fast for large repositories
    /// and invisible to the user.
    @discardableResult
    public func snapshotWorkingTree(in worktree: URL, ref: String, message: String) async throws -> String {
        let indexPath = try await run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: worktree)
        let temporaryIndex = FileManager.default.temporaryDirectory
            .appending(path: "watercoded-index-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: indexPath) {
            try FileManager.default.copyItem(at: URL(filePath: indexPath), to: temporaryIndex)
        }
        defer { try? FileManager.default.removeItem(at: temporaryIndex) }

        let indexEnvironment = ["GIT_INDEX_FILE": temporaryIndex.path]
        try await run(["add", "--all", "--", "."], in: worktree, extraEnvironment: indexEnvironment)
        let tree = try await run(["write-tree"], in: worktree, extraEnvironment: indexEnvironment)
        // The snapshot's parent is the HEAD it was taken on, so branches started from it keep the repository's
        // history (a parentless snapshot would make them "unrelated histories" that can't be merged).
        let head = try? await run(["rev-parse", "--verify", "-q", "HEAD"], in: worktree)
        let parent = head.flatMap { $0.isEmpty ? nil : ["-p", $0] } ?? []
        let commit = try await run(
            ["commit-tree", tree] + parent + ["-m", message],
            in: worktree,
            extraEnvironment: Self.snapshotIdentity
        )
        try await run(["update-ref", ref, commit], in: worktree)
        return commit
    }

    /// The commit a snapshot was taken on (its parent), or `nil` for older snapshots that don't record one.
    public func snapshotParent(_ snapshot: String, in repository: URL) async -> String? {
        let parent = try? await run(["rev-parse", "--verify", "-q", "\(snapshot)^"], in: repository)
        return parent.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Makes `worktree`'s files match `snapshot` without committing: `HEAD` stays where it is and the differences
    /// show as uncommitted changes (new files untracked, removed files deleted).
    public func checkOutFiles(of snapshot: String, in worktree: URL) async throws {
        try await run(["read-tree", "-u", "--reset", snapshot], in: worktree)
        try await run(["reset", "-q"], in: worktree) // index back to HEAD; the files stay as the snapshot has them
    }

    /// Deletes every ref under `prefix` (e.g. a deleted Current's snapshots).
    public func deleteRefs(withPrefix prefix: String, in repository: URL) async throws {
        let refs = try await run(["for-each-ref", "--format=%(refname)", prefix], in: repository)
        for ref in refs.split(separator: "\n") where !ref.isEmpty {
            try await run(["update-ref", "-d", String(ref)], in: repository)
        }
    }

    /// Unified diff between two commits (or a commit and the working tree when `to` is `nil`).
    public func diff(in worktree: URL, from: String, to: String?) async throws -> String {
        guard let to else { return try await diff(in: worktree, against: from) }
        return try await run(["diff", "--no-color", "--no-ext-diff", "-M", from, to], in: worktree, trim: false)
    }

    // MARK: Reverting

    /// Puts one file back the way it was at `base`. Files that didn't exist at `base` are deleted.
    /// Only the working tree changes; the index is left alone.
    public func revertFile(_ file: FileDiff, to base: String, in worktree: URL) async throws {
        let current = worktree.appending(path: file.path)
        switch file.change {
        case .added:
            try FileManager.default.removeItem(at: current)
        case .renamed:
            if let oldPath = file.oldPath {
                try await run(["restore", "--source", base, "--worktree", "--", oldPath], in: worktree)
            }
            try? FileManager.default.removeItem(at: current)
        case .modified, .deleted:
            try await run(["restore", "--source", base, "--worktree", "--", file.path], in: worktree)
        }
    }

    /// Undoes one hunk in the working tree.
    public func revertHunk(_ hunk: Hunk, of file: FileDiff, in worktree: URL) async throws {
        let patchFile = FileManager.default.temporaryDirectory.appending(path: "watercoded-\(UUID().uuidString).patch")
        try file.patch(for: hunk).write(to: patchFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: patchFile) }
        try await run(["apply", "-R", "--recount", "--whitespace=nowarn", patchFile.path], in: worktree)
    }
}

extension FileDiff {
    /// A standalone patch containing just `hunk`, suitable for `git apply`.
    public func patch(for hunk: Hunk) -> String {
        let source = GitPatchPath.encode("a/\(oldPath ?? path)")
        let destination = GitPatchPath.encode("b/\(path)")
        let oldName = change == .added ? "/dev/null" : source
        let newName = change == .deleted ? "/dev/null" : destination
        var lines = ["diff --git \(source) \(destination)", "--- \(oldName)", "+++ \(newName)", hunk.header]
        for line in hunk.lines {
            let marker = switch line.kind {
            case .context: " "
            case .addition: "+"
            case .deletion: "-"
            }
            lines.append(marker + line.text)
            if line.isMissingNewline {
                lines.append("\\ No newline at end of file")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The line range a hunk covers in the new file, e.g. "12–18".
    public func lineRange(of hunk: Hunk) -> String {
        let numbers = hunk.lines.compactMap { $0.newNumber ?? $0.oldNumber }
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "\(first)" : "\(first)–\(last)"
    }
}
