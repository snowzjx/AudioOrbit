import AppKit
import CoreAudio
import SwiftUI

struct AudioOrbitSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            settingsPage { displayMappings }
                .tabItem { Label("Displays", systemImage: "display.2") }

            settingsPage {
                startup
                headphoneOverride
                ignoredApplications
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            settingsPage { permissions }
                .tabItem { Label("Permissions", systemImage: "hand.raised") }

            settingsPage { diagnostics }
                .tabItem { Label("Support", systemImage: "stethoscope") }
        }
        .frame(
            minWidth: 700,
            idealWidth: 760,
            minHeight: 540,
            idealHeight: 600
        )
        .background(SettingsWindowDockPresence())
    }

    private func settingsPage<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
        }
    }

    private var displayMappings: some View {
        GroupBox("Display audio outputs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose where applications should play when their windows are on each display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(model.mappingRows) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(
                            row.displayName,
                            systemImage: row.isBuiltIn ? "laptopcomputer" : "display"
                        )
                        .font(.subheadline.weight(.medium))

                        Picker("Audio output", selection: mappingBinding(for: row)) {
                            Text("Use System Default").tag(DisplayMappingSelection.passThrough)
                            if let unavailableName = row.unavailableDeviceName,
                               !hasListedDevice(for: row.selection) {
                                Text("\(unavailableName) — unavailable").tag(row.selection)
                            }
                            ForEach(model.devices) { device in
                                Text(device.name)
                                    .tag(DisplayMappingSelection.device(uid: device.uid))
                            }
                        }
                        .accessibilityHint("Select the output used by applications on \(row.displayName)")

                        if !row.isDisplayConnected {
                            Label("This display is not connected. Its mapping is remembered.", systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var startup: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Launch AudioOrbit at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { enabled in
                            Task { await model.setLaunchAtLoginEnabled(enabled) }
                        }
                    )
                )
                .accessibilityHint("Starts AudioOrbit automatically when you log in")

                Text("AudioOrbit can be removed at any time in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Notify when audio follows a window",
                    isOn: Binding(
                        get: { model.followNotificationsEnabled },
                        set: { enabled in
                            Task { await model.setFollowNotificationsEnabled(enabled) }
                        }
                    )
                )
                .accessibilityHint("Shows a notification when a route switches to another output")

                Text("A notification appears whenever an application's audio follows its window to a different output. Notification permission is requested the first time this is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headphoneOverride: some View {
        GroupBox("Headphone Override") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Send all managed audio to headphones when connected",
                    isOn: Binding(
                        get: { model.headphoneOverrideEnabled },
                        set: { enabled in
                            Task { await model.setHeadphoneOverrideEnabled(enabled) }
                        }
                    )
                )
                .disabled(model.headphoneOverrideDeviceUID == nil)
                .accessibilityHint("Temporarily sends all managed application audio to the selected headphones")

                Picker(
                    "Headphone output",
                    selection: Binding(
                        get: { model.headphoneOverrideDeviceUID },
                        set: { uid in
                            Task { await model.setHeadphoneOverrideDevice(uid) }
                        }
                    )
                ) {
                    Text("Choose headphones").tag(String?.none)
                    if let uid = model.headphoneOverrideDeviceUID,
                       !model.devices.contains(where: { $0.uid == uid }) {
                        Text("Previously selected output — unavailable").tag(Optional(uid))
                    }
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .accessibilityHint("Choose the output used for Headphone Override")

                Text("When the chosen output is connected, it temporarily overrides every display mapping. Disconnecting it restores normal window-following routes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ignoredApplications: some View {
        GroupBox("Ignored applications") {
            VStack(alignment: .leading, spacing: 10) {
                Text("AudioOrbit never routes these applications, including during Headphone Override. Allow an application again to resume automatic routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.ignoredApplications.isEmpty {
                    Text("No applications are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignoredApplications) { application in
                        HStack(spacing: 10) {
                            ignoredApplicationIcon(application.applicationBundleIdentifier)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.applicationName)
                                    .font(.subheadline.weight(.medium))
                                Text(application.applicationBundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Allow Again") {
                                Task {
                                    await model.allowIgnoredApplication(
                                        application.applicationBundleIdentifier
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ignoredApplicationIcon(_ bundleIdentifier: String) -> some View {
        Group {
            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var permissions: some View {
        GroupBox("Window access") {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    model.accessibilityGranted ? "Accessibility is enabled" : "Accessibility is required",
                    systemImage: model.accessibilityGranted
                        ? "checkmark.circle.fill"
                        : "hand.raised.fill"
                )
                .foregroundStyle(model.accessibilityGranted ? .green : .orange)
                .accessibilityValue(
                    model.accessibilityGranted ? "Granted" : "Not granted"
                )

                Text("AudioOrbit uses Accessibility only to determine which display contains an application's window. It does not read window titles or screen pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Recheck") {
                        Task { await model.recheckAccessibilityAccess() }
                    }
                    if !model.accessibilityGranted {
                        Button("Open System Settings…") { model.openAccessibilitySettings() }
                        Button("Grant Access…") {
                            Task { await model.requestAccessibilityAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let message = model.windowDiscoveryMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnostics: some View {
        GroupBox("Support report") {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Safe to preview before sharing",
                    systemImage: "checkmark.shield"
                )
                .font(.subheadline.weight(.medium))

                Text("The report includes build, operating-system, resource, route-state and audio-buffer measurements. It excludes audio, application and device identities, display details, window titles, document paths and user file paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Generate Preview") {
                        model.refreshSupportReportPreview()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Save Report…") {
                        model.exportSupportReport()
                    }
                    .disabled(model.supportReportPreview.isEmpty)
                }

                if model.supportReportPreview.isEmpty {
                    ContentUnavailableView(
                        "No Preview Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Generate a report to inspect exactly what will be saved.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.supportReportPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                        .frame(height: 280)
                        .accessibilityLabel("Support report preview")
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary)
                        }
                }

                if let message = model.supportReportExportMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mappingBinding(for row: DisplayMappingRow) -> Binding<DisplayMappingSelection> {
        Binding(
            get: {
                model.mappingRows.first(where: { $0.displayUUID == row.displayUUID })?.selection
                    ?? .passThrough
            },
            set: { selection in
                Task { await model.updateMapping(for: row.displayUUID, selection: selection) }
            }
        )
    }

    private func hasListedDevice(for selection: DisplayMappingSelection) -> Bool {
        guard case .device(let uid) = selection else { return false }
        return model.devices.contains { $0.uid == uid }
    }
}

private struct SettingsWindowDockPresence: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowDockObserverView {
        SettingsWindowDockObserverView()
    }

    func updateNSView(
        _ nsView: SettingsWindowDockObserverView,
        context: Context
    ) {}

    static func dismantleNSView(
        _ nsView: SettingsWindowDockObserverView,
        coordinator: Void
    ) {
        nsView.stopObserving()
    }
}

@MainActor
private final class SettingsWindowDockObserverView: NSView {
    private weak var observedWindow: NSWindow?
    private var becameKeyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else {
            if observedWindow != nil {
                stopObserving()
                restoreAccessoryMode()
            }
            return
        }
        guard observedWindow !== window else { return }

        stopObserving()
        observedWindow = window
        showDockIcon()

        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showDockIcon()
            }
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreAccessoryMode()
            }
        }
    }

    func stopObserving() {
        if let becameKeyObserver {
            NotificationCenter.default.removeObserver(becameKeyObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        becameKeyObserver = nil
        closeObserver = nil
        observedWindow = nil
    }

    private func showDockIcon() {
        ApplicationDockPresence.show()
    }

    private func restoreAccessoryMode() {
        ApplicationDockPresence.hideIfNoOtherUserWindow(excluding: observedWindow)
    }
}
