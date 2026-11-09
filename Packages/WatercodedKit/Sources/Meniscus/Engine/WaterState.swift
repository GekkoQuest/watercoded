import Foundation

/// What a vessel's water means. Callers describe state; Meniscus decides how it looks.
public struct WaterState: Hashable, Sendable {
    /// Fill level, 0...1 (e.g. fraction of the context window in use).
    public var level: Double
    /// Clear water with caustics when healthy; murky when not.
    public var isHealthy: Bool
    /// Surface agitation, e.g. tokens streaming.
    public var isStreaming: Bool
    /// Rising bubbles, e.g. subagents at work.
    public var hasSubagents: Bool
    /// Frost and a motionless surface.
    public var isFrozen: Bool
    /// A droplet hangs from the rim until resolved.
    public var isAwaitingApproval: Bool
    /// A light frost on the surface (e.g. the prompt cache expired; the next turn re-reads context).
    public var isChilled: Bool
    /// Heat haze above the water, 0...1 (e.g. close to a plan's rate limit).
    public var heat: Double

    public init(
        level: Double = 0,
        isHealthy: Bool = true,
        isStreaming: Bool = false,
        hasSubagents: Bool = false,
        isFrozen: Bool = false,
        isAwaitingApproval: Bool = false,
        isChilled: Bool = false,
        heat: Double = 0
    ) {
        self.level = level
        self.isHealthy = isHealthy
        self.isStreaming = isStreaming
        self.hasSubagents = hasSubagents
        self.isFrozen = isFrozen
        self.isAwaitingApproval = isAwaitingApproval
        self.isChilled = isChilled
        self.heat = heat
    }
}

/// A one-off disturbance.
public enum WaterImpulse: Sendable {
    /// Something dropped in (e.g. a tool call). Larger for heavier actions.
    case drop(DropSize)
    /// The pending approval was granted: the droplet falls in.
    case approvalGranted
    /// The pending approval was denied: the droplet evaporates.
    case approvalDenied
    /// The level drained (e.g. context compaction).
    case drained
    /// Calm the water quickly (e.g. the agent was settled).
    case calm
}

public enum DropSize: Sendable {
    case small
    case medium
    case large

    var radius: Float {
        switch self {
        case .small: 3
        case .medium: 4.5
        case .large: 6.5
        }
    }
}

/// How strongly the water reacts to window motion.
public enum PhysicsIntensity: String, CaseIterable, Identifiable, Sendable {
    case still
    case calm
    case lively
    case tsunami

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .still: "Still"
        case .calm: "Calm"
        case .lively: "Lively"
        case .tsunami: "Tsunami"
        }
    }

    var gain: Float {
        switch self {
        case .still: 0
        case .calm: 0.45
        case .lively: 1
        case .tsunami: 2.3
        }
    }
}
