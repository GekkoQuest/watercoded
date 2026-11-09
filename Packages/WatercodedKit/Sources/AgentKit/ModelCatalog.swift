/// The models an agent offers right now, as the agent itself publishes them. Lets menus show exact
/// versions ("Opus 5.5") and each model's default effort instead of a static list that goes stale.
public struct ModelCatalog: Sendable, Hashable {
    public struct Model: Sendable, Hashable {
        /// Full model ID, e.g. `claude-opus-5-5`.
        public let id: String
        /// Name for people, e.g. "Opus 5.5".
        public let name: String
        /// Alias family, e.g. `opus`.
        public let family: String?
        /// Effort used when none is chosen ("Auto").
        public let defaultEffort: String?
        /// Shown in the main model list (older models are reachable through Custom…).
        public let isFeatured: Bool
        /// Effort levels this model accepts, lowest first, when the agent says.
        public let effortLevels: [String]?

        public init(
            id: String,
            name: String,
            family: String?,
            defaultEffort: String?,
            isFeatured: Bool,
            effortLevels: [String]? = nil
        ) {
            self.id = id
            self.name = name
            self.family = family
            self.defaultEffort = defaultEffort
            self.isFeatured = isFeatured
            self.effortLevels = effortLevels
        }
    }

    public let models: [Model]
    /// Alias → full ID, e.g. `opus` → `claude-opus-5-5`.
    public let aliases: [String: String]
    /// The model the agent uses when none is chosen, when the agent says.
    public let defaultModelID: String?

    public init(models: [Model], aliases: [String: String], defaultModelID: String? = nil) {
        self.models = models
        self.aliases = aliases
        self.defaultModelID = defaultModelID
    }

    /// The model a name refers to: an alias, a full ID, or `nil` when the catalog doesn't know it.
    public func model(named name: String) -> Model? {
        let id = aliases[name] ?? name
        return models.first { $0.id == id }
    }

    /// Featured models as menu choices. A model is offered by its alias when the alias points at it,
    /// so sessions keep following the newest version of that family.
    public var choices: [AgentModel] {
        models.filter(\.isFeatured).map { model in
            let alias = model.family.flatMap { aliases[$0] == model.id ? $0 : nil }
            return AgentModel(id: alias ?? model.id, displayName: model.name)
        }
    }
}
