import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import GitKit

@Suite("UnifiedDiff")
struct UnifiedDiffTests {
    @Test func `parses modified and added files`() {
        let text = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let x = 1
        +let x = 2
        +let y = 3
         print(x)
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        """
        let diff = UnifiedDiff(parsing: text)
        #expect(diff.files.map(\.path) == ["Sources/App.swift", "new.txt"])
        #expect(diff.files[0].change == .modified)
        #expect(diff.files[1].change == .added)
        #expect(diff.additions == 3)
        #expect(diff.deletions == 1)

        let lines = diff.files[0].hunks[0].lines
        #expect(lines[1] == DiffLine(kind: .deletion, text: "let x = 1", oldNumber: 2))
        #expect(lines[2] == DiffLine(kind: .addition, text: "let x = 2", newNumber: 2))
        #expect(lines[4].oldNumber == 3 && lines[4].newNumber == 4)
    }

    @Test func `parses renames and binaries`() {
        let text = """
        diff --git a/old.png b/new.png
        similarity index 100%
        rename from old.png
        rename to new.png
        Binary files a/old.png and b/new.png differ
        """
        let file = UnifiedDiff(parsing: text).files[0]
        #expect(file.change == .renamed)
        #expect(file.oldPath == "old.png")
        #expect(file.path == "new.png")
        #expect(file.isBinary)
    }
}

@Suite("Worktrees", .serialized)
struct WorktreeTests {
    @Test func `creates worktree channel and diffs it`() async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        let manager = WorktreeManager(root: repository.worktreeRoot)
        let pool = Pool(name: "Demo Repo", rootPath: repository.url.path)

        let channel = try await manager.makeWorktreeChannel(for: pool, title: "Fix the flaky test")
        #expect(channel.kind == .worktree)
        #expect(channel.branch == "watercoded/fix-the-flaky-test")
        #expect(FileManager.default.fileExists(atPath: channel.url.appending(path: "README.md").path))

        try "changed\n".write(to: channel.url.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "brand new\n".write(to: channel.url.appending(path: "NEW.md"), atomically: true, encoding: .utf8)
        let diff = try await UnifiedDiff(parsing: GitClient().diff(in: channel.url, against: channel.baseCommit))
        #expect(Set(diff.files.map(\.path)) == ["README.md", "NEW.md"])

        let second = try await manager.makeWorktreeChannel(for: pool, title: "Fix the flaky test")
        #expect(second.branch == "watercoded/fix-the-flaky-test-2")

        try await manager.removeChannel(channel, from: pool, force: true)
        #expect(!FileManager.default.fileExists(atPath: channel.path))
    }

    @Test func `rejects non repositories`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: GitError.notARepository(path: folder.path)) {
            try await GitClient().topLevel(of: folder)
        }
    }
}

/// A throwaway git repository with one commit.
struct TemporaryRepository {
    let url: URL
    let worktreeRoot: URL

    static func make() async throws -> TemporaryRepository {
        let base = FileManager.default.temporaryDirectory.appending(path: "watercoded-tests-\(UUID().uuidString)")
        let url = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "hello\n".write(to: url.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let git = URL(filePath: "/usr/bin/git")
        let identity = ["-c", "user.name=Watercoded Tests", "-c", "user.email=tests@watercoded.invalid"]
        for arguments in [
            ["init", "-q", "-b", "main"],
            ["add", "."],
            identity + ["commit", "-q", "-m", "Initial commit"]
        ] {
            let result = try await ProcessRunner.run(executable: git, arguments: arguments, currentDirectory: url)
            guard result.succeeded else { throw GitError.commandFailed(
                arguments: arguments,
                message: result.standardError
            ) }
        }
        // Resolve symlinks (/var → /private/var) so paths compare equal to git's output.
        let resolved = URL(filePath: url.resolvingSymlinksInPath().path, directoryHint: .isDirectory)
        return TemporaryRepository(url: resolved, worktreeRoot: base.appending(path: "worktrees"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite("Repositories without commits", .serialized)
struct UnbornRepositoryTests {
    @Test func `checkout channel works and worktrees explain why they can't`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "watercoded-unborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/git"),
            arguments: ["init", "-q", "-b", "main"],
            currentDirectory: folder
        )
        try "draft\n".write(to: folder.appending(path: "notes.md"), atomically: true, encoding: .utf8)

        let git = GitClient()
        let root = try await git.topLevel(of: folder)
        #expect(try await git.headCommitIfAny(in: root) == nil)
        #expect(try await git.currentBranch(in: root) == "main")
        await #expect(throws: GitError.noCommits(path: root.path)) { try await git.headCommit(in: root) }

        let pool = Pool(name: "unborn", rootPath: root.path)
        let manager = WorktreeManager(root: folder.appending(path: "worktrees"))
        await #expect(throws: GitError.noCommits(path: root.path)) {
            try await manager.makeWorktreeChannel(for: pool, title: "anything")
        }

        let channel = try await manager.makeCheckoutChannel(for: pool)
        #expect(channel.baseCommit == GitClient.emptyTree)
        #expect(channel.branch == "main")
        let diff = try await UnifiedDiff(parsing: git.diff(in: channel.url, against: channel.baseCommit))
        #expect(diff.files.map(\.path) == ["notes.md"])
    }
}

@Suite("Snapshots and reverting", .serialized)
struct SnapshotTests {
    @Test func `snapshots capture the working tree without touching the index or branch`() async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        let git = GitClient()
        let readme = repository.url.appending(path: "README.md")
        let headBefore = try await git.headCommit(in: repository.url)

        let before = try await git.snapshotWorkingTree(
            in: repository.url,
            ref: "refs/watercoded/test/before",
            message: "before"
        )
        try "changed\n".write(to: readme, atomically: true, encoding: .utf8)
        try "new\n".write(to: repository.url.appending(path: "NEW.md"), atomically: true, encoding: .utf8)
        let after = try await git.snapshotWorkingTree(
            in: repository.url,
            ref: "refs/watercoded/test/after",
            message: "after"
        )

        let turn = try await UnifiedDiff(parsing: git.diff(in: repository.url, from: before, to: after))
        #expect(Set(turn.files.map(\.path)) == ["README.md", "NEW.md"])
        #expect(try await git.headCommit(in: repository.url) == headBefore)
        let staged = try await git.run(["diff", "--cached", "--name-only"], in: repository.url)
        #expect(staged.isEmpty, "snapshots must not stage anything")

        try await git.deleteRefs(withPrefix: "refs/watercoded/test/", in: repository.url)
        #expect(try await git.run(["for-each-ref", "refs/watercoded/"], in: repository.url).isEmpty)
    }

    @Test func `files and hunks can be reverted`() async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        let git = GitClient()
        let base = try await git.headCommit(in: repository.url)
        let readme = repository.url.appending(path: "README.md")
        try "hello\nworld\n".write(to: readme, atomically: true, encoding: .utf8)
        try "new\n".write(to: repository.url.appending(path: "NEW.md"), atomically: true, encoding: .utf8)

        var diff = try await UnifiedDiff(parsing: git.diff(in: repository.url, against: base))
        let modified = try #require(diff.files.first { $0.path == "README.md" })
        try await git.revertHunk(modified.hunks[0], of: modified, in: repository.url)
        #expect(try String(contentsOf: readme, encoding: .utf8) == "hello\n")

        diff = try await UnifiedDiff(parsing: git.diff(in: repository.url, against: base))
        let added = try #require(diff.files.first { $0.path == "NEW.md" })
        try await git.revertFile(added, to: base, in: repository.url)
        #expect(try await UnifiedDiff(parsing: git.diff(in: repository.url, against: base)).isEmpty)
    }
}

@Suite("Landing", .serialized)
struct LandingTests {
    private let identity = ["-c", "user.name=Tests", "-c", "user.email=tests@watercoded.invalid"]

    @Test func `commit and merge a worktree branch`() async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        try await setIdentity(in: repository.url)
        let git = GitClient()
        let pool = Pool(name: "repo", rootPath: repository.url.path)
        let channel = try await WorktreeManager(root: repository.worktreeRoot).makeWorktreeChannel(
            for: pool,
            title: "Add notes"
        )

        try "notes\n".write(to: channel.url.appending(path: "NOTES.md"), atomically: true, encoding: .utf8)
        #expect(try await git.hasUncommittedChanges(in: channel.url))
        #expect(try await git.listFiles(in: channel.url).contains("NOTES.md"))
        try await git.commitEverything(in: channel.url, message: "Add notes")
        #expect(try await git.commitsAhead(of: channel.baseCommit, head: "HEAD", in: channel.url) == 1)

        try await git.merge(channel.branch, into: "main", in: repository.url)
        #expect(FileManager.default.fileExists(atPath: repository.url.appending(path: "NOTES.md").path))
    }

    @Test func `merging refuses the wrong branch and aborts conflicts`() async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        try await setIdentity(in: repository.url)
        let git = GitClient()
        let pool = Pool(name: "repo", rootPath: repository.url.path)
        let channel = try await WorktreeManager(root: repository.worktreeRoot).makeWorktreeChannel(
            for: pool,
            title: "Change readme"
        )
        try "agent\n".write(to: channel.url.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git.commitEverything(in: channel.url, message: "Agent change")

        await #expect(throws: GitError.wrongBranch(expected: "release", actual: "main")) {
            try await git.merge(channel.branch, into: "release", in: repository.url)
        }

        // A conflicting change on main makes the merge fail and be rolled back.
        try "user\n".write(to: repository.url.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await git.commitEverything(in: repository.url, message: "User change")
        await #expect(throws: GitError.mergeConflict(branch: channel.branch)) {
            try await git.merge(channel.branch, into: "main", in: repository.url)
        }
        #expect(try await !git.hasUncommittedChanges(in: repository.url), "a failed merge leaves no mess")
    }

    @Test(arguments: [
        ("git@github.com:acme/app.git", "https://github.com/acme/app/compare/main...feature/x?expand=1"),
        ("https://github.com/acme/app", "https://github.com/acme/app/compare/main...feature/x?expand=1"),
        (
            "git@gitlab.com:acme/app.git",
            "https://gitlab.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature/x&merge_request%5Btarget_branch%5D=main"
        ),
        (
            "https://bitbucket.org/acme/app.git",
            "https://bitbucket.org/acme/app/pull-requests/new?source=feature/x&dest=main"
        )
    ])
    func `builds pull request pages for common hosts`(remote: String, expected: String) {
        #expect(GitClient.compareURL(remote: remote, base: "main", head: "feature/x")?.absoluteString == expected)
    }

    private func setIdentity(in repository: URL) async throws {
        for (key, value) in [("user.name", "Tests"), ("user.email", "tests@watercoded.invalid")] {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: ["config", key, value],
                currentDirectory: repository
            )
        }
    }
}
