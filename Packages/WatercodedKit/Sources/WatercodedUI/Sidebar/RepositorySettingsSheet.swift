import AppKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Per-repository settings: worktree setup, extra folders agents may use, and standing approval rules.
struct RepositorySettingsSheet: View {
    let pool: Pool
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    @State private var selectedFolder: URL?
    @State private var ignoredItems: [String]?
    @State private var copyPaths: Set<String> = []
    @State private var setupScript = ""
    @State private var verifyCommand = ""
    @State private var verifyAfterEdits = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text("“\(pool.name)” Settings").font(.title2.weight(.semibold))

            GroupBox("New Worktrees") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Prepare each new worktree before the agent starts, so it has what your checkout has.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Copy from your checkout").font(.callout.weight(.medium))
                    if let ignoredItems {
                        if ignoredItems.isEmpty {
                            Text("Nothing git-ignored to copy.").foregroundStyle(.tertiary).font(.callout)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                                    ForEach(ignoredItems, id: \.self) { item in
                                        Toggle(item, isOn: Binding(
                                            get: { copyPaths.contains(item) },
                                            set: { isOn in
                                                if isOn {
                                                    copyPaths.insert(item)
                                                } else {
                                                    copyPaths.remove(item)
                                                }
                                            }
                                        ))
                                        .font(.callout.monospaced())
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 96)
                            Text("Copies are instant clones and take no extra space until changed. "
                                + "Secrets like .env are copied only if you tick them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Then run").font(.callout.weight(.medium))
                    TextEditor(text: $setupScript)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xSmall)
                        .frame(height: 54)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
                        .overlay(alignment: .topLeading) {
                            if setupScript.isEmpty {
                                Text("e.g. npm install").font(.callout.monospaced()).foregroundStyle(.tertiary)
                                    .padding(Spacing.small).allowsHitTesting(false)
                            }
                        }
                }
                .padding(Spacing.small)
            }

            GroupBox("Verify") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Watercoded runs this itself, so clear water means your checks really passed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Command", text: $verifyCommand, prompt: Text("e.g. npm test"))
                        .font(.callout.monospaced())
                    Toggle("Run after every turn that edits files", isOn: $verifyAfterEdits)
                        .disabled(verifyCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Extra Folders") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Agents can also read and edit these folders. Applies the next time an agent starts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    List(selection: $selectedFolder) {
                        ForEach(folders, id: \.self) { folder in
                            Label(folder.path(percentEncoded: false), systemImage: "folder").tag(folder)
                        }
                    }
                    .frame(minHeight: 90)
                    HStack {
                        Button("Add Folder…", systemImage: "plus", action: addFolders)
                        Button("Remove", systemImage: "minus") {
                            folders.removeAll { $0 == selectedFolder }
                            selectedFolder = nil
                        }
                        .disabled(selectedFolder == nil)
                    }
                }
                .padding(Spacing.small)
            }

            GroupBox("Always Allowed") {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Tool calls matching these rules are approved without asking. Add rules with "
                        + "“Always Allow” on an approval.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    let rules = workspace.pool(pool.id)?.approvalRules ?? []
                    if rules.isEmpty {
                        Text("No rules yet").foregroundStyle(.tertiary)
                    }
                    ForEach(rules) { rule in
                        HStack {
                            Label(rule.displayName, systemImage: "checkmark.shield").font(.callout.monospaced())
                            Spacer()
                            Button("Remove", systemImage: "trash") { workspace.removeApprovalRule(rule, from: pool.id) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        workspace.setWorktreeSetup(
                            WorktreeSetup(copyPaths: copyPaths.sorted(), script: setupScript),
                            for: pool.id
                        )
                        workspace.setVerifySettings(
                            VerifySettings(command: verifyCommand, runsAfterEdits: verifyAfterEdits),
                            for: pool.id
                        )
                        await workspace.setAdditionalDirectories(folders, for: pool.id)
                        dismiss()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xLarge)
        .frame(width: 560)
        .onAppear {
            folders = pool.additionalDirectoryURLs
            copyPaths = Set(pool.worktreeSetup?.copyPaths ?? [])
            setupScript = pool.worktreeSetup?.script ?? ""
            verifyCommand = pool.verify?.command ?? ""
            verifyAfterEdits = pool.verify?.runsAfterEdits ?? true
        }
        .task {
            // Keep earlier choices visible even if the item no longer exists.
            let found = await workspace.ignoredItems(in: pool.id)
            ignoredItems = Array(Set(found).union(copyPaths)).sorted()
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url) {
            folders.append(url)
        }
    }
}
