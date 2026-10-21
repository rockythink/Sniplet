import AppKit
import Observation

@MainActor @Observable final class AnnotationEditor {
    private(set) var document: AnnotationDocument
    let undoManager = UndoManager()
    var selectedTool: AnnotationTool = .select
    var selectedID: UUID?
    var style: AnnotationStyle
    var mosaicBlockSize: CGFloat = 16
    var isInteractionEnabled = true
    private(set) var isValid = true
    /// True while the canvas's text input is open; the toolbar shows text format controls.
    var isEditingText = false
    @ObservationIgnored var commitTextHandler: (() -> Void)?
    /// Applies a style to the text being typed; returns false when no text input is open.
    @ObservationIgnored var textStyleHandler: ((AnnotationStyle) -> Bool)?
    @ObservationIgnored var invalidateHandler: (() -> Void)?
    @ObservationIgnored var changeHandler: ((CGRect) -> Void)?
    @ObservationIgnored var revisionHandler: ((UInt64) -> Void)?
    @ObservationIgnored var captureStyleHandler: ((CaptureStyle) -> Void)?
    @ObservationIgnored var regionSelectionHandler: ((CaptureRegionSelection) -> Void)?
    /// The frozen source image and the current crop window into it.
    private(set) var regionSelection: CaptureRegionSelection?
    /// False without a frozen source context, or when the crop spans both source axes.
    var canMoveCaptureSelection: Bool {
        guard isValid, isInteractionEnabled, let selection = regionSelection else { return false }
        return selection.pixelRect.width < CGFloat(selection.source.image.width)
            || selection.pixelRect.height < CGFloat(selection.source.image.height)
    }
    /// Full-source region crops can still shrink; fixed captures have no resize context.
    var canResizeCaptureSelection: Bool {
        guard isValid, isInteractionEnabled, let selection = regionSelection else { return false }
        return selection.source.image.width > 1 || selection.source.image.height > 1
    }
    @ObservationIgnored private var transaction: Transaction?
    @ObservationIgnored private var captureStyleBeforeTransaction: CaptureStyle?
    @ObservationIgnored private var selectionAdjustment: SelectionAdjustment?
    @ObservationIgnored private var selectionSource: CapturedImage?
    @ObservationIgnored private var selectionScreenFrame: CGRect?
    @ObservationIgnored private var isCommittingText = false

    private struct Transaction {
        let id: UUID
        let before: Annotation?
        let index: Int
        let name: String
    }

    private struct SelectionAdjustment {
        let before: CaptureRegionSelection
        let beforeCapture: CapturedImage
        let handle: CaptureSelectionResizeHandle?
        // Array value snapshots preserve fractional coordinates exactly, with COW storage.
        // Moving the frame leaves local marks untouched and needs no annotation snapshot.
        let beforeAnnotations: [Annotation]?
    }

    init(capture: CapturedImage, captureStyle: CaptureStyle = .plain,
         regionSelection: CaptureRegionSelection? = nil) {
        document = AnnotationDocument(capture: capture, captureStyle: captureStyle.normalized)
        self.regionSelection = regionSelection
        selectionSource = regionSelection?.source
        selectionScreenFrame = regionSelection?.screenFrame
        style = AnnotationStyle(lineWidth: 2*capture.sourceScale, fontSize: 16*capture.sourceScale)
        undoManager.groupsByEvent = false
    }

    var selectedAnnotation: Annotation? { document.annotations.first { $0.id == selectedID } }
    var hasTransaction: Bool { transaction != nil }

    func commitTextEditing() {
        guard isValid, isInteractionEnabled, !isCommittingText else { return }
        // The canvas's commit handler may itself call back into the editor; never recurse
        // and never discard a transaction which that handler is still finishing.
        isCommittingText = true
        defer { isCommittingText = false }
        commitTextHandler?()
        endTransaction()
        endCaptureStyleTransaction()
        endSelectionAdjustment()
    }

    func invalidate() {
        invalidateHandler?()
        invalidateHandler = nil
        isInteractionEnabled = false
        isValid = false
        transaction = nil
        captureStyleBeforeTransaction = nil
        selectionAdjustment = nil
        selectionSource = nil
        selectionScreenFrame = nil
        regionSelection = nil
        undoManager.removeAllActions()
        commitTextHandler = nil
        textStyleHandler = nil
        isEditingText = false
        changeHandler = nil
        revisionHandler = nil
        captureStyleHandler = nil
        regionSelectionHandler = nil
    }

