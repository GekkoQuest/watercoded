import Meniscus
import Orchestrator
import SwiftUI
import WatercodedUI

struct WatercodedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        Window("Watercoded", id: "main") {
            RootView()
                .environment(environment.workspace)
                .environment(environment.providerStatus)
                .environment(environment.waterEngine)
                .environment(environment.settings)
                .onAppear { appDelegate.workspace = environment.workspace }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { WatercodedCommands() }

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
