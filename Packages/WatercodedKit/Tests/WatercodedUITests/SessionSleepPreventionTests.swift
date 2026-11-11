import AgentKit
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator
@testable import WatercodedUI

@MainActor
@Suite("Session sleep prevention")
struct SessionSleepPreventionTests {
    @Test func `one assertion covers overlapping turns and releases when the last finishes`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var acquisitions = 0
        var releases: [UInt32] = []
        let service = SessionSleepPrevention(
            workspace: fixture.workspace, settings: fixture.settings,
            acquire: { acquisitions += 1
                return 42
            }, release: { releases.append($0) }
        )
        service.update(enabled: false, activeSessionCount: 1)
        service.update(enabled: true, activeSessionCount: 0)
        #expect(acquisitions == 0)
        for count in [1, 2, 1] {
            service.update(enabled: true, activeSessionCount: count)
        }
        #expect(acquisitions == 1)
        #expect(releases.isEmpty)
        service.update(enabled: true, activeSessionCount: 0)
        service.update(enabled: true, activeSessionCount: 0)
        #expect(releases == [42])
    }

    @Test func `disabling releases immediately and destruction releases a reacquired assertion`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var releases = 0
        var service: SessionSleepPrevention? = SessionSleepPrevention(
            workspace: fixture.workspace, settings: fixture.settings,
            acquire: { 42 }, release: { _ in releases += 1 }
        )
        service?.update(enabled: true, activeSessionCount: 1)
        service?.update(enabled: false, activeSessionCount: 1)
        #expect(releases == 1)
        service?.update(enabled: true, activeSessionCount: 1)
        service = nil
        #expect(releases == 2)
    }

    @Test func `failed acquisition can retry without releasing an invalid assertion`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var attempts = 0
        var releases = 0
        let service = SessionSleepPrevention(
            workspace: fixture.workspace, settings: fixture.settings,
            acquire: { attempts += 1
                return attempts == 1 ? nil : 42
            },
            release: { _ in releases += 1 }
        )
        service.update(enabled: true, activeSessionCount: 1)
        service.update(enabled: false, activeSessionCount: 0)
        #expect(releases == 0)
        service.update(enabled: true, activeSessionCount: 1)
        service.update(enabled: true, activeSessionCount: 0)
        #expect(attempts == 2)
        #expect(releases == 1)
    }

    @Test func `observes preferences session activity and removal without a window`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var acquisitions = 0
        var releases = 0
        let service = SessionSleepPrevention(
            workspace: fixture.workspace, settings: fixture.settings,
            acquire: { acquisitions += 1
                return 42
            }, release: { _ in releases += 1 }
        )
        let current = Current(
            poolID: PoolID(), title: "Test", providerID: ProviderID(rawValue: "test"),
            channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "")
        )
        let controller = fixture.workspace.adopt(current, transcript: [])
        defer { controller.discard() }
        controller.isTurnActive = true
        fixture.settings.keepAwakeWhileRunning = true
        try await waitUntil { acquisitions == 1 }
        fixture.settings.keepAwakeWhileRunning = false
        try await waitUntil { releases == 1 }
        fixture.settings.keepAwakeWhileRunning = true
        try await waitUntil { acquisitions == 2 }
        controller.isTurnActive = false
        try await waitUntil { releases == 2 }
        controller.isTurnActive = true
        try await waitUntil { acquisitions == 3 }
        await fixture.workspace.removePool(current.poolID)
        try await waitUntil { releases == 3 }
        withExtendedLifetime(service) {}
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @MainActor
    private struct Fixture {
        let suite = "watercoded-sleep-test-\(UUID().uuidString)"
        let defaults: UserDefaults
        let settings: AppSettings
        let workspace = Workspace(registry: ProviderRegistry([]), repository: InMemoryWorkspaceRepository())

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
