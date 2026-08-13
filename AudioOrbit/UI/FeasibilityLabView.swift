import CoreAudio
import SwiftUI

struct AudioOrbitSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            settingsPage { displayMappings }
                .tabItem { Label("Displays", systemImage: "display.2") }

            settingsPage {
                headphoneOverride
                rememberedRoutes
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            settingsPage { permissions }
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
        }
        .frame(
            minWidth: 700,
            idealWidth: 760,
            minHeight: 540,
            idealHeight: 600
        )
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
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }

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

    private var rememberedRoutes: some View {
        GroupBox("Remembered routes") {
            VStack(alignment: .leading, spacing: 10) {
                Text("AudioOrbit remembers an application after its first route and reconnects it when the application returns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let remembered = model.routes.filter(\.isCached)
                if remembered.isEmpty {
                    Text("No inactive routes are remembered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remembered) { route in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.sourceName).font(.subheadline.weight(.medium))
                                Text("\(route.followedDisplayName ?? "Last display") → \(route.destinationName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteRoute(route.id) }
                            }
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
