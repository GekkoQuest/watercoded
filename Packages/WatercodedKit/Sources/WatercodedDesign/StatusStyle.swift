import SwiftUI
import WatercodedCore

/// Presentation of a ``CurrentStatus``: label, symbol and color.
extension CurrentStatus {
    public var title: String {
        switch self {
        case .draft: "Draft"
        case .flowing: "Flowing"
        case .waiting: "Needs You"
        case .ashore: "Ready for Review"
        case .stalled: "Stalled"
        case .settled: "Archived"
        }
    }

    public var symbolName: String {
        switch self {
        case .draft: "square.and.pencil"
        case .flowing: "water.waves"
        case .waiting: "hand.raised.fill"
        case .ashore: "checkmark.circle"
        case .stalled: "exclamationmark.triangle.fill"
        case .settled: "archivebox"
        }
    }

    public var color: Color {
        switch self {
        case .draft, .settled: .secondary
        case .flowing: .accentColor
        case .waiting: .orange
        case .ashore: .green
        case .stalled: .red
        }
    }
}

extension PermissionMode {
    public var symbolName: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "checkmark.shield"
        case .plan: "list.bullet.clipboard"
        case .fullAccess: "exclamationmark.shield"
        }
    }
}

extension PermissionMode {
    /// One-line explanation shown wherever a mode is chosen.
    public var summary: String {
        switch self {
        case .ask: "Asks before editing files or running commands."
        case .acceptEdits: "Edits files without asking; still asks before running commands."
        case .plan: "Read-only: explores the code and proposes a plan, changes nothing."
        case .fullAccess: "Edits files and runs any command without asking. Use only in an isolated worktree you trust."
        }
    }

    /// Modes that deserve a visible warning.
    public var isRisky: Bool {
        self == .fullAccess
    }
}
