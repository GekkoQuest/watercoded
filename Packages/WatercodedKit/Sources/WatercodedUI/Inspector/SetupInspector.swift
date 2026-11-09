import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// What the agent loaded for this Current, read-only: so you see what the agent sees.
struct SetupInspector: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let environment = controller.current.environment {
            Form {
                Section("Agent") {
                    LabeledContent("Version", value: environment.version ?? "Unknown")
                    LabeledContent("Model", value: environment.model ?? controller.current.model ?? "Default")
                    LabeledContent("Permissions", value: controller.current.permissionMode.displayName)
                }
                Section("Instruction Files") {
                    if environment.memoryFiles.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(environment.memoryFiles, id: \.self) { path in
                        Button {
                            NSWorkspace.shared.open(URL(filePath: path))
                        } label: {
                            Label((path as NSString).abbreviatingWithTildeInPath, systemImage: "doc.text")
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .buttonStyle(.link)
                    }
                }
                Section("MCP Servers") {
                    if environment.mcpServers.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(environment.mcpServers) { server in
                        LabeledContent(server.name) {
                            Text(server.status.capitalized)
                                .foregroundStyle(server.status == "connected" ? Color.green : .secondary)
                        }
                    }
                }
                list("Skills", environment.skills)
                list("Plugins", environment.plugins)
                list("Subagents", environment.agents)
                Section("Always Allowed in This Repository") {
                    let rules = workspace.pool(controller.current.poolID)?.approvalRules ?? []
                    if rules.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(rules) { Text($0.displayName).font(.callout.monospaced()) }
                }
                Section {
                    Text("\(environment.tools.count) tools available")
                        .foregroundStyle(.secondary)
                        .help(environment.tools.joined(separator: ", "))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Setup Yet",
                systemImage: "gearshape.2",
                description: Text(
                    "What the agent loads (MCP servers, skills, instruction files) appears once it starts."
                )
            )
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.self) { Text($0) }
            }
        }
    }
}

/// The inspector column: changes made, or the agent's setup.
struct CurrentInspector: View {
    let controller: CurrentController
    @State private var tab = Tab.changes

    enum Tab: Hashable {
        case changes
        case setup
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                Text("Changes").tag(Tab.changes)
                Text("Setup").tag(Tab.setup)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.small)
            switch tab {
            case .changes: DiffInspector(controller: controller)
            case .setup: SetupInspector(controller: controller)
            }
        }
        // Start at the top and fill the column, even when the content is short (e.g. no changes yet).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
