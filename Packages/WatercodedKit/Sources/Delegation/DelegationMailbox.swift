import Foundation

/// A request from an agent's `delegate` tool for Watercoded to start another agent.
public struct DelegationRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The Current whose agent asked (its id's UUID string).
    public var parentID: String
    /// A provider id, e.g. `codex` or `claude-code`.
    public var agent: String
    public var model: String?
    public var effort: String?
    public var task: String

    public init(
        id: String = UUID().uuidString,
        parentID: String,
        agent: String,
        model: String?,
        effort: String?,
        task: String
    ) {
        self.id = id
        self.parentID = parentID
        self.agent = agent
        self.model = model
        self.effort = effort
        self.task = task
    }
}

/// The helper agent's final answer, or why there isn't one.
public struct DelegationResponse: Codable, Sendable, Hashable {
    public var id: String
    public var text: String?
    public var error: String?

    public init(id: String, text: String? = nil, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

/// Files the `delegate` MCP server and the app use to talk: `requests/`, `claimed/` and `responses/`
/// under `~/.watercoded/delegation`. Files, not sockets, so either side can restart without losing work.
public struct DelegationMailbox: Sendable {
    public let root: URL

    public init(root: URL = DelegationMailbox.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".watercoded/delegation",
            directoryHint: .isDirectory
        )
    }

    private var requests: URL {
        root.appending(path: "requests", directoryHint: .isDirectory)
    }

    private var claimed: URL {
        root.appending(path: "claimed", directoryHint: .isDirectory)
    }

    private var responses: URL {
        root.appending(path: "responses", directoryHint: .isDirectory)
    }

    /// Server side: asks the app to delegate.
    public func post(_ request: DelegationRequest) throws {
        try write(request, to: requests.appending(path: "\(request.id).json"))
    }

    /// App side: takes every waiting request. Each is moved to `claimed/` first, so it's handled once.
    public func claimRequests() -> [DelegationRequest] {
        try? FileManager.default.createDirectory(at: claimed, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            let target = claimed.appending(path: file.lastPathComponent)
            guard (try? FileManager.default.moveItem(at: file, to: target)) != nil,
                  let data = try? Data(contentsOf: target) else { return nil }
            return try? JSONDecoder().decode(DelegationRequest.self, from: data)
        }
    }

    /// App side: answers a request.
    public func respond(_ response: DelegationResponse) throws {
        try write(response, to: responses.appending(path: "\(response.id).json"))
        try? FileManager.default.removeItem(at: claimed.appending(path: "\(response.id).json"))
    }

    /// Server side: the answer, once there is one (and removes it).
    public func takeResponse(for id: String) -> DelegationResponse? {
        let file = responses.appending(path: "\(id).json")
        guard let data = try? Data(contentsOf: file),
              let response = try? JSONDecoder().decode(DelegationResponse.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return response
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written whole, then moved into place, so readers never see half a file.
        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        try JSONEncoder().encode(value).write(to: temporary)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