    func select(_ id: UUID?) {
        let old = selectedAnnotation.map(AnnotationGeometry.bounds) ?? .null
        selectedID = id
        let dirty = old.union(selectedAnnotation.map(AnnotationGeometry.bounds) ?? .null)
        if !dirty.isNull { changeHandler?(dirty) }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Annotation? {
        // Mosaics are composited last, and therefore hit before ordinary marks.
        for item in document.annotations.reversed() where item.kind == .mosaic {
            if AnnotationGeometry.hit(item, at: point, tolerance: tolerance) { return item }
        }
        for item in document.annotations.reversed() where item.kind != .mosaic {
            if AnnotationGeometry.hit(item, at: point, tolerance: tolerance) { return item }
        }
        return nil
    }

    func insert(_ annotation: Annotation, actionName: String = "创建标注") {
        guard isValid, isInteractionEnabled else { return }
        apply(id: annotation.id, value: annotation, index: document.annotations.count, registeringUndo: true, name: actionName)
        select(annotation.id)
        selectedTool = .select
    }

    func replace(_ annotation: Annotation, actionName: String = "修改标注") {
        guard isValid, isInteractionEnabled, let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        apply(id: annotation.id, value: annotation, index: index, registeringUndo: true, name: actionName)
    }

    func deleteSelected() {
        guard isValid, isInteractionEnabled, let id = selectedID, let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        apply(id: id, value: nil, index: index, registeringUndo: true, name: "删除标注")
        select(nil)
    }

    func moveSelected(by delta: CGSize) {
        guard isValid, isInteractionEnabled, let item = selectedAnnotation else { return }
        replace(AnnotationGeometry.translated(item, by: delta), actionName: "移动标注")
    }

    /// Text size and weight sit in the toolbar while text is being placed, typed or selected.
    var showsTextFormat: Bool {
        selectedTool == .text || isEditingText || selectedAnnotation?.kind == .text
    }

    /// The style the toolbar edits: the selected mark's, otherwise the next mark's.
    /// Highlight and mosaic marks keep fixed styles, so they never report one.
    var activeStyle: AnnotationStyle {
        if let item = selectedAnnotation, item.kind != .highlight, item.kind != .mosaic { return item.style }
        return style
    }

    /// Text being typed takes the change live and stays open; a selected mark records one undo step.
    func setStyle(_ newStyle: AnnotationStyle) {
        guard isValid, isInteractionEnabled else { return }
        style = newStyle
        if textStyleHandler?(newStyle) == true { return }
        guard var item = selectedAnnotation, item.kind != .highlight, item.kind != .mosaic else { return }
        item.style = newStyle
        replace(AnnotationTextLayout.refitted(item, in: document.imageBounds), actionName: "修改样式")
    }

    /// Steps through `AnnotationTextLayout.pointSizes`; returns false at either end.
    @discardableResult
    func stepFontSize(larger: Bool) -> Bool {
        let scale = document.capture.sourceScale
        let current = activeStyle.fontSize / scale
        let sizes = AnnotationTextLayout.pointSizes
        guard let next = larger ? sizes.first(where: { $0 > current + 0.01 })
                                : sizes.last(where: { $0 < current - 0.01 }) else { return false }
        var newStyle = activeStyle
        newStyle.fontSize = next * scale
        setStyle(newStyle)
        return true
    }

    func toggleBold() {
        var newStyle = activeStyle
        newStyle.isBold.toggle()
        setStyle(newStyle)
    }

    func toggleTextBackground() {
        var newStyle = activeStyle
        newStyle.hasTextBackground.toggle()
        setStyle(newStyle)
    }

    func beginCaptureStyleTransaction() {
        guard isValid, isInteractionEnabled, captureStyleBeforeTransaction == nil else { return }
        commitTextEditing()
        captureStyleBeforeTransaction = document.captureStyle
    }

    func endCaptureStyleTransaction() {
        guard isValid, isInteractionEnabled, let before = captureStyleBeforeTransaction else { return }
        captureStyleBeforeTransaction = nil
        guard before != document.captureStyle else { return }
        registerCaptureStyleUndo(before)
    }

    func setCaptureStyle(_ newStyle: CaptureStyle) {
        guard isValid, isInteractionEnabled else { return }
        if captureStyleBeforeTransaction == nil { commitTextEditing() }
        applyCaptureStyle(newStyle.normalized, registeringUndo: captureStyleBeforeTransaction == nil)
    }

    private func registerCaptureStyleUndo(_ style: CaptureStyle) {
        let createsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if createsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in editor.applyCaptureStyle(style) }
        undoManager.setActionName("修改截图样式")
        if createsGroup { undoManager.endUndoGrouping() }
    }

