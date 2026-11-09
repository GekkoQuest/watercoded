import Orchestrator
import SwiftUI
import WatercodedDesign

/// Matches for the sidebar search across every Current's messages and tool calls.
struct SearchResultsList: View {
    let query: String
    @Environment(Workspace.self) private var workspace
    @Environment(WindowModel.self) private var window

    var body: some View {
        let hits = workspace.search(query)
        let grouped = Dictionary(grouping: hits, by: \.currentID)
        List {
            if hits.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
            }
            ForEach(workspace.currents.filter { grouped[$0.id] != nil }) { controller in
                Section(controller.current.title) {
                    ForEach(grouped[controller.id] ?? []) { hit in
                        Button {
                            window.selection = hit.currentID
                            window.highlightedItem = hit.itemID
                        } label: {
                            Text(highlighted(hit.snippet))
                                .font(.callout)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .callout.bold()
            text[range].foregroundColor = .accentColor
        }
        return text
    }
}
