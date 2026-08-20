import ApplicationServices
import Foundation

/// Observes window-level accessibility notifications for the applications
/// whose windows AudioOrbit inspects, so window evidence refreshes are
/// event-driven ("the window arrived on a display") instead of purely
/// polled. A slow poll remains in the model as a safety net for transitions
/// that emit no window notification (for example dragging a Safari tab into
/// an already-open window).
///
/// Two things make this observer actually work where the original did not:
///
/// 1. AXObserverCreate's first parameter is the PID OF THE OBSERVED
///    application, not the observer's own PID. The original monitor created
///    a single observer with getpid() and registered other apps' elements on
///    it; every AXObserverAddNotification silently failed with
///    kAXErrorIllegalArgument (-25201), so no event was ever delivered and
///    everything depended on the poll. Each tracked application now gets its
///    own observer created with that application's PID.
///
/// 2. kAXWindowMovedNotification is a WINDOW-level notification. AppKit
///    applications forward it to observers registered on the application
///    element, but Safari's custom window machinery does not — it only posts
///    on the window elements themselves. Each window of every tracked
///    application therefore gets its own registration for moved / resized /
///    destroyed, while the application element carries the
///    application-level notifications (created / focused / main). New
///    windows are picked up from kAXWindowCreatedNotification plus a
///    periodic sync, so late-appearing windows (tabs, fullscreen surfaces)
///    get observers too.
///
/// The callback fires on the main run loop; delivery to the model is
/// debounced so a burst of notifications (move + resize + focus) collapses
/// into a single evidence refresh per application.
final class AccessibilityWindowEventMonitor {
    /// Debounced delivery of the most recent window event batch, carrying
    /// the PID of the application that owns the affected window.
    var onEvent: ((pid_t) -> Void)?

    /// One AXObserver per observed application: AXObserverCreate's first
    /// parameter is the observed app's PID, so cross-app observation
    /// requires per-app observers.
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var trackedApplicationPIDs: Set<pid_t> = []
    private var registeredApplicationNotifications: [pid_t: Set<String>] = [:]
    private var registeredWindowElements: [pid_t: [(element: AXUIElement, notifications: [String])]] = [:]
    private var pendingDelivery: Task<Void, Never>?
    private var pendingBatch: Set<pid_t> = []
    private var periodicSyncTask: Task<Void, Never>?

    private static let debounceNanoseconds: UInt64 = 150_000_000
    private static let windowSyncInterval = Duration.seconds(2)

