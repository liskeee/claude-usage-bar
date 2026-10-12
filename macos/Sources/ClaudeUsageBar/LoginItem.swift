import ClaudeUsageBarCore
import ServiceManagement

/// "Start at login": the app itself as a login item (System Settings → General → Login Items).
@MainActor enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() { setEnabled(!isEnabled) }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error)")
        }
    }
}
