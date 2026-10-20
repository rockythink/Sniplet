import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isUnitTesting else {
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        coordinator.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !AppRuntime.isUnitTesting { coordinator.permissions.refresh() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppRuntime.isUnitTesting else { return .terminateNow }
        coordinator.requestTermination { shouldQuit in
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuBegan(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { coordinator.menuBeganTracking(menu) }
    }
    @objc private func menuEnded(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { coordinator.menuEndedTracking(menu) }
    }
    @objc private func displaysChanged(_ notification: Notification) { coordinator.displayLayoutChanged() }
}
