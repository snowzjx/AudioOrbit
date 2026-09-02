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
            AudioOrbitSettingsView(
                model: appDelegate.model,
                updateManager: appDelegate.updateManager
            )
        }
    }
}

@MainActor
final class AudioOrbitAppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var statusItemController: AudioOrbitStatusItemController?
    private var onboardingWindowController: OnboardingWindowController?
    let updateManager = UpdateManager()
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
        statusItemController = AudioOrbitStatusItemController(
            model: model,
            updateManager: updateManager
        )
        if !isRunningTests {
            updateManager.startUpdaterIfNeeded()
        }
        if !isRunningTests, CommandLine.arguments.contains("--check-updates") {
            // Diagnostic hook: trigger an update check shortly after launch
            // so failures can be observed in the unified log.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.updateManager.checkForUpdates()
            }
        }
        if !isRunningTests, !model.hasCompletedOnboarding {
            let controller = OnboardingWindowController(model: model)
            onboardingWindowController = controller
            controller.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.applicationWillTerminate()
    }
}

@MainActor
private final class AudioOrbitStatusItemController: NSObject {
    private let model: AppModel
    private let updateManager: UpdateManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let statusMenu = NSMenu()
    private let routingToggleItem = NSMenuItem()
    private var modelObservation: AnyCancellable?
    private var lastIconSymbol: String?
    private var lastIconAccessibilityState: String?

    init(model: AppModel, updateManager: UpdateManager) {
        self.model = model
        self.updateManager = updateManager
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: 410,
            height: preferredPopoverHeight(on: NSScreen.main)
        )
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
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        let about = NSMenuItem(
            title: "About AudioOrbit",
            action: #selector(openAboutPanel),
            keyEquivalent: ""
        )
        about.target = self
        statusMenu.addItem(about)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        statusMenu.addItem(settings)

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

    }

    private func refresh() {
        routingToggleItem.title = model.automaticRoutingEnabled
            ? "Disable AudioOrbit"
            : "Enable AudioOrbit"
        updateIcon()

        if popover.isShown {
            let screen = popover.contentViewController?.view.window?.screen
            updatePopoverSize(on: screen)
        }
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            presentStatusMenu(from: sender)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            updatePopoverSize(on: sender.window?.screen)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func presentStatusMenu(from sender: NSStatusBarButton) {
        // Assign the menu only while AppKit is tracking it. Keeping a menu on
        // the status item makes AppKit consume left clicks before the button's
        // action can open the popover.
        statusItem.menu = statusMenu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    private func preferredPopoverHeight(on screen: NSScreen?) -> CGFloat {
        // Keep these values aligned with MenuBarView's padding and spacing.
        // Route rows reserve enough room for their optional second detail line.
        let outerVerticalPadding: CGFloat = 32
        let headerHeight: CGFloat = 58
        let overlayClearance: CGFloat = 26
        let sectionSpacing: CGFloat = 15
        let routeTitleHeight: CGFloat = 19
        let routeTitleSpacing: CGFloat = 9
        let routeRowHeight: CGFloat = 68
        let routeRowSpacing: CGFloat = 9

        let hasVolumeControls = model.devices.contains {
            $0.isAlive && $0.isVolumeSettable && $0.volumeScalar != nil
        }
        // Collapsed Output Volume + divider + footer, or the footer alone.
        let bottomControlsHeight: CGFloat = hasVolumeControls ? 94 : 52

        let routeCount = max(model.routes.count, 1)
        let routesHeight = routeTitleHeight
            + routeTitleSpacing
            + CGFloat(routeCount) * routeRowHeight
            + CGFloat(max(routeCount - 1, 0)) * routeRowSpacing

        var contentSectionHeights = [routesHeight]
        if !model.accessibilityGranted {
            contentSectionHeights.insert(100, at: 0)
        }
        if model.activeHeadphoneOverrideDevice != nil {
            contentSectionHeights.insert(34, at: contentSectionHeights.count - 1)
        }
        if model.lastError != nil {
            contentSectionHeights.append(34)
        }

        let contentHeight = contentSectionHeights.reduce(0, +)
            + CGFloat(max(contentSectionHeights.count - 1, 0)) * sectionSpacing
        let fittedHeight = outerVerticalPadding
            + headerHeight
            + overlayClearance
            + contentHeight
            + bottomControlsHeight

        let desiredHeight = max(350, ceil(fittedHeight))
        return min(desiredHeight, Self.maximumPopoverHeight(on: screen))
    }

    private func updatePopoverSize(on screen: NSScreen?) {
        let height = preferredPopoverHeight(on: screen)
        guard abs(popover.contentSize.height - height) > 1 else { return }
        popover.contentSize = NSSize(width: 410, height: height)
    }

    private static func maximumPopoverHeight(on screen: NSScreen?) -> CGFloat {
        let usableHeight = screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 700
        return floor(usableHeight * 0.8)
    }

    @objc private func toggleRouting() {
        Task { await model.toggleAutomaticRouting() }
    }

    @objc private func openAboutPanel() {
        // Let the status menu finish tracking before presenting the panel;
        // AppKit can otherwise drop the activation request for an LSUIElement.
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [:])
        }
    }

    @objc private func openSettings() {
        // Defer past menu tracking so the action lands after the menu
        // closes. Dispatch the same action as the main menu's Settings…
        // item (⌘,), which SwiftUI provides and handles correctly.
        DispatchQueue.main.async { [weak self] in
            self?.dispatchSettingsMenuItemAction()
        }
    }

    private func dispatchSettingsMenuItemAction() {
        if let item = Self.settingsMenuItem(), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            // Fallback if the SwiftUI main menu has not been built yet.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        // Bring the window forward without changing the activation policy,
        // so no Dock icon appears for this menu-bar-only app.
        NSApp.activate()
    }

    private static func settingsMenuItem() -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where item.keyEquivalent == "," {
                return item
            }
        }
        return nil
    }

    @objc private func checkForUpdates() {
        // Note: NSApp.delegate is SwiftUI's own AppDelegate wrapper, not
        // AudioOrbitAppDelegate, so route through the injected manager
        // instead of casting NSApp.delegate (that cast silently returns nil).
        updateManager.checkForUpdates()
    }

    @objc private func quitApplication() {
        Task { await model.quit() }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        // Only touch the button when something actually changed; the model
        // publishes several times per second and re-setting the image every
        // time forces an NSImage symbol lookup plus a full redraw.
        let symbol = model.menuBarSymbol
        if symbol != lastIconSymbol {
            button.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: "AudioOrbit"
            )
            button.image?.isTemplate = true
            lastIconSymbol = symbol
        }
        let state = model.automaticRoutingEnabled ? "enabled" : "disabled"
        if state != lastIconAccessibilityState {
            button.setAccessibilityValue("AudioOrbit is \(state)")
            lastIconAccessibilityState = state
        }
    }
}
