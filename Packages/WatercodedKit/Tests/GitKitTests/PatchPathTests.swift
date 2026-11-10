import Foundation
import Testing
@testable import GitKit

@Suite("Patch filenames", .serialized)
struct PatchPathTests {
    @Test(arguments: ["hello world.txt", "tab\tfile.txt", "quote\"file.txt", "slash\\file.txt", "café notes.txt"])
    func `file and hunk reverts preserve filenames`(name: String) async throws {
        let repository = try await TemporaryRepository.make()
        defer { repository.remove() }
        let git = GitClient()
        let url = repository.url.appending(path: name)
        try "original\n".write(to: url, atomically: true, encoding: .utf8)
        var diff = try await UnifiedDiff(parsing: git.diff(in: repository.url, against: "HEAD"))
        let added = try #require(diff.files.first { $0.path == name })
        try await git.revertFile(added, to: "HEAD", in: repository.url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try "original\n".write(to: url, atomically: true, encoding: .utf8)
        try await git.commitAll(in: repository.url, message: "Add file", identity: ("Tests", "tests@tests.invalid"))
        try "changed\n".write(to: url, atomically: true, encoding: .utf8)
        diff = try await UnifiedDiff(parsing: git.diff(in: repository.url, against: "HEAD"))
        let modified = try #require(diff.files.first { $0.path == name })
        try await git.revertHunk(#require(modified.hunks.first), of: modified, in: repository.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original\n")
        try FileManager.default.removeItem(at: url)
        diff = try await UnifiedDiff(parsing: git.diff(in: repository.url, against: "HEAD"))
        let deleted = try #require(diff.files.first { $0.path == name })
        try await git.revertFile(deleted, to: "HEAD", in: repository.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original\n")
    }

    @Test func `binary and mode only headers preserve spaces`() {
        for (header, path) in [
            ("a/hello world.png b/hello world.png", "hello world.png"),
            ("a/dir b/file.png b/dir b/file.png", "dir b/file.png")
        ] {
            let text = "diff --git \(header)\nold mode 100644\nnew mode 100755\n"
            #expect(UnifiedDiff(parsing: text).files.first?.path == path)
        }
        let text = """
        diff --git "a/old\\tname" "b/new\\tname"
        similarity index 100%
        rename from "old\\tname"
        rename to "new\\tname"
        """
        let file = UnifiedDiff(parsing: text).files.first
        #expect(file?.oldPath == "old\tname")
        #expect(file?.path == "new\tname")
    }
}
