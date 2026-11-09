import Observation
import SwiftUI
import WatercodedCore

/// Per-window UI state, shared with menu commands through `focusedSceneValue`.
@Observable
public final class WindowModel {
    public var selection: CurrentID?
    public var isInspectorPresented = false
    public var newCurrentPool: PoolID?
    public var isNewCurrentPresented = false
    public var isAddingPool = false
    public var isSettlePromptVisible = false
    public var presentedError: PresentedError?
    /// A plain folder the user picked; we offer to `git init` it.
    public var folderAwaitingInitialization: URL?
    /// The Current being landed (commit/merge/PR sheet).
    public var landing: CurrentID?
    /// The pool whose outside sessions are being imported.
    public var importingInto: PoolID?
    /// A transcript item to scroll to and highlight (from search).
    public var highlightedItem: UUID?
    /// Text in the sidebar's search field; non-empty shows results across all Currents.
    public var searchQuery = ""
    public var isSearchFocused = false

    public init() {}

    /// Shows an alert whose title names what failed (e.g. "Couldn't Add Repository").
    public func present(_ error: any Error, title: String) {
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }

    public func beginNewCurrent(in pool: PoolID? = nil) {
        newCurrentPool = pool
        isNewCurrentPresented = true
    }
}

public struct PresentedError: Identifiable, Hashable {
    public let id = UUID()
    public let title: String
    public let message: String
}

extension FocusedValues {
    @Entry public var windowModel: WindowModel?
}
