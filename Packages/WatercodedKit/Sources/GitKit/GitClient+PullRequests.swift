import Foundation
import ProcessKit
import WatercodedCore

extension GitClient {
    /// The current state, checks and reviews of a pull request, via `gh pr view`.
    /// Returns `nil` when `gh` isn't installed or the lookup fails (e.g. signed out, offline).
    public func pullRequestStatus(_ url: URL, in directory: URL) async -> PullRequestStatus? {
        guard let gh = await environment.locate("gh"),
              let result = try? await ProcessRunner.run(
                  executable: gh,
                  arguments: [
                      "pr",
                      "view",
                      url.absoluteString,
                      "--json",
                      "number,state,statusCheckRollup,reviewDecision,comments,reviews"
                  ],
                  currentDirectory: directory,
                  environment: environment.environment(),
                  timeout: .seconds(30)
              ),
              result.succeeded else { return nil }
        return Self.parsePullRequestStatus(Data(result.standardOutput.utf8), url: url)
    }

    static func parsePullRequestStatus(_ data: Data, url: URL, now: Date = .now) -> PullRequestStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let state: PullRequestStatus.State = switch root["state"] as? String {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        var failing: [String] = []
        var pending = false
        let rollup = root["statusCheckRollup"] as? [[String: Any]] ?? []
        for check in rollup {
            let name = check["name"] as? String ?? check["context"] as? String ?? "check"
            // CheckRun: status + conclusion. StatusContext: state.
            let conclusion = (check["conclusion"] as? String ?? check["state"] as? String ?? "").uppercased()
            let status = (check["status"] as? String ?? "COMPLETED").uppercased()
            if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                .contains(conclusion) {
                failing.append(name)
            } else if status != "COMPLETED" || ["PENDING", "EXPECTED", ""].contains(conclusion) {
                pending = true
            }
        }
        let checks: PullRequestStatus.Checks = rollup.isEmpty ? .none
            : !failing.isEmpty ? .failing : pending ? .pending : .passing
        let comments = (root["comments"] as? [Any])?.count ?? 0
        let reviews = (root["reviews"] as? [[String: Any]] ?? [])
            .count { !(($0["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let decision = (root["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestStatus(
            url: url,
            number: root["number"] as? Int,
            state: state,
            checks: checks,
            failingChecks: failing,
            reviewDecision: decision,
            commentCount: comments + reviews,
            checkedAt: now
        )
    }
}
