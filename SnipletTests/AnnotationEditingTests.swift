import AppKit
import Testing
@testable import Sniplet

@MainActor struct AnnotationEditingTests {
    private func capture() throws -> CapturedImage {
        let context = try AnnotationCompositor.bitmap(width: 400, height: 300)
        let image = try #require(context.makeImage())
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .region, image: image, sourceScale: 2, displayID: 1)
    }

    private func annotation(_ kind: AnnotationKind) -> Annotation {
        let rect = CGRect(x: 20, y: 30, width: 80, height: 50)
        let payload: AnnotationPayload = switch kind {
        case .arrow: .arrow(start: rect.origin, end: CGPoint(x: 100, y: 80))
        case .rectangle: .rectangle(rect: rect)
        case .pen: .pen(points: [rect.origin, CGPoint(x: 40, y: 70), CGPoint(x: 100, y: 80)])
        case .text: .text(rect: rect, text: "本地识别\n繁體中文")
        case .mosaic: .mosaic(rect: rect, blockSize: 16)
        case .highlight: .highlight(rect: rect)
        }
        return Annotation(payload: payload)
    }

    @Test(arguments: AnnotationKind.allCases)
    func everyKindMovesAndUndoesAsOneGesture(_ kind: AnnotationKind) throws {
        let editor = AnnotationEditor(capture: try capture())
        let original = annotation(kind)
        editor.insert(original)
        let createdRevision = editor.document.revision
        editor.beginTransaction(id: original.id)
        for offset in 1...20 {
            editor.updateTransaction(AnnotationGeometry.translated(original, by: CGSize(width: offset, height: offset)))
        }
        editor.endTransaction()
        let movedRevision = editor.document.revision
        #expect(movedRevision > createdRevision)
        #expect(editor.document.annotations[0] == AnnotationGeometry.translated(original, by: CGSize(width: 20, height: 20)))
        editor.undo()
        #expect(editor.document.annotations == [original])
        #expect(editor.document.revision > movedRevision)
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
        editor.redo()
        #expect(editor.document.annotations == [original])
        editor.redo()
        #expect(editor.document.annotations[0] == AnnotationGeometry.translated(original, by: CGSize(width: 20, height: 20)))
    }

    @Test(arguments: AnnotationKind.allCases)
    func everyKindCreationTransactionAndCancellation(_ kind: AnnotationKind) throws {
        let editor = AnnotationEditor(capture: try capture())
        let original = annotation(kind)
        editor.beginTransaction(id: original.id, actionName: "创建")
        editor.updateTransaction(original)
        editor.endTransaction()
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
        editor.redo()
        let revision = editor.document.revision
        editor.beginTransaction(id: original.id)
        editor.updateTransaction(AnnotationGeometry.translated(original, by: CGSize(width: 12, height: -9)))
        editor.cancelTransaction()
        #expect(editor.document.annotations == [original])
        #expect(editor.document.revision > revision)
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
    }

    @Test(arguments: AnnotationKind.allCases)
    func deletionAndNewEditDiscardRedo(_ kind: AnnotationKind) throws {
        let editor = AnnotationEditor(capture: try capture())
        let original = annotation(kind)
        editor.insert(original)
        editor.deleteSelected()
        #expect(editor.document.annotations.isEmpty)
        editor.undo()
        #expect(editor.document.annotations == [original])
        editor.moveSelected(by: CGSize(width: 1, height: 0))
        #expect(!editor.undoManager.canRedo)
    }

    @Test(arguments: [AnnotationKind.rectangle, .text, .mosaic, .highlight])
    func allRectangularObjectsHaveEditableCorners(_ kind: AnnotationKind) throws {
        let editor = AnnotationEditor(capture: try capture())
        let original = annotation(kind)
        editor.insert(original)
        #expect(AnnotationGeometry.handles(original).count == 4)
        let resized = AnnotationGeometry.resized(original, handle: .corner(2), to: CGPoint(x: 160, y: 150))
        editor.beginTransaction(id: original.id, actionName: "调整尺寸")
        editor.updateTransaction(resized)
        editor.endTransaction()
        #expect(AnnotationGeometry.bounds(editor.document.annotations[0]) == CGRect(x: 20, y: 30, width: 140, height: 120))
        editor.undo()
        #expect(editor.document.annotations == [original])
        editor.redo()
        #expect(editor.document.annotations == [resized])
    }

    @Test func arrowEndpointsAndTextStyleAreUndoable() throws {
        let editor = AnnotationEditor(capture: try capture())
        let arrow = annotation(.arrow)
        editor.insert(arrow)
        let changed = AnnotationGeometry.resized(arrow, handle: .start, to: CGPoint(x: 1, y: 2))
        editor.replace(changed)
        #expect(changed.payload == .arrow(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 100, y: 80)))
        editor.undo()
        #expect(editor.document.annotations == [arrow])
        let text = annotation(.text)
        editor.insert(text)
        var changedText = text
        changedText.payload = .text(rect: AnnotationGeometry.bounds(text), text: "中文输入\nSniplet 12345")
        editor.replace(changedText, actionName: "编辑文字")
        editor.undo()
        #expect(editor.selectedAnnotation == text)
        editor.redo()
        #expect(editor.selectedAnnotation == changedText)
        let newStyle = AnnotationStyle(color: .blue, lineWidth: 8, fontSize: 64)
        editor.setStyle(newStyle)
        #expect(editor.selectedAnnotation?.style == newStyle)
        editor.undo()
        #expect(editor.selectedAnnotation?.style == changedText.style)
    }

    @Test func penHitDoesNotSwallowItsBoundingBoxAndMosaicIsTopmost() throws {
        let editor = AnnotationEditor(capture: try capture())
        let pen = Annotation(payload: .pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]))
        editor.insert(pen)
        #expect(editor.hitTest(CGPoint(x: 0, y: 100), tolerance: 6) == nil)
        #expect(editor.hitTest(CGPoint(x: 50, y: 52), tolerance: 6)?.id == pen.id)
        let mosaic = annotation(.mosaic)
        editor.insert(mosaic)
        editor.insert(annotation(.highlight))
        #expect(editor.hitTest(CGPoint(x: 50, y: 50), tolerance: 1)?.id == mosaic.id)
    }

    @Test func nativeCanvasExposesEveryObjectForSelection() throws {
        let editor = AnnotationEditor(capture: try capture())
        for kind in AnnotationKind.allCases { editor.insert(annotation(kind)) }
        let canvas = AnnotationCanvasView(editor: editor)
        let children = try #require(canvas.accessibilityChildren())
        #expect(children.count == 6)
        for (index, child) in children.enumerated() {
            let element = try #require(child as? NSAccessibilityElement)
            #expect(element.accessibilityPerformPress())
            #expect(editor.selectedID == editor.document.annotations[index].id)
        }
        canvas.detach()
    }

    @Test func sourceScaleDefaultsAndMosaicStyleTransactions() throws {
        let editor = AnnotationEditor(capture: try capture())
        #expect(editor.style.fontSize == 32)
        #expect(editor.style.lineWidth == 4)
        let mosaic = annotation(.mosaic)
        editor.insert(mosaic)
        editor.setMosaicBlockSize(32)
        #expect(editor.selectedAnnotation?.payload == .mosaic(rect: AnnotationGeometry.bounds(mosaic), blockSize: 32))
        editor.undo()
        #expect(editor.selectedAnnotation == mosaic)
    }

    @Test func exportingGateBlocksMutationsUndoAndNativeAccessibility() throws {
        let editor = AnnotationEditor(capture: try capture())
        let original = annotation(.text)
        editor.insert(original)
        let revision = editor.document.revision
        let canvas = AnnotationCanvasView(editor: editor)
        let child = try #require(canvas.accessibilityChildren()?.first as? NSAccessibilityElement)
        editor.isInteractionEnabled = false
        editor.moveSelected(by: CGSize(width: 20, height: 0))
        editor.deleteSelected()
        editor.insert(annotation(.pen))
        editor.undo()
        editor.beginTransaction(id: original.id)
        #expect(!editor.hasTransaction)
        #expect(!child.accessibilityPerformPress())
        #expect(editor.document.revision == revision)
        #expect(editor.document.annotations == [original])
        editor.isInteractionEnabled = true
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
        editor.invalidate()
        #expect(!editor.undoManager.canRedo)
        canvas.detach()
    }

    @Test(arguments: [CGFloat(0.25), 1, 2, 4])
    func hitToleranceUsesScreenPointsAtEveryZoom(_ magnification: CGFloat) {
        let imageTolerance = AnnotationGeometry.imageTolerance(screenPoints: 6, backingScale: 2,
                                                               magnification: magnification)
        #expect(imageTolerance * magnification / 2 == 6)
        let pen = Annotation(payload: .pen(points: [CGPoint(x: 10, y: 100), CGPoint(x: 300, y: 100)]),
                             style: AnnotationStyle(lineWidth: 2))
        #expect(AnnotationGeometry.hit(pen, at: CGPoint(x: 100, y: 100+imageTolerance*0.9), tolerance: imageTolerance))
        #expect(!AnnotationGeometry.hit(pen, at: CGPoint(x: 100, y: 100+imageTolerance+2), tolerance: imageTolerance))
    }
}
