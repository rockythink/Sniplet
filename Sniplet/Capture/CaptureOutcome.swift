import AppKit

@MainActor struct CaptureOutcome {
    let capture: CapturedImage
    /// The actual original-image footprint, in global AppKit points (before decoration).
    let screenRect: CGRect
    let host: InlineCaptureHost
    let regionSelection: CaptureRegionSelection?

    init(capture: CapturedImage, screenRect: CGRect, host: InlineCaptureHost,
         regionSelection: CaptureRegionSelection? = nil) {
        self.capture = capture
        self.screenRect = screenRect
        self.host = host
        self.regionSelection = regionSelection
    }
}

/// The selection controller's ownership boundary, independent of presentation. Taking a
/// host removes it before general cancellation, so cleanup cannot close the adopted editor.
@MainActor final class InlineCaptureHostSet {
    private var hosts: [CGDirectDisplayID: InlineCaptureHost] = [:]
    subscript(_ id: CGDirectDisplayID) -> InlineCaptureHost? { hosts[id] }
    var windowIDs: Set<CGWindowID> {
        Set(hosts.values.compactMap { host in
            guard let number = host.panel?.windowNumber, number > 0 else { return nil }
            return CGWindowID(number)
        })
    }
    isolated deinit { close() }

    func insert(_ host: InlineCaptureHost, for id: CGDirectDisplayID) {
        if let old = hosts.updateValue(host, forKey: id), old !== host { old.close() }
    }

    func retainOnly(_ id: CGDirectDisplayID) {
        for other in Array(hosts.keys) where other != id {
            hosts.removeValue(forKey: other)?.close()
        }
    }

    func take(_ id: CGDirectDisplayID) -> InlineCaptureHost? {
        hosts.removeValue(forKey: id)
    }

    func close() {
        for host in hosts.values { host.close() }
        hosts.removeAll()
    }
}

/// Owns the *same* borderless surface from selection through editing. Creation is lazy so
/// cancellation/ownership tests require neither a window nor screen-capture permission.
@MainActor final class InlineCaptureHost {
    private(set) var screenFrame: CGRect
    private(set) var displayID: CGDirectDisplayID?
    private(set) var rootView: InlineCaptureBackdropView?
    private(set) var isClosed = false
    private(set) var hasPresented = false
    private var panelStorage: InlineCapturePanel?
    var panel: InlineCapturePanel? { panelStorage }
    var panelWindowID: CGWindowID? {
        guard let number = panel?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }

    init(screenFrame: CGRect, displayID: CGDirectDisplayID? = nil, snapshot: CGImage? = nil,
         selectionAppearance: CaptureSelectionAppearance = .standard) {
        self.screenFrame = screenFrame
        self.displayID = displayID
        let root = InlineCaptureBackdropView(frame: CGRect(origin: .zero, size: screenFrame.size))
        root.selectionAppearance = selectionAppearance
        root.setSnapshot(snapshot)
        rootView = root
    }

    isolated deinit { close() }

    func present() {
        guard !isClosed, let rootView else { return }
        if panelStorage == nil {
            // Never toggle nonactivatingPanel after creation: native text/IME needs a key panel.
            let panel = InlineCapturePanel(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.setFrame(screenFrame, display: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.canHide = false
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = rootView
            panelStorage = panel
        }
        hasPresented = true
        panelStorage?.makeKeyAndOrderFront(nil)
    }

    func setSnapshot(_ image: CGImage?) { rootView?.setSnapshot(image) }

    func lockSelection(_ globalRect: CGRect) {
        rootView?.selection = globalRect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        rootView?.lockForEditing()
    }

    /// When a display disappears, keep the unsaved document but discard the obsolete backdrop.
    /// The editor lays its image and controls out again in this now-accessible host.
    func relocate(to frame: CGRect, displayID: CGDirectDisplayID?) {
        guard !isClosed else { return }
        screenFrame = frame
        self.displayID = displayID
        rootView?.setSnapshot(nil)
        rootView?.frame = CGRect(origin: .zero, size: frame.size)
        panelStorage?.setFrame(frame, display: true)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        rootView?.tearDown()
        panelStorage?.onCopy = nil
        panelStorage?.onSave = nil
        panelStorage?.onFinish = nil
        panelStorage?.onCancel = nil
        panelStorage?.delegate = nil
        panelStorage?.orderOut(nil)
        panelStorage?.contentView = nil
        panelStorage?.close()
        panelStorage = nil
        rootView = nil
    }
}

@MainActor final class InlineCapturePanel: NSPanel {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Native editing always wins, including OCR's selected text and marked IME text.
        if let text = firstResponder as? NSTextView {
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                text.copy(nil)
                return true
            }
            if [36, 76, 53].contains(event.keyCode) { return super.performKeyEquivalent(with: event) }
        }
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where onCopy != nil: onCopy?(); return true
            case "s" where onSave != nil: onSave?(); return true
            default: break
            }
            if [36, 76].contains(event.keyCode), let onFinish { onFinish(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if [36, 76].contains(event.keyCode), flags.isEmpty, let onCopy { onCopy() }
        else if event.keyCode == 53, let onCancel { onCancel() }
        else { super.keyDown(with: event) }
    }
}

/// Selection chrome and frozen backdrop stay in the transferred host. Both native canvas
/// and independent toolbars become subviews, as in CapCap's SelectionView/EditWindowController.
/// Adapted from realskyrin/CapCap (MIT), commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
@MainActor final class InlineCaptureBackdropView: NSView {
    private var snapshot: NSImage?
    var hasSnapshot: Bool { snapshot != nil }
    private var storedSelectionAppearance: CaptureSelectionAppearance = .standard
    /// Selection-only chrome; changing it never invalidates the frozen editing backdrop.
    var selectionAppearance: CaptureSelectionAppearance {
        get { storedSelectionAppearance }
        set {
            let normalized = newValue.normalized
            guard normalized != storedSelectionAppearance else { return }
            storedSelectionAppearance = normalized
            if !hasEditorContent { needsDisplay = true }
        }
    }
    var selection: CGRect? { didSet { needsDisplay = true } }
    /// Window hover uses a CleanShot-like strong accent treatment, distinct from region dashes.
    var isHoverHighlight = false { didSet { needsDisplay = true } }
    var instruction = "拖动选择区域 · 单击截取窗口 · Esc 取消" { didSet { needsDisplay = true } }
    private(set) var isLocked = false
    var hasEditorContent = false { didSet { needsDisplay = true } }
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSnapshot(_ image: CGImage?) {
        snapshot = image.map { NSImage(cgImage: $0, size: bounds.size) }
        needsDisplay = true
    }

