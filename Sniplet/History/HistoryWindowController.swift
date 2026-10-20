import AppKit
import SwiftUI

/// An on-demand native window avoids auto-opening a history scene on macOS 14.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(coordinator: AppCoordinator) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "截图历史"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 700, height: 440)
        window.contentView = NSHostingView(rootView: HistoryContainerView(coordinator: coordinator))
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("Sniplet.History") { window.center() }
        window.setFrameAutosaveName("Sniplet.History")
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}
