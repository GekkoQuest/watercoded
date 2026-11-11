import Foundation
import IOKit.pwr_mgt
import Observation
import Orchestrator
import OSLog

/// Holds one idle-sleep assertion for all active turns, independently of window visibility.
public final class SessionSleepPrevention {
    private let workspace: Workspace
    private let settings: AppSettings
    private let acquire: () -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var assertion: IOPMAssertionID?

    /// Starts observing session activity and the user's preference for the lifetime of this service.
    public convenience init(workspace: Workspace, settings: AppSettings) {
        self.init(workspace: workspace, settings: settings, acquire: {
            var assertion: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Watercoded is running sessions" as CFString,
                &assertion
            )
            guard result == kIOReturnSuccess else {
                Logger(subsystem: "Watercoded", category: "Sleep prevention")
                    .error("Could not prevent idle sleep: \(result)")
                return nil
            }
            return assertion
        }, release: { IOPMAssertionRelease($0) })
    }

    init(
        workspace: Workspace,
        settings: AppSettings,
        acquire: @escaping () -> IOPMAssertionID?,
        release: @escaping (IOPMAssertionID) -> Void
    ) {
        self.workspace = workspace
        self.settings = settings
        self.acquire = acquire
        self.release = release
        observe()
    }

    isolated deinit {
        if let assertion {
            release(assertion)
        }
    }

    private func observe() {
        withObservationTracking {
            // Read both even when disabled so every observation cycle tracks both inputs.
            let enabled = settings.keepAwakeWhileRunning
            let activeSessionCount = workspace.workingCount
            update(enabled: enabled, activeSessionCount: activeSessionCount)
        } onChange: { [weak self] in
            // Observation fires before the mutation. Read the updated state on the next actor turn.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    func update(enabled: Bool, activeSessionCount: Int) {
        if enabled, activeSessionCount > 0 {
            if assertion == nil {
                assertion = acquire()
            }
        } else if let assertion {
            release(assertion)
            self.assertion = nil
        }
    }
}
