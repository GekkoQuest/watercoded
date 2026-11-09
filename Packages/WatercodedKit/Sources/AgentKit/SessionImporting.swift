import Foundation
import WatercodedCore

/// A session the provider ran outside Watercoded (e.g. in Terminal) that can be imported.
public struct ImportableSession: Sendable, Hashable, Identifiable {
    /// The provider's own session identifier (used to resume it).
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: String, title: String, updatedAt: Date, messageCount: Int) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

/// A provider whose own sessions on disk can be listed and brought into Watercoded as Currents.
/// The UI finds it through the registry, so it never imports the provider.
public protocol SessionImporting: AgentProvider {
    /// Sessions the provider ran in `directory`, newest first.
    func importableSessions(in directory: URL) -> [ImportableSession]

    /// The transcript of one of those sessions.
    func transcript(ofSession id: String, in directory: URL) throws -> [TranscriptItem]
}

extension ProviderRegistry {
    /// Registered providers that can import their own sessions.
    public var importers: [any SessionImporting] {
        providers.compactMap { $0 as? any SessionImporting }
    }
}
