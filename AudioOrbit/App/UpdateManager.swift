import AppKit
import Combine
import Foundation
import Sparkle

/// User-visible state of the most recent update check.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case failed(String)
}

/// Owns the Sparkle updater and surfaces its progress and failures so the
/// About page can show them instead of failing silently.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var lastCheckedAt: Date?

    private var updaterController: SPUStandardUpdaterController?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func startUpdaterIfNeeded() {
        guard updaterController == nil, !isRunningTests else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard updaterController != nil else {
            status = .failed("The updater is unavailable in this build.")
            return
        }
        NSLog("[Update] User requested an update check")
        status = .checking
        // Menu actions run while the menu is still tracking; an activation
        // request made from that context is dropped by AppKit, which leaves
        // Sparkle's status window invisible. Defer to the next runloop tick
        // so the menu has fully closed before activating and checking.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentUpdaterUI()
            self.updaterController?.checkForUpdates(nil)
        }
    }

    /// AudioOrbit is a menu-bar-only app (LSUIElement), so its activation
    /// policy is accessory and Sparkle's windows (checking status, update
    /// alerts) never appear. Temporarily activate as a regular app for the
    /// duration of the user-initiated check so the UI is actually visible,
    /// then restore the accessory policy once the cycle settles.
    private func presentUpdaterUI() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    private func restoreAccessoryPolicyIfIdle() {
        if hasPendingUpdate { return }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var hasPendingUpdate: Bool {
        if case .updateAvailable = status { return true }
        return false
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        NSLog("[Update] Appcast loaded with %d items", appcast.items.count)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("[Update] Valid update found: %@", item.displayVersionString)
        status = .updateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("[Update] No update found: %@", error.localizedDescription)
        status = .upToDate
        lastCheckedAt = Date()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("[Update] Update aborted: %@", error.localizedDescription)
        // Sparkle aborts the "no update found" flow with an error whose
        // message is "You're up to date!"; that is not a failure.
        if status != .upToDate, !hasPendingUpdate {
            status = .failed(error.localizedDescription)
        }
        lastCheckedAt = Date()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            NSLog("[Update] Update cycle finished with error: %@", error.localizedDescription)
            // If the flow reported something more specific (up to date,
            // update available, or an abort failure), keep it. Only surface
            // the cycle error when nothing else did.
            if status == .checking {
                status = .failed(error.localizedDescription)
            }
        } else {
            NSLog("[Update] Update cycle finished cleanly")
        }
        lastCheckedAt = Date()
        NSLog("[Update] Cycle settled, status: %@", statusDescription)
        restoreAccessoryPolicyIfIdle()
    }

    private var statusDescription: String {
        switch status {
        case .idle:
            return "idle"
        case .checking:
            return "checking"
        case .upToDate:
            return "upToDate"
        case .updateAvailable(let version):
            return "updateAvailable(" + version + ")"
        case .failed(let message):
            return "failed(" + message + ")"
        }
    }
}
