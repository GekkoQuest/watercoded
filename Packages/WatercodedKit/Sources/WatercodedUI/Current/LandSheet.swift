import AppKit
import GitKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Ships a Current's work: commit, then merge into your branch or open a pull request.
struct LandSheet: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    private enum Destination: Hashable {
        case merge
        case pullRequest
        case commitOnly
    }

    @State private var message = ""
    @State private var destination = Destination.pullRequest
    @State private var target = "main"
    @State private var removeWorktree = true
    @State private var isWorking = false
    @State private var isDrafting = true
    @State private var errorMessage: String?
    @State private var conflictingTarget: String?
    @State private var result: LandResult?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text("Land “\(controller.current.title)”").font(.title2.weight(.semibold)).lineLimit(2)
            if let result {
                outcome(result)
            } else {
                form
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 560)
        .task { await prepare() }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("Commit message").font(.headline)
                if isDrafting {
                    ProgressView().controlSize(.small)
                    Text("Drafting…").foregroundStyle(.secondary).font(.callout)
                }
            }
            TextEditor(text: $message)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(Spacing.small)
                .frame(minHeight: 90)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium))
        }

        Picker("Then", selection: $destination) {
            Text("Open a pull request into \(target)").tag(Destination.pullRequest)
            if isWorktree {
                Text("Merge into \(target) locally").tag(Destination.merge)
            }
            Text("Just commit (keep the branch)").tag(Destination.commitOnly)
        }
        .pickerStyle(.radioGroup)

        if isWorktree {
            Toggle(
                "Remove the worktree afterwards (the branch \(controller.current.channel.branch) is kept)",
                isOn: $removeWorktree
            )
        }
        if destination == .pullRequest {
            Text("Pushes the branch, then opens the pull request with the GitHub CLI if it's signed in, "
                + "or in your browser otherwise. The description is written from this session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let conflictingTarget {
                Button("Ask the Agent to Fix the Conflict", systemImage: "wand.and.sparkles") {
                    Task {
                        await controller.send(Self.conflictPrompt(target: conflictingTarget))
                        dismiss()
                    }
                }
                .help("Sends the agent a request to rebase onto \(conflictingTarget) and resolve the conflicts")
            }
        }

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) { Task { await land() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func outcome(_ result: LandResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            if let commit = result.commit {
                Label("Committed \(commit.prefix(7))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if result.merged {
                Label("Merged into \(target)", systemImage: "arrow.triangle.merge").foregroundStyle(.green)
            }
            if let url = result.pullRequestURL {
                Label { Link("Pull request opened", destination: url) } icon: {
                    Image(systemName: "arrow.up.forward.square")
                }
            } else if let url = result.compareURL {
                Label {
                    Link("Open the pull request page", destination: url)
                } icon: {
                    Image(systemName: "safari")
                }
                Text("The branch is pushed. Finish the pull request in your browser.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isWorktree: Bool {
        controller.current.channel.kind == .worktree
    }

    private var actionTitle: String {
        switch destination {
        case .merge: "Commit & Merge"
        case .pullRequest: "Commit & Open Pull Request"
        case .commitOnly: "Commit"
        }
    }

    private func prepare() async {
        target = await workspace.landingTarget(for: controller.id) ?? "main"
        message = controller.current.title
        message = await workspace.draftCommitMessage(for: controller.id)
        isDrafting = false
    }

    private func land() async {
        isWorking = true
        defer { isWorking = false }
        conflictingTarget = nil
        let landing: LandDestination = switch destination {
        case .merge: .merge(into: target)
        case .pullRequest: .pullRequest(base: target)
        case .commitOnly: .commitOnly
        }
        do {
            let result = try await workspace.land(controller.id, options: LandOptions(
                commitMessage: message,
                destination: landing,
                removeWorktree: isWorktree && removeWorktree
            ))
            self.result = result
            if let url = result.compareURL, result.pullRequestURL == nil {
                NSWorkspace.shared.open(url)
            }
        } catch {
            errorMessage = error.localizedDescription
            if case .mergeConflict? = error as? GitError {
                conflictingTarget = target
            }
        }
    }

    static func conflictPrompt(target: String) -> String {
        "Landing failed: merging this branch into `\(target)` conflicts. Rebase this branch onto `\(target)`, "
            + "resolve every conflict while keeping the intent of both sides, run the tests, "
            + "and tell me when it's ready to land again."
    }
}
