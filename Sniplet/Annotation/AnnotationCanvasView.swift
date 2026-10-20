import AppKit
import CoreImage

enum CanvasZoomCommand: Equatable { case fit, actual, percent(Int) }

private final class CenteredCanvasClipView: NSClipView {
    var preservesDocumentPosition = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        if preservesDocumentPosition { return proposedBounds }
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width { rect.origin.x = (documentView.frame.width-rect.width)/2 }
        if rect.height > documentView.frame.height { rect.origin.y = (documentView.frame.height-rect.height)/2 }
        return rect
    }
}

final class AnnotationScrollView: NSScrollView {
    let canvas: AnnotationCanvasView
    private var fitsWindow = true
    private var previousBackingScale: CGFloat = 0
    private var previousViewportSize: CGSize = .zero

    init(editor: AnnotationEditor) {
        canvas = AnnotationCanvasView(editor: editor)
        super.init(frame: .zero)
        contentView = CenteredCanvasClipView()
        documentView = canvas
        hasHorizontalScroller = true
        hasVerticalScroller = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 4
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ command: CanvasZoomCommand) {
        canvas.editor.commitTextEditing()
        (contentView as? CenteredCanvasClipView)?.preservesDocumentPosition = false
        switch command {
        case .fit: fitsWindow = true; fitCanvas()
        case .actual: fitsWindow = false; magnification = 1
        case let .percent(value): fitsWindow = false; magnification = CGFloat(value)/100
        }
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        synchronizePresentation()
    }

    /// Crop changes keep the existing zoom and frozen-source pixel positions.
    func preserveSelectionPresentation() {
        fitsWindow = false
        (contentView as? CenteredCanvasClipView)?.preservesDocumentPosition = true
    }

    func positionImageOrigin(_ origin: CGPoint, in reference: NSView) {
        let current = canvas.convert(CGPoint.zero, to: contentView)
        let target = contentView.convert(origin, from: reference)
        contentView.scroll(to: CGPoint(x: contentView.bounds.minX + current.x - target.x,
                                      y: contentView.bounds.minY + current.y - target.y))
        reflectScrolledClipView(contentView)
    }

    func synchronizePresentation() {
        let reference = superview
        let savedOrigin = (contentView as? CenteredCanvasClipView)?.preservesDocumentPosition == true
            ? reference.map { canvas.convert(CGPoint.zero, to: $0) } : nil
        let backing = window?.backingScaleFactor ?? 1
        let document = canvas.editor.document
        let presentation = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                          sourceScale: document.capture.sourceScale).presentationBounds
        let geometryChanged = previousBackingScale != backing || canvas.bounds != presentation
        if geometryChanged {
            previousBackingScale = backing
            canvas.setFrameSize(NSSize(width: presentation.width/backing, height: presentation.height/backing))
            canvas.bounds = presentation
            canvas.needsDisplay = true
        }
        let viewportChanged = previousViewportSize != contentSize
        previousViewportSize = contentSize
        if fitsWindow, geometryChanged || viewportChanged { fitCanvas() }
        if geometryChanged, let reference, let savedOrigin { positionImageOrigin(savedOrigin, in: reference) }
    }

    private func fitCanvas() {
        guard canvas.frame.width > 0, canvas.frame.height > 0, contentSize.width > 0 else { return }
        let fit = min(contentSize.width/canvas.frame.width, contentSize.height/canvas.frame.height)
        let target = min(4, max(0.25, fit))
        if abs(magnification-target) > 0.0001 { magnification = target }
    }


    override func magnify(with event: NSEvent) {
        fitsWindow = false
        (contentView as? CenteredCanvasClipView)?.preservesDocumentPosition = false
        canvas.editor.commitTextEditing()
        super.magnify(with: event)
    }
}