    private func applyCaptureStyle(_ newStyle: CaptureStyle, registeringUndo: Bool = true) {
        let old = document.captureStyle
        guard old != newStyle else { return }
        if registeringUndo { registerCaptureStyleUndo(old) }
        let size = document.imageBounds.size
        let scale = document.capture.sourceScale
        let dirty = old.geometry(imageSize: size, sourceScale: scale).presentationBounds
            .union(newStyle.geometry(imageSize: size, sourceScale: scale).presentationBounds)
        document.captureStyle = newStyle
        document.revision += 1
        // Invalidate frozen output/OCR before layout or drawing observers can run.
        revisionHandler?(document.revision)
        captureStyleHandler?(newStyle)
        changeHandler?(dirty)
    }

    func setMosaicBlockSize(_ size: CGFloat) {
        guard isValid, isInteractionEnabled else { return }
        guard [CGFloat(8), 16, 32].contains(size) else { return }
        mosaicBlockSize = size
        guard var item = selectedAnnotation, case let .mosaic(rect, _) = item.payload else { return }
        item.payload = .mosaic(rect: rect, blockSize: size)
        replace(item, actionName: "修改马赛克块大小")
    }

    /// Mouse gestures record one object delta, never a bitmap or a per-frame undo item.
    func beginTransaction(id: UUID, actionName: String = "移动标注") {
        guard isValid, isInteractionEnabled, transaction == nil else { return }
        let index = document.annotations.firstIndex { $0.id == id } ?? document.annotations.count
        transaction = Transaction(id: id, before: document.annotations.first { $0.id == id }, index: index, name: actionName)
    }

    func updateTransaction(_ annotation: Annotation) {
        guard isValid, isInteractionEnabled, let t = transaction, t.id == annotation.id else { return }
        apply(id: t.id, value: annotation, index: t.index, registeringUndo: false, name: t.name)
    }

    func endTransaction() {
        guard isValid, isInteractionEnabled, let t = transaction else { return }
        transaction = nil
        let after = document.annotations.first { $0.id == t.id }
        guard after != t.before else { return }
        registerUndo(id: t.id, value: t.before, index: t.index, name: t.name)
    }

    /// Drawing tools stay active after each mark, so the first idle Escape only leaves
    /// the tool; Escape in the select tool is what discards the capture.
    func exitDrawingTool() -> Bool {
        guard selectedTool != .select else { return false }
        selectedTool = .select
        return true
    }

    func cancelTransaction() {
        guard isValid, isInteractionEnabled, let t = transaction else { return }
        transaction = nil
        apply(id: t.id, value: t.before, index: t.index, registeringUndo: false, name: t.name)
    }

    /// Commits pending text/style interactions before starting one crop adjustment.
    @discardableResult
    func beginSelectionAdjustment(resizing handle: CaptureSelectionResizeHandle? = nil) -> Bool {
        guard handle == nil ? canMoveCaptureSelection : canResizeCaptureSelection,
              selectionAdjustment == nil, let selection = regionSelection else { return false }
        commitTextEditing()
        guard isValid, isInteractionEnabled, selectionAdjustment == nil,
              let current = regionSelection, current.pixelRect == selection.pixelRect else { return false }
        selectionAdjustment = SelectionAdjustment(before: current, beforeCapture: document.capture,
                                                   handle: handle,
                                                   beforeAnnotations: handle == nil ? nil : document.annotations)
        return true
    }

    /// `delta` is the total displacement from mouseDown, in global AppKit points.
    /// A failed crop changes neither the selection nor its annotations.
    func updateSelectionAdjustment(by delta: CGSize) throws {
        guard isValid, isInteractionEnabled, let adjustment = selectionAdjustment else { return }
        let target = if let handle = adjustment.handle {
            adjustment.before.resized(from: handle, by: delta)
        } else {
            adjustment.before.moved(by: delta)
        }
        guard target.pixelRect != regionSelection?.pixelRect else { return }
        let cropped: CapturedImage
        if target.pixelRect == adjustment.before.pixelRect {
            cropped = adjustment.beforeCapture
        } else {
            cropped = try target.croppedCapture()
        }
        var annotations: [Annotation]?
        if let before = adjustment.beforeAnnotations {
            let offset = CGSize(width: adjustment.before.pixelRect.minX - target.pixelRect.minX,
                                height: adjustment.before.pixelRect.minY - target.pixelRect.minY)
            // Work from the original snapshot, not successive floating-point translations.
            // No allocation for unchanged pointer updates or stationary crop origins.
            annotations = offset == .zero ? before : before.map { AnnotationGeometry.translated($0, by: offset) }
        }
        applySelection(target, capture: cropped, annotations: annotations)
    }

