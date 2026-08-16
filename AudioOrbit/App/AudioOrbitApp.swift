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

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "AudioOrbit — right-click to enable or disable"
            button.setAccessibilityLabel("AudioOrbit")
            button.setAccessibilityHelp(
                "Left-click for routes and output volume. Right-click to enable, disable, or quit."
            )
        }
        updateIcon()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(relativeTo: sender)
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: model.automaticRoutingEnabled ? "Disable AudioOrbit" : "Enable AudioOrbit",
            action: #selector(toggleRouting),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: model.automaticRoutingEnabled ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )
        menu.addItem(toggle)
        menu.addItem(.separator())

        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdates.target = self
        menu.addItem(checkUpdates)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit AudioOrbit",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
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
