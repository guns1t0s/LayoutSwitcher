import ServiceManagement

/// Start-at-login via the modern SMAppService API (FR-29). No external
/// LaunchAgent plist needed when launched as a bundled .app.
enum LoginItem {
    static func set(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
        }
    }
}
