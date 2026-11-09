import Foundation

/// A GitHub issue a Current was started from. Landing a pull request closes it.
public struct IssueReference: Hashable, Codable, Sendable {
    public var number: Int
    public var title: String
    public var url: URL

    public init(number: Int, title: String, url: URL) {
        self.number = number
        self.title = title
        self.url = url
    }
}
