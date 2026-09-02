import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var processes: [AudioProcessSnapshot] = []
    @Published private(set) var displays: [DisplaySnapshot] = []
    @Published private(set) var mappings: [DisplayAudioMapping] = []
    @Published private(set) var routes: [ProbeRouteSnapshot] = []
    @Published var selectedProcessID: AudioObjectID?
    @Published var selectedDeviceID: AudioObjectID?
    @Published private(set) var isAddingRoute = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var windowDiscoveryMessage: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var followNotificationsEnabled = false
    @Published private(set) var automaticRoutingEnabled = false
    @Published private(set) var automaticRoutingMessage: String?
    @Published private(set) var headphoneOverrideEnabled = false
    @Published private(set) var headphoneOverrideDeviceUID: String?
    @Published private(set) var ignoredApplications: [IgnoredApplication] = []
    @Published private(set) var lastError: String?
    @Published private(set) var supportReportPreview = ""
    @Published private(set) var supportReportExportMessage: String?
    @Published private(set) var hasCompletedOnboarding: Bool

    private enum CleanupCompletion: Sendable {
        case remove(preserveAutomaticMode: Bool)
        case waitForDestination
    }

    private final class RouteSession {
        let id = UUID()
        var sourcePID: pid_t
        let sourceName: String
        let audioProcessName: String
        var audioProcessBundleIdentifier: String?
        let applicationBundleIdentifier: String?
        var sourceObjectID: AudioObjectID
        var destinationDeviceID: AudioObjectID?
        var destinationUID: String
        var destinationName: String
        let isAutomatic: Bool
        var followedDisplayUUID: UUID?
        var followedDisplayName: String?
        var state: TapProbeState = .starting
        var metrics = TapProbeMetrics()
        var health = AudioRouteHealth()
        var lastReportedHealthLevel: AudioRouteHealthLevel = .observing
        var notice: String?
        var error: String?
        var healthAnalyzer = AudioHealthAnalyzer()
        var metricsTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var switchTask: Task<Void, Error>?
        var cleanupRetryTask: Task<Void, Never>?
        var cleanupCompletion: CleanupCompletion?
        let probe = ProcessTapProbe()

        init(
            source: AudioProcessSnapshot,
            destination: AudioDeviceSnapshot,
            isAutomatic: Bool = false,
            displayedSourceName: String? = nil,
            applicationBundleIdentifier: String? = nil,
            followedDisplayUUID: UUID? = nil,
            followedDisplayName: String? = nil
        ) {
            sourcePID = source.pid
            sourceName = displayedSourceName ?? source.name
            audioProcessName = source.name
            audioProcessBundleIdentifier = source.bundleIdentifier
            self.applicationBundleIdentifier = applicationBundleIdentifier
                ?? source.bundleIdentifier
            sourceObjectID = source.id
            destinationDeviceID = destination.id
            destinationUID = destination.uid
            destinationName = destination.name
            self.isAutomatic = isAutomatic
            self.followedDisplayUUID = followedDisplayUUID
            self.followedDisplayName = followedDisplayName
        }
    }

    private final class AutomaticTrackingState {
        var hasCandidate = false
        var candidateDisplayUUID: UUID?
        var committedDisplayUUID: UUID?
        var committedWindowIdentifier: String?
        var wasRunningOutput: Bool?
        var association: ProcessWindowAssociation?
        var evidence: WindowDisplayEvidence?
        var decisionTask: Task<Void, Never>?
        var silentTickCount = 0
        var anchoredWebViewProcessID: pid_t?
        var anchoredPIDLastReportedAt: ContinuousClock.Instant?
        var manualAnchorOverride = false
        var commitRetryAttempted = false
        var candidateRetryNotBefore: ContinuousClock.Instant?
        var switchRetryCount = 0
        var pendingSessionRelease = false
    }

    private static let hardwareChangeCoalescingDelay = Duration.milliseconds(100)
    private static let routeSilenceSuspendSeconds = 60
    private static let routeSilenceMigrateSeconds = 3
    private static let routeSilenceMigrateRetrySeconds = 5
    private static let reconnectDwell = Duration.seconds(1)
    private static let healthWarmUp = Duration.seconds(3)
    private static let cleanupRetryDelay = Duration.seconds(1)
    private static let playbackSessionSilenceTicks = 2
    /// Route-side debounce: the actual device switch fires only after the
    /// target display has held steady for this long. Every event pushes its
    /// candidate into the queue and restarts the timer, so rapid A-B-A-B
    /// alternation is absorbed at the sink instead of being gated upstream.
    private static let routeSwitchDebounce = Duration.milliseconds(500)
    private static let precomputeInterval: TimeInterval = 4
    /// A renderer that stays unreported for this duration is genuinely gone
    /// (the playing tab closed); shorter gaps are churn transients. Wall-clock
    /// duration is stable even when AX events temporarily accelerate refreshes.
    private static let anchorLongGapRelease = Duration.seconds(6)
    private static let failedCandidateRetryCooldown = Duration.seconds(5)
    private static let followNotificationsDefaultsKey = "AudioOrbitFollowNotificationsEnabled"

    private let discovery = AudioDiscovery()
    private let deviceMonitor = AudioDeviceMonitor()
    private let processActivityMonitor = AudioProcessActivityMonitor()
    private let windowEventMonitor = AccessibilityWindowEventMonitor()
    private let displayDiscovery = DisplayDiscovery()
    private let displayMonitor = DisplayMonitor()
    private let processWindowResolver = ProcessWindowAssociationResolver()
    private let volumeController = AudioDeviceVolumeController()
    private let mappingStore: MappingStore
    private let diagnostics: DiagnosticsRecorder
    private let onboardingStore: OnboardingStateStore
    private let launchDate = Date()
    private var sessions: [UUID: RouteSession] = [:]
    private var routeOrder: [UUID] = []
    private var hardwareRefreshTask: Task<Void, Never>?
    private var hardwareFollowUpTask: Task<Void, Never>?
    private var windowObservationTask: Task<Void, Never>?
    private var lastDisplayRefreshDate = Date.distantPast
    private var automaticTracking: [pid_t: AutomaticTrackingState] = [:]
    private var automaticRouteIDs: [pid_t: UUID] = [:]
    private var vanishedSourceGraceTasks: [pid_t: Task<Void, Never>] = [:]
    private var cachedApplicationRoutes: [CachedApplicationRoute] = []
    private var suppressedAutomaticSourcePIDs: Set<pid_t> = []

    /// Invalidates results from an older AX query batch when a newer window,
    /// Space or hardware event starts another refresh while the first batch
    /// is suspended awaiting cross-process Accessibility calls.
    private var automaticEvidenceRefreshGeneration = 0
    private var automaticEvidenceRefreshInProgress = false
    private var automaticEvidenceRefreshPending = false
    private var automaticEvidenceRefreshPendingForce = false



    private var lastSeenPlayingPIDs: Set<pid_t> = []
    /// Precomputed window→display evidence for applications that exist
    /// but are not currently playing. Recording the mapping while the
    /// process exists (the app's core principle) lets a playback start
    /// take over immediately from the cache instead of waiting for a
    /// fresh Accessibility round trip.
    private var precomputedEvidenceByOwnerPID: [pid_t: (evidence: WindowDisplayEvidence, at: ContinuousClock.Instant)] = [:]
    private var precomputeTickCounter = 0
    private var lastPrecomputeDate = Date.distantPast
    private var reportedUnassociatedSourcePIDs: Set<pid_t> = []
    private var reportedSessionEvidenceIssuePIDs: Set<pid_t> = []
    private var applicationActivationObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var hasPerformedTerminationCleanup = false

    var menuBarSymbol: String {
        if routes.contains(where: { $0.state == .waitingForDestination || $0.state == .failed }) {
            return "exclamationmark.triangle"
        }
        if isAddingRoute || routes.contains(where: {
            $0.state == .starting
                || $0.state == .switching
                || $0.state == .stopping
                || $0.state == .reconnecting
        }) {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        return routes.contains(where: { $0.state == .running })
            ? "dot.radiowaves.left.and.right"
            : "waveform"
    }

    var canStartProbe: Bool {
        ConcurrentRouteAdmission.canStart(
            processID: selectedProcessID,
            deviceID: selectedDeviceID,
            processes: processes,
            devices: devices,
            activeSourcePIDs: activeSourcePIDs
        ) && !isAddingRoute
    }

    var selectedDevice: AudioDeviceSnapshot? {
        devices.first { $0.id == selectedDeviceID }
    }

    var mappingRows: [DisplayMappingRow] {
        let connectedIDs = Set(displays.map(\.id))
        let connectedRows = displays.map { display in
            mappingRow(
                for: mappings.first(where: { $0.displayUUID == display.id })
                    ?? .passThrough(display: display),
                display: display
            )
        }
        let disconnectedRows = mappings
            .filter { !connectedIDs.contains($0.displayUUID) }
            .sorted { $0.displayNameHint.localizedStandardCompare($1.displayNameHint) == .orderedAscending }
            .map { mappingRow(for: $0, display: nil) }
        return connectedRows + disconnectedRows
    }

    var hasRoutedDisplayMapping: Bool {
        mappings.contains { $0.behavior == .routeToDevice }
    }

    var headphoneOverrideDevice: AudioDeviceSnapshot? {
        guard let headphoneOverrideDeviceUID else { return nil }
        return devices.first { $0.uid == headphoneOverrideDeviceUID }
    }

    var activeHeadphoneOverrideDevice: AudioDeviceSnapshot? {
        guard automaticRoutingEnabled,
              headphoneOverrideEnabled,
              let device = headphoneOverrideDevice,
              device.isAlive else { return nil }
        return device
    }

    init(
        mappingStore: MappingStore = MappingStore(),
        startsServices: Bool = true,
        diagnostics: DiagnosticsRecorder = .shared,
        onboardingStore: OnboardingStateStore = OnboardingStateStore()
    ) {
        self.mappingStore = mappingStore
        self.diagnostics = diagnostics
        self.onboardingStore = onboardingStore
        hasCompletedOnboarding = onboardingStore.isCompleted
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
        followNotificationsEnabled = UserDefaults.standard.bool(
            forKey: Self.followNotificationsDefaultsKey
        )
        let loadedConfiguration = mappingStore.load()
        mappings = loadedConfiguration.configuration.mappings
        automaticRoutingEnabled = loadedConfiguration.configuration.routingEnabled
        cachedApplicationRoutes = loadedConfiguration.configuration.cachedRoutes
        ignoredApplications = loadedConfiguration.configuration.ignoredApplications
        headphoneOverrideEnabled = loadedConfiguration.configuration.headphoneOverrideEnabled
        headphoneOverrideDeviceUID = loadedConfiguration.configuration.headphoneOverrideDeviceUID
        publishRoutes()
        if let recoveryNotice = loadedConfiguration.recoveryNotice {
            lastError = recoveryNotice
            diagnostics.record(
                "configuration-recovered",
                category: "persistence",
                level: .warning
            )
        }
        diagnostics.record("launch", category: "application")
        guard startsServices else { return }
        deviceMonitor.onChange = { [weak self] in
            self?.scheduleHardwareReconciliation()
        }
        processActivityMonitor.onActivityChange = { [weak self] in
            self?.scheduleHardwareReconciliation()
            // A process often joins the audio table before it actually
            // starts output (launch-then-play), and the per-process
            // running-output property is not notifying. Follow up with
            // extra reconciles shortly after the event so playback
            // starts are discovered without waiting for the idle poll.
            self?.scheduleHardwareFollowUpChecks()
        }
        windowEventMonitor.onEvent = { [weak self] ownerPID in
            Task { @MainActor [weak self] in
                AccessibilityWindowDiscovery.invalidateSurfaceScanCache()
                AccessibilityWindowDiscovery.invalidateWindowMetadataCache()
                self?.precomputedEvidenceByOwnerPID.removeValue(
                    forKey: ownerPID
                )
                self?.precomputeTickCounter = 3
                await self?.refreshAutomaticWindowEvidence()
            }
        }
        displayMonitor.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A topology callback must bypass the normal one-second
                // display snapshot throttle and invalidate frame evidence now.
                self.lastDisplayRefreshDate = .distantPast
                await self.refreshWindowEvidence()
                await self.refreshAutomaticWindowEvidence()
            }
        }
        do {
            try deviceMonitor.start()
            try displayMonitor.start()
            try processActivityMonitor.start()
            try windowEventMonitor.start()
        } catch {
            lastError = "AudioOrbit could not watch for hardware changes: \(error)"
        }
        // Warm the application table off the main thread so the first
        // evidence refresh does not stall on LaunchServices lookups.
        processWindowResolver.warmApplicationsCache()
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.precomputeTickCounter = 3
                await self?.recheckAccessibilityAccess()
            }
        }
        // Space changes are a trigger, not a judgment: entering or
        // exiting a fullscreen Space fires no window events, so re-enumerate
        // the windows and refresh the evidence. The decision path's
        // debounce absorbs the transition animation itself.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AccessibilityWindowDiscovery.invalidateSurfaceScanCache()
                AccessibilityWindowDiscovery.invalidateWindowMetadataCache()
                self.windowEventMonitor.resyncAllWindows()
                await self.refreshAutomaticWindowEvidence()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isAddingRoute, !hasControlPlaneTransition else { return }
        diagnostics.markRefresh()
        refreshLaunchAtLoginStatus()
        await reconcileAudioHardware(clearErrorOnSuccess: true)
        await refreshWindowEvidence()
    }

    func setFollowNotificationsEnabled(_ enabled: Bool) async {
        followNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.followNotificationsDefaultsKey)
        if enabled {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                if !granted {
                    lastError = "Notifications are disabled in System Settings, so follow feedback will not appear."
                }
            } catch {
                lastError = "AudioOrbit could not request notification permission: \(error)"
            }
        }
    }

    private func postFollowNotification(for session: RouteSession) {
        guard followNotificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "AudioOrbit"
        content.body = "\(session.sourceName) is now playing through \(session.destinationName)."
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            diagnostics.record(
                enabled ? "launch-at-login-enabled" : "launch-at-login-disabled",
                category: "application"
            )
            lastError = nil
        } catch {
            lastError = "AudioOrbit could not update the launch-at-login setting: \(error)"
        }
        refreshLaunchAtLoginStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        let currentStatus = LaunchAtLogin.isEnabled
        if currentStatus != launchAtLoginEnabled {
            launchAtLoginEnabled = currentStatus
        }
    }

    func refreshSupportReportPreview() {
        supportReportPreview = makeSupportReport()
        supportReportExportMessage = nil
        diagnostics.record("preview-generated", category: "diagnostics")
    }


    func reanchorRouteToFocusedWindow(_ routeID: UUID) async {
        guard let session = sessions[routeID],
              let state = automaticTracking[session.sourcePID],
              let focusedID = state.evidence?.focusedWindowIdentifier,
              focusedID != state.committedWindowIdentifier else { return }
        // A manual pin is authoritative: suppress automatic anchor
        // following until the playback session restarts, otherwise the
        // renderer following would immediately pull the anchor back to the
        // previous reporter and the audio would snap back.
        state.committedWindowIdentifier = focusedID
        state.manualAnchorOverride = true
        if let focusedRendererPID = state.evidence?
            .webViewProcessIDsByWindow[focusedID] {
            state.anchoredWebViewProcessID = focusedRendererPID
            state.anchoredPIDLastReportedAt = .now
        }
        diagnostics.record("playback-anchor-manual-repin", category: "routing")
        await refreshAutomaticWindowEvidence(forceImmediate: true)
    }

    func completeOnboarding() {
        onboardingStore.setCompleted(true)
        hasCompletedOnboarding = true
        diagnostics.record("completed", category: "onboarding")
    }

    func exportSupportReport() {
        let report = makeSupportReport()
        supportReportPreview = report
        let panel = NSSavePanel()
        panel.title = "Save AudioOrbit Support Report"
        panel.nameFieldStringValue = "AudioOrbit-Support-Report.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                self?.supportReportExportMessage = "Support report saved."
                self?.diagnostics.record("export-succeeded", category: "diagnostics")
            } catch {
                self?.supportReportExportMessage = "The support report could not be saved."
                self?.diagnostics.record(
                    "export-failed",
                    category: "diagnostics",
                    level: .error
                )
            }
        }
    }

    func requestAccessibilityAccess() async {
        _ = AccessibilityPermission.requestFromUserAction()
        await recheckAccessibilityAccess()
        if !accessibilityGranted {
            windowDiscoveryMessage = "Approve the current AudioOrbit build in System Settings → Privacy & Security → Accessibility. If an older AudioOrbit entry is present, remove it once, then grant access again and press Recheck."
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSystemAudioRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func updateMapping(
        for displayUUID: UUID,
        selection: DisplayMappingSelection
    ) async {
        guard let index = mappings.firstIndex(where: { $0.displayUUID == displayUUID }) else {
            return
        }

        switch selection {
        case .passThrough:
            mappings[index].behavior = .passThrough
            mappings[index].audioDeviceUID = nil
            mappings[index].audioDeviceNameHint = nil

        case .device(let uid):
            guard let device = devices.first(where: { $0.uid == uid }) else { return }
            mappings[index].behavior = .routeToDevice
            mappings[index].audioDeviceUID = device.uid
            mappings[index].audioDeviceNameHint = device.name
        }
        persistConfiguration()

        if automaticRoutingEnabled {
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence(forceImmediate: true)
        }
    }

    func forgetDisplayMapping(for displayUUID: UUID) async {
        guard !displays.contains(where: { $0.id == displayUUID }),
              let index = mappings.firstIndex(where: { $0.displayUUID == displayUUID }) else {
            return
        }

        mappings.remove(at: index)
        persistConfiguration()

        if automaticRoutingEnabled {
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence(forceImmediate: true)
        }
    }

    func setDeviceVolume(deviceUID: String, scalar: Double) async {
        guard let index = devices.firstIndex(where: { $0.uid == deviceUID && $0.isAlive }) else {
            lastError = "That audio output is no longer connected."
            return
        }
        let device = devices[index]
        let previousVolume = device.volumeScalar
        let requestedVolume = Float(min(1, max(0, scalar)))
        devices[index].volumeScalar = requestedVolume
        do {
            try volumeController.setVolume(
                requestedVolume,
                deviceID: device.id,
                outputChannelCount: device.outputChannelCount
            )
            lastError = nil
        } catch {
            devices[index].volumeScalar = previousVolume
            lastError = "\(device.name) volume could not be changed: \(error)"
        }
    }

    func setHeadphoneOverrideDevice(_ deviceUID: String?) async {
        headphoneOverrideDeviceUID = deviceUID
        if deviceUID == nil {
            headphoneOverrideEnabled = false
        }
        persistConfiguration()
        if automaticRoutingEnabled {
            if !headphoneOverrideEnabled && !accessibilityGranted {
                await setAutomaticRoutingEnabled(false)
                return
            }
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence(forceImmediate: true)
        }
    }

    func setHeadphoneOverrideEnabled(_ enabled: Bool) async {
        guard !enabled || headphoneOverrideDeviceUID != nil else {
            lastError = "Choose a headphone output before enabling the override."
            return
        }
        headphoneOverrideEnabled = enabled
        persistConfiguration()
        if automaticRoutingEnabled {
            if !enabled && !accessibilityGranted {
                await setAutomaticRoutingEnabled(false)
                return
            }
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence(forceImmediate: true)
        }
    }

    func ignoreRoute(_ routeID: UUID) async {
        let session = sessions[routeID]
        let cachedRoute = cachedApplicationRoutes.first { $0.id == routeID }
        guard let bundleIdentifier = session?.applicationBundleIdentifier
                ?? cachedRoute?.applicationBundleIdentifier else {
            if let session {
                suppressedAutomaticSourcePIDs.insert(session.sourcePID)
                await stopRoute(routeID, preserveAutomaticMode: true)
                lastError = "The route was stopped, but this process has no stable application identifier and cannot be ignored permanently."
            }
            publishRoutes()
            return
        }

        let applicationName = session?.sourceName
            ?? cachedRoute?.applicationName
            ?? bundleIdentifier
        ignoreApplication(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )

        let matchingSourcePIDs = processes
            .filter { automaticApplicationBundleIdentifier(for: $0) == bundleIdentifier }
            .map(\.pid)
        for sourcePID in matchingSourcePIDs {
            suppressedAutomaticSourcePIDs.insert(sourcePID)
            automaticTracking[sourcePID]?.decisionTask?.cancel()
            automaticTracking.removeValue(forKey: sourcePID)
        }
        let matchingRouteIDs = sessions.values
            .filter { $0.applicationBundleIdentifier == bundleIdentifier }
            .map(\.id)
        for matchingRouteID in matchingRouteIDs {
            guard let matchingSession = sessions[matchingRouteID] else { continue }
            suppressedAutomaticSourcePIDs.insert(matchingSession.sourcePID)
            automaticTracking[matchingSession.sourcePID]?.decisionTask?.cancel()
            automaticTracking.removeValue(forKey: matchingSession.sourcePID)
            await stopRoute(matchingRouteID, preserveAutomaticMode: true)
        }
        persistConfiguration()
        await precomputeWindowMappings()
        updateAutomaticRoutingSummary()
        publishRoutes()
    }

    func allowIgnoredApplication(_ bundleIdentifier: String) async {
        ignoredApplications.removeAll {
            $0.applicationBundleIdentifier == bundleIdentifier
        }
        for source in processes where automaticApplicationBundleIdentifier(for: source)
            == bundleIdentifier {
            suppressedAutomaticSourcePIDs.remove(source.pid)
        }
        persistConfiguration()
        if automaticRoutingEnabled {
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence(forceImmediate: true)
        }
    }

    func setAutomaticRoutingEnabled(_ enabled: Bool) async {
        if enabled {
            let canRunHeadphoneOverride = headphoneOverrideEnabled
                && headphoneOverrideDeviceUID != nil
            guard accessibilityGranted || canRunHeadphoneOverride else {
                automaticRoutingMessage = "Grant Accessibility permission before enabling Follow Window."
                return
            }
            guard hasRoutedDisplayMapping
                    || (headphoneOverrideEnabled && headphoneOverrideDeviceUID != nil) else {
                automaticRoutingMessage = "Map a display or configure Headphone Override first."
                return
            }
            automaticRoutingEnabled = true
            diagnostics.record("enabled", category: "routing")
            automaticRoutingMessage = "Playing applications will follow their windows after a short stable delay."
            persistConfiguration()
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence()
        } else {
            automaticRoutingEnabled = false
            diagnostics.record("disabled", category: "routing")
            automaticRoutingMessage = "Follow Window is off. Normal macOS playback is used."
            cancelAutomaticDecisions()
            persistConfiguration()
            await stopAllAutomaticRoutes()
        }
    }

    func toggleAutomaticRouting() async {
        await setAutomaticRoutingEnabled(!automaticRoutingEnabled)
    }

    func recheckAccessibilityAccess() async {
        refreshLaunchAtLoginStatus()
        accessibilityGranted = AccessibilityPermission.isGranted
        let permissionAction = PermissionRoutingPolicy.action(
            accessibilityGranted: accessibilityGranted,
            automaticRoutingEnabled: automaticRoutingEnabled,
            hasConfiguredHeadphoneOverride: headphoneOverrideEnabled
                && headphoneOverrideDeviceUID != nil
        )
        switch permissionAction {
        case .keepCurrentState where accessibilityGranted:
            windowDiscoveryMessage = nil
            ensureWindowObservation()
            await refreshWindowEvidence()
        case .keepCurrentState:
            windowObservationTask?.cancel()
            windowObservationTask = nil
        case .continueHeadphoneOverride:
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence()
        case .stopAndRestorePassThrough:
            windowObservationTask?.cancel()
            windowObservationTask = nil
            automaticRoutingEnabled = false
            automaticRoutingMessage = "Accessibility permission is required. Automatic routing was stopped and normal playback was restored."
            diagnostics.record(
                "permission-revoked-pass-through",
                category: "routing",
                level: .warning
            )
            cancelAutomaticDecisions()
            persistConfiguration()
            await stopAllAutomaticRoutes()
        }
    }

    func refreshWindowEvidence() async {
        // Display topology rarely changes; snapshotting it on every tick is
        // wasted work. Throttle to once per second and rely on the
        // DisplayMonitor reconfiguration callback for instant updates.
        if Date().timeIntervalSince(lastDisplayRefreshDate) >= 1.0 {
            do {
                let refreshedDisplays = try displayDiscovery.snapshots()
                if refreshedDisplays != displays {
                    // Cached window frames were resolved against the previous
                    // display topology and cannot be safely reused.
                    precomputedEvidenceByOwnerPID.removeAll()
                }
                displays = refreshedDisplays
                synchronizeMappingsWithConnectedHardware()
                lastDisplayRefreshDate = Date()
            } catch {
                windowDiscoveryMessage = String(describing: error)
                return
            }
        }

        accessibilityGranted = AccessibilityPermission.isGranted
        guard accessibilityGranted else {
            if automaticRoutingEnabled && headphoneOverrideEnabled {
                ensureWindowObservation()
                await refreshAutomaticWindowEvidence()
            } else {
                windowObservationTask?.cancel()
                windowObservationTask = nil
            }
            return
        }
        ensureWindowObservation()
        // The window-selection check is event-driven: AX events, Space
        // changes, display reconfigurations, and hardware reconciliations
        // trigger refreshAutomaticWindowEvidence. The poll keeps the
        // display snapshot, the accessibility check, and the observer
        // registrations fresh but does not re-judge the selection on its
        // own cadence.
        await precomputeWindowMappings()
    }

    func startProbe() async {
        guard canStartProbe,
              let selectedProcessID,
              let selectedDeviceID,
              let source = processes.first(where: { $0.id == selectedProcessID }),
              let destination = devices.first(where: { $0.id == selectedDeviceID }) else { return }

        isAddingRoute = true
        lastError = nil
        let session = RouteSession(source: source, destination: destination)
        diagnostics.markRouteTransition()
        diagnostics.record("start-requested", category: "route")
        sessions[session.id] = session
        routeOrder.append(session.id)
        publishRoutes()
        defer { isAddingRoute = false }

        do {
            try session.probe.start(
                processObjectID: source.id,
                destinationDeviceID: destination.id
            )
            session.state = .running
            diagnostics.record("start-succeeded", category: "route")
            startMetricsSampling(for: session.id)
            updateWatchedDeviceIDs()
            chooseSuggestedInputs()
            publishRoutes()
        } catch {
            diagnostics.record("start-failed", category: "route", level: .error)
            if session.probe.requiresCleanup {
                session.state = .failed
                session.notice = cleanupRetryNotice(for: session)
                session.error = String(describing: error)
                session.cleanupCompletion = .remove(preserveAutomaticMode: false)
                scheduleCleanupRetry(for: session.id)
                lastError = "AudioOrbit could not finish restoring normal playback for \(source.name)."
            } else {
                sessions.removeValue(forKey: session.id)
                routeOrder.removeAll { $0 == session.id }
                lastError = String(describing: error)
            }
            chooseSuggestedInputs()
            publishRoutes()
        }
    }

    func stopRoute(_ routeID: UUID, preserveAutomaticMode: Bool = false) async {
        await cleanUpRoute(
            routeID,
            completion: .remove(preserveAutomaticMode: preserveAutomaticMode)
        )
    }

    func retryRouteCleanup(_ routeID: UUID) async {
        guard let session = sessions[routeID],
              let completion = session.cleanupCompletion else { return }
        session.cleanupRetryTask?.cancel()
        session.cleanupRetryTask = nil
        await cleanUpRoute(routeID, completion: completion)
    }

    private func cleanUpRoute(
        _ routeID: UUID,
        completion: CleanupCompletion
    ) async {
        guard let session = sessions[routeID] else { return }
        diagnostics.markRouteTransition()
        diagnostics.record("stop-requested", category: "route")
        session.cleanupCompletion = completion
        session.cleanupRetryTask?.cancel()
        session.cleanupRetryTask = nil
        session.metricsTask?.cancel()
        session.metricsTask = nil
        session.reconnectTask?.cancel()
        session.reconnectTask = nil
        session.state = .stopping
        session.notice = "Restoring normal playback…"
        session.error = nil
        publishRoutes()

        if let switchTask = session.switchTask {
            switchTask.cancel()
            _ = await switchTask.result
            session.switchTask = nil
        }
        guard let currentSession = sessions[routeID],
              currentSession === session else { return }

        do {
            if session.probe.requiresCleanup {
                try session.probe.stop()
            }
        } catch {
            if session.probe.requiresCleanup {
                session.state = .failed
                session.notice = cleanupRetryNotice(for: session)
                session.error = String(describing: error)
                diagnostics.record(
                    "cleanup-retry-required",
                    category: "route",
                    level: .error
                )
                lastError = session.probe.isNormalPlaybackRestored
                    ? "Normal playback is restored for \(session.sourceName), but AudioOrbit is retrying final Core Audio cleanup."
                    : "AudioOrbit could not confirm normal playback for \(session.sourceName). Keep AudioOrbit running while cleanup retries."
                scheduleCleanupRetry(for: routeID)
                updateWatchedDeviceIDs()
                publishRoutes()
                return
            }
            // The muting tap is gone, so pass-through is restored even if an
            // unrelated renderer/HAL cleanup operation reported an error.
            lastError = "Normal playback was restored, but Core Audio reported a cleanup issue: \(error)"
        }

        session.cleanupCompletion = nil
        switch completion {
        case .waitForDestination:
            session.metrics = TapProbeMetrics()
            session.health = AudioRouteHealth()
            session.state = .waitingForDestination
            session.notice = "\(session.destinationName) disconnected. Normal playback is restored while AudioOrbit waits for it to return."
            diagnostics.record("safe-pass-through-ready", category: "route")
            updateWatchedDeviceIDs()
            publishRoutes()
        case .remove(let preserveAutomaticMode):
            await removeCleanedRoute(
                routeID,
                session: session,
                preserveAutomaticMode: preserveAutomaticMode
            )
        }
    }

    private func scheduleCleanupRetry(for routeID: UUID) {
        guard let session = sessions[routeID],
              session.cleanupCompletion != nil else { return }
        session.cleanupRetryTask?.cancel()
        session.cleanupRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cleanupRetryDelay)
            guard !Task.isCancelled, let self,
                  let current = self.sessions[routeID],
                  let completion = current.cleanupCompletion else { return }
            current.cleanupRetryTask = nil
            await self.cleanUpRoute(routeID, completion: completion)
        }
    }

    private func cleanupRetryNotice(for session: RouteSession) -> String {
        session.probe.isNormalPlaybackRestored
            ? "Normal playback is restored. AudioOrbit will retry final Core Audio cleanup."
            : "Normal playback could not be confirmed. AudioOrbit will retry cleanup."
    }

    private func removeCleanedRoute(
        _ routeID: UUID,
        session: RouteSession,
        preserveAutomaticMode: Bool
    ) async {
        let wasAutomaticRoute = session.isAutomatic
        sessions.removeValue(forKey: routeID)
        diagnostics.record("stop-completed", category: "route")
        routeOrder.removeAll { $0 == routeID }
        if wasAutomaticRoute {
            automaticRouteIDs.removeValue(forKey: session.sourcePID)
            if !preserveAutomaticMode, automaticRoutingEnabled {
                automaticRoutingEnabled = false
                automaticRoutingMessage = "Follow Window was turned off and normal playback was restored."
                cancelAutomaticDecisions()
                persistConfiguration()
                await stopAllAutomaticRoutes()
            }
        }
        updateWatchedDeviceIDs()
        chooseSuggestedInputs()
        publishRoutes()
    }

    func switchRoute(
        _ routeID: UUID,
        to destinationDeviceID: AudioObjectID,
        persistDestination: Bool = true
    ) async {
        guard let session = sessions[routeID],
              session.state == .running,
              destinationDeviceID != session.probe.currentDestinationDeviceID,
              let destination = devices.first(where: {
                  $0.id == destinationDeviceID && $0.isAlive
              }) else { return }

        session.state = .switching
        diagnostics.markRouteTransition()
        diagnostics.record("switch-requested", category: "route")
        session.metricsTask?.cancel()
        session.metricsTask = nil
        session.notice = nil
        session.error = nil
        publishRoutes()

        let switchTask = Task {
            try await session.probe.switchDestination(to: destinationDeviceID)
        }
        session.switchTask = switchTask
        defer {
            session.switchTask = nil
        }

        do {
            try await switchTask.value
            guard let currentSession = sessions[routeID],
                  currentSession === session,
                  session.state == .switching else { return }
            session.destinationDeviceID = destination.id
            session.destinationUID = destination.uid
            session.destinationName = destination.name
            session.state = .running
            diagnostics.record("switch-succeeded", category: "route")
            if session.isAutomatic,
               let followedDisplay = session.followedDisplayName,
               followedDisplay != "Headphone Override" {
                postFollowNotification(for: session)
            }
            if persistDestination {
                cacheAutomaticSession(session)
            }
            startMetricsSampling(for: routeID)
        } catch {
            guard let currentSession = sessions[routeID],
                  currentSession === session,
                  session.state == .switching else { return }
            diagnostics.record("switch-failed", category: "route", level: .error)
            session.error = String(describing: error)
            if session.probe.hasActiveRoute {
                session.state = .running
                startMetricsSampling(for: routeID)
            } else {
                session.metrics = TapProbeMetrics()
                session.health = AudioRouteHealth()
                session.notice = "Normal playback was restored for \(session.sourceName)."
                session.state = .failed
                if session.probe.requiresCleanup {
                    session.cleanupCompletion = .remove(
                        preserveAutomaticMode: session.isAutomatic
                    )
                    session.notice = cleanupRetryNotice(for: session)
                    scheduleCleanupRetry(for: routeID)
                }
            }
        }
        updateWatchedDeviceIDs()
        publishRoutes()
    }

    func quit() async {
        diagnostics.record("quit-requested", category: "application")
        hardwareRefreshTask?.cancel()
        cancelAutomaticDecisions()
        for session in sessions.values {
            session.metricsTask?.cancel()
            session.reconnectTask?.cancel()
            session.cleanupRetryTask?.cancel()
            session.state = .stopping
            if let switchTask = session.switchTask {
                switchTask.cancel()
                _ = await switchTask.result
                session.switchTask = nil
            }
        }
        tearDownForTermination()
        NSApplication.shared.terminate(nil)
    }

    /// Synchronous fallback for exit paths that do not run `quit()` (for
    /// example Cmd+Q while the Settings window is key). A destination switch
    /// still suspended at its gain-ramp wait is safe to overlap with this
    /// teardown: the probe revalidates callback-object identity after every
    /// suspension point and aborts the switch instead of touching freed state.
    func applicationWillTerminate() {
        tearDownForTermination()
    }

    private func tearDownForTermination() {
        guard !hasPerformedTerminationCleanup else { return }
        hasPerformedTerminationCleanup = true
        for session in sessions.values {
            try? session.probe.stop()
        }
        sessions.removeAll()
        routeOrder.removeAll()
        windowObservationTask?.cancel()
        windowObservationTask = nil
        deviceMonitor.stop()
        displayMonitor.stop()
        if let applicationActivationObserver {
            NotificationCenter.default.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                spaceChangeObserver
            )
            self.spaceChangeObserver = nil
        }
    }

    private var activeSourcePIDs: Set<pid_t> {
        Set(sessions.values.map(\.sourcePID))
    }

    private var activeDestinationUIDs: Set<String> {
        Set(sessions.values.map(\.destinationUID))
    }

    private var hasControlPlaneTransition: Bool {
        sessions.values.contains {
            $0.state == .starting || $0.state == .switching || $0.state == .stopping
        }
    }

    private func makeSupportReport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development"
        let build = info["CFBundleVersion"] as? String ?? "development"
        return SupportReportBuilder.makeReport(SupportReportInput(
            generatedAt: Date(),
            appVersion: version,
            appBuild: build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appUptimeSeconds: Date().timeIntervalSince(launchDate),
            accessibilityGranted: accessibilityGranted,
            routingEnabled: automaticRoutingEnabled,
            displayCount: displays.count,
            managedDisplayCount: mappings.filter { $0.behavior == .routeToDevice }.count,
            headphoneOverrideArmed: headphoneOverrideEnabled,
            headphoneOverrideActive: activeHeadphoneOverrideDevice != nil,
            devices: devices,
            routes: routes,
            resources: .current(),
            events: diagnostics.snapshot()
        ))
    }

    private func scheduleHardwareFollowUpChecks() {
        hardwareFollowUpTask?.cancel()
        hardwareFollowUpTask = Task { [weak self] in
            // The process-table event fires when the audio connection is
            // established, before output actually starts (launch-then-play).
            // Reconcile quickly in a short series so playback starts are
            // discovered within about a second instead of waiting for the
            // idle poll.
            for followUpDelay in [300, 600, 900, 1500, 2500, 4000] {
                try? await Task.sleep(
                    for: .milliseconds(followUpDelay)
                )
                guard !Task.isCancelled, let self else { return }
                await self.reconcileAudioHardware(
                    clearErrorOnSuccess: false
                )
            }
        }
    }

    private func scheduleHardwareReconciliation() {
        hardwareRefreshTask?.cancel()
        hardwareRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hardwareChangeCoalescingDelay)
            guard !Task.isCancelled, let self else { return }
            await self.reconcileAudioHardware(clearErrorOnSuccess: false)
        }
    }

    private func reconcileAudioHardware(clearErrorOnSuccess: Bool) async {
        do {
            let hadConnectedHeadphoneOverride = automaticRoutingEnabled
                && headphoneOverrideEnabled
                && headphoneOverrideDeviceUID.flatMap { selectedUID in
                    devices.first { $0.uid == selectedUID && $0.isAlive }
                } != nil
            let snapshot = try discovery.snapshot()
            apply(snapshot)
            let didDisconnectHeadphoneOverride = hadConnectedHeadphoneOverride
                && activeHeadphoneOverrideDevice == nil
            if clearErrorOnSuccess {
                lastError = nil
            }

            if didDisconnectHeadphoneOverride {
                diagnostics.record(
                    "headphone-override-disconnected",
                    category: "hardware",
                    level: .warning
                )
                await relinquishDisconnectedHeadphoneOverride()
            }

            for routeID in routeOrder {
                guard let session = sessions[routeID] else { continue }
                let knownDestination = devices.first { $0.uid == session.destinationUID }
                let intendedDestination = knownDestination.flatMap { $0.isAlive ? $0 : nil }
                session.destinationDeviceID = knownDestination?.id

                let recoveryAction = RouteHardwareRecoveryPolicy.action(
                    state: session.state,
                    destinationIsAlive: intendedDestination != nil,
                    destinationMatchesRenderer: intendedDestination?.id
                        == session.probe.currentDestinationDeviceID
                )
                switch recoveryAction {
                case .none:
                    break
                case .enterSafePassThrough:
                    await enterSafeRecovery(for: routeID)
                case .beginReconnectDwell:
                    beginReconnectDwell(for: routeID)
                case .cancelReconnectAndWait:
                    session.reconnectTask?.cancel()
                    session.reconnectTask = nil
                    session.state = .waitingForDestination
                    session.notice = "\(session.destinationName) disappeared again. Normal playback remains restored."
                }
            }
            updateWatchedDeviceIDs()
            publishRoutes()
            if automaticRoutingEnabled {
                // The per-decision delay logic already distinguishes
                // event-backed commits, eventless dwells, and route-less
                // immediate starts; a blanket reconnect dwell here only
                // delayed the first route by a second after playback
                // detection.
                await refreshAutomaticWindowEvidence(
                    forceImmediate: didDisconnectHeadphoneOverride
                )
            }
        } catch {
            diagnostics.record("refresh-failed", category: "hardware", level: .error)
            if clearErrorOnSuccess {
                lastError = String(describing: error)
            }
        }
    }

    private func relinquishDisconnectedHeadphoneOverride() async {
        let overrideRouteIDs = routeOrder.filter { routeID in
            guard let session = sessions[routeID] else { return false }
            return session.isAutomatic
                && session.followedDisplayName == "Headphone Override"
        }
        let overrideBundles = Set(overrideRouteIDs.compactMap {
            sessions[$0]?.applicationBundleIdentifier
        })
        for routeID in overrideRouteIDs {
            await stopRoute(routeID, preserveAutomaticMode: true)
        }
        cachedApplicationRoutes.removeAll {
            overrideBundles.contains($0.applicationBundleIdentifier)
                && $0.lastDisplayName == "Headphone Override"
        }
        persistConfiguration()
        automaticRoutingMessage = "Restoring display audio outputs."
        publishRoutes()
    }

    private func apply(_ snapshot: AudioDiscoverySnapshot) {
        let selectedDeviceUID = devices.first(where: { $0.id == selectedDeviceID })?.uid
        let selectedProcessPID = processes.first(where: { $0.id == selectedProcessID })?.pid

        devices = snapshot.devices
        processes = snapshot.processes.filter {
            $0.pid != ProcessInfo.processInfo.processIdentifier
        }

        if let selectedProcessPID,
           !activeSourcePIDs.contains(selectedProcessPID) {
            selectedProcessID = processes.first(where: { $0.pid == selectedProcessPID })?.id
        } else {
            selectedProcessID = ConcurrentRouteAdmission.suggestedProcessID(
                processes: processes,
                activeSourcePIDs: activeSourcePIDs
            )
        }

        if let selectedDeviceUID,
           let selected = devices.first(where: { $0.uid == selectedDeviceUID && $0.isAlive }) {
            selectedDeviceID = selected.id
        } else {
            selectedDeviceID = ConcurrentRouteAdmission.suggestedDeviceID(
                devices: devices,
                activeDestinationUIDs: activeDestinationUIDs
            )
        }
    }

    private func chooseSuggestedInputs() {
        selectedProcessID = ConcurrentRouteAdmission.suggestedProcessID(
            processes: processes,
            activeSourcePIDs: activeSourcePIDs
        )
        selectedDeviceID = ConcurrentRouteAdmission.suggestedDeviceID(
            devices: devices,
            activeDestinationUIDs: activeDestinationUIDs
        )
    }

    private func mappingRow(
        for mapping: DisplayAudioMapping,
        display: DisplaySnapshot?
    ) -> DisplayMappingRow {
        let selection: DisplayMappingSelection
        switch mapping.behavior {
        case .passThrough:
            selection = .passThrough
        case .routeToDevice:
            selection = mapping.audioDeviceUID.map(DisplayMappingSelection.device(uid:))
                ?? .passThrough
        }
        let mappedDevice = mapping.audioDeviceUID.flatMap { uid in
            devices.first { $0.uid == uid }
        }
        let unavailableName = mapping.behavior == .routeToDevice && mappedDevice?.isAlive != true
            ? (mapping.audioDeviceNameHint ?? "Previously selected output")
            : nil

        return DisplayMappingRow(
            displayUUID: mapping.displayUUID,
            displayName: display?.name ?? mapping.displayNameHint,
            isDisplayConnected: display != nil,
            isBuiltIn: display?.isBuiltIn ?? false,
            selection: selection,
            unavailableDeviceName: unavailableName
        )
    }

    private func synchronizeMappingsWithConnectedHardware() {
        var updatedMappings = mappings
        for display in displays {
            if let index = updatedMappings.firstIndex(where: { $0.displayUUID == display.id }) {
                updatedMappings[index].displayNameHint = display.name
                if let uid = updatedMappings[index].audioDeviceUID,
                   let device = devices.first(where: { $0.uid == uid }) {
                    updatedMappings[index].audioDeviceNameHint = device.name
                }
            } else {
                updatedMappings.append(.passThrough(display: display))
            }
        }
        updatedMappings.sort {
            if $0.displayNameHint != $1.displayNameHint {
                return $0.displayNameHint.localizedStandardCompare($1.displayNameHint) == .orderedAscending
            }
            return $0.displayUUID.uuidString < $1.displayUUID.uuidString
        }
        guard updatedMappings != mappings else { return }
        mappings = updatedMappings
        persistConfiguration()
    }

    private func persistConfiguration() {
        do {
            try mappingStore.save(PersistedConfiguration(
                schemaVersion: PersistedConfiguration.currentSchemaVersion,
                mappings: mappings,
                routingEnabled: automaticRoutingEnabled,
                cachedRoutes: cachedApplicationRoutes,
                ignoredApplications: ignoredApplications,
                headphoneOverrideEnabled: headphoneOverrideEnabled,
                headphoneOverrideDeviceUID: headphoneOverrideDeviceUID
            ))
        } catch {
            lastError = "AudioOrbit could not save the display mappings: \(error)"
        }
    }

    private func refreshAutomaticWindowEvidence(
        forceImmediate: Bool = false
    ) async {
        guard automaticRoutingEnabled else { return }
        if automaticEvidenceRefreshInProgress {
            automaticEvidenceRefreshPending = true
            automaticEvidenceRefreshPendingForce =
                automaticEvidenceRefreshPendingForce || forceImmediate
            // The in-flight AX batch predates this request and must not be
            // applied before the coalesced follow-up refresh.
            automaticEvidenceRefreshGeneration += 1
            return
        }

        automaticEvidenceRefreshInProgress = true
        var nextForce = forceImmediate
        repeat {
            automaticEvidenceRefreshPending = false
            automaticEvidenceRefreshPendingForce = false
            await performAutomaticWindowEvidenceRefresh(
                forceImmediate: nextForce
            )
            nextForce = automaticEvidenceRefreshPendingForce
        } while automaticRoutingEnabled && automaticEvidenceRefreshPending
        automaticEvidenceRefreshInProgress = false
    }

    private func performAutomaticWindowEvidenceRefresh(
        forceImmediate: Bool
    ) async {
        guard automaticRoutingEnabled else { return }
        automaticEvidenceRefreshGeneration += 1
        let refreshGeneration = automaticEvidenceRefreshGeneration
        let currentlyPlayingPIDs = Set(processes.filter(\.isRunningOutput).map(\.pid))
        if !currentlyPlayingPIDs.isSubset(of: lastSeenPlayingPIDs) {
            diagnostics.record("playing-detected", category: "route")
        }
        lastSeenPlayingPIDs = currentlyPlayingPIDs
        suppressedAutomaticSourcePIDs.formIntersection(currentlyPlayingPIDs)
        reportedUnassociatedSourcePIDs.formIntersection(currentlyPlayingPIDs)
        reportedSessionEvidenceIssuePIDs.formIntersection(currentlyPlayingPIDs)
        let currentPIDs = Set(processes.map(\.pid))
        var windowOwnerPIDs: Set<pid_t> = []
        let sourceAssociations: [(
            source: AudioProcessSnapshot,
            association: ProcessWindowAssociation?
        )] = processes.compactMap { source in
            let isRelevant = (source.isRunningOutput
                && !suppressedAutomaticSourcePIDs.contains(source.pid))
                || automaticRouteIDs[source.pid] != nil
            guard isRelevant else { return nil }
            let association = processWindowResolver.resolve(source)
                ?? automaticTracking[source.pid]?.association.map {
                    ProcessWindowAssociation(
                        audioProcess: source,
                        windowOwner: $0.windowOwner,
                        reason: $0.reason
                    )
                }
            guard AutomaticRouteEligibilityPolicy.shouldManage(
                source: source,
                association: association,
                ignoredBundleIdentifiers: ignoredBundleIdentifiers
            ) else { return nil }
            if let ownerPID = association?.windowOwner.pid {
                windowOwnerPIDs.insert(ownerPID)
            }
            return (source, association)
        }
        let sources = sourceAssociations.map(\.source)
        windowEventMonitor.setTrackedApplicationPIDs(windowOwnerPIDs)
        let trackedPIDs = Set(automaticTracking.keys).union(automaticRouteIDs.keys)
        let vanishedPIDs = trackedPIDs.filter { !currentPIDs.contains($0) }
        for pid in vanishedPIDs {
            // One grace coordinator owns the detached state for this PID.
            // Later refreshes must not race it with a nil-state migration.
            guard vanishedSourceGraceTasks[pid] == nil else { continue }
            automaticTracking[pid]?.decisionTask?.cancel()
            let trackedState = automaticTracking.removeValue(forKey: pid)
            guard automaticRouteIDs[pid] != nil else { continue }
            // Safari restarts its media helper during fullscreen
            // transitions: the old process dies moments before the
            // replacement appears, so stopping immediately produced an
            // audible stop/start loop. Migrate at once when a replacement
            // already exists; otherwise keep the route and retry for a
            // few seconds before giving up.
            if let replacement = replacementSource(
                forVanishedPID: pid,
                anchoredRendererPID: trackedState?.anchoredWebViewProcessID
            ) {
                await migrateAutomaticRoute(
                    fromPID: pid,
                    to: replacement,
                    state: trackedState
                )
            } else {
                scheduleVanishedSourceGrace(
                    for: pid,
                    state: trackedState
                )
            }
        }

        // A playback-session boundary releases the window anchor. Require
        // two consecutive silent ticks before honoring the stopped→running
        // transition so brief buffering or tab-switch blips cannot re-pin the
        // anchor to whatever window is focused at the time of the blip.
        for source in processes {
            guard let state = automaticTracking[source.pid] else { continue }
            if source.isRunningOutput {
                if WindowRouteAffinityPolicy.beginsNewPlaybackSession(
                    wasRunningOutput: state.wasRunningOutput,
                    isRunningOutput: true,
                    silenceTicks: state.silentTickCount,
                    requiredSilenceTicks: Self.playbackSessionSilenceTicks
                ),
                    // A brand-new source has no session to release; the
                    // ceremony would only delay its first route by several
                    // ticks (launch-then-play sources sit through it twice).
                    state.committedDisplayUUID != nil
                        || state.committedWindowIdentifier != nil {
                    // Defer the anchor release until this tick's evidence
                    // is available: a pause/resume of the same tab keeps
                    // its renderer in the anchor window and must NOT count
                    // as a new playback session.
                    state.pendingSessionRelease = true
                }
                state.silentTickCount = 0
            } else {
                state.silentTickCount += 1
            }
            state.wasRunningOutput = source.isRunningOutput
        }

        if let overrideDevice = activeHeadphoneOverrideDevice {
            await applyHeadphoneOverride(to: sources, destination: overrideDevice)
            updateAutomaticRoutingSummary()
            return
        }

        // Resolve associations and tracking state on the main actor, then
        // compute window evidence concurrently. A single unresponsive target
        // application can otherwise stall the evidence for every other source
        // because Accessibility queries block until their messaging timeout.
        let currentDisplays = displays
        var sourceCountByOwnerPID: [pid_t: Int] = [:]
        for request in sourceAssociations {
            if let ownerPID = request.association?.windowOwner.pid {
                sourceCountByOwnerPID[ownerPID, default: 0] += 1
            }
        }
        let evidenceRequests: [(
            AudioProcessSnapshot,
            ProcessWindowAssociation?,
            UUID?,
            String?,
            pid_t?,
            Bool
        )] = sourceAssociations.map { request in
                let source = request.source
                let association = request.association
                if association == nil,
                   source.isRunningOutput,
                   !reportedUnassociatedSourcePIDs.contains(source.pid) {
                    reportedUnassociatedSourcePIDs.insert(source.pid)
                    diagnostics.record(
                        "playing-source-unassociated",
                        category: "routing",
                        level: .warning
                    )
                }
                let committedDisplayUUID = automaticTracking[source.pid]?.committedDisplayUUID
                // The display follows the window the video plays in: the
                // renderer-PID-tracked anchor window. Dragging that window
                // moves its frame and the route follows; the fullscreen
                // presentation still wins over it during fullscreen.
                let preferredWindowIdentifier: String?
                if let state = automaticTracking[source.pid],
                   let association,
                   WindowRouteAffinityPolicy.pinsInitialWindow(
                       for: association.reason
                   ) {
                    preferredWindowIdentifier = state.committedWindowIdentifier
                } else {
                    preferredWindowIdentifier = nil
                }
                let preferredRendererPID = WindowRouteAffinityPolicy
                    .preferredRendererPID(
                        anchoredRendererPID: automaticTracking[source.pid]?
                            .anchoredWebViewProcessID,
                        sourcePID: source.pid,
                        sourceBundleIdentifier: source.bundleIdentifier
                    )
                let allowsUnverifiedFullscreenPresentation = association.map {
                    sourceCountByOwnerPID[$0.windowOwner.pid] == 1
                } ?? false
                return (
                    source,
                    association,
                    committedDisplayUUID,
                    preferredWindowIdentifier,
                    preferredRendererPID,
                    allowsUnverifiedFullscreenPresentation
                )
            }
        var evidenceResults: [(
            AudioProcessSnapshot,
            ProcessWindowAssociation?,
            WindowDisplayEvidence?
        )] = []
        await withTaskGroup(
            of: (
                AudioProcessSnapshot,
                ProcessWindowAssociation?,
                WindowDisplayEvidence?
            ).self
        ) { group in
            for (source, association, committedDisplayUUID, preferredWindowIdentifier, preferredRendererPID, allowsUnverifiedFullscreenPresentation)
                in evidenceRequests {
                let cachedEvidence: WindowDisplayEvidence?
                if let association {
                    if let cached = precomputedEvidenceByOwnerPID[
                        association.windowOwner.pid
                    ], ContinuousClock.now - cached.at < .seconds(2),
                       WindowRouteAffinityPolicy.canReusePrecomputedEvidence(
                           sourcePID: source.pid,
                           associationReason: association.reason,
                           cachedSourcePID: cached.evidence.sourcePID,
                           cachedAssociationReason: cached.evidence.associationReason,
                           committedDisplayUUID: committedDisplayUUID,
                           preferredWindowIdentifier: preferredWindowIdentifier,
                           preferredRendererPID: preferredRendererPID
                       ) {
                        cachedEvidence = cached.evidence
                    } else {
                        cachedEvidence = nil
                    }
                } else {
                    cachedEvidence = nil
                }
                group.addTask(priority: .utility) {
                    guard let association else { return (source, nil, nil) }
                    if let cachedEvidence {
                        return (source, association, cachedEvidence)
                    }
                    let evidence = AccessibilityWindowDiscovery().evidence(
                        for: source,
                        windowOwner: association.windowOwner,
                        associationReason: association.reason,
                        displays: currentDisplays,
                        committedDisplayUUID: committedDisplayUUID,
                        preferredWindowIdentifier: preferredWindowIdentifier,
                        preferredRendererPID: preferredRendererPID,
                        allowsUnverifiedFullscreenPresentation:
                            allowsUnverifiedFullscreenPresentation
                    )
                    return (source, association, evidence)
                }
            }
            for await result in group {
                evidenceResults.append(result)
            }
        }
        // AppModel is re-entrant while the task group awaits AX. Never let a
        // completed older batch overwrite the state produced by a newer event.
        guard refreshGeneration == automaticEvidenceRefreshGeneration else {
            return
        }
        for (source, association, evidence) in evidenceResults {
                if evidence?.issue != nil,
                   source.isRunningOutput,
                    automaticRouteIDs[source.pid] != nil
                       || automaticTracking[source.pid]?.wasRunningOutput == true,
                   !reportedSessionEvidenceIssuePIDs.contains(source.pid) {
                    reportedSessionEvidenceIssuePIDs.insert(source.pid)
                    diagnostics.record(
                        "session-evidence-issue",
                        category: "routing",
                        level: .warning
                    )
                }
                scheduleAutomaticRouteDecision(
                    for: source,
                    association: association,
                    evidence: evidence,
                    force: forceImmediate
                )
        }

        updateAutomaticRoutingSummary()
    }

    private func applyHeadphoneOverride(
        to sources: [AudioProcessSnapshot],
        destination: AudioDeviceSnapshot
    ) async {
        for source in sources {
            let association = processWindowResolver.resolve(source)
            let displayedName = association?.windowOwner.name ?? source.name
            let bundleIdentifier = association?.windowOwner.bundleIdentifier
                ?? source.bundleIdentifier

            if let routeID = automaticRouteIDs[source.pid],
               let session = sessions[routeID] {
                switch RouteLifecyclePolicy.reconciliationAction(
                    for: session.state,
                    requiresCleanupRetry: session.cleanupCompletion != nil
                ) {
                case .retryAfterTransition:
                    continue
                case .replaceRoute:
                    await stopRoute(routeID, preserveAutomaticMode: true)
                case .useRunningRoute:
                    if session.destinationUID != destination.uid {
                        await switchRoute(
                            routeID,
                            to: destination.id,
                            persistDestination: false
                        )
                    }
                    guard session.state == .running else { continue }
                    session.followedDisplayUUID = nil
                    session.followedDisplayName = "Headphone Override"
                    session.notice = "Headphone Override is active."
                    publishRoutes()
                    continue
                }
            }

            guard source.isRunningOutput,
                  !activeSourcePIDs.contains(source.pid),
                  !isAddingRoute,
                  !hasControlPlaneTransition else { continue }
            await startAutomaticRoute(
                source: source,
                displayedSourceName: displayedName,
                applicationBundleIdentifier: bundleIdentifier,
                displayUUID: nil,
                displayName: "Headphone Override",
                destination: destination
            )
        }
    }

    /// Refreshes the window→display mapping for a small set of relevant
    /// applications that are not currently playing: the frontmost app,
    /// apps with remembered routes, and previously tracked owners. Runs
    /// at a slow cadence (every fourth evidence pass) and is nudged by
    /// AX and activation events, so moves stay current without a
    /// high-frequency poll.
    private func precomputeWindowMappings() async {
        let wasNudgedByEvent = precomputeTickCounter >= 3
        precomputeTickCounter += 1
        guard precomputeTickCounter >= 4 else { return }
        guard wasNudgedByEvent
                || Date().timeIntervalSince(lastPrecomputeDate)
                    >= Self.precomputeInterval else { return }
        precomputeTickCounter = 0
        lastPrecomputeDate = Date()

        var ownerPIDs: Set<pid_t> = []
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier {
            ownerPIDs.insert(frontmostPID)
        }
        for cached in cachedApplicationRoutes {
            if let owner = processes.first(where: {
                $0.bundleIdentifier == cached.applicationBundleIdentifier
            }) {
                ownerPIDs.insert(owner.pid)
            }
        }
        for pid in automaticTracking.keys where
            !automaticRouteIDs.keys.contains(pid) {
            ownerPIDs.insert(pid)
        }

        var stalePIDs: [pid_t] = []
        for (pid, entry) in precomputedEvidenceByOwnerPID where
            !processes.contains(where: { $0.pid == pid })
                || ContinuousClock.now - entry.at > .seconds(30) {
            stalePIDs.append(pid)
        }
        for pid in stalePIDs {
            precomputedEvidenceByOwnerPID.removeValue(forKey: pid)
        }

        let routedOwnerPIDValues: [pid_t] = automaticRouteIDs.keys.compactMap {
            sourcePID -> pid_t? in
            guard let source = processes.first(where: { $0.pid == sourcePID }) else {
                return nil
            }
            return processWindowResolver.resolve(source)?.windowOwner.pid
        }
        let routedOwnerPIDs = Set(routedOwnerPIDValues)
        for pid in ownerPIDs {
            guard !routedOwnerPIDs.contains(pid),
                  let source = processes.first(where: { $0.pid == pid }),
                  !source.isRunningOutput else { continue }
            let association = processWindowResolver.resolve(source)
            guard let association, association.reason == .sameProcess else {
                continue
            }
            let evidence = AccessibilityWindowDiscovery().evidence(
                for: source,
                windowOwner: association.windowOwner,
                associationReason: association.reason,
                displays: displays,
                committedDisplayUUID: nil,
                preferredWindowIdentifier: nil
            )
            if evidence.displayUUID != nil {
                precomputedEvidenceByOwnerPID[pid] = (evidence, .now)
            }
        }
    }

    private func scheduleAutomaticRouteDecision(
        for source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?,
        evidence: WindowDisplayEvidence?,
        force: Bool
    ) {
        guard automaticRoutingEnabled else { return }
        let state = automaticTracking[source.pid] ?? AutomaticTrackingState()
        automaticTracking[source.pid] = state
        var effectiveForce = force
        // The very first route for a directly associated process takes over
        // immediately: focus-based selection is trustworthy for regular
        // applications, and skipping the display dwell removes a visible
        // delay between playback start and audio handoff. Helper processes
        // still commit through the anchor adoption, which already forces an
        // immediate decision.
        if state.committedDisplayUUID == nil,
           association?.reason == .sameProcess,
           evidence?.displayUUID != nil {
            effectiveForce = true
        }
        state.wasRunningOutput = source.isRunningOutput
        state.association = association
        state.evidence = evidence
        if let association,
           let evidence {
            // The anchor is the pair (renderer PID, current reporter
            // window). Both are managed by the sticky-PID adoption below;
            // nothing else in the decision path may write them.
            let pidMap = evidence.webViewProcessIDsByWindow
            if state.pendingSessionRelease {
                state.pendingSessionRelease = false
                // The playing identity is the RENDERER PID, not the window:
                // a stop→start transition (helper restart, fullscreen churn)
                // does not release it. A single-tick check is too fragile —
                // the churn's transient report gaps would false-release. The
                // long-gap release below handles genuinely closed tabs.
                diagnostics.record(
                    "playback-session-kept",
                    category: "routing"
                )
            }
            // Long-gap release: only a renderer that stays unreported for a
            // stable wall-clock duration is genuinely gone. AX event bursts
            // cannot accelerate this timeout during churn.
            if let anchoredPID = state.anchoredWebViewProcessID {
                if pidMap.values.contains(anchoredPID) {
                    state.anchoredPIDLastReportedAt = .now
                } else if let lastReportedAt = state.anchoredPIDLastReportedAt,
                          ContinuousClock.now - lastReportedAt
                            >= Self.anchorLongGapRelease {
                    state.anchoredWebViewProcessID = nil
                    state.anchoredPIDLastReportedAt = nil
                    state.committedWindowIdentifier = nil
                    state.manualAnchorOverride = false
                    diagnostics.record(
                        "playback-anchor-released",
                        category: "routing"
                    )
                }
            }
            let targetID: String?
            if state.manualAnchorOverride {
                // The user pinned this window manually; automatic
                // following stays suppressed until the playback session
                // restarts or the pinned window disappears.
                targetID = nil
            } else if WindowRouteAffinityPolicy.pinsInitialWindow(
                for: association.reason
            ), source.isRunningOutput {
                // The anchor is the pair (renderer PID, current reporter).
                // The PID is STICKY: it is seeded once and released only by
                // the long-gap rule. The window re-pins on each refresh to
                // whichever window reports the PID — tear-offs follow, and
                // the churn's transient windows merely flip the display
                // candidate, which the route-side debounce absorbs.
                let anchorID = state.committedWindowIdentifier
                if let anchoredPID = state.anchoredWebViewProcessID,
                   let reporter = WindowRouteAffinityPolicy
                       .reporterWindowIdentifier(
                           rendererPID: anchoredPID,
                           currentWindowIdentifier: anchorID,
                           webViewProcessIDsByWindow: pidMap
                       ) {
                    targetID = reporter != anchorID ? reporter : nil
                } else if anchorID == nil {
                    // First adoption: seed from the selected window's
                    // renderer (the window the user sees at playback
                    // start). A window without a renderer cannot anchor;
                    // the next tick retries.
                    if let selectedID = evidence.selectedWindowIdentifier,
                       pidMap[selectedID] != nil {
                        targetID = selectedID
                    } else {
                        targetID = nil
                    }
                } else {
                    targetID = nil
                }
            } else {
                targetID = nil
            }
            if source.isRunningOutput,
               let targetID,
               targetID != state.committedWindowIdentifier {
                // Adoption updates the anchor only: the display commit
                // flows through the route-side debounce queue like every
                // other change, so churn-time adoptions cannot bypass it.
                state.committedWindowIdentifier = targetID
                if state.anchoredWebViewProcessID == nil {
                    // The PID is sticky — never replaced by the window's
                    // own renderer once seeded.
                    if let rendererPID = pidMap[targetID] {
                        state.anchoredWebViewProcessID = rendererPID
                        state.anchoredPIDLastReportedAt = .now
                    }
                }
                diagnostics.record(
                    "playback-anchor-followed-media-window",
                    category: "routing"
                )
            }
        }
        // The fullscreen surface drives the display by design. It does not
        // have to win window selection: while the anchor is gone (its window
        // was destroyed by Safari's fullscreen churn) one unambiguous,
        // near-fullscreen surface may take over the display — Safari keeps
        // the hidden desktop window focused, so focus-based selection alone
        // would keep the route pinned to the pre-fullscreen display.
        let surfaceIdentifiers = Set(evidence?.surfaceOnlyWindowIdentifiers ?? [])
        let anchorGone = state.committedWindowIdentifier.map { anchorID in
            !(evidence?.candidateWindowIdentifiers.contains(anchorID) ?? false)
        } ?? true
        var candidateDisplayUUID = evidence?.displayUUID
        let surfaceTakeover = anchorGone
            && !surfaceIdentifiers.isEmpty
        if surfaceTakeover,
           let surfaceDisplay = surfaceDisplayUUID(
               for: surfaceIdentifiers,
               evidence: evidence
           ) {
            candidateDisplayUUID = surfaceDisplay
        }
        if candidateDisplayUUID == nil,
           let routeID = automaticRouteIDs[source.pid],
           let session = sessions[routeID] {
            // No candidate evidence: keep the established route in EVERY
            // session state (switching, reconnecting, running alike). A
            // route ends only when its source process ends. Re-sync the
            // tracking display in case the route was started by the
            // takeover path, which commits without scheduling a decision.
            if state.committedDisplayUUID == nil,
               let followed = session.followedDisplayUUID,
               displays.contains(where: { $0.id == followed }) {
                state.committedDisplayUUID = followed
            }
            state.hasCandidate = false
            state.decisionTask?.cancel()
            state.decisionTask = nil
            let notice = "The window is transitioning or fullscreen. Keeping the last output."
            if session.notice != notice {
                session.notice = notice
                publishRoutes()
            }
            return
        }

        if let displayUUID = candidateDisplayUUID,
           let windowFrame = evidence?.windowFrame,
           !DisplayTransitionPolicy.shouldCommit(
               candidateDisplayUUID: displayUUID,
               committedDisplayUUID: state.committedDisplayUUID,
               windowFrame: windowFrame,
               displays: displays
           ) {
            state.hasCandidate = false
            state.decisionTask?.cancel()
            state.decisionTask = nil
            return
        }
        let candidateChanged = state.candidateDisplayUUID != candidateDisplayUUID
        if !effectiveForce, !candidateChanged,
           let retryNotBefore = state.candidateRetryNotBefore,
           ContinuousClock.now < retryNotBefore {
            return
        }
        if effectiveForce || candidateChanged {
            state.candidateRetryNotBefore = nil
        } else if state.candidateRetryNotBefore != nil {
            state.candidateRetryNotBefore = nil
            state.switchRetryCount = 0
        }
        guard effectiveForce || !state.hasCandidate || candidateChanged else {
            return
        }
        if effectiveForce || candidateChanged {
            state.switchRetryCount = 0
        }
        // A retry belongs to one queued candidate. A later candidate (or an
        // explicit forced re-evaluation) gets its own retry allowance.
        state.commitRetryAttempted = false
        state.hasCandidate = true
        state.candidateDisplayUUID = candidateDisplayUUID
        state.decisionTask?.cancel()
        // Route-side debounce queue: every candidate restarts the timer,
        // and the actual switch fires only once the target display has
        // held steady for the debounce interval. Rapid A-B-A-B
        // alternation is absorbed here, at the sink, instead of being
        // gated upstream — upstream lets every event through.
        let delay = (effectiveForce
            || automaticRouteIDs[source.pid] == nil)
            ? Duration.zero
            : Self.routeSwitchDebounce
        state.decisionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.commitAutomaticRoute(
                sourcePID: source.pid,
                candidateDisplayUUID: candidateDisplayUUID
            )
        }
    }

    private func commitAutomaticRoute(
        sourcePID: pid_t,
        candidateDisplayUUID: UUID?
    ) async {
        guard automaticRoutingEnabled,
              let state = automaticTracking[sourcePID],
              state.hasCandidate,
              state.candidateDisplayUUID == candidateDisplayUUID else { return }
        guard let displayUUID = candidateDisplayUUID,
              let display = displays.first(where: { $0.id == displayUUID }) else {
            // A nil candidate NEVER stops a route. Transitional evidence
            // gaps (fullscreen churn, Mission Control) must leave
            // established routes alone; vanished sources are handled
            // exclusively by the vanish-grace machinery. (The explicit
            // pass-through branch below is the one intentional exception:
            // it honors a user-mapped terminal destination.)
            state.hasCandidate = false
            return
        }
        let mapping = mappings.first { $0.displayUUID == displayUUID }
        if mapping?.behavior != .routeToDevice {
            // A connected display with no routed mapping is an explicit
            // pass-through destination, not a transient evidence gap. Tear
            // down any existing tap so macOS resumes normal playback.
            state.commitRetryAttempted = false
            state.candidateRetryNotBefore = nil
            state.committedDisplayUUID = displayUUID
            if automaticRouteIDs[sourcePID] != nil {
                await stopAutomaticRoute(for: sourcePID)
            }
            updateAutomaticRoutingSummary()
            return
        }
        guard let source = processes.first(where: { $0.pid == sourcePID }),
              let target = AutomaticRouteTargetPolicy.resolve(
                  source: source,
                  association: state.association,
                  evidence: state.evidence,
                  displayUUID: displayUUID,
                  displays: displays,
                  mappings: mappings,
                  devices: devices
              ),
              let destination = devices.first(where: {
                  $0.uid == target.destinationDeviceUID && $0.isAlive
              }),
              let association = state.association else {
            // Target resolution can fail transiently (the media helper is
            // mid-swap, the association is briefly nil, the destination is
            // reconnecting). A transient failure must not stop a route or
            // drop the commit: after a drag ends no more
            // moved events arrive, so a dropped candidate would leave the
            // drag permanently unfollowed. Retry once shortly.
            if !state.commitRetryAttempted {
                state.commitRetryAttempted = true
                state.decisionTask?.cancel()
                state.decisionTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    guard let retryState = self.automaticTracking[sourcePID],
                          retryState.hasCandidate,
                          retryState.candidateDisplayUUID == displayUUID else {
                        return
                    }
                    await self.commitAutomaticRoute(
                        sourcePID: sourcePID,
                        candidateDisplayUUID: displayUUID
                    )
                }
            } else {
                // Do not permanently strand a stable candidate after a
                // transient association/device failure. Pause periodic
                // retries briefly, then allow the same evidence to retry.
                state.commitRetryAttempted = false
                state.hasCandidate = false
                state.candidateRetryNotBefore = ContinuousClock.now
                    + Self.failedCandidateRetryCooldown
                state.decisionTask = nil
            }
            return
        }
        state.commitRetryAttempted = false
        state.candidateRetryNotBefore = nil
        state.committedDisplayUUID = displayUUID
        if let routeID = automaticRouteIDs[sourcePID],
           let session = sessions[routeID] {
            switch RouteLifecyclePolicy.reconciliationAction(
                for: session.state,
                requiresCleanupRetry: session.cleanupCompletion != nil
            ) {
            case .retryAfterTransition:
                state.hasCandidate = false
                scheduleAutomaticRouteDecision(
                    for: source,
                    association: association,
                    evidence: state.evidence,
                    force: true
                )
                return
            case .replaceRoute:
                await stopRoute(routeID, preserveAutomaticMode: true)
            case .useRunningRoute where session.destinationUID != destination.uid:
                await switchRoute(routeID, to: destination.id)
                if session.destinationUID == destination.uid {
                    state.switchRetryCount = 0
                    session.followedDisplayUUID = display.id
                    session.followedDisplayName = display.name
                    session.notice = "Followed the window to \(display.name)."
                    cacheAutomaticSession(session)
                } else {
                    state.committedDisplayUUID = session.followedDisplayUUID
                    if session.state == .running,
                       let retryNumber = RouteLifecyclePolicy
                           .nextSwitchRetryNumber(
                               after: state.switchRetryCount
                           ) {
                        state.switchRetryCount = retryNumber
                        state.hasCandidate = true
                        state.candidateDisplayUUID = displayUUID
                        state.decisionTask?.cancel()
                        state.decisionTask = Task { [weak self] in
                            try? await Task.sleep(
                                for: .seconds(retryNumber)
                            )
                            guard !Task.isCancelled, let self else { return }
                            await self.commitAutomaticRoute(
                                sourcePID: sourcePID,
                                candidateDisplayUUID: displayUUID
                            )
                        }
                    } else if session.state == .running {
                        // Cool down instead of suppressing this candidate
                        // forever. The same stable target may recover after a
                        // transient Core Audio failure without another move.
                        state.hasCandidate = false
                        state.candidateRetryNotBefore = ContinuousClock.now
                            + Self.failedCandidateRetryCooldown
                        state.decisionTask = nil
                    } else {
                        state.hasCandidate = false
                        state.decisionTask = nil
                    }
                }
                publishRoutes()
                updateAutomaticRoutingSummary()
                return
            case .useRunningRoute:
                session.followedDisplayUUID = display.id
                session.followedDisplayName = display.name
                session.notice = "Following \(display.name)."
                cacheAutomaticSession(session)
                publishRoutes()
                updateAutomaticRoutingSummary()
                return
            }
        }

        if activeSourcePIDs.contains(sourcePID) {
            return
        }
        if isAddingRoute || hasControlPlaneTransition {
            state.hasCandidate = false
            scheduleAutomaticRouteDecision(
                for: source,
                association: association,
                evidence: windowEvidenceForRetry(source: source, display: display),
                force: true
            )
            return
        }

        diagnostics.record("takeover-committed", category: "route")
        // The takeover commits this display: record it in the tracking
        // state so a later nil-candidate tick (broken evidence during
        // window churn) keeps the route instead of stopping it.
        state.committedDisplayUUID = display.id
        await startAutomaticRoute(
            source: source,
            displayedSourceName: association.windowOwner.name,
            applicationBundleIdentifier: association.windowOwner.bundleIdentifier
                ?? source.bundleIdentifier,
            displayUUID: display.id,
            displayName: display.name,
            destination: destination
        )
    }

    /// Resolves a pure-surface takeover only when all qualifying fullscreen
    /// surfaces point to one display. Multiple displays are ambiguous (for
    /// example two Safari presentations) and must retain the existing route.
    private func surfaceDisplayUUID(
        for identifiers: Set<String>,
        evidence: WindowDisplayEvidence?
    ) -> UUID? {
        guard let evidence else { return nil }
        let resolvedDisplayIDs: [UUID] = identifiers.compactMap { identifier in
            guard let frame = evidence.candidateWindowFrames[identifier],
                  WindowDisplayPolicy.isLikelyFullscreenSurface(
                      frame,
                      displays: displays
                  ) else { return nil }
            return WindowDisplayPolicy.resolveDisplay(
                for: frame,
                displays: displays
            )?.id
        }
        let resolvedDisplays = Set(resolvedDisplayIDs)
        guard resolvedDisplays.count == 1 else { return nil }
        return resolvedDisplays.first
    }

    private func startAutomaticRoute(
        source: AudioProcessSnapshot,
        displayedSourceName: String,
        applicationBundleIdentifier: String?,
        displayUUID: UUID?,
        displayName: String,
        destination: AudioDeviceSnapshot
    ) async {
        isAddingRoute = true
        diagnostics.record("start-requested", category: "route")
        lastError = nil
        let session = RouteSession(
            source: source,
            destination: destination,
            isAutomatic: true,
            displayedSourceName: displayedSourceName,
            applicationBundleIdentifier: applicationBundleIdentifier,
            followedDisplayUUID: displayUUID,
            followedDisplayName: displayName
        )
        automaticRouteIDs[source.pid] = session.id
        sessions[session.id] = session
        routeOrder.append(session.id)
        publishRoutes()
        defer { isAddingRoute = false }

        do {
            try session.probe.start(
                processObjectID: source.id,
                destinationDeviceID: destination.id
            )
            diagnostics.record("start-succeeded", category: "route")
            session.state = .running
            session.notice = "Following \(displayName)."
            cacheAutomaticSession(session)
            startMetricsSampling(for: session.id)
            updateWatchedDeviceIDs()
            chooseSuggestedInputs()
            publishRoutes()
        } catch {
            if session.probe.requiresCleanup {
                session.state = .failed
                session.notice = cleanupRetryNotice(for: session)
                session.error = String(describing: error)
                session.cleanupCompletion = .remove(preserveAutomaticMode: true)
                scheduleCleanupRetry(for: session.id)
                lastError = "AudioOrbit could not finish restoring normal playback for \(displayedSourceName)."
            } else {
                sessions.removeValue(forKey: session.id)
                routeOrder.removeAll { $0 == session.id }
                automaticRouteIDs.removeValue(forKey: source.pid)
                lastError = String(describing: error)
            }
            chooseSuggestedInputs()
            publishRoutes()
        }
        updateAutomaticRoutingSummary()
    }

    /// Keeps a vanished source's route alive while a same-owner
    /// replacement appears; migrates on the first hit and stops only when
    /// the grace expires, so helper churn does not surface as an audible
    /// stop/start loop.
    private func scheduleVanishedSourceGrace(
        for vanishedPID: pid_t,
        state: AutomaticTrackingState?
    ) {
        guard vanishedSourceGraceTasks[vanishedPID] == nil else { return }
        diagnostics.record(
            "route-grace-vanished-source",
            category: "routing",
            level: .warning
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.vanishedSourceGraceTasks[vanishedPID] = nil }
            for delay in [300, 700, 1500, 3000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                guard self.automaticRouteIDs[vanishedPID] != nil else {
                    return
                }
                if let replacement = self.replacementSource(
                    forVanishedPID: vanishedPID,
                    anchoredRendererPID: state?.anchoredWebViewProcessID
                ) {
                    await self.migrateAutomaticRoute(
                        fromPID: vanishedPID,
                        to: replacement,
                        state: state
                    )
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self.stopAutomaticRoute(for: vanishedPID)
        }
        vanishedSourceGraceTasks[vanishedPID] = task
    }

    /// Finds a running replacement source for a vanished one: same visible
    /// owner (bundle identifier) via process association, currently
    /// producing output, not already routed and not suppressed.
    private func replacementSource(
        forVanishedPID vanishedPID: pid_t,
        anchoredRendererPID: pid_t? = nil
    ) -> AudioProcessSnapshot? {
        guard let routeID = automaticRouteIDs[vanishedPID],
              let session = sessions[routeID],
              let ownerBundleIdentifier = session.applicationBundleIdentifier else {
            return nil
        }
        let candidates = processes.filter { candidate in
            candidate.isRunningOutput
                && candidate.pid != vanishedPID
                && automaticRouteIDs[candidate.pid] == nil
                && !activeSourcePIDs.contains(candidate.pid)
                && !suppressedAutomaticSourcePIDs.contains(candidate.pid)
                && processWindowResolver.resolve(candidate)?.windowOwner
                    .bundleIdentifier == ownerBundleIdentifier
        }
        return RouteLifecyclePolicy.replacementSource(
            from: candidates,
            originalBundleIdentifier: session.audioProcessBundleIdentifier,
            originalName: session.audioProcessName,
            anchoredRendererPID: anchoredRendererPID
                ?? automaticTracking[vanishedPID]?.anchoredWebViewProcessID
        )
    }

    /// Re-parents an automatic route to a replacement source process,
    /// preserving the session, anchors and destination. Safari restarting
    /// its media helper during a fullscreen transition then costs only a
    /// tap re-attach instead of a full stop/recreate cycle.
    private func migrateAutomaticRoute(
        fromPID vanishedPID: pid_t,
        to replacement: AudioProcessSnapshot,
        state detachedState: AutomaticTrackingState? = nil
    ) async {
        vanishedSourceGraceTasks[vanishedPID]?.cancel()
        guard let routeID = automaticRouteIDs[vanishedPID],
              let session = sessions[routeID],
              let destination = devices.first(where: {
                  $0.uid == session.destinationUID && $0.isAlive
              }) else {
            await stopAutomaticRoute(for: vanishedPID)
            return
        }
        diagnostics.markRouteTransition()
        diagnostics.record(
            "route-migrated-process",
            category: "routing",
            level: .warning
        )
        session.state = .stopping
        session.metricsTask?.cancel()
        session.metricsTask = nil
        publishRoutes()
        if session.probe.isRunning {
            try? session.probe.stop()
        }
        guard !session.probe.isRunning else {
            // The old tap could not be detached; give up and restore
            // pass-through instead of double-tapping.
            await stopRoute(routeID, preserveAutomaticMode: true)
            return
        }
        // Every migration path must move the complete tracking state with the
        // route. The vanished-source callers may already have detached it;
        // the silent-helper path leaves it under the old, still-live PID.
        let trackingState = detachedState
            ?? automaticTracking.removeValue(forKey: vanishedPID)
        if let trackingState {
            if let replacementState = automaticTracking[replacement.pid],
               replacementState !== trackingState {
                replacementState.decisionTask?.cancel()
            }
            trackingState.wasRunningOutput = true
            automaticTracking[replacement.pid] = trackingState
        }
        // A window-evidence batch may still be querying the old helper PID.
        // Invalidate it before publishing the replacement key, then request a
        // fresh batch after the migration completes.
        automaticEvidenceRefreshGeneration += 1
        automaticRouteIDs.removeValue(forKey: vanishedPID)
        automaticRouteIDs[replacement.pid] = routeID
        session.sourcePID = replacement.pid
        session.sourceObjectID = replacement.id
        session.audioProcessBundleIdentifier = replacement.bundleIdentifier
        do {
            try session.probe.start(
                processObjectID: replacement.id,
                destinationDeviceID: destination.id
            )
            session.destinationDeviceID = destination.id
            session.state = .running
            session.notice = "Safari restarted its media helper; the route was kept alive."
            session.error = nil
            startMetricsSampling(for: routeID)
        } catch {
            session.state = .failed
            session.error = "AudioOrbit could not keep the route after the media helper restarted: \(error)"
            automaticRouteIDs.removeValue(forKey: replacement.pid)
            await stopRoute(routeID, preserveAutomaticMode: true)
        }
        updateWatchedDeviceIDs()
        publishRoutes()
        Task { @MainActor [weak self] in
            await self?.refreshAutomaticWindowEvidence()
        }
    }

    private func stopAutomaticRoute(for sourcePID: pid_t) async {
        vanishedSourceGraceTasks[sourcePID]?.cancel()
        guard let routeID = automaticRouteIDs[sourcePID] else { return }
        await stopRoute(routeID, preserveAutomaticMode: true)
    }

    private func stopAllAutomaticRoutes() async {
        for routeID in Array(automaticRouteIDs.values) {
            await stopRoute(routeID, preserveAutomaticMode: true)
        }
    }

    private func cancelAutomaticDecisions() {
        automaticEvidenceRefreshGeneration += 1
        automaticEvidenceRefreshPending = false
        automaticEvidenceRefreshPendingForce = false
        for state in automaticTracking.values {
            state.decisionTask?.cancel()
        }
        for task in vanishedSourceGraceTasks.values {
            task.cancel()
        }
        vanishedSourceGraceTasks.removeAll()
        automaticTracking.removeAll()
    }

    private func cacheAutomaticSession(_ session: RouteSession) {
        guard session.isAutomatic,
              session.followedDisplayName != "Headphone Override",
              let bundleIdentifier = session.applicationBundleIdentifier,
              !ignoredBundleIdentifiers.contains(bundleIdentifier) else { return }
        let cached = CachedApplicationRoute(
            id: cachedApplicationRoutes.first(where: {
                $0.applicationBundleIdentifier == bundleIdentifier
            })?.id ?? UUID(),
            applicationBundleIdentifier: bundleIdentifier,
            applicationName: session.sourceName,
            audioProcessName: session.audioProcessName,
            lastDisplayUUID: session.followedDisplayUUID,
            lastDisplayName: session.followedDisplayName,
            lastDeviceUID: session.destinationUID,
            lastDeviceName: session.destinationName
        )
        if let index = cachedApplicationRoutes.firstIndex(where: {
            $0.applicationBundleIdentifier == bundleIdentifier
        }) {
            cachedApplicationRoutes[index] = cached
        } else {
            cachedApplicationRoutes.append(cached)
        }
        persistConfiguration()
    }

    private var ignoredBundleIdentifiers: Set<String> {
        Set(ignoredApplications.map(\.applicationBundleIdentifier))
    }

    private func automaticApplicationBundleIdentifier(
        for source: AudioProcessSnapshot
    ) -> String? {
        AutomaticRouteEligibilityPolicy.applicationBundleIdentifier(
            source: source,
            association: processWindowResolver.resolve(source)
        )
    }

    private func ignoreApplication(
        bundleIdentifier: String,
        applicationName: String
    ) {
        cachedApplicationRoutes.removeAll {
            $0.applicationBundleIdentifier == bundleIdentifier
        }
        let ignored = IgnoredApplication(
            applicationBundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
        if let index = ignoredApplications.firstIndex(where: {
            $0.applicationBundleIdentifier == bundleIdentifier
        }) {
            ignoredApplications[index] = ignored
        } else {
            ignoredApplications.append(ignored)
        }
        ignoredApplications.sort {
            $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
        }
    }

    private func updateAutomaticRoutingSummary() {
        guard automaticRoutingEnabled else { return }
        let runningCount = automaticRouteIDs.values.compactMap { sessions[$0] }
            .filter { $0.state == .running }
            .count
        if runningCount == 0 {
            automaticRoutingMessage = "Waiting for a playing application on a mapped display."
        } else if runningCount == 1 {
            automaticRoutingMessage = "Following 1 playing application."
        } else {
            automaticRoutingMessage = "Following \(runningCount) playing applications independently."
        }
    }

    private func windowEvidenceForRetry(
        source: AudioProcessSnapshot,
        display: DisplaySnapshot
    ) -> WindowDisplayEvidence {
        WindowDisplayEvidence(
            sourcePID: source.pid,
            sourceName: source.name,
            audioProcessName: source.name,
            windowOwnerPID: source.pid,
            associationReason: .sameProcess,
            eligibleWindowCount: 1,
            selectedWindowIdentifier: nil,
            selectionSource: nil,
            windowFrame: display.frame,
            displayUUID: display.id,
            displayName: display.name,
            issue: nil,
            candidateWindowIdentifiers: [],
            focusedWindowIdentifier: nil
        )
    }

    private func ensureWindowObservation() {
        guard windowObservationTask == nil,
              accessibilityGranted
                || (automaticRoutingEnabled && headphoneOverrideEnabled) else { return }
        windowObservationTask = Task { [weak self] in
            var automaticPollTick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let hasActiveRoutes = !self.automaticRouteIDs.isEmpty
                let hasPlayingSources = self.processes.contains(where: \.isRunningOutput)
                if self.automaticRoutingEnabled {
                    automaticPollTick += 1
                    // Hardware reconciliation can run less often while no
                    // routes are being managed.
                    let hardwareTicks = hasActiveRoutes ? 4 : 8
                    if automaticPollTick >= hardwareTicks {
                        automaticPollTick = 0
                        await self.reconcileAudioHardware(clearErrorOnSuccess: false)
                    }
                }
                await self.refreshWindowEvidence()
                let interval: Duration
                if self.automaticRoutingEnabled {
                    // Keep the fast tick while audio is actively routed or
                    // playing; otherwise relax to a slow safety-net poll.
                    // Playback starts and window arrivals are already
                    // event-driven through the CoreAudio and AX observers.
                    interval = (hasActiveRoutes || hasPlayingSources)
                        ? .milliseconds(250)
                        : .seconds(2)
                } else {
                    interval = .seconds(1)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func enterSafeRecovery(for routeID: UUID) async {
        guard sessions[routeID]?.state == .running else { return }
        diagnostics.markRouteTransition()
        diagnostics.record(
            "safe-pass-through-entered",
            category: "route",
            level: .warning
        )
        await cleanUpRoute(routeID, completion: .waitForDestination)
    }

    private func beginReconnectDwell(for routeID: UUID) {
        guard let session = sessions[routeID], session.state == .waitingForDestination else { return }
        session.reconnectTask?.cancel()
        session.state = .reconnecting
        session.notice = "\(session.destinationName) is back. Waiting briefly for it to become stable…"
        session.reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectDwell)
            guard !Task.isCancelled, let self else { return }
            await self.restoreRecoveredRoute(routeID)
        }
    }

    private func restoreRecoveredRoute(_ routeID: UUID) async {
        guard let session = sessions[routeID], session.state == .reconnecting else { return }

        do {
            let snapshot = try discovery.snapshot()
            apply(snapshot)
            guard let destination = devices.first(where: {
                $0.uid == session.destinationUID && $0.isAlive
            }) else {
                session.state = .waitingForDestination
                session.notice = "Waiting for \(session.destinationName). Normal playback remains restored."
                updateWatchedDeviceIDs()
                publishRoutes()
                return
            }
            guard let source = processes.first(where: { $0.pid == session.sourcePID }) else {
                session.state = .failed
                session.notice = "Normal playback remains in place."
                session.error = "\(session.sourceName) is no longer producing a routable Core Audio process."
                publishRoutes()
                return
            }

            session.sourceObjectID = source.id
            session.destinationDeviceID = destination.id
            try session.probe.start(
                processObjectID: source.id,
                destinationDeviceID: destination.id
            )
            session.state = .running
            session.notice = "Route restored to \(destination.name)."
            session.error = nil
            startMetricsSampling(for: routeID)
        } catch {
            session.state = .failed
            session.error = "AudioOrbit could not restore this route: \(error)"
            if session.probe.requiresCleanup {
                session.cleanupCompletion = .waitForDestination
                session.notice = cleanupRetryNotice(for: session)
                scheduleCleanupRetry(for: routeID)
            } else {
                session.notice = "Normal playback remains in place."
            }
        }
        updateWatchedDeviceIDs()
        publishRoutes()
    }

    private func updateWatchedDeviceIDs() {
        let ids = Set(sessions.values.compactMap { session in
            devices.first(where: { $0.uid == session.destinationUID })?.id
        })
        do {
            try deviceMonitor.watchAliveStates(of: ids)
        } catch {
            lastError = "AudioOrbit could not watch a routed output: \(error)"
        }
    }

    private func startMetricsSampling(for routeID: UUID) {
        guard let session = sessions[routeID] else { return }
        session.metricsTask?.cancel()
        session.probe.resetHealthObservationWindow()
        session.metrics = session.probe.metricsSnapshot()
        session.healthAnalyzer.reset()
        session.health = AudioRouteHealth(
            maximumQueuedFrameCount: session.metrics.maximumQueuedFrameCount,
            capacityFrameCount: session.metrics.capacityFrameCount
        )
        session.lastReportedHealthLevel = .observing
        let start = ContinuousClock.now
        session.metricsTask = Task { [weak self] in
            var didCompleteWarmUp = false
            var ticksSincePublish = 0
            var lastNonSilentFrameCount: UInt64 = 0
            var silentSeconds = 0
            while !Task.isCancelled {
                guard let self,
                      let current = self.sessions[routeID],
                      current.state == .running else { return }
                current.metrics = current.probe.metricsSnapshot()
                let elapsed = start.duration(to: .now)
                if !didCompleteWarmUp, elapsed >= Self.healthWarmUp {
                    current.probe.resetHealthObservationWindow()
                    current.metrics = current.probe.metricsSnapshot()
                    didCompleteWarmUp = true
                }
                let components = elapsed.components
                let elapsedSeconds = Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
                current.health = current.healthAnalyzer.update(
                    metrics: current.metrics,
                    elapsedSeconds: elapsedSeconds
                )
                let healthChanged = current.health.level
                    != current.lastReportedHealthLevel
                if healthChanged {
                    current.lastReportedHealthLevel = current.health.level
                    switch current.health.level {
                    case .observing:
                        break
                    case .healthy:
                        self.diagnostics.record("healthy", category: "route-health")
                    case .needsAttention:
                        self.diagnostics.record(
                            "buffer-needs-attention",
                            category: "route-health",
                            level: .warning
                        )
                    }
                }
                // Republishing every second re-renders the route UI (and
                // reloads application icons) continuously during playback.
                // Publish immediately on health transitions and otherwise
                // at most every 10 seconds.
                ticksSincePublish += 1
                if healthChanged || ticksSincePublish >= 10 {
                    ticksSincePublish = 0
                    self.publishRoutes()
                }
                // A paused source keeps the renderer alive rendering silence,
                // which keeps Core Audio's prevent-sleep assertion attached
                // indefinitely. After a sustained silence the route is torn
                // down (the anchor and display are retained), so the Mac can
                // sleep; audio returning rebuilds the route within a second.
                let nonSilentFrames = current.metrics.nonSilentFrameCount
                if nonSilentFrames > lastNonSilentFrameCount {
                    silentSeconds = 0
                } else {
                    silentSeconds += 1
                }
                lastNonSilentFrameCount = nonSilentFrames
                // Safari moves audio to a freshly spawned media process on
                // fullscreen transitions while the old process stays alive in
                // the table, so the tap keeps receiving silence and the real
                // audio plays through the default device. While the tap is
                // silent and a same-owner process is actually producing
                // output, migrate the route to it (retried every few seconds
                // until the replacement appears).
                if RouteLifecyclePolicy.shouldAttemptSilentMigration(
                    silentSeconds: silentSeconds,
                    firstAttemptAfter: Self.routeSilenceMigrateSeconds,
                    retryEvery: Self.routeSilenceMigrateRetrySeconds
                ) {
                    await self.migrateSilentRouteIfReplacementAvailable(routeID)
                }
                if silentSeconds >= Self.routeSilenceSuspendSeconds {
                    diagnostics.record(
                        "route-suspended-for-silence",
                        category: "route"
                    )
                    await self.suspendRouteForSilence(routeID)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// While the tap of a running route receives silence, Safari may have
    /// moved its audio to a freshly spawned media process (fullscreen
    /// transitions do exactly that without removing the old process from
    /// the table). If a same-owner process is producing output, migrate the
    /// route to it so the audio never falls back to the default device.
    private func migrateSilentRouteIfReplacementAvailable(
        _ routeID: UUID
    ) async {
        guard let session = sessions[routeID], session.state == .running,
              let replacement = replacementSource(
                  forVanishedPID: session.sourcePID
              ) else { return }
        diagnostics.record(
            "route-migrated-silent-source",
            category: "routing",
            level: .warning
        )
        await migrateAutomaticRoute(
            fromPID: session.sourcePID,
            to: replacement
        )
    }

    /// Tears down a running route after sustained silence while keeping the
    /// automatic-tracking state (anchor, committed display) so returning
    /// audio re-establishes the route to the same destination.
    private func suspendRouteForSilence(_ routeID: UUID) async {
        guard let session = sessions[routeID], session.state == .running else {
            return
        }
        // Clear the candidate residue so the decision path can re-run when
        // audio returns; a stale hasCandidate with a matching display made
        // scheduleAutomaticRouteDecision return early and the route never
        // came back after a silence suspension.
        if let state = automaticTracking[session.sourcePID] {
            state.hasCandidate = false
            state.candidateDisplayUUID = nil
            state.decisionTask?.cancel()
            state.decisionTask = nil
        }
        await stopRoute(routeID, preserveAutomaticMode: true)
    }

    private func publishRoutes() {
        let liveRoutes: [ProbeRouteSnapshot] = routeOrder.compactMap { routeID -> ProbeRouteSnapshot? in
            guard let session = sessions[routeID] else { return nil }
            return ProbeRouteSnapshot(
                id: session.id,
                sourcePID: session.sourcePID,
                sourceName: session.sourceName,
                audioProcessName: session.audioProcessName,
                applicationBundleIdentifier: session.applicationBundleIdentifier,
                isAutomatic: session.isAutomatic,
                isCached: false,
                followedDisplayName: session.followedDisplayName,
                destinationDeviceID: session.destinationDeviceID,
                destinationUID: session.destinationUID,
                destinationName: session.destinationName,
                state: session.state,
                metrics: session.metrics,
                health: session.health,
                notice: session.notice,
                error: session.error,
                requiresCleanupRetry: session.cleanupCompletion != nil,
                supportsManualReanchor: automaticTracking[session.sourcePID]
                    .flatMap { $0.association }
                    .map { WindowRouteAffinityPolicy.pinsInitialWindow(for: $0.reason) }
                    ?? false
            )
        }
        let liveBundles = Set(liveRoutes.compactMap {
            $0.applicationBundleIdentifier
        })
        let cachedRoutes: [ProbeRouteSnapshot] = cachedApplicationRoutes
            .filter { !liveBundles.contains($0.applicationBundleIdentifier) }
            .map { cached in
                ProbeRouteSnapshot(
                    id: cached.id,
                    sourcePID: 0,
                    sourceName: cached.applicationName,
                    audioProcessName: cached.audioProcessName,
                    applicationBundleIdentifier: cached.applicationBundleIdentifier,
                    isAutomatic: true,
                    isCached: true,
                    followedDisplayName: cached.lastDisplayName,
                    destinationDeviceID: devices.first(where: {
                        $0.uid == cached.lastDeviceUID
                    })?.id,
                    destinationUID: cached.lastDeviceUID,
                    destinationName: cached.lastDeviceName,
                    state: .idle,
                    notice: "Remembered route"
                )
            }
        routes = liveRoutes + cachedRoutes
    }
}
