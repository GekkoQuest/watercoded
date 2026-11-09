import Combine
import Sparkle

/// Owns the updater only in the GUI process; relay and delegation helpers never start it.
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    private var backgroundChecks: Task<Void, Never>?
    private static let checkInterval: Duration = .seconds(10 * 60)
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    override init() {
        super.init()
        // Development builds must not replace themselves with a published release.
        #if !DEBUG
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
        checkForUpdateInformation()
        backgroundChecks = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.checkInterval) } catch { return }
                guard self != nil else { return }
                self?.checkForUpdateInformation()
            }
        }
        #endif
    }

    deinit {
        backgroundChecks?.cancel()
    }

    private func checkForUpdateInformation() {
        let updater = controller.updater
        guard updater.automaticallyChecksForUpdates, !updater.sessionInProgress else { return }
        // Sparkle's scheduled checks have a one-hour minimum. Probing is a documented,
        // quiet API for updating our own UI without interfering with that scheduler.
        updater.checkForUpdateInformation()
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: any Error) {
        availableVersion = nil
    }

    func checkForUpdates() {
        // Also brings a pending gentle reminder into focus without starting a second check.
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem,
        andInImmediateFocus _: Bool
    ) -> Bool {
        // Even near launch, a background check should only reveal the sidebar icon.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        availableVersion = handleShowingUpdate ? nil : update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
