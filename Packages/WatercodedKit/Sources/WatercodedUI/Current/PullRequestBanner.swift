import AppKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The pull request this session opened: its checks and reviews, and a way to hand problems back
/// to the agent.
struct PullRequestBanner: View {
    let controller: CurrentController
    let pull: PullRequestStatus
    @Environment(Workspace.self) private var workspace
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Image(systemName: PullRequestBadge.symbol(for: pull))
                .font(.title3)
                .foregroundStyle(PullRequestBadge.color(for: pull))
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Pull request \(pull.name)").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Check Now", systemImage: "arrow.clockwise") {
                Task {
                    isRefreshing = true
                    await workspace.refreshPullRequests()
                    isRefreshing = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(isRefreshing || pull.state != .open)
            Button("Open") { NSWorkspace.shared.open(pull.url) }
            if controller.pullRequestNeedsWork {
                Button("Ask the Agent to Fix") { Task { await controller.fixPullRequest() } }
                    .buttonStyle(.glassProminent)
                    .disabled(controller.isTurnActive)
            }
        }
        .padding(Spacing.medium)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
    }

    private var detail: String {
        switch pull.state {
        case .merged: return "Merged."
        case .closed: return "Closed without merging."
        case .open: break
        }
        var parts: [String] = switch pull.checks {
        case .none: []
        case .pending: ["Checks running"]
        case .passing: ["Checks passed"]
        case .failing: ["Failing: " +
                (pull.failingChecks.isEmpty ? "checks" : pull.failingChecks.joined(separator: ", "))]
        }
        if pull.changesRequested {
            parts.append("changes requested")
        } else if pull.reviewDecision == "APPROVED" {
            parts.append("approved")
        }
        if pull.commentCount > 0 {
            parts.append("\(pull.commentCount) \(pull.commentCount == 1 ? "comment" : "comments")")
        }
        if parts.isEmpty {
            return "Open. Watercoded checks it every couple of minutes."
        }
        return parts.joined(separator: " · ")
    }
}

/// A small icon for a pull request's state, shared by the banner and sidebar rows.
enum PullRequestBadge {
    static func symbol(for pull: PullRequestStatus) -> String {
        switch (pull.state, pull.checks) {
        case (.merged, _): "arrow.triangle.merge"
        case (.closed, _): "xmark.circle"
        case (_, .failing): "xmark.octagon.fill"
        case (_, .pending): "clock"
        case (_, .passing): "checkmark.circle.fill"
        case (_, .none): "arrow.triangle.pull"
        }
    }

    static func color(for pull: PullRequestStatus) -> Color {
        switch (pull.state, pull.checks) {
        case (.merged, _): .purple
        case (.closed, _): .secondary
        case (_, .failing): .red
        case (_, .passing): .green
        default: .secondary
        }
    }
}
