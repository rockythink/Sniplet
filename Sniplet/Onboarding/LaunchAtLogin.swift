import Observation
import ServiceManagement

/// Sniplet itself as a login item. It is registered only when the user turns it on, never
/// on every launch, so switching it off in System Settings stays off.
@Observable final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != isEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = (enabled ? "无法设为登录时打开：" : "无法取消登录时打开：") + error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