    func endSelectionAdjustment() {
        guard let adjustment = selectionAdjustment else { return }
        selectionAdjustment = nil
        guard isValid, isInteractionEnabled, let current = regionSelection,
              current.pixelRect != adjustment.before.pixelRect else { return }
        registerSelectionUndo(adjustment.before.pixelRect, mode: adjustment.beforeCapture.mode,
                              annotations: adjustment.beforeAnnotations)
    }

    /// Escape restores exact crop/annotation values without disturbing the redo branch.
    func cancelSelectionAdjustment() {
        guard let adjustment = selectionAdjustment else { return }
        selectionAdjustment = nil
        guard isValid, let current = regionSelection,
              current.pixelRect != adjustment.before.pixelRect else { return }
        applySelection(adjustment.before, capture: adjustment.beforeCapture,
                       annotations: adjustment.beforeAnnotations)
    }

    private func applySelection(_ selection: CaptureRegionSelection, capture: CapturedImage,
                                annotations: [Annotation]? = nil) {
        let oldBounds = document.imageBounds
        regionSelection = selection
        document.capture = capture
        if let annotations { document.annotations = annotations }
        document.revision += 1
        // Frozen PNG/OCR belong to the old crop; invalidate them before layout or drawing.
        revisionHandler?(document.revision)
        regionSelectionHandler?(selection)
        changeHandler?(oldBounds.union(document.imageBounds))
    }

    /// History contains crop rectangles and, only for resize, annotation value snapshots.
    /// Every crop is regenerated from the single frozen source, never from bitmap history.
    private func registerSelectionUndo(_ pixelRect: CGRect, mode: CaptureMode, annotations: [Annotation]?) {
        let createsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if createsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in
            editor.applySelectionPixelRect(pixelRect, mode: mode, annotations: annotations)
        }
        undoManager.setActionName(annotations == nil ? "移动截图选区" : "调整截图选区")
        if createsGroup { undoManager.endUndoGrouping() }
    }

    private func applySelectionPixelRect(_ rect: CGRect, mode: CaptureMode, annotations: [Annotation]?) {
        guard isValid, let source = selectionSource, let screenFrame = selectionScreenFrame,
              let selection = CaptureRegionSelection(source: source, screenFrame: screenFrame, pixelRect: rect),
              selection.pixelRect != regionSelection?.pixelRect else { return }
        let fullSource = CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height)
        let cropped: CapturedImage
        if rect == fullSource, mode == source.mode {
            cropped = source
        } else {
            guard let image = try? selection.croppedCapture() else { return }
            cropped = image
        }
        let previous = regionSelection
        let previousMode = document.capture.mode
        let previousAnnotations = annotations == nil ? nil : document.annotations
        applySelection(selection, capture: cropped, annotations: annotations)
        // UndoManager routes this registration into the redo branch.
        if let previous {
            registerSelectionUndo(previous.pixelRect, mode: previousMode, annotations: previousAnnotations)
        }
    }

    func undo() { guard isValid, isInteractionEnabled else { return }; commitTextEditing(); undoManager.undo() }
    func redo() { guard isValid, isInteractionEnabled else { return }; commitTextEditing(); undoManager.redo() }

    private func registerUndo(id: UUID, value: Annotation?, index: Int, name: String) {
        let createsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if createsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in
            editor.apply(id: id, value: value, index: index, registeringUndo: true, name: name)
            editor.select(value?.id)
        }
        undoManager.setActionName(name)
        if createsGroup { undoManager.endUndoGrouping() }
    }

    private func apply(id: UUID, value: Annotation?, index: Int, registeringUndo: Bool, name: String) {
        let currentIndex = document.annotations.firstIndex { $0.id == id }
        let old = currentIndex.map { document.annotations[$0] }
        guard old != value else { return }
        if registeringUndo { registerUndo(id: id, value: old, index: currentIndex ?? index, name: name) }
        if let currentIndex {
            if let value { document.annotations[currentIndex] = value }
            else { document.annotations.remove(at: currentIndex) }
        } else if let value {
            document.annotations.insert(value, at: min(index, document.annotations.count))
        }
        document.revision += 1
        revisionHandler?(document.revision)
        let oldBounds = old.map(AnnotationGeometry.bounds) ?? .null
        let newBounds = value.map(AnnotationGeometry.bounds) ?? .null
        changeHandler?(oldBounds.union(newBounds))
    }
}
