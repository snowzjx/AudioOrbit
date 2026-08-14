import AppKit

@MainActor
enum ApplicationDockPresence {
    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hideIfNoOtherUserWindow(excluding closingWindow: NSWindow?) {
        let hasOtherUserWindow = NSApp.windows.contains { window in
            window !== closingWindow
                && window.isVisible
                && window.styleMask.contains(.titled)
        }
        if !hasOtherUserWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
