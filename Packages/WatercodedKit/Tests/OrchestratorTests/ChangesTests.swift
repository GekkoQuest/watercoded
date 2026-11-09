import Foundation
import GitKit
import ProcessKit
import Testing
@testable import Orchestrator

@MainActor
@Suite("Change comparisons", .serialized)
struct ChangesTests {
    @Test func `committing clears uncommitted changes but preserves session history`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let (workspace, controller) = try await fixture.finishedDemo()
        let directory = controller.current.channel.url
        let git = GitClient()
        try "session work\n".write(to: directory.appending(path: "WORK.md"), atomically: true, encoding: .utf8)
        #expect(try await workspace.diff(for: controller.id, scope: .uncommitted).files.map(\.path) == ["WORK.md"])

        try await git.commitEverything(in: directory, message: "Commit session work externally")
        #expect(try await workspace.diff(for: controller.id, scope: .uncommitted).isEmpty)
        #expect(try await workspace.diff(for: controller.id, scope: .session).files.map(\.path) == ["WORK.md"])

        try "another edit\n".write(to: directory.appending(path: "WORK.md"), atomically: true, encoding: .utf8)
        let diff = try await workspace.diff(for: controller.id, scope: .uncommitted)
        let file = try #require(diff.files.first)
        #expect(file.change == .modified, "a committed session file must not be treated as a new file")
        try await workspace.revert(file, in: controller.id, scope: .uncommitted)
        #expect(try String(contentsOf: directory.appending(path: "WORK.md"), encoding: .utf8) == "session work\n")
        #expect(try await workspace.diff(for: controller.id, scope: .uncommitted).isEmpty)
    }

    @Test func `stale uncommitted patches cannot undo files committed after loading`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let (workspace, controller) = try await fixture.finishedDemo()
        let directory = controller.current.channel.url
        let readme = directory.appending(path: "README.md")
        let added = directory.appending(path: "new.md")
        for path in [readme, added] {
            try "committed work\n".write(to: path, atomically: true, encoding: .utf8)
        }
        let stale = try await workspace.diff(for: controller.id, scope: .uncommitted)
        try await GitClient().commitEverything(in: directory, message: "Commit before the inspector reloads")
        for file in stale.files {
            if let hunk = file.hunks.first {
                try await workspace.revert(hunk, of: file, in: controller.id, scope: .uncommitted)
            }
            try await workspace.revert(file, in: controller.id, scope: .uncommitted)
        }
        #expect(try String(contentsOf: readme, encoding: .utf8) == "committed work\n")
        #expect(try String(contentsOf: added, encoding: .utf8) == "committed work\n")
        #expect(try await workspace.diff(for: controller.id, scope: .uncommitted).isEmpty)
    }

    @Test func `uncommitted comparison includes staged unstaged and untracked files`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let (workspace, controller) = try await fixture.finishedDemo()
        let directory = controller.current.channel.url
        for name in ["staged.md", "untracked.md", "README.md"] {
            try "changed\n".write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/git"), arguments: ["add", "staged.md"], currentDirectory: directory
        )
        #expect(result.exitCode == 0)
        let diff = try await workspace.diff(for: controller.id, scope: .uncommitted)
        #expect(Set(diff.files.map(\.path)) == ["staged.md", "untracked.md", "README.md"])
    }
}
