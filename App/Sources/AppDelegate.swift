import AppKit
import Orchestrator

/// Lifecycle hooks SwiftUI doesn't cover: quitting safely while agents are working.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        // Agents that can't keep running in the background would be stopped mid-task: ask first.
        let working = workspace.workingCount
        if working > 0, !workspace.backgroundSessionsEnabled {
            let alert = NSAlert()
            alert.messageText = working == 1 ? "An agent is still working" : "\(working) agents are still working"
            alert.informativeText = "Quitting stops them mid-task. You can resume them later, but the work in "
                + "progress is interrupted. To avoid this, turn on “Keep agents working after Watercoded quits” "
                + "in Settings."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        Task {
            await workspace.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // agents keep working; the menu bar extra stays available
    }
}
