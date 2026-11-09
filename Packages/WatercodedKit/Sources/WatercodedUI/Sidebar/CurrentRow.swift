import Meniscus
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// A Current in the sidebar: its vessel glyph, title and status.
struct CurrentRow: View {
    let controller: CurrentController
    let showsPool: Bool
    @Environment(WaterEngine.self) private var engine
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = controller.current
        HStack(spacing: Spacing.medium) {
            VesselGlyph(vessel: engine.vessel(for: controller), tint: controller.waterTint)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                HStack(spacing: Spacing.xSmall) {
                    Text(current.title)
                        .lineLimit(1)
                    if let pull = current.pullRequest {
                        Image(systemName: PullRequestBadge.symbol(for: pull))
                            .font(.caption)
                            .foregroundStyle(PullRequestBadge.color(for: pull))
                            .help("Pull request \(pull.name)")
                    }
                    if let tasks = current.tasks, !tasks.isEmpty {
                        Text("\(tasks.completedCount)/\(tasks.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.xSmall)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: current.status.symbolName)
                        .foregroundStyle(current.status.color)
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xSmall)
        .opacity(current.status == .settled ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitle: String {
        if let summary = controller.current.summary, controller.current.status != .waiting {
            return summary
        }
        var parts = [controller.current.status.title]
        if showsPool, let pool = workspace.pool(controller.current.poolID) {
            parts.append(pool.name)
        }
        if let provider = controller.providerDescriptor {
            parts.append(provider.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let current = controller.current
        var parts = [current.title, current.status.title]
        parts.append("context \(Int(current.usage.contextFraction * 100)) percent")
        if controller.isAwaitingUser {
            parts.append("waiting for you")
        }
        if let tasks = current.tasks, !tasks.isEmpty {
            parts.append("\(tasks.completedCount) of \(tasks.count) tasks done")
        }
        if let summary = current.summary {
            parts.append(summary)
        }
        return parts.joined(separator: ", ")
    }
}
