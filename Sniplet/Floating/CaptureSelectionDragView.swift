import AppKit
import QuartzCore

/// Root-sized transparent pointer surface. Only crop edges intercept primary presses;
/// blank image dragging, annotation handles, text and toolbar events stay with their owners.
final class CaptureSelectionDragView: NSView {

    private let editor: AnnotationEditor


    /// Displayed image bounds in this view's unflipped AppKit coordinates.
    /// These are shared with the visible outline, including canvas zoom and scrolling.
    var selectionRect: CGRect? {
        didSet {
            guard selectionRect != oldValue else { return }
            updateAffordances()
            refreshHoverCursor()
        }
    }

    var clippingRect: CGRect = .zero {
        didSet {
            guard clippingRect != oldValue else { return }
            updateAffordances()
            refreshHoverCursor()
        }
    }

    /// Usable screen area, excluding the menu bar and Dock, in this view's coordinates.
    var interactionBounds: CGRect? {
        didSet {
            guard interactionBounds != oldValue else { return }
            updateAffordances()
            refreshHoverCursor()
        }
    }

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { cancelActiveAdjustment() }
            updateAffordances()
            refreshHoverCursor()
        }
    }

    var selectionAppearance: CaptureSelectionAppearance = .standard {
        didSet {
            guard selectionAppearance != oldValue else { return }
            updateColors()
        }
    }

    /// Parent excludes annotation handles and any other higher-priority controls.
    /// The point is in this view's coordinates, just like `selectionRect`.
    var permitsResizeAtPoint: ((CGPoint) -> Bool)?

    var onError: ((String) -> Void)?

    private struct Adjustment {
        let start: CGPoint
        let handle: CaptureSelectionResizeHandle
        let mapping: CaptureSelectionResizeMapping
        var hasMoved = false
    }

    private var adjustment: Adjustment?
    private weak var previousFirstResponder: NSResponder?
    private weak var gestureWindow: NSWindow?
    private var previousCursor: NSCursor?
    private var tracking: NSTrackingArea?
    private weak var mouseMovedWindow: NSWindow?
    private var previousAcceptsMouseMoved = false

    // Layer-hosting, not a layer-backed draw(_:) surface: the root never allocates a
    // screen-sized bitmap. Clipping is rectangular and every visible mark is a vector.
    private let clippedLayer = CALayer()
    private static let handleOrder = CaptureSelectionResizeHandle.allCases
    private let handleLayers: [CAShapeLayer] = CaptureSelectionDragView.handleOrder.map { _ in CAShapeLayer() }
    private static let handleSize = CaptureSelectionResizeGeometry.handleSize

    init(editor: AnnotationEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        clippedLayer.masksToBounds = true
        layer?.addSublayer(clippedLayer)
        let handlePath = CGPath(rect: CGRect(x: 0.5, y: 0.5,
                                             width: Self.handleSize - 1, height: Self.handleSize - 1),
                                transform: nil)
        for handleLayer in handleLayers {
            handleLayer.lineWidth = 1
            handleLayer.path = handlePath
            clippedLayer.addSublayer(handleLayer)
        }
        updateColors()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateAffordances()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stroke = selectionAppearance.normalized.color.cgColor
        let fill = NSColor.white.cgColor
        for handle in handleLayers {
            handle.fillColor = fill
            handle.strokeColor = stroke
        }
        CATransaction.commit()
    }

    private func updateAffordances() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let clip = clippingRect.intersection(bounds)
        guard isEnabled, let rect = selectionRect,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              !clip.isNull, !clip.isEmpty else {
            clippedLayer.isHidden = true
            return
        }
        clippedLayer.isHidden = false
        clippedLayer.frame = clip
        let size = Self.handleSize
        let half = size / 2
        for (handle, handleLayer) in zip(Self.handleOrder, handleLayers) {
            guard let anchor = CaptureSelectionResizeGeometry.controlPoint(for: handle, selection: rect,
                clippingRect: clippingRect, bounds: bounds, interactionBounds: interactionBounds) else {
                handleLayer.isHidden = true
                continue
            }
            handleLayer.isHidden = false
            let x = min(max(anchor.x, clip.minX + half), max(clip.minX + half, clip.maxX - half))
            let y = min(max(anchor.y, clip.minY + half), max(clip.minY + half, clip.maxY - half))
            handleLayer.frame = CGRect(x: x - clip.minX - half, y: y - clip.minY - half,
                                       width: size, height: size)
        }
    }

    // MARK: Hit routing

    private func resizeHandle(at point: CGPoint) -> CaptureSelectionResizeHandle? {
        guard isEnabled, !isHidden, editor.canResizeCaptureSelection,
              let selectionRect,
              let handle = CaptureSelectionResizeGeometry.hit(at: point, selection: selectionRect,
                                                               clippingRect: clippingRect, bounds: bounds,
                                                               interactionBounds: interactionBounds),
              permitsResizeAtPoint?(point) != false else { return nil }
        return handle
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard window != nil, isEnabled, !isHidden else { return nil }
        if adjustment != nil { return self }
        // Non-primary presses, scroll and magnification pass through to the canvas.
        if let event = NSApp.currentEvent, event.type != .leftMouseDown { return nil }
        return resizeHandle(at: convert(point, from: superview)) == nil ? nil : self
    }

    // MARK: Cursor and lifecycle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            cancelActiveAdjustment()
            releaseCursor()
            restoreMouseMovedPolicy()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            cancelActiveAdjustment()
            releaseCursor()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            if let tracking { removeTrackingArea(tracking) }
            tracking = nil
            selectionRect = nil
            clippingRect = .zero
            interactionBounds = nil
            permitsResizeAtPoint = nil
            onError = nil
            return
        }
        if mouseMovedWindow == nil {
            previousAcceptsMouseMoved = window.acceptsMouseMovedEvents
            mouseMovedWindow = window
            window.acceptsMouseMovedEvents = true
        }
        updateAffordances()
    }

    private func restoreMouseMovedPolicy() {
        mouseMovedWindow?.acceptsMouseMovedEvents = previousAcceptsMouseMoved
        mouseMovedWindow = nil
    }

    private func cursor(for handle: CaptureSelectionResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        // Public diagonal resize cursors are newer than macOS 14. Crosshair is a
        // native, unambiguous two-axis fallback without private cursor selectors.
        case .topLeft, .topRight, .bottomRight, .bottomLeft: .crosshair
        }
    }

    private func updateHover(at point: CGPoint) {
        guard adjustment == nil else { return }
        guard let handle = resizeHandle(at: point) else {
            releaseCursor()
            return
        }
        if previousCursor == nil { previousCursor = NSCursor.current }
        cursor(for: handle).set()
    }

    private func releaseCursor() {
        previousCursor?.set()
        previousCursor = nil
    }

    private func refreshHoverCursor() {
        guard adjustment == nil else { return }
        guard isEnabled, let window, window.isKeyWindow else {
            releaseCursor()
            return
        }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        updateHover(at: local)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if let adjustment {
            cursor(for: adjustment.handle).set()
        } else {
            updateHover(at: convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseExited(with event: NSEvent) {
        if adjustment == nil { releaseCursor() }
    }

    override func resignFirstResponder() -> Bool {
        if adjustment != nil {
            // AppKit is already transferring focus. Do not recursively ask the
            // window to make the old responder first while it is resigning us.
            editor.cancelSelectionAdjustment()
            finishGesture(restoringResponder: false)
        }
        return super.resignFirstResponder()
    }

    // MARK: Gesture

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, adjustment == nil,
              let window, let start = globalPoint(event),
              let handle = resizeHandle(at: convert(event.locationInWindow, from: nil)) else { return }
        guard self.window === window, isEnabled, editor.canResizeCaptureSelection else { return }
        guard editor.beginSelectionAdjustment(resizing: handle) else {
            releaseCursor()
            onError?("当前无法调整截图区域，请完成正在进行中的操作后重试。")
            return
        }
        guard let rect = selectionRect, let source = editor.regionSelection?.screenRect,
              let mapping = CaptureSelectionResizeMapping(handle: handle, selection: rect,
                sourceSize: source.size, clippingRect: clippingRect, bounds: bounds,
                interactionBounds: interactionBounds) else {
            editor.cancelSelectionAdjustment()
            return
        }
        adjustment = Adjustment(start: start, handle: handle, mapping: mapping)
        gestureWindow = window
        previousFirstResponder = window.firstResponder
        if previousCursor == nil { previousCursor = NSCursor.current }
        guard window.makeFirstResponder(self) else {
            cancelActiveAdjustment()
            return
        }
        cursor(for: handle).set()
    }

    @discardableResult
    private func updateAdjustment(with event: NSEvent) -> Bool {
        guard let adjustment, let point = globalPoint(event) else { return false }
        cursor(for: adjustment.handle).set()
        let moved = adjustment.hasMoved || point != adjustment.start
        guard moved else { return true } // Clicking a handle alone must not change the crop.
        self.adjustment?.hasMoved = true
        let delta = adjustment.mapping.displacement(from: adjustment.start, to: point)
        do {
            try editor.updateSelectionAdjustment(by: delta)
            return true
        } catch {
            cancelActiveAdjustment()
            onError?(error.localizedDescription)
            return false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateAdjustment(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard adjustment != nil else { return }
        guard updateAdjustment(with: event) else {
            cancelActiveAdjustment()
            return
        }
        editor.endSelectionAdjustment()
        finishGesture()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, adjustment != nil {
            cancelActiveAdjustment()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if adjustment != nil { cancelActiveAdjustment() } else { super.cancelOperation(sender) }
    }

    private func cancelActiveAdjustment() {
        guard adjustment != nil else { return }
        editor.cancelSelectionAdjustment()
        finishGesture()
    }

    private func finishGesture(restoringResponder: Bool = true) {
        guard adjustment != nil else { return }
        adjustment = nil
        if restoringResponder {
            restoreFirstResponder()
        } else {
            previousFirstResponder = nil
            gestureWindow = nil
        }
        releaseCursor()
        if restoringResponder { refreshHoverCursor() }
    }

    private func restoreFirstResponder() {
        defer {
            previousFirstResponder = nil
            gestureWindow = nil
        }
        guard let window = gestureWindow, window.firstResponder === self else { return }
        if let previousFirstResponder {
            if !window.makeFirstResponder(previousFirstResponder) { window.makeFirstResponder(nil) }
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint? {
        (gestureWindow ?? window)?.convertPoint(toScreen: event.locationInWindow)
    }
}
