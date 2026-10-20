import AppKit

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    private var panels: [UUID: NSPanel] = [:]
    private let encoder = ImageEncoder()

    func pin(_ capture: RenderedCapture) {
        let id = UUID()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = NSSize(width: min(720, visible.width * 0.7), height: min(640, visible.height * 0.7))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "钉图"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: min(220, visible.width), height: min(160, visible.height))
        panel.maxSize = visible.size
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        let content = PinnedImageView(capture: capture, encoder: encoder, onClose: { [weak panel] in panel?.close() })
        panel.contentView = content
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20))
        panels[id] = panel
        panel.orderFrontRegardless()
        content.configureForDisplay(fit: true)
    }

    func closeAll() {
        let openPanels = Array(panels.values)
        for panel in openPanels { panel.close() }
        panels.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let identifier = panel.identifier,
              let id = UUID(uuidString: identifier.rawValue) else { return }
        (panel.contentView as? PinnedImageView)?.invalidate()
        panels[id] = nil
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? PinnedImageView)?.configureForDisplay(fit: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let visible = window.screen?.visibleFrame { window.maxSize = visible.size }
    }
}
