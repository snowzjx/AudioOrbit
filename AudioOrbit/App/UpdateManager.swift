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
    @Published private(set) var hasUnattendedUpdate = false

    private var updaterController: SPUStandardUpdaterController?
    private var updaterOwnsRegularActivationPolicy = false

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func startUpdaterIfNeeded() {
        guard updaterController == nil, !isRunningTests else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        guard updaterController != nil else {
            status = .failed("The updater is unavailable in this build.")
            return
        }
        hasUnattendedUpdate = false
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
            updaterOwnsRegularActivationPolicy = true
        }
        NSApp.activate()
    }

    private func restoreAccessoryPolicyIfIdle() {
        guard !hasPendingUpdate, updaterOwnsRegularActivationPolicy else { return }
        updaterOwnsRegularActivationPolicy = false

        // Settings and onboarding also use regular activation while their
        // windows are visible. Do not hide one of those windows merely
        // because Sparkle finished an update check.
        ApplicationDockPresence.hideIfNoOtherUserWindow(excluding: nil)
    }

    var hasPendingUpdate: Bool {
        if case .updateAvailable = status { return true }
        return false
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .updateAvailable(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .upToDate
        lastCheckedAt = Date()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
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
            // If the flow reported something more specific (up to date,
            // update available, or an abort failure), keep it. Only surface
            // the cycle error when nothing else did.
            if status == .checking {
                status = .failed(error.localizedDescription)
            }
        }
        lastCheckedAt = Date()
        restoreAccessoryPolicyIfIdle()
    }
}

extension UpdateManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle may present an update immediately when it knows the alert
        // will receive attention. Otherwise, keep the alert out of the
        // background and advertise it through AudioOrbit's menu-bar item.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        status = .updateAvailable(version: update.displayVersionString)
        hasUnattendedUpdate = !handleShowingUpdate && !state.userInitiated
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasUnattendedUpdate = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasUnattendedUpdate = false
    }
}
