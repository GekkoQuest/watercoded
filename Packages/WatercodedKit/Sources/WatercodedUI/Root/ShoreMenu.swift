import Orchestrator
import SwiftUI
import WatercodedDesign

/// Contents of the menu bar extra: everything that needs you, answerable inline where possible.
public struct ShoreMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        let shore = workspace.shore
        if shore.isEmpty {
            Text("Nothing needs you")
        } else {
            ForEach(shore) { controller in
                Section(controller.current.title) {
                    if let request = controller.pendingPermissions.first {
                        Text(request.summary)
                        Button("Approve") { Task { await controller.decide(request.id, .allow) } }
                        Button("Deny") {
                            Task { await controller.decide(request.id, .deny(reason: "The user denied this action.")) }
                        }
                    } else if controller.pendingPlan != nil {
                        Text("A plan is ready for review")
                        Button("Build") { Task { await controller.approvePlan() } }
                        Button("Review in Watercoded…") { open() }
                    } else if let question = controller.pendingQuestions.first?.questions.first {
                        Text(question.text)
                        Button("Answer in Watercoded…") { open() }
                    } else {
                        Text(controller.current.status.title)
                    }
                }
            }
        }
        Divider()
        Button("Open Watercoded") { open() }
        Button("Quit Watercoded") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open() {
        NSApp.activate()
        openWindow(id: "main")
    }
}

/// The menu bar icon: a drop that fills when something needs you.
public struct ShoreMenuIcon: View {
    @Environment(Workspace.self) private var workspace

    public init() {}

    public var body: some View {
        Image(systemName: workspace.shore.contains(where: \.isAwaitingUser) ? "drop.fill" : "drop")
    }
}
