import ApplicationServices
import Foundation
import OSLog

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
    /// the PID of the application that owns the affected window and whether
    /// the batch included a window-destroyed notification. The destroyed
    /// flag lets the model skip stale-anchor waiting: a window that really
    /// closed never needs a staleness dwell to be noticed.
    /// (ownerPID, movedSeen)
    var onEvent: ((pid_t, Bool) -> Void)?

    /// Public-privacy Logger: NSLog would be hidden from 'log show' as
    /// private data, which silently ate every diagnostic so far.
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.snowzjx.AudioOrbit",
        category: "AXEvents"
    )

    /// One AXObserver per observed application: AXObserverCreate's first
    /// parameter is the observed app's PID, so cross-app observation
    /// requires per-app observers.
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var trackedApplicationPIDs: Set<pid_t> = []
    private var registeredWindowElements: [pid_t: [(element: AXUIElement, notifications: [String])]] = [:]
    private var pendingDelivery: Task<Void, Never>?
    private var pendingBatch: [pid_t: Bool] = [:]
    private var periodicSyncTask: Task<Void, Never>?
    private var lastEventLogByKey: [String: Date] = [:]

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
    /// is missing) are tolerated: the model's slow poll still refreshes
    /// evidence.
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

    /// Debug dump of every tracked application's AX windows: role, subrole,
    /// title, frame, and AXFullScreen — used to learn what Safari's AX tree
    /// looks like during WebKit video fullscreen.
    func dumpWindowState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for pid in self.trackedApplicationPIDs {
                let application = AXUIElementCreateApplication(pid)
                var windowsValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    application,
                    kAXWindowsAttribute as CFString,
                    &windowsValue
                ) == .success,
                    let windows = windowsValue as? [AXUIElement] else {
                    continue
                }
                for (index, window) in windows.enumerated() {
                    let role = Self.axString(window, kAXRoleAttribute as CFString)
                        ?? "?"
                    let subrole = Self.axString(window, kAXSubroleAttribute as CFString)
                        ?? "-"
                    let title = Self.axString(window, kAXTitleAttribute as CFString)
                        ?? "-"
                    let position = Self.axPoint(window, kAXPositionAttribute as CFString)
                    let size = Self.axSize(window, kAXSizeAttribute as CFString)
                    let fullscreen = Self.axBool(window, "AXFullScreen" as CFString)
                        ?? false
                    self.logger.info(
                        "dump pid=\(pid, privacy: .public) #\(index, privacy: .public) role=\(role, privacy: .public) subrole=\(subrole, privacy: .public) title=\(title, privacy: .public) fullscreen=\(fullscreen, privacy: .public) pos=\(position?.debugDescription ?? "-", privacy: .public) size=\(size?.debugDescription ?? "-", privacy: .public)"
                    )
                }
            }
        }
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String else { return nil }
        return string
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
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
    /// application, with the destroyed flag OR-ed so a window close inside
    /// the burst is never lost.
    private func deliverEvent(ownerPID: pid_t, movedSeen: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBatch[ownerPID] =
                (self.pendingBatch[ownerPID] ?? false) || movedSeen
            self.pendingDelivery?.cancel()
            self.pendingDelivery = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.pendingDelivery = nil
                let batch = self.pendingBatch
                self.pendingBatch = [:]
                for (pid, moved) in batch {
                    self.onEvent?(pid, moved)
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
        let moved = name == kAXWindowMovedNotification
        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)
        if ownerPID <= 0 {
            // A destroyed window may already refuse attribute reads;
            // fall back to the PID recorded at registration time.
            ownerPID = monitor.pidForRegisteredElement(element)
        }
        guard ownerPID > 0 else { return }
        monitor.logEvent(name, pid: ownerPID)
        if name == kAXWindowCreatedNotification {
            monitor.scheduleWindowSync(for: ownerPID)
        }
        monitor.deliverEvent(ownerPID: ownerPID, movedSeen: moved)
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
            logger.warning("observer create for pid \(pid, privacy: .public) failed: \(result.rawValue, privacy: .public)")
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

    private func addApplicationRegistrations(pid: pid_t) {
        guard let observer = observer(for: pid) else { return }
        let application = AXUIElementCreateApplication(pid)
        var succeeded = 0
        for notification in Self.applicationNotifications {
            let result = AXObserverAddNotification(
                observer,
                application,
                notification as CFString,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if result == .success {
                succeeded += 1
            } else {
                logger.warning("observe \(notification, privacy: .public) on pid \(pid, privacy: .public) failed: \(result.rawValue, privacy: .public)")
            }
        }
        logger.info("app registrations pid=\(pid, privacy: .public) ok=\(succeeded, privacy: .public)")
    }

    private func removeApplicationRegistrations(pid: pid_t) {
        guard let observer = observersByPID[pid] else { return }
        let application = AXUIElementCreateApplication(pid)
        for notification in Self.applicationNotifications {
            AXObserverRemoveNotification(
                observer,
                application,
                notification as CFString
            )
        }
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
        guard let observer = observersByPID[pid] else { return }
        let application = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success else {
            logger.warning("window sync pid=\(pid, privacy: .public): windows attribute failed")
            return
        }
        guard let windows = windowsValue as? [AXUIElement] else {
            logger.warning("window sync pid=\(pid, privacy: .public): cast failed")
            return
        }
        logger.info("window sync pid=\(pid, privacy: .public): \(windows.count, privacy: .public) windows")
        var next: [(element: AXUIElement, notifications: [String])] = []
        for entry in registeredWindowElements[pid] ?? [] {
            if windows.contains(where: { CFEqual($0, entry.element) }) {
                next.append(entry)
            } else {
                for notification in entry.notifications {
                    AXObserverRemoveNotification(
                        observer,
                        entry.element,
                        notification as CFString
                    )
                }
            }
        }
        for window in windows {
            guard !next.contains(where: { CFEqual($0.element, window) }) else {
                continue
            }
            var registered: [String] = []
            for notification in Self.windowNotifications {
                let result = AXObserverAddNotification(
                    observer,
                    window,
                    notification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                if result == .success {
                    registered.append(notification)
                } else {
                    logger.warning("observe \(notification, privacy: .public) on a window of pid \(pid, privacy: .public) failed: \(result.rawValue, privacy: .public)")
                }
            }
            next.append((window, registered))
        }
        registeredWindowElements[pid] = next
    }

    private func scheduleWindowSync(for pid: pid_t) {
        DispatchQueue.main.async { [weak self] in
            self?.syncWindowObservers(for: pid)
        }
    }

    private func startPeriodicWindowSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.windowSyncInterval)
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for pid in self.trackedApplicationPIDs {
                        self.syncWindowObservers(for: pid)
                    }
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

    /// Rate-limited (once per second per pid+type) event logging so drags
    /// are diagnosable without flooding the unified log.
    private func logEvent(_ name: String, pid: pid_t) {
        let key = "\(pid):\(name)"
        let now = Date()
        if let last = lastEventLogByKey[key], now.timeIntervalSince(last) < 1 {
            return
        }
        lastEventLogByKey[key] = now
        logger.info("\(name, privacy: .public) pid=\(pid, privacy: .public)")
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