    func lockForEditing() {
        isLocked = true
        isHoverHighlight = false
        instruction = ""
        onDown = nil; onDrag = nil; onUp = nil; onMove = nil
        window?.invalidateCursorRects(for: self)
    }

    func tearDown() {
        onDown = nil; onDrag = nil; onUp = nil; onMove = nil; onCancel = nil
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        snapshot = nil
        for view in subviews { view.removeFromSuperview() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: isLocked ? .arrow : .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    private func globalPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    }
    override func mouseDown(with event: NSEvent) { onDown?(globalPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onDrag?(globalPoint(event)) }
    override func mouseUp(with event: NSEvent) { onUp?(globalPoint(event)) }
    override func mouseMoved(with event: NSEvent) { onMove?(globalPoint(event)) }
    override func mouseEntered(with event: NSEvent) { onMove?(globalPoint(event)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        snapshot?.draw(in: bounds)
        NSColor.black.withAlphaComponent(isHoverHighlight ? 0.52 : 0.32).setFill()
        bounds.fill()
        if !hasEditorContent, let selection, !selection.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            if let snapshot {
                snapshot.draw(in: bounds)
            } else {
                // Show the live screen through the selection until the frozen frame arrives.
                NSColor.clear.setFill()
                selection.fill(using: .copy)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard !hasEditorContent else { return } // editing chrome is above the canvas, not beneath it
        if let selection, !selection.isEmpty {
            let color = selectionAppearance.color
            let selectionColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            if isHoverHighlight {
                let path = NSBezierPath(roundedRect: selection.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
                selectionColor.withAlphaComponent(0.16).setFill()
                path.fill()
                selectionColor.setStroke()
                path.lineWidth = 2
                path.stroke()
            } else {
                selectionColor.setStroke()
                let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
                let pattern = selectionAppearance.lineStyle.dashPattern
                pattern.withUnsafeBufferPointer {
                    border.setLineDash($0.baseAddress, count: $0.count, phase: 0)
                }
                border.lineCapStyle = selectionAppearance.lineStyle == .dotted ? .round : .butt
                border.lineWidth = 1
                border.stroke()
            }
        }
        guard !instruction.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let text = instruction as NSString
        let size = text.size(withAttributes: attributes)
        let box = CGRect(x: max(8, (bounds.width-size.width)/2-10), y: max(8, bounds.height-68), width: min(size.width+20, max(1, bounds.width-16)), height: 32)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(in: box.insetBy(dx: 10, dy: 7), withAttributes: attributes)
    }
}

/// Inverse of outward pixel rounding; crop and on-screen canvas use exactly the same footprint.
nonisolated enum CaptureFootprint {
    static func regionRect(_ rect: CGRect, screenFrame: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width >= 1, imageSize.height >= 1,
              imageSize.width < CGFloat(Int.max), imageSize.height < CGFloat(Int.max) else { return nil }
        guard let pixels = DisplayGeometry.pixelRect(for: rect, screenFrame: screenFrame,
                                                     imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height)) else { return nil }
        let sx = screenFrame.width/imageSize.width
        let sy = screenFrame.height/imageSize.height
        return CGRect(x: screenFrame.minX + pixels.minX*sx,
                      y: screenFrame.maxY - pixels.maxY*sy, width: pixels.width*sx, height: pixels.height*sy)
    }

    /// Presentation bounds have a top-left image-pixel origin, often negative for shadow padding.
    static func presentationRect(_ bounds: CGRect, imageSize: CGSize, sourceRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return sourceRect }
        let sx = sourceRect.width/imageSize.width
        let sy = sourceRect.height/imageSize.height
        return CGRect(x: sourceRect.minX + bounds.minX*sx, y: sourceRect.maxY - bounds.maxY*sy,
                      width: bounds.width*sx, height: bounds.height*sy)
    }
}
