import AgentKit
import Foundation
import Observation
import ProcessKit
import WatercodedCore

/// Live availability of every registered provider, shared by the welcome screen, the New Current
/// sheet and Settings so they always agree.
@MainActor
@Observable
public final class ProviderStatus {
    public private(set) var availability: [ProviderID: ProviderAvailability] = [:]
    public private(set) var isRefreshing = false
    /// Each provider's configured default model (see ``AgentProvider/configuredDefaultModel()``).
    public private(set) var configuredDefaultModels: [ProviderID: String] = [:]
    /// Each provider's configured default effort (see ``AgentProvider/configuredDefaultEffort()``).
    public private(set) var configuredDefaultEfforts: [ProviderID: String] = [:]
    /// Each provider's current model catalog (see ``AgentProvider/modelCatalog()``).
    public private(set) var catalogs: [ProviderID: ModelCatalog] = [:]

    public let registry: ProviderRegistry
    @ObservationIgnored private let environment: ShellEnvironment
    @ObservationIgnored private var hasLoaded = false

    public init(registry: ProviderRegistry, environment: ShellEnvironment = .shared) {
        self.registry = registry
        self.environment = environment
    }

    public func availability(of id: ProviderID) -> ProviderAvailability? {
        availability[id]
    }

    /// Checks providers once; later calls are no-ops. Use ``refresh()`` to re-check.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    /// Re-reads the login-shell `PATH` (so CLIs installed while the app is open are found) and
    /// re-checks every provider.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await environment.invalidate()
        for provider in registry.providers {
            let result = await provider.availability()
            // A cancelled check (e.g. the sheet closed) says nothing about the provider; don't record it.
            guard !Task.isCancelled else { return }
            availability[provider.descriptor.id] = result
            configuredDefaultModels[provider.descriptor.id] = await provider.configuredDefaultModel()
            configuredDefaultEfforts[provider.descriptor.id] = await provider.configuredDefaultEffort()
            catalogs[provider.descriptor.id] = await provider.modelCatalog()
        }
        hasLoaded = true
    }

    /// The first available real agent, falling back to a demo provider.
    public func preferredProvider() -> ProviderDescriptor? {
        let available = registry.descriptors.filter { availability[$0.id]?.isAvailable == true }
        return available.first { !$0.isDemo } ?? available.first
    }
}
