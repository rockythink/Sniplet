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
        guard let previous = RelaunchHandoff.previousInstance(in: ProcessInfo.processInfo.arguments) else {
            coordinator.start()
            return
        }
        // Started by our own relaunch: the old instance still holds the shortcuts until it quits.
        Task { [coordinator] in
            if await Self.waitForExit(of: previous) { coordinator.start() }
            else { NSApp.terminate(nil) }
        }
    }

    private static func waitForExit(of pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Opening Sniplet again while it runs (Launchpad, Spotlight, Finder) has nothing to show
    /// in the Dock, so it opens the guide — the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !AppRuntime.isUnitTesting, !coordinator.isCapturing else { return false }
        coordinator.showGuide()
        return false
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
