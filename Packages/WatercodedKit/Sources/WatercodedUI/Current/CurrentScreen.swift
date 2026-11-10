import AgentKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The selected Current: its transcript, approvals and composer (whose water is the vessel).
struct CurrentScreen: View {
    let controller: CurrentController
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            if controller.current.interruptedByQuit == true {
                ResumeBanner(controller: controller)
                    .frame(maxWidth: Metrics.readableWidth)
                    .padding(.top, Spacing.small)
            }
            if let pull = controller.current.pullRequest {
                PullRequestBanner(controller: controller, pull: pull)
                    .frame(maxWidth: Metrics.readableWidth)
                    .padding(.top, Spacing.small)
                    .padding(.horizontal, Spacing.large)
            }
            if controller.hasUnseenResults {
                RecapCard(controller: controller)
                    .frame(maxWidth: Metrics.readableWidth)
                    .padding(.top, Spacing.small)
            }
            if let tasks = controller.current.tasks, !tasks.isEmpty {
                TaskProgressHeader(tasks: tasks)
                    .frame(maxWidth: Metrics.readableWidth)
                    .padding(.top, Spacing.small)
            }
            TranscriptView(controller: controller)
            VStack(spacing: Spacing.small) {
                if controller.current.status != .settled, let question = controller.pendingQuestions.first {
                    Button {
                        window.highlightedItem = controller.transcript.first(where: {
                            if case let .question(record) = $0.content {
                                return record.requestID == question.requestID
                            }
                            return false
                        })?.id
                    } label: {
                        Label(
                            "Answer: \(question.questions.first?.text ?? "The agent has a question")",
                            systemImage: "questionmark.bubble"
                        )
                        .lineLimit(1)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ApprovalTray(controller: controller)
                TurnStatsBar(controller: controller)
                ComposerView(controller: controller)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
            .frame(maxWidth: Metrics.readableWidth + Spacing.large * 2)
        }
        .frame(maxWidth: .infinity)
        // A Current you're looking at when its turn ends has been seen; one you return to later gets a recap.
        .onAppear {
            if !controller.hasUnseenResults {
                controller.markViewed()
            }
        }
        .onDisappear { controller.markViewed() }
        .onChange(of: controller.current.lastTurnEndedAt) { controller.markViewed() }
        .navigationTitle(controller.current.title)
        .navigationSubtitle(controller.current.channel.branch)
        .toolbar { toolbar }
        .transcriptLinks(relativeTo: controller.current.channel.url)
    }

    /// Two toolbar groups: how this Current runs (model, permissions, context), then what you can do
    /// with it. The system glass capsules behind toolbar items are hidden: plain controls read calmer.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ModelMenu(controller: controller)
            PermissionModeMenu(controller: controller)
            UsageButton(controller: controller)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Open In", systemImage: "arrow.up.forward.app") {
                OpenInMenuItems(url: controller.current.channel.url)
                Divider()
                ContinueInTerminalButton(controller: controller)
            }
            .help("Open this session's folder in Finder, an editor or a terminal")
            Button("Verify", systemImage: "checkmark.seal") { Task { await controller.verify() } }
                .disabled(!controller.canVerify || controller.isVerifying || controller.isTurnActive)
                .help(controller.canVerify
                    ? "Run this repository's check command now"
                    : "Set a check command in the repository's settings to verify work")
            Button("Land", systemImage: "arrow.down.to.line") { window.landing = controller.id }
                .disabled(controller.isTurnActive || controller.current.status == .settled
                    || controller.current.parentID != nil) // land through the session that delegated
                .help("Commit this session's work, then merge it or open a pull request")
            Button("Changes", systemImage: "sidebar.right") {
                window.isInspectorPresented.toggle()
            }
            .help("Show or hide the changes this session made (⌥⌘I)")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

private struct PermissionModeMenu: View {
    let controller: CurrentController
    @State private var isConfirmingFullAccess = false

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    choose(mode)
                } label: {
                    Text(mode.displayName)
                    Text(mode.summary)
                    if mode == controller.current.permissionMode {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(mode == .plan && !controller.capabilities.contains(.planMode))
            }
        } label: {
            Label(
                controller.current.permissionMode.displayName,
                systemImage: controller.current.permissionMode.symbolName
            )
            .labelStyle(.titleAndIcon)
        }
        .tint(controller.current.permissionMode.isRisky ? .red : nil)
        .help(helpText)
        .confirmationDialog("Give the agent full access?", isPresented: $isConfirmingFullAccess) {
            Button("Allow Full Access", role: .destructive) {
                Task { await controller.setPermissionMode(.fullAccess) }
            }
        } message: {
            Text(controller.current.channel.kind == .worktree
                ? "It can edit files and run any command in this worktree without asking."
                : "It can edit files and run any command in your checkout without asking. "
                + "Consider an isolated worktree instead.")
        }
    }

    private var helpText: String {
        "Permissions: \(controller.current.permissionMode.summary) "
            + "Changing it restarts the agent on your next message."
    }

    private func choose(_ mode: PermissionMode) {
        if mode.isRisky, mode != controller.current.permissionMode {
            isConfirmingFullAccess = true
        } else {
            Task { await controller.setPermissionMode(mode) }
        }
    }
}
