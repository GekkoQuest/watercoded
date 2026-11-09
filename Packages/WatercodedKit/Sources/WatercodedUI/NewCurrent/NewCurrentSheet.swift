import AgentKit
import AppKit
import GitKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Starts a Current: pick a Pool, a provider and model, write the first prompt.
struct NewCurrentSheet: View {
    let initialPool: PoolID?
    let onStarted: (CurrentID) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(ProviderStatus.self) private var providers
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var poolID: PoolID?
    @State private var providerID: ProviderID?
    @State private var modelID: String?
    @State private var customModel = ""
    @State private var effort: String?
    @State private var permissionMode: PermissionMode = .ask
    @State private var isolate = true
    @State private var prompt = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var poolHasCommits = true
    @State private var issue: GitHubIssue?
    @State private var issueQuery = ""
    @State private var isLoadingIssue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Session")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, Self.formEdge)
                .padding(.top, Spacing.xLarge)

            // One grouped form for everything, so every section shares the same edges and style.
            Form {
                Section {
                    Picker("Repository", selection: $poolID) {
                        ForEach(workspace.pools) { Text($0.name).tag(Optional($0.id)) }
                    }
                    agentSection
                    isolationSection
                }
                issueSection
                promptSection
            }
            .formStyle(.grouped)
            // Tall enough to show everything on most screens, but never taller than the space above the
            // Dock: on small screens the form scrolls and the title and buttons stay in view.
            .frame(minHeight: 280, idealHeight: min(620, Self.maxFormHeight), maxHeight: Self.maxFormHeight)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, Self.formEdge)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session") { Task { await start() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding(.horizontal, Self.formEdge)
            .padding(.vertical, Spacing.xLarge)
        }
        .frame(width: 580)
        .task { await prepare() }
        .task(id: poolID) {
            guard let poolID else { return }
            poolHasCommits = await workspace.hasCommits(poolID)
            if !poolHasCommits {
                isolate = false
            }
        }
        .onChange(of: providerID) {
            modelID = selectedDescriptor?.defaultModel?.id
            effort = nil
        }
    }

    @ViewBuilder private var agentSection: some View {
        Picker("Agent", selection: $providerID) {
            ForEach(providers.registry.descriptors) { descriptor in
                Label(providerTitle(descriptor), systemImage: descriptor.symbolName)
                    .tag(Optional(descriptor.id))
            }
        }
        if let descriptor = selectedDescriptor {
            let options = ModelOptions(descriptor: descriptor, providers: providers, workspace: workspace)
            if providers.availability(of: descriptor.id)?.isAvailable == false {
                ProviderStatusRow(descriptor: descriptor, availability: providers.availability(of: descriptor.id))
                Button("Check Again") { Task { await providers.refresh() } }
                    .disabled(providers.isRefreshing)
            }
            Picker("Model", selection: $modelID) {
                ForEach(options.models) { model in
                    Text(options.name(for: model)).tag(Optional(model.id))
                }
                if descriptor.capabilities.contains(.customModels) {
                    Divider()
                    Text("Custom…").tag(Optional(Self.customModelTag))
                }
            }
            if modelID == Self.customModelTag {
                TextField("Model name", text: $customModel, prompt: Text("e.g. a newly released model"))
            }
            if !descriptor.effortLevels.isEmpty {
                Picker("Effort", selection: $effort) {
                    Text(options.autoEffortName(forRequested: requestedModel(descriptor))).tag(String?.none)
                    ForEach(descriptor.effortLevels, id: \.self) { Text(options.effortName($0)).tag(Optional($0)) }
                }
            }
            Picker("Permissions", selection: $permissionMode) {
                ForEach(PermissionMode.allCases) { Text($0.displayName).tag($0) }
            }
            Label(
                permissionMode.summary,
                systemImage: permissionMode.isRisky ? "exclamationmark.triangle.fill" : "info.circle"
            )
            .font(.callout)
            .foregroundStyle(permissionMode.isRisky ? Color.red : .secondary)
        }
    }

    @ViewBuilder private var isolationSection: some View {
        Toggle("Run in its own worktree", isOn: $isolate)
            .disabled(!poolHasCommits)
            .help("Creates a branch and checkout under ~/.watercoded/worktrees so parallel agents never collide.")
        if !poolHasCommits {
            Text("No commits yet, so the agent works in your checkout. Commit once to enable worktrees.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !isolate {
            Text("The agent will edit your checkout directly.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Optional: load a GitHub issue to fill in the prompt and link the pull request to it.
    private var issueSection: some View {
        Section {
            HStack(spacing: Spacing.small) {
                TextField("Issue", text: $issueQuery, prompt: Text(verbatim: "Issue link or number, e.g. 12"))
                    .labelsHidden()
                    .onSubmit { Task { await loadIssue() } }
                if isLoadingIssue {
                    ProgressView().controlSize(.small)
                }
                Button("Load") { Task { await loadIssue() } }
                    .disabled(poolID == nil || isLoadingIssue || issueQuery.trimmingCharacters(in: .whitespaces)
                        .isEmpty)
            }
            if let issue {
                HStack(spacing: Spacing.small) {
                    Label("#\(issue.number) \(issue.title)", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.multicolor)
                        .lineLimit(1)
                    Spacer()
                    Button("Unlink", systemImage: "xmark.circle.fill") { unlinkIssue() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Don't link this issue")
                }
            }
        } header: {
            HStack(spacing: Spacing.xSmall) {
                Text("From a GitHub issue")
                Text("Optional").foregroundStyle(.tertiary)
            }
            .padding(.leading, -Self.rowInset)
        } footer: {
            Text(issue == nil
                ? "Its title and description become the prompt. Needs the GitHub CLI (gh)."
                : "Its description is in the prompt below. The pull request will close it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, -Self.rowInset)
        }
    }

    private var promptSection: some View {
        Section {
            TextEditor(text: $prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .accessibilityLabel("What should the agent do?")
        } header: {
            Text("What should the agent do?").padding(.leading, -Self.rowInset)
        }
    }

    private func loadIssue() async {
        guard let poolID, !issueQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isLoadingIssue = true
        defer { isLoadingIssue = false }
        do {
            let loaded = try await workspace.issue(issueQuery, in: poolID)
            issue = loaded
            prompt = loaded.prompt
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlinkIssue() {
        if prompt == issue?.prompt {
            prompt = ""
        }
        issue = nil
        issueQuery = ""
    }

    private static let customModelTag = "__custom__"
    /// Where a grouped form's sections start, measured from the sheet's edge.
    private static let formEdge: CGFloat = 20
    /// How far a grouped form indents headers and footers from the section's edge. Undone so section
    /// titles line up with the boxes below them rather than with the text inside.
    private static let rowInset: CGFloat = 10
    /// The usable screen height (excluding the menu bar and Dock) minus the sheet's title, buttons and margins.
    private static var maxFormHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(280, visible - 190)
    }

    /// The model to request: the picked one, the typed custom name, or `nil` for the default.
    /// The chosen model as the agent will receive it, with `nil` for Default.
    private func requestedModel(_ descriptor: ProviderDescriptor) -> String? {
        modelID == descriptor.defaultModel?.id ? nil : resolvedModel
    }

    private var resolvedModel: String? {
        if modelID == Self.customModelTag {
            let name = customModel.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return modelID
    }

    private var selectedDescriptor: ProviderDescriptor? {
        providerID.flatMap { id in providers.registry.descriptors.first { $0.id == id } }
    }

    private var canStart: Bool {
        guard poolID != nil, let providerID, !isStarting,
              providers.availability(of: providerID)?.isAvailable == true else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func providerTitle(_ descriptor: ProviderDescriptor) -> String {
        switch providers.availability(of: descriptor.id) {
        case nil, .available?: descriptor.displayName
        case .notInstalled?: "\(descriptor.displayName) (not installed)"
        case .unavailable?: "\(descriptor.displayName) (unavailable)"
        }
    }

    private func prepare() async {
        poolID = initialPool ?? workspace.pools.first?.id
        permissionMode = settings.defaultPermissionMode
        isolate = settings.isolateByDefault && poolHasCommits
        // Always re-check: the user may have just installed a CLI.
        await providers.refresh()
        let preferred = settings.defaultProviderID.flatMap {
            providers.availability(of: $0)?.isAvailable == true ? $0 : nil
        }
        providerID = preferred ?? providers.preferredProvider()?.id ?? providers.registry.descriptors.first?.id
        modelID = selectedDescriptor?.defaultModel?.id
    }

    private func start() async {
        guard let poolID, let providerID else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let controller = try await workspace.startCurrent(NewCurrentRequest(
                poolID: poolID,
                prompt: prompt,
                title: issue.map { "#\($0.number) \($0.title)" },
                providerID: providerID,
                model: resolvedModel,
                effort: effort,
                permissionMode: permissionMode,
                isolation: isolate ? .worktree : .checkout,
                issue: issue?.reference
            ))
            settings.defaultProviderID = providerID
            onStarted(controller.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
