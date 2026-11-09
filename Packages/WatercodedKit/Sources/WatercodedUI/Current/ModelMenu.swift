import AgentKit
import Orchestrator
import SwiftUI
import WatercodedDesign

/// Model and reasoning effort for a Current. Model changes apply live when the provider allows it.
struct ModelMenu: View {
    let controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Environment(ProviderStatus.self) private var providers
    @State private var isEnteringCustomModel = false
    @State private var customModel = ""

    var body: some View {
        if let descriptor = controller.providerDescriptor {
            let options = ModelOptions(descriptor: descriptor, providers: providers, workspace: workspace)
            Menu {
                Section("Model") {
                    ForEach(options.models) { model in
                        Button {
                            Task { await controller.setModel(model.isDefault ? nil : model.id) }
                        } label: {
                            let name = options.name(for: model)
                            if isCurrent(model) {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                    if descriptor.capabilities.contains(.customModels) {
                        Button("Custom…") {
                            customModel = controller.current.model ?? ""
                            isEnteringCustomModel = true
                        }
                    }
                }
                if !descriptor.effortLevels.isEmpty {
                    Section("Effort") {
                        effortButton(nil, title: options.autoEffortName(forRequested: controller.current.model))
                        ForEach(descriptor.effortLevels, id: \.self) { effortButton($0, title: options.effortName($0)) }
                    }
                }
            } label: {
                Label(title(options), systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
            }
            .help(helpText(for: descriptor))
            .task { await providers.loadIfNeeded() }
            .alert("Custom Model", isPresented: $isEnteringCustomModel) {
                TextField("Model name", text: $customModel)
                Button("Use Model") {
                    let name = customModel.trimmingCharacters(in: .whitespaces)
                    Task { await controller.setModel(name.isEmpty ? nil : name) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter any model name or alias \(descriptor.displayName) accepts, e.g. a newly released model.")
            }
        }
    }

    private func isCurrent(_ model: AgentModel) -> Bool {
        controller.current.model.map { $0 == model.id } ?? model.isDefault
    }

    private func title(_ options: ModelOptions) -> String {
        // On Default, name the model this session actually runs, as the agent reported it.
        let running = controller.current.model == nil ? controller.current.environment?.model : nil
        let model = running.flatMap { options.displayName(forRequested: $0) }
            ?? options.displayName(forRequested: controller.current.model)
            ?? "Default"
        guard let effort = controller.current.effort else { return model }
        return "\(model) · \(options.effortName(effort))"
    }

    private func helpText(for descriptor: ProviderDescriptor) -> String {
        descriptor.capabilities.contains(.liveSettings)
            ? "Model and effort. Model changes apply immediately; effort applies from your next message."
            : "Model and effort. Changes apply from your next message."
    }

    private func effortButton(_ level: String?, title: String) -> some View {
        Button {
            Task { await controller.setEffort(level) }
        } label: {
            if controller.current.effort == level {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
