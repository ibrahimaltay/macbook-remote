import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// False for ad-hoc or unregistered builds, where `register()` always fails.
    static var isAvailable: Bool {
        SMAppService.mainApp.status != .notFound
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
