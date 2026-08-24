import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            VStack(spacing: 22) {
                HStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.32), lineWidth: 1.5)
                            .frame(width: 94, height: 94)
                        Circle()
                            .fill(Color.accentColor.opacity(0.10))
                            .frame(width: 84, height: 84)
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Welcome to AudioOrbit")
                            .font(.largeTitle.weight(.semibold))
                        Text("Let application audio follow its window across your displays.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .liquidGlassPanel(cornerRadius: 22, castsShadow: true)

                VStack(alignment: .leading, spacing: 12) {
                    onboardingStep(
                        number: 1,
                        title: "Map each display",
                        detail: "Choose the audio output that belongs to each screen. Screens without speakers can use another output or normal Mac audio."
                    )
                    onboardingStep(
                        number: 2,
                        title: "Allow window location access",
                        detail: "Accessibility access lets AudioOrbit identify which display contains a window. Window titles and screen pixels are never read."
                    )
                    onboardingStep(
                        number: 3,
                        title: "Enable AudioOrbit",
                        detail: "Use the menu-bar switch when setup is complete. The first route may also request System Audio Recording permission. AudioOrbit uses one output per application, so separate windows from the same app cannot play through different outputs."
                    )
                }

                Label(
                    model.accessibilityGranted
                        ? "Window access granted — setup can be completed."
                        : "Window access is required before setup can be completed.",
                    systemImage: model.accessibilityGranted
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(model.accessibilityGranted ? .green : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .liquidGlassPanel(
                    cornerRadius: 14,
                    tint: model.accessibilityGranted ? .green : .orange
                )
                .accessibilityValue(
                    model.accessibilityGranted ? "Permission granted" : "Permission required"
                )

                HStack {
                    SettingsLink {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)

                    if !model.accessibilityGranted {
                        Button("Grant Window Access…") {
                            Task { await model.requestAccessibilityAccess() }
                        }
                    }

                    Spacer()

                    Button("Finish") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.accessibilityGranted)
                        .accessibilityHint(
                            model.accessibilityGranted
                                ? "Completes setup and closes this window"
                                : "Grant Window Access before completing setup"
                        )
                }
            }
            .padding(28)
        }
        .frame(width: 640)
        .accessibilityElement(children: .contain)
    }

    private func onboardingStep(
        number: Int,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Step \(number): \(title)")
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .liquidGlassPanel(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to AudioOrbit"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(model: model) { [weak self] in
                self?.model.completeOnboarding()
                self?.close()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        ApplicationDockPresence.show()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        ApplicationDockPresence.hideIfNoOtherUserWindow(excluding: window)
    }
}
