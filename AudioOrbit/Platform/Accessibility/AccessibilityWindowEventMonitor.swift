import ApplicationServices
import Foundation

/// Observes window-level accessibility notifications for the applications
/// whose windows AudioOrbit inspects, so window evidence refreshes are
/// event-driven ("the window arrived on a display") instead of purely
/// polled. A slow poll remains in the model as a safety net for transitions
/// that emit no window notification (for example dragging a Safari tab into
/// an already-open window).
///
/// The callback fires on a CoreFoundation run-loop thread; delivery to the
/// model is debounced so a burst of notifications (move + resize + focus)
/// collapses into a single evidence refresh.
final class AccessibilityWindowEventMonitor {
    /// Debounced delivery of the most recent window event batch, carrying
    /// the PID of the application that owns the affected window and whether
    /// the batch included a window-destroyed notification. The destroyed
    /// flag lets the model skip stale-anchor waiting: a window that really
    /// closed never needs a staleness dwell to be noticed.
    var onEvent: ((pid_t, Bool) -> Void)?

    private var observer: AXObserver?
    private var trackedApplicationPIDs: Set<pid_t> = []
    private var pendingDelivery: Task<Void, Never>?
    private var pendingBatch: [pid_t: Bool] = [:]

    private static let debounceNanoseconds: UInt64 = 150_000_000

    private static let monitoredNotifications: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
    ]

    func start() throws {
        guard observer == nil else { return }
        var createdObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AccessibilityWindowEventMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            let destroyed =
                (notification as String) == kAXUIElementDestroyedNotification
            var ownerPID: pid_t = 0
            AXUIElementGetPid(element, &ownerPID)
            monitor.deliverEvent(ownerPID: ownerPID, destroyedSeen: destroyed)
        }
        let result = AXObserverCreate(getpid(), callback, &createdObserver)
        guard result == .success, let createdObserver else {
            throw AccessibilityEventMonitorError.observerCreationFailed(result)
        }
        observer = createdObserver
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .defaultMode
        )
        // Re-register any application PIDs that were requested before the
        // observer existed.
        let pids = trackedApplicationPIDs
        trackedApplicationPIDs = []
        setTrackedApplicationPIDs(pids)
    }

    /// Keeps notifications registered for exactly the given application PIDs.
    /// Registration failures (for example while the accessibility permission
    /// is missing) are tolerated: the model's slow poll still refreshes
    /// evidence.
    func setTrackedApplicationPIDs(_ pids: Set<pid_t>) {
        guard pids != trackedApplicationPIDs else { return }
        guard let observer else {
            trackedApplicationPIDs = pids
            return
        }
        for pid in trackedApplicationPIDs.subtracting(pids) {
            for notification in Self.monitoredNotifications {
                AXObserverRemoveNotification(
                    observer,
                    AXUIElementCreateApplication(pid),
                    notification as CFString
                )
            }
        }
        for pid in pids.subtracting(trackedApplicationPIDs) {
            let application = AXUIElementCreateApplication(pid)
            for notification in Self.monitoredNotifications {
                let result = AXObserverAddNotification(
                    observer,
                    application,
                    notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                if result != .success {
                    NSLog("[AXEvents] observe %@ on pid %d failed: %d", notification, pid, result.rawValue)
                }
            }
        }
        trackedApplicationPIDs = pids
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        for pid in trackedApplicationPIDs {
            for notification in Self.monitoredNotifications {
                AXObserverRemoveNotification(
                    observer,
                    AXUIElementCreateApplication(pid),
                    notification as CFString
                )
            }
        }
        trackedApplicationPIDs.removeAll()
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingBatch.removeAll()
        self.observer = nil
    }

    deinit {
        stop()
    }

    /// Called on the AX run-loop thread; hops to the main actor and delivers
    /// the accumulated batch once per debounce window. A burst of
    /// notifications (move + resize + focus) collapses into one delivery per
    /// application, with the destroyed flag OR-ed so a window close inside
    /// the burst is never lost.
    private func deliverEvent(ownerPID: pid_t, destroyedSeen: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBatch[ownerPID] =
                (self.pendingBatch[ownerPID] ?? false) || destroyedSeen
            self.pendingDelivery?.cancel()
            self.pendingDelivery = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.pendingDelivery = nil
                let batch = self.pendingBatch
                self.pendingBatch = [:]
                for (pid, destroyed) in batch {
                    self.onEvent?(pid, destroyed)
                }
            }
        }
    }
}

enum AccessibilityEventMonitorError: Error, CustomStringConvertible {
    case observerCreationFailed(AXError)

    var description: String {
        switch self {
        case .observerCreationFailed(let error):
            return "Could not create the accessibility observer (\(error.rawValue))."
        }
    }
}