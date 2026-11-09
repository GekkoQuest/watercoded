import SwiftUI

/// A pending app update, supplied by the app without coupling the UI package to its updater framework.
public struct AppUpdate: Sendable {
    public let version: String
    public let showDetails: @MainActor @Sendable () -> Void

    public init(version: String, showDetails: @escaping @MainActor @Sendable () -> Void) {
        self.version = version
        self.showDetails = showDetails
    }
}

extension EnvironmentValues {
    @Entry public var appUpdate: AppUpdate?
}
