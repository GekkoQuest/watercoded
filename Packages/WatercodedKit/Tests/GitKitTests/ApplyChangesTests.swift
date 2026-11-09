import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import GitKit

@Suite("Applying a helper's changes")
struct ApplyChangesTests {
    private func repository() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "-q"],
            ["add", "."],
            ["-c", "user.name=T", "-c", "user.email=t@t.invalid", "commit", "-qm", "init"]
        ] {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: arguments,
                currentDirectory: folder
            )
        }
        return folder
    }

    private func write(_ text: String, in folder: URL) throws {
        try text.write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    }

    private func read(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: "a.txt"), encoding: .utf8)
    }

    @Test func `changes apply when the target hasn't touched those lines`() async throws {
        let folder = try await repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let git = GitClient()
        let base = try await git.snapshotWorkingTree(in: folder, ref: "refs/test/base", message: "base")
        try write("one\nTWO\nthree\n", in: folder) // what the helper did
        try "new\n".write(to: folder.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let result = try await git.snapshotWorkingTree(in: folder, ref: "refs/test/result", message: "result")
        try write("one\ntwo\nthree\n", in: folder) // back to the parent's state
        try FileManager.default.removeItem(at: folder.appending(path: "b.txt"))

        #expect(try await git.applyChanges(from: base, to: result, into: folder) == .applied(["a.txt", "b.txt"]))
        #expect(try read(folder) == "one\nTWO\nthree\n")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "b.txt").path))
        #expect(try await git.applyChanges(from: base, to: base, into: folder) == .nothingToApply)
    }

    @Test func `a conflicting change is refused and nothing is touched`() async throws {
        let folder = try await repository()
        defer { try? FileManager.default.removeItem(at: folder) }
        let git = GitClient()
        let base = try await git.snapshotWorkingTree(in: folder, ref: "refs/test/base", message: "base")
        try write("one\nhelper\nthree\n", in: folder)
        let result = try await git.snapshotWorkingTree(in: folder, ref: "refs/test/result", message: "result")
        try write("one\nparent\nthree\n", in: folder) // the parent changed the same line meanwhile

        guard case .conflict = try await git.applyChanges(from: base, to: result, into: folder) else {
            Issue.record("Expected a conflict")
            return
        }
        #expect(try read(folder) == "one\nparent\nthree\n")
    }
}

@Suite("Reverting hunks")
struct RevertHunkTests {
    @Test func `a hunk at the end of a file without a trailing newline reverts`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "revert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a.txt")
        try "keep\nold".write(to: file, atomically: true, encoding: .utf8) // no newline at the end
        for arguments in [
            ["init", "-q"],
            ["add", "."],
            ["-c", "user.name=T", "-c", "user.email=t@t.invalid", "commit", "-qm", "init"]
        ] {
            _ = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/git"),
                arguments: arguments,
                currentDirectory: folder
            )
        }
        try "keep\nnew".write(to: file, atomically: true, encoding: .utf8)

        let git = GitClient()
        let diff = try await UnifiedDiff(parsing: git.diff(in: folder, against: "HEAD"))
        let changed = try #require(diff.files.first)
        let hunk = try #require(changed.hunks.first)
        #expect(hunk.lines.contains { $0.isMissingNewline })
        try await git.revertHunk(hunk, of: changed, in: folder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep\nold")
    }
}

@Suite("Branching from snapshots")
struct SnapshotBranchTests {
    @Test func `a branch started from a snapshot shares history and merges back`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "branch-\(UUID().uuidString)")
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String], in folder: URL) async throws -> String {
            let identity = ["-c", "user.name=T", "-c", "user.email=t@t.invalid"]
            let result = try await ProcessRunner.run(
                executable: URL(filePath: "/usr/bin/git"), arguments: identity + arguments, currentDirectory: folder
            )
            #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.standardError)")
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try "one\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["init", "-q", "-b", "main"], in: repo)
        _ = try await git(["add", "."], in: repo)
        _ = try await git(["commit", "-qm", "init"], in: repo)

        // Uncommitted work, snapshotted the way turns are.
        try "one\ntwo\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let client = GitClient()
        let snapshot = try await client.snapshotWorkingTree(in: repo, ref: "refs/test/snap", message: "snap")
        let head = try await git(["rev-parse", "HEAD"], in: repo)
        #expect(await client.snapshotParent(snapshot, in: repo) == head)
        _ = try await git(["checkout", "-q", "--", "."], in: repo)
        try FileManager.default.removeItem(at: repo.appending(path: "b.txt"))

        let manager = WorktreeManager(root: root.appending(path: "worktrees"))
        let pool = Pool(name: "repo", rootPath: repo.path)
        let channel = try await manager.makeWorktreeChannel(for: pool, title: "Branch", base: head, files: snapshot)
        #expect(try String(contentsOf: channel.url.appending(path: "a.txt"), encoding: .utf8) == "one\ntwo\n")
        #expect(FileManager.default.fileExists(atPath: channel.url.appending(path: "b.txt").path))
        #expect(try await git(["log", "--oneline"], in: channel.url).components(separatedBy: "\n").count == 1)

        // What Land does: commit on the branch, then merge into main.
        _ = try await git(["add", "-A"], in: channel.url)
        _ = try await git(["commit", "-qm", "Work from the branch"], in: channel.url)
        _ = try await git(["merge", "--no-edit", "-q", channel.branch], in: repo)
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "one\ntwo\n")
    }
}
