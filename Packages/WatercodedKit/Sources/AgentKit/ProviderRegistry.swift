import Foundation
import WatercodedCore

/// The set of providers the app knows about, in display order.
///
/// Built once by the composition root (the app target) and passed down. Immutable after
/// construction, so it can be shared freely.
public struct ProviderRegistry: Sendable {
    public let providers: [any AgentProvider]

    public init(_ providers: [any AgentProvider]) {
        var seen = Set<ProviderID>()
        self.providers = providers.filter { seen.insert($0.descriptor.id).inserted }
    }

    public func provider(for id: ProviderID) -> (any AgentProvider)? {
        providers.first { $0.descriptor.id == id }
    }

    public var descriptors: [ProviderDescriptor] {
        providers.map(\.descriptor)
    }
}

public enum AgentError: Error, LocalizedError, Sendable {
    case providerNotFound(ProviderID)
    case providerUnavailable(name: String, reason: String)
    case sessionClosed
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .providerNotFound(id): "No provider named “\(id)” is registered."
        case let .providerUnavailable(name, reason): "\(name) isn't available: \(reason)"
        case .sessionClosed: "The agent session has ended."
        case let .unsupported(what): "\(what) isn't supported by this provider."
        }
    }
}
