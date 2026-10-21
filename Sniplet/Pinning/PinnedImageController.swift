import AppKit

@MainActor
final class PinnedImageController: NSObject, NSWindowDelegate {
    private var panels: [UUID: NSPanel] = [:] { didSet { if panels.count != oldValue.count { onCountChange?(panels.count) } } }
    private let encoder = ImageEncoder()
    /// Lets the menu offer "close all" only while pins exist.
    var onCountChange: ((Int) -> Void)?

    /// `anchor` is the global screen rect the image occupied while editing. With it the pin
    /// replaces the capture in place; without it (history) pins cascade from the screen center.
    func pin(_ capture: RenderedCapture, at anchor: CGRect? = nil) {
        let id = UUID()
        let anchorScreen = anchor.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        }
        let screen = anchorScreen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let backing = screen?.backingScaleFactor ?? 2
        let natural = CGSize(width: CGFloat(capture.image.width) / backing,
                             height: CGFloat(capture.image.height) / backing)
        let frame: CGRect
        if let anchor, anchorScreen != nil {
            frame = PinnedImageLayout.anchoredFrame(size: PinnedImageLayout.fittedSize(natural, in: visible.size),
                                                    anchor: anchor, visible: visible)
        } else {
            let limit = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
            frame = PinnedImageLayout.cascadedFrame(size: PinnedImageLayout.fittedSize(natural, in: limit),
                                                    index: panels.count, visible: visible)
        }
        let panel = PinnedPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "钉图"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        let content = PinnedImageView(capture: capture, encoder: encoder, onClose: { [weak panel] in panel?.close() })
        panel.contentView = content
        panels[id] = panel
        panel.orderFrontRegardless()
        content.synchronizeZoomWithWindow()
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
        (window.contentView as? PinnedImageView)?.backingScaleDidChange()
    }
}

/// Borderless pins still take key focus for Esc/⌘C/zoom keys, without activating Sniplet.
@MainActor private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Pin window geometry in global screen points. The window always shows the whole image,
/// so its size is the zoom of the image's natural point size.
nonisolated enum PinnedImageLayout {
    static let cascadeStep: CGFloat = 24
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4
    static let minimumSide: CGFloat = 16

    /// Scales down (never up) to fit `limit`, keeping the aspect ratio.
    static func fittedSize(_ natural: CGSize, in limit: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: minimumSide, height: minimumSide) }
        let scale = min(1, limit.width / natural.width, limit.height / natural.height)
        return CGSize(width: max(1, natural.width * scale), height: max(1, natural.height * scale))
    }

    /// Moves a frame fully on screen; an oversized frame keeps its top-left corner visible.
    static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        result.origin.y = min(visible.maxY - frame.height, max(frame.minY, visible.minY))
        return result
    }

    /// Keeps the anchor's top-left corner, where the capture sat on screen.
    static func anchoredFrame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        clamped(CGRect(x: anchor.minX, y: anchor.maxY - size.height, width: size.width, height: size.height),
                to: visible)
    }

    /// Centered, then stepped down-right per open pin so new pins never cover older ones exactly.
    static func cascadedFrame(size: CGSize, index: Int, visible: CGRect) -> CGRect {
        let step = cascadeStep * CGFloat(max(0, index) % 10)
        return clamped(CGRect(x: visible.midX - size.width / 2 + step, y: visible.midY - size.height / 2 - step,
                              width: size.width, height: size.height), to: visible)
    }

    /// Limits zoom to the supported range and to what the screen can show.
    static func clampedZoom(_ zoom: CGFloat, natural: CGSize, visible: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0, zoom.isFinite else { return 1 }
        let screenLimit = min(visible.width / natural.width, visible.height / natural.height)
        let minimum = max(zoomRange.lowerBound, minimumSide / min(natural.width, natural.height))
        let maximum = max(minimum, min(zoomRange.upperBound, screenLimit))
        return min(maximum, max(minimum, zoom))
    }

    /// Resizes around the current center, then keeps the result on screen.
    static func zoomedFrame(_ frame: CGRect, natural: CGSize, zoom: CGFloat, visible: CGRect) -> CGRect {
        let size = CGSize(width: natural.width * zoom, height: natural.height * zoom)
        return clamped(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), to: visible)
    }
}
