import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// `.requiresApproval` means the registration succeeded and is
    /// awaiting user action in System Settings — the setting is on, not
    /// off.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Retrying an already-registered or pending-approval item
                // can throw an already-registered error; the registration
                // itself succeeded, so treat it as enabled.
                let status = SMAppService.mainApp.status
                guard status != .enabled, status != .requiresApproval else { return }
                throw error
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
