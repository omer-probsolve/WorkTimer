import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` — the modern login-item API.
///
/// Registration is bound to the bundle's location, so the app should live in
/// /Applications (or another stable path) before this is switched on.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when macOS says the user has to approve the item in Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
