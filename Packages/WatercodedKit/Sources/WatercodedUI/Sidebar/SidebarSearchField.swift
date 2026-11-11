import Orchestrator
import SwiftUI
import WatercodedDesign

/// The sidebar's search field. A custom field rather than `.searchable`, whose system capsule clashes
/// with the app's squarer shapes. ⇧⌘F focuses it through `WindowModel.isSearchFocused`; Escape clears it.
struct SidebarSearchField: View {
    @Environment(WindowModel.self) private var window
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var window = window
        VStack(spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search sessions", text: $window.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onKeyPress(.escape) {
                        window.searchQuery = ""
                        isFocused = false
                        return .handled
                    }
                if !window.searchQuery.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { window.searchQuery = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall + 2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            if !window.searchQuery.isEmpty {
                Picker("Search in", selection: $window.searchScope) {
                    Text("Session names").tag(Workspace.SearchScope.sessionNames)
                    Text("All content").tag(Workspace.SearchScope.allContent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Search session names, or include conversation text and tool activity")
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .onChange(of: window.isSearchFocused, initial: true) { _, focused in isFocused = focused }
        .onChange(of: isFocused) { _, focused in window.isSearchFocused = focused }
    }
}
