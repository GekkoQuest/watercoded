import Foundation
import Testing
import WatercodedCore
@testable import GitKit

@Suite("Pull request status")
struct PullRequestStatusTests {
    private let url = URL(string: "https://github.com/o/r/pull/12")!

    @Test func `failing check runs and status contexts are both caught`() throws {
        let json = """
        {"number":12,"state":"OPEN","reviewDecision":"CHANGES_REQUESTED",
         "statusCheckRollup":[
           {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
           {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"},
           {"__typename":"StatusContext","context":"lint","state":"ERROR"}
         ],
         "comments":[{"body":"hi"}],"reviews":[{"body":"Please fix"},{"body":""}]}
        """
        let status = try #require(GitClient.parsePullRequestStatus(Data(json.utf8), url: url))
        #expect(status.number == 12)
        #expect(status.checks == .failing)
        #expect(status.failingChecks == ["test", "lint"])
        #expect(status.changesRequested)
        #expect(status.commentCount == 2)
    }

    @Test func `running checks are pending and merged is merged`() {
        let pending = #"{"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]}"#
        #expect(GitClient.parsePullRequestStatus(Data(pending.utf8), url: url)?.checks == .pending)
        let merged = #"{"state":"MERGED","statusCheckRollup":[]}"#
        let status = GitClient.parsePullRequestStatus(Data(merged.utf8), url: url)
        #expect(status?.state == .merged)
        #expect(status?.checks == PullRequestStatus.Checks.none)
    }
}
