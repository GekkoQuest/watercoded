import AgentKit
import WatercodedCore

extension Workspace {
    /// The exact model a choice ran as most recently, as the agent reported it when a session started.
    /// `requested` is the model asked for: an alias like `opus`, or `nil` for Default.
    public func resolvedModel(for requested: String?, provider: ProviderID) -> String? {
        currents
            .map(\.current)
            .filter { $0.providerID == provider && $0.model == requested }
            .compactMap { current in current.environment?.model.map { (date: current.createdAt, model: $0) } }
            .max { $0.date < $1.date }?
            .model
    }
}

/// What the model and effort menus offer for one provider, and how each choice is named.
///
/// Prefers the agent's own catalog (exact versions, per-model default effort), then the user's
/// configured defaults, then what past sessions reported, and finally the provider's static list.
@MainActor
public struct ModelOptions {
    public let descriptor: ProviderDescriptor
    private let catalog: ModelCatalog?
    private let configuredModel: String?
    private let configuredEffort: String?
    private let workspace: Workspace

    public init(descriptor: ProviderDescriptor, providers: ProviderStatus, workspace: Workspace) {
        self.descriptor = descriptor
        catalog = providers.catalogs[descriptor.id]
        configuredModel = providers.configuredDefaultModels[descriptor.id]
        configuredEffort = providers.configuredDefaultEfforts[descriptor.id]
        self.workspace = workspace
    }

    /// Default first, then the featured models.
    public var models: [AgentModel] {
        let fallback = descriptor.models.filter { !$0.isDefault }
        let choices = catalog?.choices ?? []
        return descriptor.models.filter(\.isDefault) + (choices.isEmpty ? fallback : choices)
    }

    /// "Default (Opus 5.5)" once the default is known; other models by name.
    public func name(for model: AgentModel) -> String {
        guard model.isDefault, let resolved = defaultModelName else { return model.displayName }
        return "\(model.displayName) (\(resolved))"
    }

    /// A short name for a requested model (`nil` = Default), e.g. "Opus 5.5".
    public func displayName(forRequested requested: String?) -> String? {
        guard let requested else { return defaultModelName }
        return catalog?.model(named: requested)?.name
            ?? models.first { $0.id == requested }?.displayName
            ?? ModelName.display(requested)
    }

    /// "Auto (Medium)" when the effort Auto uses for this model is known, otherwise "Auto".
    public func autoEffortName(forRequested requested: String?) -> String {
        let model = requested ?? defaultModelID
        guard let effort = configuredEffort ?? model.flatMap({ catalog?.model(named: $0)?.defaultEffort }) else {
            return "Auto"
        }
        return "Auto (\(effortName(effort)))"
    }

    /// Effort level names as the agent shows them ("xhigh" → "Extra").
    public func effortName(_ level: String) -> String {
        level == "xhigh" ? "Extra" : level.capitalized
    }

    private var defaultModelID: String? {
        configuredModel ?? catalog?.defaultModelID ?? workspace.resolvedModel(for: nil, provider: descriptor.id)
    }

    private var defaultModelName: String? {
        guard let id = defaultModelID else { return nil }
        return catalog?.model(named: id)?.name
            ?? workspace.resolvedModel(for: id, provider: descriptor.id).map(ModelName.display)
            ?? ModelName.display(id)
    }
}
