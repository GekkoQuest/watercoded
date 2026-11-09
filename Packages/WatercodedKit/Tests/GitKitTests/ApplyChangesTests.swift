import Foundation
import ProcessKit
import Testing
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
