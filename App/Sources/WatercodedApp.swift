import Meniscus
import Orchestrator
import SwiftUI
import WatercodedUI

struct WatercodedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appUpdater = AppUpdater()
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        Window("Watercoded", id: "main") {
            RootView()
                .environment(environment.workspace)
                .environment(environment.providerStatus)
                .environment(environment.waterEngine)
                .environment(environment.settings)
                .environment(\.appUpdate, appUpdater.availableVersion.map { version in
                    AppUpdate(version: version) { appUpdater.checkForUpdates() }
                })
                .onAppear { appDelegate.workspace = environment.workspace }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            WatercodedCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: appUpdater.checkForUpdates)
                    .disabled(!appUpdater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environment(environment.workspace)
                .environment(environment.providerStatus)
                .environment(environment.settings)
        }

        Window("What the Water Means", id: GlossaryView.windowID) {
            GlossaryView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            ShoreMenu()
                .environment(environment.workspace)
        } label: {
            ShoreMenuIcon()
                .environment(environment.workspace)
        }
    }
}
