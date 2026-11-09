import Orchestrator
import SwiftUI

/// Menu bar commands. They act on the focused window through ``WindowModel``.
public struct WatercodedCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { window?.beginNewCurrent() }
                .keyboardShortcut("n")
                .disabled(window == nil)
            Button("Add Repository…") { window?.isAddingPool = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(window == nil)
        }
        CommandGroup(replacing: .help) {
            Button("What the Water Means") { openWindow(id: GlossaryView.windowID) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Search Sessions") { window?.isSearchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(window == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Changes") { window?.isInspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(window?.selection == nil)
        }
    }
}
