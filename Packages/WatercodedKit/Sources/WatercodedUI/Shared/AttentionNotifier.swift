import AgentKit
import AppKit
import Orchestrator
import UserNotifications
import WatercodedCore

/// Posts macOS notifications when a Current needs you while Watercoded isn't in front, and handles
/// their action buttons (Allow / Deny an approval, Build a plan) without opening the app.
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionNotifier()

    private enum Category {
        static let approval = "watercoded.approval"
        static let plan = "watercoded.plan"
        static let open = "watercoded.open"
    }

    private nonisolated enum Action {
        static let allow = "watercoded.allow"
        static let deny = "watercoded.deny"
        static let build = "watercoded.build"
    }

    private nonisolated enum Key {
        static let current = "currentID"
        static let request = "requestID"
    }

    private weak var workspace: Workspace?
    private var settings: AppSettings?
    private var onOpen: ((CurrentID) -> Void)?
    private var hasRequestedAuthorization = false
    private var center: UNUserNotificationCenter {
        .current()
    }

    func install(workspace: Workspace, settings: AppSettings, onOpen: @escaping (CurrentID) -> Void) {
        self.workspace = workspace
        self.settings = settings
        self.onOpen = onOpen
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.approval, actions: [
                UNNotificationAction(identifier: Action.allow, title: "Allow"),
                UNNotificationAction(identifier: Action.deny, title: "Deny", options: .destructive)
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.plan, actions: [
                UNNotificationAction(identifier: Action.build, title: "Build")
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.open, actions: [], intentIdentifiers: [])
        ])
        workspace.onAttention = { [weak self] controller, event in self?.notify(controller, event) }
    }

    /// Clears notifications once the user is looking at the app.
    func appDidBecomeActive() {
        center.removeAllDeliveredNotifications()
    }

    // MARK: Posting

    private func notify(_ controller: CurrentController, _ event: AttentionEvent) {
        guard settings?.notificationsEnabled != false, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = controller.current.title
        content.userInfo = [Key.current: controller.id.rawValue.uuidString]
        content.sound = .default

        switch event {
        case let .approvalNeeded(request):
            content.subtitle = "\(request.toolName) needs your approval"
            content.body = request.summary
            content.categoryIdentifier = Category.approval
            content.userInfo[Key.request] = request.id
            content.interruptionLevel = .timeSensitive
        case .planReady:
            content.subtitle = "A plan is ready for review"
            content.body = "Build it, or open Watercoded to ask for changes."
            content.categoryIdentifier = Category.plan
        case let .questionAsked(question):
            content.subtitle = "The agent has a question"
            content.body = question
            content.categoryIdentifier = Category.open
        case let .turnFinished(outcome):
            switch outcome {
            case .completed:
                content.subtitle = "Ready for review"
                content.body = controller.current.summary ?? "The agent finished its turn."
            case let .failed(message):
                content.subtitle = "The agent stopped"
                content.body = message
            case .interrupted:
                return
            }
            content.categoryIdentifier = Category.open
            content.sound = nil
        case let .pullRequestChanged(change):
            describe(change, for: controller, in: content)
            content.categoryIdentifier = Category.open
        }

        let request = UNNotificationRequest(
            identifier: "\(controller.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        Task { [center] in
            if !hasRequestedAuthorization {
                hasRequestedAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            try? await center.add(request)
        }
    }

    private func describe(
        _ change: PullRequestChange,
        for controller: CurrentController,
        in content: UNMutableNotificationContent
    ) {
        let name = controller.current.pullRequest?.name ?? "The pull request"
        switch change {
        case let .checksFailed(checks):
            content.subtitle = "Checks failed on \(name)"
            content.body = checks.isEmpty ? "Open Watercoded to have the agent fix it." : checks
                .joined(separator: ", ")
        case .checksPassed:
            content.subtitle = "Checks passed on \(name)"
            content.sound = nil
        case .changesRequested:
            content.subtitle = "Changes requested on \(name)"
            content.body = "Open Watercoded to have the agent address the review."
        case let .newComments(count):
            content.subtitle = "\(count) new \(count == 1 ? "comment" : "comments") on \(name)"
        case .merged:
            content.subtitle = "\(name) was merged"
            content.sound = nil
        case .closed:
            content.subtitle = "\(name) was closed"
            content.sound = nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let currentString = info[Key.current] as? String,
              let uuid = UUID(uuidString: currentString) else { return }
        let requestID = info[Key.request] as? String
        let action = response.actionIdentifier
        await handle(action: action, current: CurrentID(uuid), requestID: requestID)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [] // in front, the app itself shows what needs attention
    }

    private func handle(action: String, current: CurrentID, requestID: String?) async {
        guard let controller = workspace?.controller(current) else { return }
        switch action {
        case Action.allow:
            if let requestID {
                await controller.decide(requestID, .allow)
            }
        case Action.deny:
            if let requestID {
                await controller.decide(requestID, .deny(reason: "The user denied this action."))
            }
        case Action.build:
            await controller.approvePlan()
        default:
            NSApp.activate()
            onOpen?(current)
        }
    }
}
