import AppKit
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" setting.
/// Registers the app itself as a login item (macOS 13+). Requires a real,
/// bundled `.app` — registration will throw when running as a bare executable.
enum LoginItemService {
    enum State: Equatable {
        /// Enabled and will launch at login.
        case enabled
        /// Not registered / disabled.
        case disabled
        /// The user disabled the item in System Settings; needs manual approval.
        case requiresApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    static var isEnabled: Bool {
        state == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    /// Opens System Settings → General → Login Items so the user can approve a
    /// login item they previously disabled.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
