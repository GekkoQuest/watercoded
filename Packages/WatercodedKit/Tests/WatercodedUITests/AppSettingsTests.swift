import Foundation
import Testing
import WatercodedUI

@MainActor
@Suite("App preferences")
struct AppSettingsTests {
    @Test func `background agents default to enabled and preserve an explicit opt out`() throws {
        let suite = "watercoded-preferences-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.keepAgentsRunning)
        settings.keepAgentsRunning = false
        #expect(!AppSettings(defaults: defaults).keepAgentsRunning)
    }
}
