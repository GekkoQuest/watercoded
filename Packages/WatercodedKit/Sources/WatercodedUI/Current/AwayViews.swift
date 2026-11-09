import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Shown when the app quit while this Current's agent was working and couldn't keep running.
struct ResumeBanner: View {
    let controller: CurrentController

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: "pause.circle").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Stopped when Watercoded quit").font(.headline)
                Text("The agent was mid-task. Resume to let it continue from where it was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { Task { await controller.resumeAfterQuit() } }
                .buttonStyle(.glassProminent)
        }
        .padding(Spacing.medium)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: Radius.large))
    }
}

/// "While you were away": what the agent did since you last looked, before the full transcript.
struct RecapCard: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @State private var diffSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Label("While you were away", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button("Got It") { controller.markViewed() }
                    .buttonStyle(.borderless)
            }
            if let summary = controller.current.summary {
                Text(summary)
            }
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                if let diffSummary {
                    Label(diffSummary, systemImage: "doc.on.doc")
                }
                if let check = controller.current.lastCheck {
                    Label(
                        "\(check.passed ? "Passed" : "Failed"): \(check.command)",
                        systemImage: check.passed ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundStyle(check.passed ? Color.green : .red)
                    .lineLimit(1)
                }
                if controller.isAwaitingUser {
                    Label("Waiting for your decision below", systemImage: "hand.raised").foregroundStyle(.orange)
                }
                if let ended = controller.current.lastTurnEndedAt {
                    Label("Finished \(ended.formatted(.relative(presentation: .named)))", systemImage: "flag.checkered")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(Spacing.medium)
        .glassEffect(.regular.tint(.accentColor.opacity(0.1)), in: RoundedRectangle(cornerRadius: Radius.large))
        .task {
            if let diff = try? await workspace.diff(for: controller.id), !diff.isEmpty {
                diffSummary = "\(diff.files.count) \(diff.files.count == 1 ? "file" : "files") changed, "
                    + "+\(diff.additions) −\(diff.deletions)"
            }
        }
    }
}
