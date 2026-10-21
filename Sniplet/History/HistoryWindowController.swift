import AppKit
import SwiftUI

/// An on-demand native window avoids auto-opening a history scene on macOS 14.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(coordinator: AppCoordinator) {
        let window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
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

/// SwiftUI toolbar shortcuts are window key equivalents and would take ⌘C from the search
/// field. Selected native text copies as text first, as in InlineCapturePanel.
private final class HistoryWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           let text = firstResponder as? NSTextView, text.selectedRange().length > 0 {
            text.copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
