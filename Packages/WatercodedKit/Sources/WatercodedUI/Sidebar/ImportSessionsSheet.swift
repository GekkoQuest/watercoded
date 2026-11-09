import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Lists sessions agents ran in a repository outside Watercoded (e.g. `claude` in Terminal) and
/// imports the chosen ones as Currents that can be resumed.
struct ImportSessionsSheet: View {
    let poolID: PoolID
    let onImported: (CurrentID) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Workspace.ImportCandidate] = []
    @State private var selection = Set<String>()
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("Import Sessions").font(.title2.weight(.semibold))
            Text("Sessions you ran in “\(workspace.pool(poolID)?.name ?? "")” outside Watercoded. "
                + "Imported sessions keep their history, and your next message continues them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(candidates, selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(candidate.session.title).lineLimit(2)
                    Text("\(candidate.session.updatedAt.formatted(.relative(presentation: .named))) · "
                        + "\(candidate.session.messageCount) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.xxSmall)
                .tag(candidate.id)
            }
            .frame(minHeight: 240)
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Sessions to Import",
                        systemImage: "tray",
                        description: Text("Sessions you start with the Claude Code CLI in this repository appear here.")
                    )
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Select All") { selection = Set(candidates.map(\.id)) }
                    .disabled(candidates.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(
                    importTitle
                ) {
                    Task { await importSelected() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || isImporting)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 600)
        .task { candidates = workspace.importCandidates(for: poolID) }
    }

    private var importTitle: String {
        let noun = selection.count == 1 ? "Session" : "Sessions"
        return selection.isEmpty ? "Import" : "Import \(selection.count) \(noun)"
    }

    private func importSelected() async {
        isImporting = true
        defer { isImporting = false }
        var last: CurrentID?
        for candidate in candidates where selection.contains(candidate.id) {
            do {
                last = try await workspace.importSession(candidate, into: poolID).id
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if let last {
            onImported(last)
        }
        dismiss()
    }
}
