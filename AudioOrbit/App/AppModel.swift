import AppKit
import CoreAudio
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [AudioDeviceSnapshot] = []
    @Published private(set) var processes: [AudioProcessSnapshot] = []
    @Published private(set) var displays: [DisplaySnapshot] = []
    @Published private(set) var mappings: [DisplayAudioMapping] = []
    @Published private(set) var routes: [ProbeRouteSnapshot] = []
    @Published var selectedProcessID: AudioObjectID?
    @Published var selectedDeviceID: AudioObjectID?
    @Published var selectedWindowProcessID: AudioObjectID?
    @Published private(set) var isAddingRoute = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var windowEvidence: WindowDisplayEvidence?
    @Published private(set) var windowDiscoveryMessage: String?
    @Published private(set) var automaticRoutingEnabled = false
    @Published private(set) var automaticRoutingMessage: String?
    @Published private(set) var headphoneOverrideEnabled = false
    @Published private(set) var headphoneOverrideDeviceUID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var supportReportPreview = ""
    @Published private(set) var supportReportExportMessage: String?
    @Published private(set) var hasCompletedOnboarding: Bool

    private final class RouteSession {
        let id = UUID()
        let sourcePID: pid_t
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
        var association: ProcessWindowAssociation?
        var evidence: WindowDisplayEvidence?
        var decisionTask: Task<Void, Never>?
    }

    private static let hardwareChangeCoalescingDelay = Duration.milliseconds(100)
    private static let reconnectDwell = Duration.seconds(1)
    private static let healthWarmUp = Duration.seconds(3)
    private static let displayChangeDwell = Duration.milliseconds(500)
    private static let noEligibleWindowGrace = Duration.seconds(1)

    private let discovery = AudioDiscovery()
    private let deviceMonitor = AudioDeviceMonitor()
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
    private var automaticTracking: [pid_t: AutomaticTrackingState] = [:]
    private var automaticRouteIDs: [pid_t: UUID] = [:]
    private var cachedApplicationRoutes: [CachedApplicationRoute] = []
    private var suppressedAutomaticSourcePIDs: Set<pid_t> = []
    private var applicationActivationObserver: NSObjectProtocol?

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
        let loadedConfiguration = mappingStore.load()
        mappings = loadedConfiguration.configuration.mappings
        automaticRoutingEnabled = loadedConfiguration.configuration.routingEnabled
        cachedApplicationRoutes = loadedConfiguration.configuration.cachedRoutes
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
        displayMonitor.onChange = { [weak self] in
            Task { await self?.refreshWindowEvidence() }
        }
        do {
            try deviceMonitor.start()
            try displayMonitor.start()
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
        await reconcileAudioHardware(clearErrorOnSuccess: true)
        await refreshWindowEvidence()
    }

    func refreshSupportReportPreview() {
        supportReportPreview = makeSupportReport()
        supportReportExportMessage = nil
        diagnostics.record("preview-generated", category: "diagnostics")
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

    func deleteRoute(_ routeID: UUID) async {
        if let session = sessions[routeID] {
            suppressedAutomaticSourcePIDs.insert(session.sourcePID)
            if let bundleIdentifier = session.applicationBundleIdentifier {
                cachedApplicationRoutes.removeAll {
                    $0.applicationBundleIdentifier == bundleIdentifier
                }
            }
            persistConfiguration()
            await stopRoute(routeID, preserveAutomaticMode: true)
            publishRoutes()
            return
        }
        cachedApplicationRoutes.removeAll { $0.id == routeID }
        persistConfiguration()
        publishRoutes()
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
            windowEvidence = nil
            windowObservationTask?.cancel()
            windowObservationTask = nil
        case .continueHeadphoneOverride:
            windowEvidence = nil
            ensureWindowObservation()
            await refreshAutomaticWindowEvidence()
        case .stopAndRestorePassThrough:
            windowEvidence = nil
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
        do {
            displays = try displayDiscovery.snapshots()
            synchronizeMappingsWithConnectedHardware()
        } catch {
            windowDiscoveryMessage = String(describing: error)
            return
        }

        accessibilityGranted = AccessibilityPermission.isGranted
        guard accessibilityGranted else {
            windowEvidence = nil
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
        guard let process = processes.first(where: { $0.id == selectedWindowProcessID }) else {
            windowEvidence = nil
            windowDiscoveryMessage = processes.isEmpty
                ? "No Core Audio application processes are currently available to inspect."
                : "Choose an application to inspect."
            if automaticRoutingEnabled {
                await refreshAutomaticWindowEvidence()
            }
            return
        }

        let currentDisplays = displays
        let committedDisplayUUID = windowEvidence?.sourcePID == process.pid
            ? windowEvidence?.displayUUID
            : nil
        let association = processWindowResolver.resolve(process)
        let evidence: WindowDisplayEvidence?
        if let association {
            evidence = await Task.detached(priority: .utility) {
                AccessibilityWindowDiscovery().evidence(
                    for: process,
                    windowOwner: association.windowOwner,
                    associationReason: association.reason,
                    displays: currentDisplays,
                    committedDisplayUUID: committedDisplayUUID
                )
            }.value
        } else {
            evidence = nil
        }
        guard process.id == selectedWindowProcessID else { return }
        windowEvidence = evidence
        windowDiscoveryMessage = evidence?.issue
            ?? "AudioOrbit could not safely associate this audio process with a visible application window."
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
            sessions.removeValue(forKey: session.id)
            routeOrder.removeAll { $0 == session.id }
            lastError = String(describing: error)
            chooseSuggestedInputs()
            publishRoutes()
        }
    }

    func stopRoute(_ routeID: UUID, preserveAutomaticMode: Bool = false) async {
        guard let session = sessions[routeID] else { return }
        diagnostics.markRouteTransition()
        diagnostics.record("stop-requested", category: "route")
        let wasAutomaticRoute = session.isAutomatic
        session.state = .stopping
        session.metricsTask?.cancel()
        session.metricsTask = nil
        session.reconnectTask?.cancel()
        session.reconnectTask = nil
        publishRoutes()

        if session.probe.isRunning {
            do {
                try session.probe.stop()
            } catch {
                lastError = "The route was removed, but Core Audio reported a cleanup issue: \(error)"
            }
        }

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

        do {
            try await session.probe.switchDestination(to: destinationDeviceID)
            session.destinationDeviceID = destination.id
            session.destinationUID = destination.uid
            session.destinationName = destination.name
            session.state = .running
            diagnostics.record("switch-succeeded", category: "route")
            if persistDestination {
                cacheAutomaticSession(session)
            }
            startMetricsSampling(for: routeID)
        } catch {
            diagnostics.record("switch-failed", category: "route", level: .error)
            session.error = String(describing: error)
            if session.probe.isRunning {
                session.state = .running
                startMetricsSampling(for: routeID)
            } else {
                session.metrics = TapProbeMetrics()
                session.health = AudioRouteHealth()
                session.notice = "Normal playback was restored for \(session.sourceName)."
                session.state = .failed
            }
        }
        updateWatchedDeviceIDs()
        publishRoutes()
    }

    func quit() {
        diagnostics.record("quit-requested", category: "application")
        hardwareRefreshTask?.cancel()
        cancelAutomaticDecisions()
        for session in sessions.values {
            session.metricsTask?.cancel()
            session.reconnectTask?.cancel()
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
        NSApplication.shared.terminate(nil)
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
        let selectedWindowProcessPID = processes.first(where: {
            $0.id == selectedWindowProcessID
        })?.pid

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

        if let selectedWindowProcessPID,
           let matchingProcess = processes.first(where: { $0.pid == selectedWindowProcessPID }) {
            selectedWindowProcessID = matchingProcess.id
        } else {
            selectedWindowProcessID = processes.first(where: \.isRunningOutput)?.id
                ?? processes.first?.id
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
        let currentlyPlayingPIDs = Set(processes.filter(\.isRunningOutput).map(\.pid))
        suppressedAutomaticSourcePIDs.formIntersection(currentlyPlayingPIDs)
        let sources = processes.filter {
            ($0.isRunningOutput && !suppressedAutomaticSourcePIDs.contains($0.pid))
                || automaticRouteIDs[$0.pid] != nil
        }
        let currentPIDs = Set(processes.map(\.pid))
        let trackedPIDs = Set(automaticTracking.keys).union(automaticRouteIDs.keys)
        let vanishedPIDs = trackedPIDs.filter { !currentPIDs.contains($0) }
        for pid in vanishedPIDs {
            automaticTracking[pid]?.decisionTask?.cancel()
            automaticTracking.removeValue(forKey: pid)
            await stopAutomaticRoute(for: pid)
        }

        if let overrideDevice = activeHeadphoneOverrideDevice {
            await applyHeadphoneOverride(to: sources, destination: overrideDevice)
            updateAutomaticRoutingSummary()
            return
        }

        let currentDisplays = displays
        for source in sources {
            guard let association = processWindowResolver.resolve(source) else {
                scheduleAutomaticRouteDecision(
                    for: source,
                    association: nil,
                    evidence: nil,
                    force: forceImmediate,
                    requestedDelay: requestedDelay
                )
                continue
            }
            let committedDisplayUUID = automaticTracking[source.pid]?.committedDisplayUUID
            let evidence = await Task.detached(priority: .utility) {
                AccessibilityWindowDiscovery().evidence(
                    for: source,
                    windowOwner: association.windowOwner,
                    associationReason: association.reason,
                    displays: currentDisplays,
                    committedDisplayUUID: committedDisplayUUID
                )
            }.value
            scheduleAutomaticRouteDecision(
                for: source,
                association: association,
                evidence: evidence,
                force: forceImmediate,
                requestedDelay: requestedDelay
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
                if session.state != .running {
                    await stopRoute(routeID, preserveAutomaticMode: true)
                } else {
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
        state.association = association
        state.evidence = evidence
        let candidateDisplayUUID = evidence?.displayUUID

        // Native and HTML video fullscreen transitions can temporarily remove
        // the standard AX window even though the audio process keeps playing.
        // Retain an established route on its last connected display instead of
        // audibly falling back to the system default. A newly playing process
        // still requires positive window evidence before its first route.
        if candidateDisplayUUID == nil,
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
        guard force || !state.hasCandidate || state.candidateDisplayUUID != candidateDisplayUUID else {
            return
        }
        state.hasCandidate = true
        state.candidateDisplayUUID = candidateDisplayUUID
        state.decisionTask?.cancel()
        let committedDisplayDisconnected = state.committedDisplayUUID.map { committed in
            !displays.contains { $0.id == committed }
        } ?? false
        let delay = requestedDelay
            ?? (force || committedDisplayDisconnected
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

        if let routeID = automaticRouteIDs[sourcePID],
           let session = sessions[routeID] {
            if session.state != .running {
                await stopRoute(routeID, preserveAutomaticMode: true)
            } else if session.destinationUID != destination.uid {
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
            } else {
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
            sessions.removeValue(forKey: session.id)
            routeOrder.removeAll { $0 == session.id }
            automaticRouteIDs.removeValue(forKey: source.pid)
            lastError = String(describing: error)
            chooseSuggestedInputs()
            publishRoutes()
        }
        updateAutomaticRoutingSummary()
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
              let bundleIdentifier = session.applicationBundleIdentifier else { return }
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
            issue: nil
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
                if self.automaticRoutingEnabled {
                    automaticPollTick += 1
                    if automaticPollTick >= 4 {
                        automaticPollTick = 0
                        await self.reconcileAudioHardware(clearErrorOnSuccess: false)
                    }
                }
                await self.refreshWindowEvidence()
                let interval: Duration = self.automaticRoutingEnabled
                    ? .milliseconds(250)
                    : .seconds(1)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func enterSafeRecovery(for routeID: UUID) async {
        guard let session = sessions[routeID], session.state == .running else { return }
        diagnostics.markRouteTransition()
        diagnostics.record(
            "safe-pass-through-entered",
            category: "route",
            level: .warning
        )
        session.state = .stopping
        session.metricsTask?.cancel()
        session.metricsTask = nil
        session.reconnectTask?.cancel()
        session.reconnectTask = nil
        publishRoutes()

        do {
            try session.probe.stop()
        } catch {
            session.error = "The route was removed, but Core Audio reported a cleanup issue: \(error)"
        }

        session.metrics = TapProbeMetrics()
        session.health = AudioRouteHealth()
        session.state = .waitingForDestination
        session.notice = "\(session.destinationName) disconnected. AudioOrbit restored \(session.sourceName) to normal playback and will reconnect only when that output returns."
        updateWatchedDeviceIDs()
        publishRoutes()
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
            session.notice = "Normal playback remains in place."
            session.error = "AudioOrbit could not restore this route: \(error)"
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
                if current.health.level != current.lastReportedHealthLevel {
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
                self.publishRoutes()
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
                error: session.error
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
