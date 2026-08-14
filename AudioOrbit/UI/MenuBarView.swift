import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    private var volumeDevices: [AudioDeviceSnapshot] {
        model.devices.filter { $0.isAlive && $0.isVolumeSettable && $0.volumeScalar != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let override = model.activeHeadphoneOverrideDevice {
                Label("Headphone Override · \(override.name)", systemImage: "headphones")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }

            routesSection

            if !volumeDevices.isEmpty {
                volumeSection
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(16)
        .frame(width: 410)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .frame(width: 34, height: 34)
                .foregroundStyle(model.automaticRoutingEnabled ? Color.accentColor : .secondary)
                .glassCard(cornerRadius: 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("AudioOrbit")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.toggleAutomaticRouting() }
            } label: {
                Label(
                    model.automaticRoutingEnabled ? "Disable" : "Enable",
                    systemImage: model.automaticRoutingEnabled ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .disabled(
                !model.automaticRoutingEnabled
                    && ((!model.accessibilityGranted
                            && !(model.headphoneOverrideEnabled
                                && model.headphoneOverrideDeviceUID != nil))
                        || (!model.hasRoutedDisplayMapping
                            && model.headphoneOverrideDeviceUID == nil))
            )
        }
    }

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Routes")
                .font(.subheadline.weight(.semibold))

            if model.routes.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: model.automaticRoutingEnabled ? "waveform" : "pause.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(model.automaticRoutingEnabled
                        ? "Play audio in an application to create a route."
                        : "AudioOrbit is disabled. Normal Mac audio is unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(13)
                .glassCard(cornerRadius: 14)
            } else {
                ForEach(model.routes) { route in
                    routeRow(route)
                }
            }
        }
    }

    private func routeRow(_ route: ProbeRouteSnapshot) -> some View {
        HStack(spacing: 11) {
            applicationIcon(for: route)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(route.sourceName)
                        .font(.subheadline.weight(.medium))
                    Text(routeStateLabel(route))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(routeDescription(route))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await model.ignoreRoute(route.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(route.isCached
                ? "Ignore this application"
                : "Stop and ignore this application")
            .accessibilityLabel("Ignore \(route.sourceName)")
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
    }

    private func applicationIcon(for route: ProbeRouteSnapshot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = resolvedApplicationIcon(for: route) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .frame(width: 30, height: 30)

            Image(systemName: route.isCached ? "clock.fill" : routeSymbol(route))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(route.isCached ? .secondary : routeColor(route))
                .padding(2)
                .background(.regularMaterial, in: Circle())
                .offset(x: 3, y: 3)
                .accessibilityHidden(true)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func resolvedApplicationIcon(for route: ProbeRouteSnapshot) -> NSImage? {
        if let bundleIdentifier = route.applicationBundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleIdentifier
           ) {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        return NSRunningApplication(processIdentifier: route.sourcePID)?.icon
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Output Volume")
                .font(.subheadline.weight(.semibold))

            ForEach(volumeDevices) { device in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(device.name, systemImage: device.isWirelessHeadphone ? "headphones" : "speaker.wave.2")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(Int((device.volumeScalar ?? 0) * 100), format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 9) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(device.volumeScalar ?? 0) },
                                set: { value in
                                    Task {
                                        await model.setDeviceVolume(
                                            deviceUID: device.uid,
                                            scalar: value
                                        )
                                    }
                                }
                            ),
                            in: 0...1
                        )
                        .accessibilityLabel("\(device.name) output volume")
                        .accessibilityValue(
                            "\(Int((device.volumeScalar ?? 0) * 100)) percent"
                        )
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .glassCard(cornerRadius: 14)
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Quit AudioOrbit") { model.quit() }
                .buttonStyle(.bordered)
        }
    }

    private var statusText: String {
        if !model.automaticRoutingEnabled { return "Disabled" }
        if let override = model.activeHeadphoneOverrideDevice {
            return "All managed audio → \(override.name)"
        }
        let liveCount = model.routes.filter { !$0.isCached && $0.state == .running }.count
        if liveCount == 0 { return "Ready for playing applications" }
        return liveCount == 1 ? "1 application routed" : "\(liveCount) applications routed"
    }

    private func routeDescription(_ route: ProbeRouteSnapshot) -> String {
        if route.isCached {
            return "\(route.followedDisplayName ?? "Last display") → \(route.destinationName)"
        }
        if route.state == .running, let display = route.followedDisplayName {
            return "\(display) → \(route.destinationName)"
        }
        if let notice = route.notice { return notice }
        if let error = route.error { return error }
        return route.destinationName
    }

    private func routeSymbol(_ route: ProbeRouteSnapshot) -> String {
        switch route.state {
        case .running: "dot.radiowaves.left.and.right"
        case .waitingForDestination, .failed: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        case .starting, .switching, .stopping, .reconnecting:
            "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private func routeColor(_ route: ProbeRouteSnapshot) -> Color {
        switch route.state {
        case .running: .green
        case .waitingForDestination, .failed: .orange
        case .idle: .secondary
        case .starting, .switching, .stopping, .reconnecting: .blue
        }
    }

    private func routeStateLabel(_ route: ProbeRouteSnapshot) -> String {
        if route.isCached { return "REMEMBERED" }
        switch route.state {
        case .idle: return "IDLE"
        case .starting: return "STARTING"
        case .running: return "ACTIVE"
        case .switching: return "SWITCHING"
        case .stopping: return "STOPPING"
        case .waitingForDestination: return "WAITING"
        case .reconnecting: return "RECONNECTING"
        case .failed: return "NEEDS ATTENTION"
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
