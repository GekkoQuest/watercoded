import Foundation
import Meniscus
import Observation
import WatercodedCore

/// User preferences, persisted in `UserDefaults`.
@Observable
public final class AppSettings {
    public var physicsIntensity: PhysicsIntensity {
        didSet { defaults.set(physicsIntensity.rawValue, forKey: Key.physicsIntensity) }
    }

    public var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) }
    }

    public var shakeToSettle: Bool {
        didSet { defaults.set(shakeToSettle, forKey: Key.shakeToSettle) }
    }

    public var defaultProviderID: ProviderID? {
        didSet { defaults.set(defaultProviderID?.rawValue, forKey: Key.defaultProvider) }
    }

    public var defaultPermissionMode: PermissionMode {
        didSet { defaults.set(defaultPermissionMode.rawValue, forKey: Key.permissionMode) }
    }

    public var isolateByDefault: Bool {
        didSet { defaults.set(isolateByDefault, forKey: Key.isolate) }
    }

    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    public var dockBadgeEnabled: Bool {
        didSet { defaults.set(dockBadgeEnabled, forKey: Key.dockBadge) }
    }

    /// Agents keep working after Watercoded quits (they run under background relays).
    public var keepAgentsRunning: Bool {
        didSet { defaults.set(keepAgentsRunning, forKey: Key.keepRunning) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.haptics: true, Key.shakeToSettle: true, Key.isolate: true,
            Key.notifications: true, Key.dockBadge: true, Key.keepRunning: true
        ])
        physicsIntensity = defaults.string(forKey: Key.physicsIntensity).flatMap(PhysicsIntensity.init) ?? .lively
        hapticsEnabled = defaults.bool(forKey: Key.haptics)
        shakeToSettle = defaults.bool(forKey: Key.shakeToSettle)
        defaultProviderID = defaults.string(forKey: Key.defaultProvider).map(ProviderID.init(rawValue:))
        defaultPermissionMode = defaults.string(forKey: Key.permissionMode).flatMap(PermissionMode.init) ?? .ask
        isolateByDefault = defaults.bool(forKey: Key.isolate)
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        dockBadgeEnabled = defaults.bool(forKey: Key.dockBadge)
        keepAgentsRunning = defaults.bool(forKey: Key.keepRunning)
    }

    private enum Key {
        static let physicsIntensity = "water.intensity"
        static let haptics = "water.haptics"
        static let shakeToSettle = "water.shakeToSettle"
        static let defaultProvider = "currents.defaultProvider"
        static let permissionMode = "currents.defaultPermissionMode"
        static let isolate = "currents.isolateByDefault"
        static let notifications = "attention.notifications"
        static let dockBadge = "attention.dockBadge"
        static let keepRunning = "agents.keepRunningAfterQuit"
    }
}
