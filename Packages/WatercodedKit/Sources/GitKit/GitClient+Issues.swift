import Foundation
import ProcessKit
import WatercodedCore

/// A GitHub issue as `gh issue view` reports it.
public struct GitHubIssue: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var body: String
    public var url: URL

    public var reference: IssueReference {
        IssueReference(number: number, title: title, url: url)
    }

    /// The first message for an agent asked to resolve this issue.
    public var prompt: String {
        let description = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Resolve GitHub issue #\(number): \(title)

        \(description.isEmpty ? "(The issue has no description.)" : description)

        Issue: \(url.absoluteString)
        """
    }
}

public enum IssueError: Error, LocalizedError, Sendable, Equatable {
    case githubCLIMissing
    case lookupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .githubCLIMissing:
            "Starting from an issue needs the GitHub CLI. Install and sign in: brew install gh && gh auth login"
        case let .lookupFailed(message):
            "Couldn't load the issue: \(message)"
        }
    }
}

extension GitClient {
    /// Loads an issue by number (`123`, `#123`) or URL, from the repository's GitHub remote.
    public func issue(_ reference: String, in repository: URL) async throws -> GitHubIssue {
        guard let gh = await environment.locate("gh") else { throw IssueError.githubCLIMissing }
        var key = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("#") {
            key.removeFirst()
        }
        let result = try await ProcessRunner.run(
            executable: gh,
            arguments: ["issue", "view", key, "--json", "number,title,body,url"],
            currentDirectory: repository,
            environment: environment.environment(),
            timeout: .seconds(30)
        )
        guard result.succeeded else {
            throw IssueError.lookupFailed(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Self.parseIssue(Data(result.standardOutput.utf8))
    }

    static func parseIssue(_ data: Data) throws -> GitHubIssue {
        struct Wire: Decodable {
            var number: Int
            var title: String
            var body: String?
            var url: URL
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: data)
            return GitHubIssue(number: wire.number, title: wire.title, body: wire.body ?? "", url: wire.url)
        } catch {
            throw IssueError.lookupFailed("unexpected response from gh")
        }
    }
}
