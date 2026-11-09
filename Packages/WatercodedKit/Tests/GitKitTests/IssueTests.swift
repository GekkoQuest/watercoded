import Foundation
import Testing
@testable import GitKit

@Suite("GitHub issues")
struct IssueTests {
    @Test func `gh issue view output becomes a prompt and a link`() throws {
        let json = #"{"number":42,"title":"Crash on launch","body":"Steps:\n1. Open the app","url":"https://github.com/o/r/issues/42"}"#
        let issue = try GitClient.parseIssue(Data(json.utf8))
        #expect(issue.reference.number == 42)
        #expect(issue.prompt.hasPrefix("Resolve GitHub issue #42: Crash on launch"))
        #expect(issue.prompt.contains("1. Open the app"))
        #expect(issue.prompt.hasSuffix("Issue: https://github.com/o/r/issues/42"))
    }

    @Test func `an empty body still reads well`() throws {
        let json = #"{"number":7,"title":"Typo","body":"","url":"https://github.com/o/r/issues/7"}"#
        #expect(try GitClient.parseIssue(Data(json.utf8)).prompt.contains("(The issue has no description.)"))
    }

    @Test func `unexpected output is a clear error`() {
        #expect(throws: IssueError.self) { try GitClient.parseIssue(Data("nope".utf8)) }
    }
}
