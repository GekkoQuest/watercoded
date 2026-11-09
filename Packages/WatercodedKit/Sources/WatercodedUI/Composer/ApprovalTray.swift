import AgentKit
import Orchestrator
import SwiftUI
import WatercodedDesign

/// The oldest pending approval, with Approve / Deny. Its glass morphs in from the composer.
struct ApprovalTray: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Namespace private var glass

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xSmall) {
            tray
            if let request = controller.pendingPermissions.first {
                alwaysAllowRow(for: request)
            }
        }
    }

    /// "Always allow" with the exact rule it would add; after a few approvals of the same kind,
    /// the nudge says so.
    private func alwaysAllowRow(for request: PermissionRequest) -> some View {
        let rule = request.proposedRule
        let count = workspace.approvalCount(for: rule, in: controller.current.poolID)
        return HStack(spacing: Spacing.small) {
            if count >= 3 {
                Text("You've approved this \(count) times.")
                    .foregroundStyle(.secondary)
            }
            Button("Always Allow “\(rule.displayName)”") {
                Task { await controller.alwaysAllow(request.id, rule: rule) }
            }
            .buttonStyle(.link)
            .help("Approve this, and don't ask again in this repository for calls matching the rule. "
                + "Manage rules in Repository Settings.")
        }
        .font(.callout)
        .padding(.trailing, Spacing.small)
    }

    private var tray: some View {
        GlassEffectContainer(spacing: Spacing.small) {
            if let request = controller.pendingPermissions.first {
                HStack(spacing: Spacing.small) {
                    Label {
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text("\(request.toolName) needs your approval").font(.headline)
                            Text(request.summary)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        Image(systemName: request.kind.symbolName)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.medium)
                    .glassEffect(.regular.tint(.orange.opacity(0.3)), in: RoundedRectangle(cornerRadius: Radius.large))
                    .glassEffectID("request", in: glass)

                    if controller.pendingPermissions.count > 1 {
                        Text("+\(controller.pendingPermissions.count - 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    decisionButton("Deny", systemImage: "xmark", tint: nil, id: "deny") {
                        await controller.decide(request.id, .deny(reason: "The user denied this action."))
                    }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])

                    decisionButton("Approve", systemImage: "checkmark", tint: .green, id: "approve") {
                        await controller.decide(request.id, .allow)
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.morph, value: controller.pendingPermissions.first?.id)
    }

    private func decisionButton(
        _ title: String,
        systemImage: String,
        tint: Color?,
        id: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.small + 2)
        }
        .buttonStyle(.plain)
        .glassEffect(
            tint.map { .regular.tint($0.opacity(0.45)).interactive() } ?? .regular.interactive(),
            in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        )
        .glassEffectID(id, in: glass)
        .help("\(title) (\(title == "Approve" ? "⇧⌘↩" : "⇧⌘⌫"))")
    }
}
