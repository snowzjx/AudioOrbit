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
        var anchorMissTickCount = 0
        var anchorEventGateTickCount = 0
        var mediaAnchorDwellTickCount = 0
        var mediaAnchorMissTickCount = 0
        var pendingMediaAnchorID: String?
        var anchoredWebViewProcessID: pid_t?
        var anchoredPIDMissingTickCount = 0
        var manualAnchorOverride = false
        var forceImmediateDecision = false
        var pendingSessionRelease = false
        var suppressAnchorAdoptionThisTick = false
    }

    private static let hardwareChangeCoalescingDelay = Duration.milliseconds(100)
    private static let overviewShrinkRatio: CGFloat = 0.6
    private static let overviewGrowRatio: CGFloat = 1.4
    private static let overviewMinimumWindows = 2
    private static let overviewHoldMaximumTicks = 240
    private static let axEventGateWindowTicks = 8
    private static let axEventGateMaximumTicks = 240
    private static let reconnectDwell = Duration.seconds(1)
    private static let healthWarmUp = Duration.seconds(3)
    private static let displayChangeDwell = Duration.milliseconds(500)
    private static let noEligibleWindowGrace = Duration.seconds(1)
    private static let cleanupRetryDelay = Duration.seconds(1)
    private static let playbackSessionSilenceTicks = 2
    private static let anchorStalenessTicks = 16
    private static let mediaAnchorDwellTicks = 3
    private static let mediaAnchorMissToleranceTicks = 3
    private static let freshMediaWindowAgeTicks = 12
    private static let anchoredPIDMissingToleranceTicks = 6
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
    private var windowObservationTask: Task<Void, Never>?
    private var lastDisplayRefreshDate = Date.distantPast
    private var automaticTracking: [pid_t: AutomaticTrackingState] = [:]
    private var automaticRouteIDs: [pid_t: UUID] = [:]
    private var cachedApplicationRoutes: [CachedApplicationRoute] = []
    private var suppressedAutomaticSourcePIDs: Set<pid_t> = []


    private var windowIdentifierAges: [pid_t: [String: Int]] = [:]
    private var windowFrameAreaHistory: [String: CGFloat] = [:]
    private var overviewHoldActive = false
    private var overviewHoldRemainingTicks = 0
    private var tickFrameAreas: [String: CGFloat] = [:]
    private var evidenceTickCounter = 0
    private var lastAXEventTickByPID: [pid_t: Int] = [:]
    private var previousTickFrameAreas: [String: CGFloat] = [:]
    private var reportedUnassociatedSourcePIDs: Set<pid_t> = []
    private var reportedSessionEvidenceIssuePIDs: Set<pid_t> = []
    private var applicationActivationObserver: NSObjectProtocol?
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
        }
        windowEventMonitor.onEvent = { [weak self] ownerPID in
            Task { @MainActor [weak self] in
                self?.noteAXEvent(ownerPID: ownerPID)
                await self?.refreshAutomaticWindowEvidence()
            }
        }
        displayMonitor.onChange = { [weak self] in
            Task { await self?.refreshWindowEvidence() }
        }
        do {
            try deviceMonitor.start()
            try displayMonitor.start()
            try processActivityMonitor.start()
            try windowEventMonitor.start()
        } catch {
            lastError = "AudioOrbit could not watch for hardware changes: \(error)"
        }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.recheckAccessibilityAccess() }
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
        // media-indicator rule would immediately pull the anchor back to
        // the media window and the audio would snap back.
        state.committedWindowIdentifier = focusedID
        state.anchorMissTickCount = 0
        state.mediaAnchorDwellTickCount = 0
        state.mediaAnchorMissTickCount = 0
        state.pendingMediaAnchorID = nil
        state.manualAnchorOverride = true
        state.anchoredWebViewProcessID = state.evidence?
            .webViewProcessIDsByWindow[focusedID]
            ?? state.anchoredWebViewProcessID
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
        evaluateOverviewHold()
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
                displays = try displayDiscovery.snapshots()
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
        if automaticRoutingEnabled {
            await refreshAutomaticWindowEvidence()
        }
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
                await refreshAutomaticWindowEvidence(
                    forceImmediate: didDisconnectHeadphoneOverride,
                    requestedDelay: didDisconnectHeadphoneOverride
                        ? .zero
                        : Self.reconnectDwell
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
        forceImmediate: Bool = false,
        requestedDelay: Duration? = nil
    ) async {
        guard automaticRoutingEnabled else { return }
        tickFrameAreas.removeAll(keepingCapacity: true)
        evidenceTickCounter += 1
        let currentlyPlayingPIDs = Set(processes.filter(\.isRunningOutput).map(\.pid))
        suppressedAutomaticSourcePIDs.formIntersection(currentlyPlayingPIDs)
        reportedUnassociatedSourcePIDs.formIntersection(currentlyPlayingPIDs)
        reportedSessionEvidenceIssuePIDs.formIntersection(currentlyPlayingPIDs)
        var windowOwnerPIDs: Set<pid_t> = []
        let sources = processes.filter { source in
            let isRelevant = (source.isRunningOutput
                && !suppressedAutomaticSourcePIDs.contains(source.pid))
                || automaticRouteIDs[source.pid] != nil
            guard isRelevant else { return false }
            let association = processWindowResolver.resolve(source)
            if let ownerPID = association?.windowOwner.pid {
                windowOwnerPIDs.insert(ownerPID)
            }
            return AutomaticRouteEligibilityPolicy.shouldManage(
                source: source,
                association: association,
                ignoredBundleIdentifiers: ignoredBundleIdentifiers
            )
        }
        windowEventMonitor.setTrackedApplicationPIDs(windowOwnerPIDs)
        let currentPIDs = Set(processes.map(\.pid))
        let trackedPIDs = Set(automaticTracking.keys).union(automaticRouteIDs.keys)
        let vanishedPIDs = trackedPIDs.filter { !currentPIDs.contains($0) }
        for pid in vanishedPIDs {
            automaticTracking[pid]?.decisionTask?.cancel()
            let trackedState = automaticTracking.removeValue(forKey: pid)
            guard automaticRouteIDs[pid] != nil else { continue }
            // Safari restarts its media helper (WebKit.GPU) during
            // fullscreen transitions. When a replacement source exists for
            // the same owner, migrate the route to it instead of stopping,
            // so the audio never falls back mid-transition.
            if let replacement = replacementSource(forVanishedPID: pid),
               let trackedState {
                // Mark the migrated state as still running so the
                // session-boundary detection below does not treat the
                // replacement as a brand-new playback session and
                // release the anchor mid-transition.
                trackedState.wasRunningOutput = true
                automaticTracking[replacement.pid] = trackedState
                await migrateAutomaticRoute(fromPID: pid, to: replacement)
            } else {
                await stopAutomaticRoute(for: pid)
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
                ) {
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
        let evidenceRequests: [(
            AudioProcessSnapshot,
            ProcessWindowAssociation?,
            UUID?,
            String?
        )] = sources.map { source in
                let association = processWindowResolver.resolve(source)
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
                return (
                    source,
                    association,
                    committedDisplayUUID,
                    preferredWindowIdentifier
                )
            }
        await withTaskGroup(
            of: (
                AudioProcessSnapshot,
                ProcessWindowAssociation?,
                WindowDisplayEvidence?
            ).self
        ) { group in
            for (source, association, committedDisplayUUID, preferredWindowIdentifier)
                in evidenceRequests {
                group.addTask(priority: .utility) {
                    guard let association else { return (source, nil, nil) }
                    let evidence = AccessibilityWindowDiscovery().evidence(
                        for: source,
                        windowOwner: association.windowOwner,
                        associationReason: association.reason,
                        displays: currentDisplays,
                        committedDisplayUUID: committedDisplayUUID,
                        preferredWindowIdentifier: preferredWindowIdentifier
                    )
                    return (source, association, evidence)
                }
            }
            for await (source, association, evidence) in group {
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
                    force: forceImmediate,
                    requestedDelay: requestedDelay
                )
            }
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

    private func scheduleAutomaticRouteDecision(
        for source: AudioProcessSnapshot,
        association: ProcessWindowAssociation?,
        evidence: WindowDisplayEvidence?,
        force: Bool,
        requestedDelay: Duration?
    ) {
        guard automaticRoutingEnabled else { return }
        let state = automaticTracking[source.pid] ?? AutomaticTrackingState()
        automaticTracking[source.pid] = state
        var effectiveForce = force
        if state.forceImmediateDecision {
            effectiveForce = true
            state.forceImmediateDecision = false
        }
        state.wasRunningOutput = source.isRunningOutput
        state.association = association
        state.evidence = evidence
        if let evidence {
            accumulateOverviewFrames(evidence: evidence)
        }
        var eventGated = false
        if let association,
           let evidence {
            // The playback window is identified by the strongest available
            // signal, in order: (1) the anchored tab's renderer pid — Safari
            // exposes each window's active-tab WebViewProcessID, and a tab
            // that keeps its renderer through a tear-off is tracked exactly;
            // (2) the unique media-indicator window; (3) the freshest media
            // window — a torn-off tab lands in a freshly created window, so
            // when the source window keeps a stale indicator and several
            // windows report media, the newest one is the destination.
            let ownerPID = association.windowOwner.pid
            let mediaIdentifiers = Set(evidence.mediaPlayingWindowIdentifiers)
            eventGated = eventGateHolding(
                state: state,
                evidence: evidence,
                ownerPID: ownerPID
            )
            let pidMap = evidence.webViewProcessIDsByWindow
            if state.pendingSessionRelease {
                state.pendingSessionRelease = false
                let sameTabResumed: Bool
                if let anchorID = state.committedWindowIdentifier,
                   let anchoredPID = state.anchoredWebViewProcessID,
                   pidMap[anchorID] == anchoredPID {
                    sameTabResumed = true
                } else {
                    sameTabResumed = false
                }
                if sameTabResumed {
                    diagnostics.record(
                        "playback-resume-kept-anchor",
                        category: "routing"
                    )
                } else {
                    state.committedWindowIdentifier = nil
                    state.anchorMissTickCount = 0
                    state.mediaAnchorDwellTickCount = 0
                    state.mediaAnchorMissTickCount = 0
                    state.pendingMediaAnchorID = nil
                    state.anchoredWebViewProcessID = nil
                    state.anchoredPIDMissingTickCount = 0
                    state.manualAnchorOverride = false
                    state.forceImmediateDecision = false
                    state.suppressAnchorAdoptionThisTick = true
                    diagnostics.record(
                        "playback-session-detected",
                        category: "routing"
                    )
                }
            }
            let currentIDs = Set(evidence.candidateWindowIdentifiers)
            var ages = windowIdentifierAges[ownerPID] ?? [:]
            for identifier in currentIDs {
                ages[identifier, default: 0] += 1
            }
            windowIdentifierAges[ownerPID] = ages
            // Adopt the anchor window's renderer only when doing so cannot
            // destroy a still-live playback signal. While a playing tab
            // moves between windows, Safari may activate another tab in the
            // anchor window, so its BrowserView pid no longer belongs to the
            // media. Keep the saved pid while it is still reported anywhere
            // (the moved tab keeps its renderer), and only re-adopt once the
            // old renderer is gone and the anchor window shows media again.
            if source.isRunningOutput,
               let anchor = state.committedWindowIdentifier,
               let anchorPID = pidMap[anchor] {
                let savedPID = state.anchoredWebViewProcessID
                let savedStillReported = savedPID.map { pidMap.values.contains($0) }
                    ?? false
                let anchorPlaysMedia = mediaIdentifiers.contains(anchor)
                if savedPID == nil || (!savedStillReported && anchorPlaysMedia) {
                    state.anchoredWebViewProcessID = anchorPID
                }
            }
            let targetID: String?
            if state.manualAnchorOverride {
                // The user pinned this window manually; automatic
                // following stays suppressed until the playback session
                // restarts or the pinned window disappears.
                targetID = nil
            } else if source.isRunningOutput,
               let anchoredPID = state.anchoredWebViewProcessID {
                // The renderer pid is the authoritative signal. Safari's
                // audio indicator follows the focused window, not the
                // playing one, so the media heuristic must never override
                // a renderer that is still reported in the anchor window.
                let windowsWithPID = pidMap.filter { $0.value == anchoredPID }
                    .map(\.key)
                let anchorID = state.committedWindowIdentifier
                if windowsWithPID.count == 1,
                   windowsWithPID[0] != anchorID {
                    // The playing tab is now in a different window.
                    state.anchoredPIDMissingTickCount = 0
                    targetID = windowsWithPID[0]
                } else if let anchorID,
                          windowsWithPID.count == 2,
                          let other = windowsWithPID.first(where: { $0 != anchorID }) {
                    // Both the anchor window and another window report the
                    // renderer. After a tab tear-off the anchor's BrowserView
                    // entry stays stale until its active tab navigates. A
                    // freshly created reporting window is the torn-off
                    // destination, so let freshness arbitrate instead of
                    // waiting for the user to navigate the anchor window.
                    let otherAge = ages[other] ?? 0
                    let anchorAge = ages[anchorID] ?? 0
                    state.anchoredPIDMissingTickCount = 0
                    if otherAge <= Self.freshMediaWindowAgeTicks,
                       otherAge < anchorAge {
                        targetID = other
                    } else {
                        targetID = nil
                    }
                } else if anchorID.map({ windowsWithPID.contains($0) }) ?? false {
                    // The playing tab is still in the anchor window.
                    state.anchoredPIDMissingTickCount = 0
                    targetID = nil
                } else {
                    // The renderer is not reported anywhere this tick.
                    // Tolerate transient Accessibility gaps before falling
                    // back, so a short hiccup cannot yank the audio. A
                    // fullscreen transition removes the standard AX window
                    // entirely; while the anchor window is invisible and no
                    // replacement window has appeared, keep holding instead
                    // of letting the focus-driven indicator take over.
                    state.anchoredPIDMissingTickCount += 1
                    let anchorInvisible = anchorIsTemporarilyInvisible(
                        state: state,
                        evidence: evidence
                    ) || overviewHoldActive || eventGated
                    if state.anchoredPIDMissingTickCount
                        >= Self.anchoredPIDMissingToleranceTicks,
                       !anchorInvisible {
                        targetID = WindowRouteAffinityPolicy.bestMediaTarget(
                            mediaIdentifiers,
                            ages: ages,
                            freshWindowAgeTicks: Self.freshMediaWindowAgeTicks
                        )
                    } else {
                        targetID = nil
                    }
                }
            } else {
                targetID = WindowRouteAffinityPolicy.bestMediaTarget(
                    mediaIdentifiers,
                    ages: ages,
                    freshWindowAgeTicks: Self.freshMediaWindowAgeTicks
                )
            }
            if source.isRunningOutput,
               let targetID,
               targetID != state.committedWindowIdentifier {
                // The same window must hold the target for the whole
                // dwell. Requiring continuity prevents the anchor from
                // flip-flopping when two windows alternate.
                if state.pendingMediaAnchorID == targetID {
                    state.mediaAnchorDwellTickCount += 1
                } else {
                    state.pendingMediaAnchorID = targetID
                    state.mediaAnchorDwellTickCount = 1
                }
                state.mediaAnchorMissTickCount = 0
                // The same window must hold the target for the whole
                // dwell. During tab transitions Safari can transiently
                // report the renderer in either window, and a shorter
                // dwell made the anchor follow every flicker.
                if state.mediaAnchorDwellTickCount >= Self.mediaAnchorDwellTicks {
                    state.mediaAnchorDwellTickCount = 0
                    state.mediaAnchorMissTickCount = 0
                    state.pendingMediaAnchorID = nil
                    state.committedWindowIdentifier = targetID
                    state.anchorMissTickCount = 0
                    state.anchoredWebViewProcessID = pidMap[targetID]
                        ?? state.anchoredWebViewProcessID
                    state.forceImmediateDecision = true
                    diagnostics.record(
                        "playback-anchor-followed-media-window",
                        category: "routing"
                    )
                }
            } else if source.isRunningOutput,
                      let pendingID = state.pendingMediaAnchorID,
                      mediaIdentifiers.isEmpty
                          || mediaIdentifiers.contains(pendingID) {
                // The pending window's indicator is momentarily missing
                // or shadowed by another window's indicator. Tolerate a
                // few ticks so a busy Safari cannot starve the dwell.
                state.mediaAnchorMissTickCount += 1
                if state.mediaAnchorMissTickCount
                    >= Self.mediaAnchorMissToleranceTicks {
                    state.mediaAnchorDwellTickCount = 0
                    state.mediaAnchorMissTickCount = 0
                    state.pendingMediaAnchorID = nil
                }
            } else {
                state.mediaAnchorDwellTickCount = 0
                state.mediaAnchorMissTickCount = 0
                state.pendingMediaAnchorID = nil
            }
        }
        if let association {
            // A window anchor that no longer matches any eligible window (for
            // example the anchored Safari window was closed) silently degrades
            // routing to follow-focus behavior, because every selection falls
            // back past the preferred identifier. After a short staleness
            // dwell, re-pin the anchor to the window that is actually being
            // followed so later focus changes stop moving established audio.
            if state.committedWindowIdentifier != nil,
               evidence?.selectedWindowIdentifier != nil,
               evidence?.selectionSource != .routeAnchor,
               !(anchorIsTemporarilyInvisible(
                   state: state,
                   evidence: evidence
               ) || overviewHoldActive || eventGated) {
                state.anchorMissTickCount += 1
                if state.anchorMissTickCount >= Self.anchorStalenessTicks {
                    state.anchorMissTickCount = 0
                    state.committedWindowIdentifier = nil
                    state.manualAnchorOverride = false
                    diagnostics.record(
                        "playback-anchor-repinned",
                        category: "routing"
                    )
                }
            } else {
                state.anchorMissTickCount = 0
            }
            if state.suppressAnchorAdoptionThisTick {
                // A deferred session release must not adopt this tick's
                // selection, which was computed against the stale anchor;
                // the next tick re-selects from scratch.
                state.suppressAnchorAdoptionThisTick = false
            } else {
                state.committedWindowIdentifier = WindowRouteAffinityPolicy.routeAnchor(
                    existing: state.committedWindowIdentifier,
                    selected: evidence?.selectedWindowIdentifier,
                    associationReason: association.reason
                )
            }
        }
        let candidateDisplayUUID = evidence?.displayUUID

        // Native and HTML video fullscreen transitions can temporarily remove
        // the standard AX window even though the audio process keeps playing.
        // Retain an established route on its last connected display instead of
        // audibly falling back to the system default or another focused
        // window. This also covers the case where the evidence selects a
        // fallback window while the anchor is merely invisible — fullscreen
        // must never move the audio. A newly playing process still requires
        // positive window evidence before its first route.
        let anchorTemporarilyInvisible = anchorIsTemporarilyInvisible(
            state: state,
            evidence: evidence
        ) || overviewHoldActive || eventGated
        if candidateDisplayUUID == nil || anchorTemporarilyInvisible,
           let committedDisplayUUID = state.committedDisplayUUID,
           displays.contains(where: { $0.id == committedDisplayUUID }),
           let routeID = automaticRouteIDs[source.pid],
           let session = sessions[routeID],
           session.state == .running {
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
        guard effectiveForce || !state.hasCandidate || state.candidateDisplayUUID != candidateDisplayUUID else {
            return
        }
        state.hasCandidate = true
        state.candidateDisplayUUID = candidateDisplayUUID
        state.decisionTask?.cancel()
        let committedDisplayDisconnected = state.committedDisplayUUID.map { committed in
            !displays.contains { $0.id == committed }
        } ?? false
        let delay = requestedDelay
            ?? (effectiveForce || committedDisplayDisconnected
                ? .zero
                : (candidateDisplayUUID == nil
                    ? Self.noEligibleWindowGrace
                    : Self.displayChangeDwell))
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
            state.committedDisplayUUID = nil
            await stopAutomaticRoute(for: sourcePID)
            updateAutomaticRoutingSummary()
            return
        }
        state.committedDisplayUUID = displayUUID
        guard let source = processes.first(where: { $0.pid == sourcePID }),
              let target = AutomaticRouteTargetPolicy.resolve(
                  source: source,
                  association: state.association,
                  evidence: state.evidence,
                  displays: displays,
                  mappings: mappings,
                  devices: devices
              ),
              let destination = devices.first(where: {
                  $0.uid == target.destinationDeviceUID && $0.isAlive
              }),
              let association = state.association else {
            if let mapping = mappings.first(where: { $0.displayUUID == displayUUID }),
               mapping.behavior == .routeToDevice,
               mapping.resolvedDevice(in: devices) == nil {
                state.hasCandidate = false
            }
            await stopAutomaticRoute(for: sourcePID)
            updateAutomaticRoutingSummary()
            return
        }
        state.committedWindowIdentifier = WindowRouteAffinityPolicy.routeAnchor(
            existing: state.committedWindowIdentifier,
            selected: state.evidence?.selectedWindowIdentifier,
            associationReason: association.reason
        )

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
                    force: true,
                    requestedDelay: .milliseconds(250)
                )
                return
            case .replaceRoute:
                await stopRoute(routeID, preserveAutomaticMode: true)
            case .useRunningRoute where session.destinationUID != destination.uid:
                await switchRoute(routeID, to: destination.id)
                if session.destinationUID == destination.uid {
                    session.followedDisplayUUID = display.id
                    session.followedDisplayName = display.name
                    session.notice = "Followed the window to \(display.name)."
                    cacheAutomaticSession(session)
                } else {
                    state.committedDisplayUUID = session.followedDisplayUUID
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
                force: true,
                requestedDelay: .milliseconds(250)
            )
            return
        }

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

    /// Mission Control scales every visible window simultaneously; a real
    /// user resize affects a single window. A mass shrink (or a shrink
    /// combined with a missing anchor) engages a hold that keeps every
    /// established route on its committed display, because the overview's
    /// scaled geometry must never migrate a route — the anchor would
    /// otherwise fall back to another fresh window (for example Safari's
    /// desktop window behind a fullscreen video) and land on the wrong
    /// output when Mission Control closes. The hold releases when the
    /// windows grow back to normal sizes.
    /// Merges this tick's candidate window frames (across every source)
    /// so the end-of-tick evaluation can compare the whole desktop's
    /// geometry against the last stable baseline.
    private func accumulateOverviewFrames(evidence: WindowDisplayEvidence) {
        for (identifier, frame) in evidence.candidateWindowFrames {
            let area = frame.width * frame.height
            guard area > 0 else { continue }
            tickFrameAreas[identifier] = area
        }
    }

    /// Mission Control scales every visible window simultaneously; a real
    /// user resize affects a single window. A mass shrink (or a shrink
    /// combined with a missing anchor) engages a hold that keeps every
    /// established route on its committed display, because the overview's
    /// scaled geometry must never migrate a route — the anchor would
    /// otherwise fall back to another fresh window (for example Safari's
    /// desktop window behind a fullscreen video) and land on the wrong
    /// output when Mission Control closes.
    ///
    /// The hold releases as soon as the anchor returns at normal scale,
    /// or any window grows back, or a backstop timeout expires — it must
    /// never outlive the overview or freeze tab following.
    /// Records that a window-level AX event arrived for an application.
    /// Mission Control never emits these, while genuine window moves and
    /// tab tear-offs do — so event recency is the discriminator between
    /// overview transforms and real user actions.
    private func noteAXEvent(ownerPID: pid_t) {
        lastAXEventTickByPID[ownerPID] = evidenceTickCounter
    }

    /// True while the anchor window is missing and no recent AX event
    /// backs the change — the signature of Mission Control's overview,
    /// whose scaled geometry must never move a route. Real moves fire
    /// events and clear the gate immediately.
    private func eventGateHolding(
        state: AutomaticTrackingState,
        evidence: WindowDisplayEvidence,
        ownerPID: pid_t
    ) -> Bool {
        guard let anchorID = state.committedWindowIdentifier,
              !evidence.candidateWindowIdentifiers.contains(anchorID) else {
            state.anchorEventGateTickCount = 0
            return false
        }
        let ticksSinceEvent = evidenceTickCounter
            - (lastAXEventTickByPID[ownerPID] ?? 0)
        let holding = ticksSinceEvent > Self.axEventGateWindowTicks
            && state.anchorEventGateTickCount < Self.axEventGateMaximumTicks
        if holding {
            state.anchorEventGateTickCount += 1
        }
        return holding
    }

    private func evaluateOverviewHold() {
        if overviewHoldActive {
            overviewHoldRemainingTicks -= 1
            var released = false
            for state in automaticTracking.values {
                if let anchorID = state.committedWindowIdentifier,
                   let area = tickFrameAreas[anchorID],
                   let baseline = windowFrameAreaHistory[anchorID],
                   baseline > 0,
                   area >= baseline * 0.9 {
                    released = true
                    break
                }
            }
            var grewCount = 0
            for (identifier, area) in tickFrameAreas {
                if let previous = previousTickFrameAreas[identifier],
                   previous > 0,
                   area > previous * Self.overviewGrowRatio {
                    grewCount += 1
                }
            }
            if grewCount >= 1 || overviewHoldRemainingTicks <= 0 {
                released = true
            }
            if released {
                overviewHoldActive = false
                diagnostics.record(
                    "overview-hold-released",
                    category: "routing"
                )
            }
        } else {
            var shrunkCount = 0
            for (identifier, area) in tickFrameAreas {
                if let baseline = windowFrameAreaHistory[identifier],
                   baseline > 0,
                   area < baseline * Self.overviewShrinkRatio {
                    shrunkCount += 1
                }
            }
            var anchorMissing = false
            for state in automaticTracking.values {
                if let anchorID = state.committedWindowIdentifier,
                   tickFrameAreas[anchorID] == nil {
                    anchorMissing = true
                    break
                }
            }
            if shrunkCount >= Self.overviewMinimumWindows
                || (shrunkCount >= 1 && anchorMissing) {
                overviewHoldActive = true
                overviewHoldRemainingTicks = Self.overviewHoldMaximumTicks
                diagnostics.record(
                    "overview-hold-engaged",
                    category: "routing"
                )
            }
            // The baseline only advances while the overview is not
            // active, so scaled frames never poison it.
            windowFrameAreaHistory = tickFrameAreas
        }
        previousTickFrameAreas = tickFrameAreas
    }

    private func anchorIsTemporarilyInvisible(
        state: AutomaticTrackingState,
        evidence: WindowDisplayEvidence?
    ) -> Bool {
        guard let anchorID = state.committedWindowIdentifier else { return false }
        guard let evidence else { return true }
        let currentIDs = Set(evidence.candidateWindowIdentifiers)
        if currentIDs.contains(anchorID) { return false }
        let ages = windowIdentifierAges[evidence.windowOwnerPID] ?? [:]
        return !currentIDs.contains { identifier in
            (ages[identifier] ?? 0) <= Self.freshMediaWindowAgeTicks
        }
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

    /// Finds a running replacement source for a vanished one: same visible
    /// owner (bundle identifier) via process association, currently
    /// producing output, not already routed and not suppressed.
    private func replacementSource(forVanishedPID vanishedPID: pid_t) -> AudioProcessSnapshot? {
        guard let routeID = automaticRouteIDs[vanishedPID],
              let session = sessions[routeID],
              let ownerBundleIdentifier = session.applicationBundleIdentifier else {
            return nil
        }
        return processes.first { candidate in
            candidate.isRunningOutput
                && candidate.pid != vanishedPID
                && automaticRouteIDs[candidate.pid] == nil
                && !activeSourcePIDs.contains(candidate.pid)
                && !suppressedAutomaticSourcePIDs.contains(candidate.pid)
                && processWindowResolver.resolve(candidate)?.windowOwner
                    .bundleIdentifier == ownerBundleIdentifier
        }
    }

    /// Re-parents an automatic route to a replacement source process,
    /// preserving the session, anchors and destination. Safari restarting
    /// its media helper during a fullscreen transition then costs only a
    /// tap re-attach instead of a full stop/recreate cycle.
    private func migrateAutomaticRoute(
        fromPID vanishedPID: pid_t,
        to replacement: AudioProcessSnapshot
    ) async {
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
        automaticRouteIDs.removeValue(forKey: vanishedPID)
        automaticRouteIDs[replacement.pid] = routeID
        session.sourcePID = replacement.pid
        session.sourceObjectID = replacement.id
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
    }

    private func stopAutomaticRoute(for sourcePID: pid_t) async {
        guard let routeID = automaticRouteIDs[sourcePID] else { return }
        await stopRoute(routeID, preserveAutomaticMode: true)
    }

    private func stopAllAutomaticRoutes() async {
        for routeID in Array(automaticRouteIDs.values) {
            await stopRoute(routeID, preserveAutomaticMode: true)
        }
    }

    private func cancelAutomaticDecisions() {
        for state in automaticTracking.values {
            state.decisionTask?.cancel()
        }
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
                try? await Task.sleep(for: .seconds(1))
            }
        }
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