    /// Application-element notifications: the observed element is the app.
    private static let applicationNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
    ]

    /// Window-element notifications: observed per window, because Safari
    /// does not forward these to application-level observers.
    private static let windowNotifications: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    func start() throws {
        guard periodicSyncTask == nil else { return }
        // Re-register any application PIDs that were requested before the
        // run-loop wiring existed.
        let pids = trackedApplicationPIDs
        trackedApplicationPIDs = []
        setTrackedApplicationPIDs(pids)
        startPeriodicWindowSync()
    }

    /// Keeps notifications registered for exactly the given application PIDs.
    /// Registration failures (for example while the accessibility permission
    /// is missing) are tolerated and retried by the periodic window sync.
    func setTrackedApplicationPIDs(_ pids: Set<pid_t>) {
        guard pids != trackedApplicationPIDs else { return }
        for pid in trackedApplicationPIDs.subtracting(pids) {
            removeApplicationRegistrations(pid: pid)
        }
        for pid in pids.subtracting(trackedApplicationPIDs) {
            addApplicationRegistrations(pid: pid)
            syncWindowObservers(for: pid)
        }
        trackedApplicationPIDs = pids
    }

    /// Re-enumerates every tracked application's windows now. Used as
    /// the reconciliation step after an active-Space change (fullscreen
    /// Spaces, swipes, Mission Control), which fires no window events.
    func resyncAllWindows() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for pid in self.trackedApplicationPIDs {
                self.syncWindowObservers(for: pid)
            }
        }
    }

    func stop() {
        for pid in trackedApplicationPIDs {
            removeApplicationRegistrations(pid: pid)
        }
        trackedApplicationPIDs.removeAll()
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingBatch.removeAll()
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
    }

    deinit {
        stop()
    }

    /// Called on the AX run-loop thread; hops to the main actor and delivers
    /// the accumulated batch once per debounce window. A burst of
    /// notifications (move + resize + focus) collapses into one delivery per
    /// application.
    private func deliverEvent(ownerPID: pid_t) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBatch.insert(ownerPID)
            self.pendingDelivery?.cancel()
            self.pendingDelivery = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.pendingDelivery = nil
                let batch = self.pendingBatch
                self.pendingBatch = []
                for pid in batch {
                    self.onEvent?(pid)
                }
            }
        }
    }

    /// Shared callback for every per-application observer; the refcon is the
    /// monitor itself.
    private static let observerCallback: AXObserverCallback = {
        _, element, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<AccessibilityWindowEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        let name = notification as String
        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)
        if ownerPID <= 0 {
            // A destroyed window may already refuse attribute reads;
            // fall back to the PID recorded at registration time.
            ownerPID = monitor.pidForRegisteredElement(element)
        }
        guard ownerPID > 0 else { return }
        if name == kAXWindowCreatedNotification
            || name == kAXUIElementDestroyedNotification {
            monitor.scheduleWindowSync(for: ownerPID)
        }
        monitor.deliverEvent(ownerPID: ownerPID)
    }

    /// Creates (or returns) the AXObserver for one observed application.
    private func observer(for pid: pid_t) -> AXObserver? {
        if let existing = observersByPID[pid] { return existing }
        var created: AXObserver?
        let result = AXObserverCreate(
            pid,
            Self.observerCallback,
            &created
        )
        guard result == .success, let created else {
            return nil
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
        observersByPID[pid] = created
        return created
    }

    @discardableResult
    private func addApplicationRegistrations(pid: pid_t) -> Bool {
        guard let observer = observer(for: pid) else { return false }
        let application = AXUIElementCreateApplication(pid)
        var registered = registeredApplicationNotifications[pid] ?? []
        var didRegister = false
        for notification in Self.applicationNotifications
            where !registered.contains(notification) {
            let result = AXObserverAddNotification(
                observer,
                application,
                notification as CFString,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if result == .success {
                registered.insert(notification)
                didRegister = true
            }
        }
        registeredApplicationNotifications[pid] = registered
        return didRegister
    }

    private func removeApplicationRegistrations(pid: pid_t) {
        guard let observer = observersByPID[pid] else {
            registeredApplicationNotifications[pid] = nil
            registeredWindowElements[pid] = nil
            return
        }
        let application = AXUIElementCreateApplication(pid)
        for notification in registeredApplicationNotifications[pid] ?? [] {
            AXObserverRemoveNotification(
                observer,
                application,
                notification as CFString
            )
        }
        registeredApplicationNotifications[pid] = nil
        for entry in registeredWindowElements[pid] ?? [] {
            for notification in entry.notifications {
                AXObserverRemoveNotification(
                    observer,
                    entry.element,
                    notification as CFString
                )
            }
        }
        registeredWindowElements[pid] = nil
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        observersByPID[pid] = nil
    }

    /// Re-enumerates the application's AX windows and makes the per-window
    /// registrations match. Runs on the main queue.
    private func syncWindowObservers(for pid: pid_t) {
        var didChange = addApplicationRegistrations(pid: pid)
        guard let observer = observersByPID[pid] else { return }
        let application = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success else { return }
        guard let windows = windowsValue as? [AXUIElement] else { return }
        let previous = registeredWindowElements[pid] ?? []
        var next: [(element: AXUIElement, notifications: [String])] = []
        for entry in previous
            where !windows.contains(where: { CFEqual($0, entry.element) }) {
                didChange = true
                for notification in entry.notifications {
                    AXObserverRemoveNotification(
                        observer,
                        entry.element,
                        notification as CFString
                    )
                }
        }
        for window in windows {
            let previousEntry = previous.first {
                CFEqual($0.element, window)
            }
            var registered = previousEntry?.notifications ?? []
            if previousEntry == nil {
                didChange = true
            }
            for notification in Self.windowNotifications
                where !registered.contains(notification) {
                let result = AXObserverAddNotification(
                    observer,
                    window,
                    notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                if result == .success {
                    registered.append(notification)
                    didChange = true
                }
            }
            next.append((window, registered))
        }
        registeredWindowElements[pid] = next
        if didChange {
            deliverEvent(ownerPID: pid)
        }
    }

    private func scheduleWindowSync(for pid: pid_t) {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindowObservers(for: pid)
        }
    }

    private func startPeriodicWindowSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.windowSyncInterval)
                guard !Task.isCancelled, let self else { return }
                for pid in self.trackedApplicationPIDs {
                    self.syncWindowObservers(for: pid)
                }
            }
        }
    }

    private func pidForRegisteredElement(_ element: AXUIElement) -> pid_t {
        for (pid, entries) in registeredWindowElements {
            if entries.contains(where: { CFEqual($0.element, element) }) {
                return pid
            }
        }
        return 0
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
