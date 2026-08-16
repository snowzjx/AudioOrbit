import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

@main
struct AudioOrbitApp: App {
    @NSApplicationDelegateAdaptor(AudioOrbitAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AudioOrbitSettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AudioOrbitAppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItemController: AudioOrbitStatusItemController?
    private var onboardingWindowController: OnboardingWindowController?
    private var updaterController: SPUStandardUpdaterController?
    private let isRunningTests: Bool

    override init() {
        isRunningTests = ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil
        if isRunningTests {
            let testConfigurationURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AudioOrbit-XCTest-\(ProcessInfo.processInfo.processIdentifier).json"
                )
            model = AppModel(
                mappingStore: MappingStore(fileURL: testConfigurationURL),
                startsServices: false
            )
        } else {
            model = AppModel()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItemController == nil else { return }
        statusItemController = AudioOrbitStatusItemController(model: model)
        if !isRunningTests {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        if !isRunningTests, !model.hasCompletedOnboarding {
            let controller = OnboardingWindowController(model: model)
            onboardingWindowController = controller
            controller.present()
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.applicationWillTerminate()
    }
}

@MainActor
private final class AudioOrbitStatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let statusMenu = NSMenu()
    private let routingToggleItem = NSMenuItem()
    private var modelObservation: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 410, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(model: model)
        )

        configureStatusButton()
        configureStatusMenu()
        refresh()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        // Swap in a button subclass so left clicks open the popover while
        // right clicks fall through to AppKit, which presents
        // statusItem.menu natively (system header, positioning, highlight).
        object_setClass(button, AudioOrbitStatusBarButton.self)
        button.target = self
        button.action = #selector(handleLeftClick(_:))
        button.toolTip = "AudioOrbit — right-click to enable or disable"
        button.setAccessibilityLabel("AudioOrbit")
        button.setAccessibilityHelp(
            "Left-click for routes and output volume. Right-click to enable, disable, or quit."
        )
    }

    private func configureStatusMenu() {
        routingToggleItem.target = self
        routingToggleItem.action = #selector(toggleRouting)
        routingToggleItem.keyEquivalent = ""
        statusMenu.addItem(routingToggleItem)
        statusMenu.addItem(.separator())

        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        statusMenu.addItem(checkUpdates)
        statusMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit AudioOrbit",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        statusMenu.addItem(quit)

        statusItem.menu = statusMenu
    }

    private func refresh() {
        routingToggleItem.title = model.automaticRoutingEnabled
            ? "Disable AudioOrbit"
            : "Enable AudioOrbit"
        updateIcon()
    }

    @objc private func handleLeftClick(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func toggleRouting() {
        Task { await model.toggleAutomaticRouting() }
    }

    @objc private func checkForUpdates() {
        (NSApp.delegate as? AudioOrbitAppDelegate)?.checkForUpdates()
    }

    @objc private func quitApplication() {
        Task { await model.quit() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: model.menuBarSymbol,
            accessibilityDescription: "AudioOrbit"
        )
        button.image?.isTemplate = true
        let state = model.automaticRoutingEnabled ? "enabled" : "disabled"
        button.setAccessibilityValue("AudioOrbit is \(state)")
    }
}

/// Left clicks are claimed by the controller (popover); right clicks are
/// forwarded to AppKit so it presents the status item's menu natively.
private final class AudioOrbitStatusBarButton: NSStatusBarButton {
    override func mouseDown(with event: NSEvent) {
        _ = sendAction(action, to: target)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
    }
}