/// AppKit supplies precise pointer/responder/IME behavior; all document mutations go through the editor.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let editor: AnnotationEditor
    var onConfirmScreenshot: (() -> Void)?
    var onCancelScreenshot: (() -> Void)?
    /// Empty select-mode drags move the captured region (and re-crop the frozen source).
    var allowsCaptureSelectionMove = true
    /// Parent surfaces crop failures; the gesture itself always restores first.
    var onSelectionMoveError: ((String) -> Void)?
    var isEditable = true {
        didSet { textView?.isEditable = canEdit }
    }
    private var canEdit: Bool { isEditable && editor.isValid && editor.isInteractionEnabled }
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let preview = AnnotationPreviewCoordinator()
    private var previewGeometry: CaptureStyleGeometry
    private var cornerMask: CGImage?
    private var cornerMaskSize: CGSize = .zero
    private var cornerMaskRadius: CGFloat = -1
    private var previewPreparationError: (any Error)?
    private var presentationSource: CGImage?
    private var presentationStyle: CaptureStyle?
    private var presentationSourceScale: CGFloat = 0
    var onPreviewStateChange: ((AnnotationPreviewCoordinator.State) -> Void)?
    var previewState: AnnotationPreviewCoordinator.State {
        if let previewPreparationError { return .failed(previewPreparationError.localizedDescription) }
        return preview.state
    }
    private var dragStart: CGPoint?
    /// Global AppKit start point of a capture-frame move; nil for annotation gestures.
    private var selectionMoveStart: CGPoint?
    private var selectionMoveScale = CGSize(width: 1, height: 1)
    private var original: Annotation?
    private var dragHandle: AnnotationHandle?
    private var creation: Annotation?
    private var textView: AnnotationTextInputView?
    private var textAnnotation: Annotation?
    private var axElements: [UUID: AnnotationAccessibilityElement] = [:]
    private var accessibilityObjectCount = 0
    private var accessibilitySelection: UUID?
    private var lastRenderError: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { canEdit ? editor.undoManager : nil }
    private var pixelTolerance: CGFloat {
        AnnotationGeometry.imageTolerance(screenPoints: 6, backingScale: window?.backingScaleFactor ?? 1,
                                          magnification: enclosingScrollView?.magnification ?? 1)
    }

    init(editor: AnnotationEditor) {
        self.editor = editor
        previewGeometry = editor.document.captureStyle.geometry(imageSize: editor.document.imageBounds.size,
                                                                sourceScale: editor.document.capture.sourceScale)
        super.init(frame: editor.document.imageBounds)
        editor.commitTextHandler = { [weak self] in self?.commitPendingInteraction() }
        editor.invalidateHandler = { [weak self] in self?.removeTextInput() }
        editor.changeHandler = { [weak self] rect in self?.documentChanged(rect) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图标注画布")
        setAccessibilityHelp("使用工具栏创建标注。Tab 选择对象，方向键移动，Shift 加方向键移动十像素，Delete 删除。文字可双击编辑。")
        preview.onChange = { [weak self] state in
            self?.needsDisplay = true
            self?.onPreviewStateChange?(state)
        }
        updatePresentationResources()
    }

    required init?(coder: NSCoder) { nil }

    private var cursorTracking: NSTrackingArea?

    func detach() {
        finishTextEditing()
        editor.commitTextHandler = nil
        editor.changeHandler = nil
        editor.invalidateHandler = nil
        onConfirmScreenshot = nil
        onCancelScreenshot = nil
        onSelectionMoveError = nil
        resetGesture()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        cursorTracking = nil
        axElements.removeAll()
        preview.detach()
        onPreviewStateChange = nil
        cornerMask = nil
        presentationSource = nil
        presentationStyle = nil
        previewPreparationError = nil
    }

    private func documentChanged(_ rect: CGRect) {
        updatePresentationResources()
        setNeedsDisplay(rect.insetBy(dx: -pixelTolerance*3, dy: -pixelTolerance*3))
        if accessibilityObjectCount != editor.document.annotations.count {
            accessibilityObjectCount = editor.document.annotations.count
            let ids = Set(editor.document.annotations.map(\.id))
            axElements = axElements.filter { ids.contains($0.key) }
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        if accessibilitySelection != editor.selectedID {
            accessibilitySelection = editor.selectedID
            NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        }
    }

    private func updatePresentationResources() {
        let document = editor.document
        if presentationSource === document.capture.image, presentationStyle == document.captureStyle,
           presentationSourceScale == document.capture.sourceScale { return }
        let style = document.captureStyle.normalized
        let geometry = style.geometry(imageSize: document.imageBounds.size,
                                      sourceScale: document.capture.sourceScale)
        previewGeometry = geometry
        do {
            // Only the cheap native-pixel coverage mask stays synchronous; never alpha shadows.
            if cornerMaskSize != document.imageBounds.size || cornerMaskRadius != geometry.cornerRadius {
                let mask = geometry.cornerRadius > 0
                    ? try AnnotationCompositor.makeCornerMask(size: document.imageBounds.size,
                                                              radius: geometry.cornerRadius) : nil
                cornerMask = mask
                cornerMaskSize = document.imageBounds.size
                cornerMaskRadius = geometry.cornerRadius
            }
            previewPreparationError = nil
            presentationSource = document.capture.image
            presentationStyle = document.captureStyle
            presentationSourceScale = document.capture.sourceScale
            let request = geometry.shadowLayers.isEmpty ? nil : AnnotationShadowRequest(
                source: document.capture.image, style: style, sourceScale: document.capture.sourceScale,
                geometry: geometry, cornerMask: cornerMask)
            preview.update(request)
        } catch {
            previewPreparationError = error
            preview.update(nil)
            onPreviewStateChange?(.failed(error.localizedDescription))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        do {
            if let previewPreparationError { throw previewPreparationError }
            try AnnotationCompositor.drawPreview(editor.document, in: context, ciContext: ciContext,
                                                  geometry: previewGeometry, cornerMask: cornerMask,
                                                  shadow: preview.shadow)
            if lastRenderError != nil { setAccessibilityValue("") }
            lastRenderError = nil
        } catch {
            // Never show an unredacted image as if a failed mosaic preview succeeded.
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(dirtyRect)
            lastRenderError = error.localizedDescription
            setAccessibilityValue(error.localizedDescription)
            let message = NSAttributedString(string: error.localizedDescription, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor
            ])
            message.draw(in: visibleRect.insetBy(dx: 12, dy: 12))
            return
        }
        guard let item = editor.selectedAnnotation, textView == nil else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let unit = pixelTolerance/6
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(unit)
        context.setLineDash(phase: 0, lengths: [4*unit, 3*unit])
        context.stroke(AnnotationGeometry.bounds(item).insetBy(dx: -2*unit, dy: -2*unit))
        context.setLineDash(phase: 0, lengths: [])
        for (_, point) in AnnotationGeometry.handles(item) {
            let rect = CGRect(x: point.x-3*unit, y: point.y-3*unit, width: 6*unit, height: 6*unit)
            context.setFillColor(NSColor.controlBackgroundColor.cgColor)
            context.fill(rect)
            context.stroke(rect)
        }
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let bounds = editor.document.imageBounds
        return CGPoint(x: min(bounds.maxX, max(0, point.x)), y: min(bounds.maxY, max(0, point.y)))
    }

    /// Global AppKit point (bottom-left origin). The canvas frame moves while the capture
    /// region is re-cropped, so frame movement deltas must never come from view coordinates.
    private func globalScreenPoint(_ event: NSEvent) -> CGPoint? {
        window?.convertPoint(toScreen: event.locationInWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
    }

    /// Dynamic cursor: open hand means an empty select drag moves the capture frame;
    /// drawing tools keep a crosshair and text keeps the insertion beam.
    override func cursorUpdate(with event: NSEvent) {
        guard canEdit,
              editor.document.imageBounds.contains(convert(event.locationInWindow, from: nil)) else {
            NSCursor.arrow.set()
            return
        }
        switch editor.selectedTool {
        case .select:
            (allowsCaptureSelectionMove && editor.canMoveCaptureSelection ? NSCursor.openHand : .arrow).set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard canEdit else { return }
        guard editor.document.imageBounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        finishTextEditing()
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        dragStart = point
        if editor.selectedTool == .select {
            if let item = editor.selectedAnnotation,
               let handle = AnnotationGeometry.handles(item).first(where: { hypot($0.1.x-point.x, $0.1.y-point.y) <= pixelTolerance }) {
                original = item
                dragHandle = handle.0
                editor.beginTransaction(id: item.id, actionName: "调整标注")
                return
            }
            let hit = editor.hitTest(point, tolerance: pixelTolerance)
            editor.select(hit?.id)
            if event.clickCount == 2, let hit, hit.kind == .text { startTextEditing(hit); return }
            if let hit {
                original = hit
                editor.beginTransaction(id: hit.id)
            } else if allowsCaptureSelectionMove, editor.canMoveCaptureSelection,
                      let start = globalScreenPoint(event) {
                // Only empty image space reaches here: handles and object hits returned above.
                if editor.beginSelectionAdjustment() {
                    dragStart = nil
                    selectionMoveStart = start
                    if let source = editor.regionSelection?.screenRect {
                        let displayed = convert(editor.document.imageBounds, to: nil)
                        selectionMoveScale = CGSize(width: source.width / displayed.width,
                                                    height: source.height / displayed.height)
                    }
                    NSCursor.closedHand.set()
                    return
                }
            }
        } else if editor.selectedTool == .text {
            let scale = editor.document.capture.sourceScale
            let bounds = editor.document.imageBounds
            let rect = CGRect(x: point.x, y: point.y,
                              width: max(1, min(240*scale, bounds.width-point.x)),
                              height: max(1, min(100*scale, bounds.height-point.y)))
            startTextEditing(Annotation(payload: .text(rect: rect, text: ""), style: editor.style))
        } else if let kind = editor.selectedTool.kind {
            let rect = CGRect(origin: point, size: .zero)
            let payload: AnnotationPayload = switch kind {
            case .arrow: .arrow(start: point, end: point)
            case .rectangle: .rectangle(rect: rect)
            case .pen: .pen(points: [point])
            case .mosaic: .mosaic(rect: rect, blockSize: editor.mosaicBlockSize)
            case .highlight: .highlight(rect: rect)
            case .text: .text(rect: rect, text: "")
            }
            let item = Annotation(payload: payload, style: editor.style)
            creation = item
            editor.beginTransaction(id: item.id, actionName: "创建\(kind.label)")
            editor.updateTransaction(item)
            editor.select(item.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if selectionMoveStart != nil {
            guard canEdit else { return }
            moveCaptureSelection(with: event)
            return
        }
        guard canEdit, let start = dragStart else { return }
        let point = imagePoint(event)
        if let original {
            let updated: Annotation
            if let dragHandle { updated = AnnotationGeometry.resized(original, handle: dragHandle, to: point) }
            else { updated = AnnotationGeometry.translated(original, by: CGSize(width: point.x-start.x, height: point.y-start.y)) }
            editor.updateTransaction(updated)
        } else if var item = creation {
            let rect = AnnotationGeometry.rect(from: start, to: point)
            item.payload = switch item.payload {
            case .arrow: .arrow(start: start, end: point)
            case .rectangle: .rectangle(rect: rect)
            case let .pen(points): .pen(points: points + [point])
            case let .mosaic(_, block): .mosaic(rect: rect, blockSize: block)
            case .highlight: .highlight(rect: rect)
            case .text: item.payload
            }
            creation = item
            editor.updateTransaction(item)
        }
    }

    /// The model maps total global point displacement to source pixels and re-crops the
    /// frozen image, so the canvas frame moving underneath cannot introduce drift.
    private func moveCaptureSelection(with event: NSEvent) {
        guard let start = selectionMoveStart, let point = globalScreenPoint(event) else { return }
        NSCursor.closedHand.set()
        let delta = CGSize(width: (point.x - start.x) * selectionMoveScale.width,
                           height: (point.y - start.y) * selectionMoveScale.height)
        do {
            try editor.updateSelectionAdjustment(by: delta)
        } catch {
            // Restore model/frame to the gesture start, then report once and stop dragging.
            editor.cancelSelectionAdjustment()
            resetGesture()
            onSelectionMoveError?(error.localizedDescription)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if selectionMoveStart != nil {
            // Also ends the move when an export/finalize disabled editing mid-gesture;
            // the model ignores this if it already committed the gesture.
            editor.endSelectionAdjustment()
            resetGesture()
            return
        }
        guard canEdit else { return }
        guard textView == nil else { resetGesture(); return }
        let invalidCreation = creation.map { item -> Bool in
            if case let .arrow(a, b) = item.payload { return hypot(a.x-b.x, a.y-b.y) < 1 }
            if item.kind == .pen { return false }
            let rect = AnnotationGeometry.bounds(item)
            return rect.width < 1 || rect.height < 1
        } ?? false
        if invalidCreation {
            editor.cancelTransaction()
            editor.select(nil)
        } else {
            editor.endTransaction()
            if creation != nil { editor.selectedTool = .select }
        }
        resetGesture()
    }

    private func resetGesture() {
        let wasMovingSelection = selectionMoveStart != nil
        dragStart = nil; original = nil; creation = nil; dragHandle = nil
        selectionMoveStart = nil
        if wasMovingSelection { restoreHoverCursor() }
    }

    /// Leave the closed hand after a frame move without fighting toolbar/cursor rects.
    private func restoreHoverCursor() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard canEdit, editor.document.imageBounds.contains(point) else { NSCursor.arrow.set(); return }
        switch editor.selectedTool {
        case .select:
            (allowsCaptureSelectionMove && editor.canMoveCaptureSelection ? NSCursor.openHand : .arrow).set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape cancels only the frame move; it must not discard the whole capture.
        if selectionMoveStart != nil {
            editor.cancelSelectionAdjustment()
            resetGesture()
            return
        }
        guard canEdit else { return }
        if let textView, textView.hasMarkedText() { textView.cancelOperation(sender); return }
        if textView != nil { cancelTextEditing(); return }
        if dragStart != nil {
            editor.cancelTransaction()
            resetGesture()
        } else {
            onCancelScreenshot?()
        }
    }

    override func keyDown(with event: NSEvent) {
        // A frame move may still be active when export/finalize disabled editing.
        if event.keyCode == 53, selectionMoveStart != nil { cancelOperation(nil); return }
        guard canEdit else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { editor.redo() } else { editor.undo() }
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: editor.deleteSelected()
        case 123: editor.moveSelected(by: CGSize(width: -step, height: 0))
        case 124: editor.moveSelected(by: CGSize(width: step, height: 0))
        case 125: editor.moveSelected(by: CGSize(width: 0, height: step))
        case 126: editor.moveSelected(by: CGSize(width: 0, height: -step))
        case 53: cancelOperation(nil)
        case 48:
            let items = editor.document.annotations
            guard !items.isEmpty else { super.keyDown(with: event); return }
            let backwards = event.modifierFlags.contains(.shift)
            let current = items.firstIndex(where: { $0.id == editor.selectedID })
            let next = (current ?? (backwards ? items.count : -1)) + (backwards ? -1 : 1)
            if next < 0 { window?.selectPreviousKeyView(self) }
            else if next >= items.count { window?.selectNextKeyView(self) }
            else { editor.select(items[next].id) }
        case 36, 76:
            onConfirmScreenshot?()
        default: super.keyDown(with: event)
        }
    }

    private func startTextEditing(_ annotation: Annotation) {
        guard case let .text(rect, string) = annotation.payload else { return }
        textAnnotation = annotation
        editor.select(annotation.id)
        editor.beginTransaction(id: annotation.id, actionName: string.isEmpty ? "创建文字" : "编辑文字")
        let input = AnnotationTextInputView(frame: rect)
        input.string = string
        input.font = NSFont.systemFont(ofSize: annotation.style.fontSize)
        input.textColor = NSColor(cgColor: annotation.style.color.cgColor)
        input.backgroundColor = .textBackgroundColor
        input.drawsBackground = true
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.textContainerInset = .zero
        input.textContainer?.lineFragmentPadding = 0
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = false
        input.textContainer?.containerSize = rect.size
        input.textContainer?.widthTracksTextView = true
        input.delegate = self
        input.onCommit = { [weak self] in self?.finishTextEditing() }
        input.onCancel = { [weak self] in self?.cancelTextEditing() }
        input.setAccessibilityLabel("标注文字，多行输入，Command Return 提交")
        textView = input
        addSubview(input)
        window?.makeFirstResponder(input)
        input.selectAll(nil)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let input = textView, var annotation = textAnnotation,
              case let .text(rect, _) = annotation.payload else { return }
        annotation.payload = .text(rect: rect, text: input.string)
        // Invalidates in-flight OCR even before the native text field is committed.
        editor.updateTransaction(annotation)
    }
    private func commitPendingInteraction() {
        finishTextEditing()
        editor.endTransaction()
        resetGesture()
    }


    private func finishTextEditing() {
        guard let input = textView else { return }
        input.unmarkText()
        textDidChange(Notification(name: NSText.didChangeNotification))
        if input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let existing = textAnnotation.flatMap { annotation in
                if case let .text(_, string) = annotation.payload { return !string.isEmpty }
                return false
            } ?? false
            editor.cancelTransaction()
            if existing { editor.deleteSelected() }
        } else {
            editor.endTransaction()
            editor.selectedTool = .select
        }
        removeTextInput()
    }

    private func cancelTextEditing() {
        editor.cancelTransaction()
        if editor.selectedAnnotation == nil { editor.select(nil) }
        removeTextInput()
    }

    private func removeTextInput() {
        textView?.delegate = nil
        textView?.onCommit = nil
        textView?.onCancel = nil
        textView?.removeFromSuperview()
        textView = nil
        textAnnotation = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = editor.document.annotations.map { annotation in
            if let element = axElements[annotation.id] { return element }
            let element = AnnotationAccessibilityElement(canvas: self, id: annotation.id)
            axElements[annotation.id] = element
            return element
        }
        if let textView { children.append(textView) }
        return children
    }

    fileprivate func selectFromAccessibility(_ id: UUID) {
        guard canEdit else { return }
        finishTextEditing()
        editor.select(id)
        editor.selectedTool = .select
        window?.makeFirstResponder(self)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }
}

private final class AnnotationTextInputView: LocalCopyTextView {
    private let nativeTextUndoManager = UndoManager()
    override var undoManager: UndoManager? { nativeTextUndoManager }
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.contains(.command), [36, 76].contains(event.keyCode) {
            onCommit?()
        } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onCancel?() }
    }
}

nonisolated private final class AnnotationAccessibilityElement: NSAccessibilityElement {
    private let canvasProvider: @MainActor @Sendable () -> AnnotationCanvasView?
    private let id: UUID

    @MainActor
    init(canvas: AnnotationCanvasView, id: UUID) {
        canvasProvider = { [weak canvas] in canvas }
        self.id = id
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("annotation-\(id.uuidString)")
        setAccessibilityHelp("按下选择。方向键移动、Delete 删除、Command Z 撤销；文字可双击编辑。Return 复制截图。")
    }

    override func accessibilityLabel() -> String? {
        let canvas = canvasProvider
        let id = id
        return MainActor.assumeIsolated {
            guard let annotation = canvas()?.editor.document.annotations.first(where: { $0.id == id }) else { return nil }
            if case let .text(_, string) = annotation.payload { return "文字：\(string)" }
            return annotation.kind.label
        }
    }

    override func accessibilityFrame() -> NSRect {
        let canvas = canvasProvider
        let id = id
        return MainActor.assumeIsolated {
            guard let canvas = canvas(),
                  let annotation = canvas.editor.document.annotations.first(where: { $0.id == id }),
                  let window = canvas.window else { return .zero }
            return window.convertToScreen(canvas.convert(AnnotationGeometry.bounds(annotation), to: nil))
        }
    }

    override func isAccessibilitySelected() -> Bool {
        let canvas = canvasProvider
        let id = id
        return MainActor.assumeIsolated { canvas()?.editor.selectedID == id }
    }

    override func accessibilityPerformPress() -> Bool {
        let canvas = canvasProvider
        let id = id
        return MainActor.assumeIsolated {
            guard let canvas = canvas(), canvas.isEditable, canvas.editor.isInteractionEnabled, canvas.editor.isValid else { return false }
            canvas.selectFromAccessibility(id)
            return true
        }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        let canvas = canvasProvider
        let id = id
        MainActor.assumeIsolated {
            if selected { canvas()?.selectFromAccessibility(id) }
        }
    }
}
