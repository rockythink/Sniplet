import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor struct CaptureSelectionResizeTests {
    private func region(_ source: CapturedImage,
                        rect: CGRect = CGRect(x: 8, y: 6, width: 12, height: 10),
                        frame: CGRect = CGRect(x: -80, y: -40, width: 32, height: 24)) throws -> CaptureRegionSelection {
        try #require(CaptureRegionSelection(source: source, screenFrame: frame, pixelRect: rect))
    }

    @Test(arguments: CaptureSelectionResizeHandle.allCases)
    func allHandlesMoveOnlyChosenEdges(_ handle: CaptureSelectionResizeHandle) throws {
        let source = try SessionTestSupport.capture()
        let initial = try region(source)
        let changed = initial.resized(from: handle, by: CGSize(width: 3, height: 2))
        let expected: CGRect = switch handle {
        case .topLeft: CGRect(x: 11, y: 4, width: 9, height: 12)
        case .top: CGRect(x: 8, y: 4, width: 12, height: 12)
        case .topRight: CGRect(x: 8, y: 4, width: 15, height: 12)
        case .right: CGRect(x: 8, y: 6, width: 15, height: 10)
        case .bottomRight: CGRect(x: 8, y: 6, width: 15, height: 8)
        case .bottom: CGRect(x: 8, y: 6, width: 12, height: 8)
        case .bottomLeft: CGRect(x: 11, y: 6, width: 9, height: 8)
        case .left: CGRect(x: 11, y: 6, width: 9, height: 10)
        }
        #expect(changed.pixelRect == expected)
        let crop = try changed.croppedCapture()
        #expect(crop.image.width == Int(expected.width))
        #expect(crop.image.height == Int(expected.height))
        #expect(crop.id == source.id && crop.createdAt == source.createdAt)
        #expect(crop.sourceScale == source.sourceScale && crop.displayID == source.displayID)
        #expect(try SessionTestSupport.pixel(crop.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: Int(expected.minX), y: Int(expected.minY)))
        #expect(try SessionTestSupport.pixel(crop.image, x: crop.image.width - 1, y: crop.image.height - 1)
            == SessionTestSupport.pixel(source.image, x: Int(expected.maxX) - 1, y: Int(expected.maxY) - 1))
    }

    @Test(arguments: CaptureSelectionResizeHandle.allCases)
    func edgesClampToSourceAndNeverFlip(_ handle: CaptureSelectionResizeHandle) throws {
        let initial = try region(SessionTestSupport.capture())
        let outward: CGSize = switch handle {
        case .topLeft: CGSize(width: -1_000, height: 1_000)
        case .top: CGSize(width: 1_000, height: 1_000)
        case .topRight: CGSize(width: 1_000, height: 1_000)
        case .right: CGSize(width: 1_000, height: 1_000)
        case .bottomRight: CGSize(width: 1_000, height: -1_000)
        case .bottom: CGSize(width: 1_000, height: -1_000)
        case .bottomLeft: CGSize(width: -1_000, height: -1_000)
        case .left: CGSize(width: -1_000, height: 1_000)
        }
        let expanded = initial.resized(from: handle, by: outward)
        let collapsed = initial.resized(from: handle, by: CGSize(width: -outward.width, height: -outward.height))
        switch handle {
        case .topLeft, .left, .bottomLeft:
            #expect(expanded.pixelRect.minX == 0)
            #expect(expanded.pixelRect.maxX == initial.pixelRect.maxX)
            #expect(collapsed.pixelRect.minX == initial.pixelRect.maxX - 1)
            #expect(collapsed.pixelRect.width == 1)
        case .topRight, .right, .bottomRight:
            #expect(expanded.pixelRect.maxX == 32)
            #expect(expanded.pixelRect.minX == initial.pixelRect.minX)
            #expect(collapsed.pixelRect.maxX == initial.pixelRect.minX + 1)
            #expect(collapsed.pixelRect.width == 1)
        case .top, .bottom:
            #expect(expanded.pixelRect.minX == initial.pixelRect.minX)
            #expect(expanded.pixelRect.width == initial.pixelRect.width)
        }
        switch handle {
        case .topLeft, .top, .topRight:
            #expect(expanded.pixelRect.minY == 0)
            #expect(expanded.pixelRect.maxY == initial.pixelRect.maxY)
            #expect(collapsed.pixelRect.minY == initial.pixelRect.maxY - 1)
            #expect(collapsed.pixelRect.height == 1)
        case .bottomLeft, .bottom, .bottomRight:
            #expect(expanded.pixelRect.maxY == 24)
            #expect(expanded.pixelRect.minY == initial.pixelRect.minY)
            #expect(collapsed.pixelRect.maxY == initial.pixelRect.minY + 1)
            #expect(collapsed.pixelRect.height == 1)
        case .left, .right:
            #expect(expanded.pixelRect.minY == initial.pixelRect.minY)
            #expect(expanded.pixelRect.height == initial.pixelRect.height)
        }
        #expect(collapsed.pixelRect.width >= 1 && collapsed.pixelRect.height >= 1)
        #expect(expanded.screenRect.minX >= initial.screenFrame.minX)
        #expect(expanded.screenRect.maxY <= initial.screenFrame.maxY)
    }

    @Test func fractionalScaleAndNegativeFootprintKeepOppositeEdgesExact() throws {
        let original = try SessionTestSupport.capture()
        let source = CapturedImage(id: original.id, createdAt: original.createdAt, mode: .region,
                                   image: original.image, sourceScale: 1.25, displayID: original.displayID)
        let initial = try region(source, frame: CGRect(x: -225.5, y: -110.25, width: 25.6, height: 16))
        let changed = initial.resized(from: .topLeft, by: CGSize(width: -2.4, height: 2))
        #expect(changed.pixelRect == CGRect(x: 5, y: 3, width: 15, height: 13))
        #expect(abs(changed.screenRect.maxX - initial.screenRect.maxX) < 0.000_001)
        #expect(abs(changed.screenRect.minY - initial.screenRect.minY) < 0.000_001)
        let tiny = initial.resized(from: .topLeft, by: CGSize(width: 0.1, height: -0.1))
        #expect(tiny.pixelRect == initial.pixelRect)
        #expect(initial.resized(from: .right, by: CGSize(width: CGFloat.infinity, height: 0)).pixelRect == initial.pixelRect)
        #expect(initial.resized(from: .top, by: CGSize(width: 0, height: CGFloat.nan)).pixelRect == initial.pixelRect)
    }

    private func marks() -> [Annotation] {
        let style = AnnotationStyle(color: .blue, lineWidth: 3.25, fontSize: 14.5)
        return [
            Annotation(payload: .arrow(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 6.3, y: 7.4)), style: style),
            Annotation(payload: .rectangle(rect: CGRect(x: 0.1, y: 0.2, width: 3.3, height: 4.4)), style: style),
            Annotation(payload: .pen(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 4.3, y: 5.4)]), style: style),
            Annotation(payload: .text(rect: CGRect(x: 0.1, y: 0.2, width: 3.3, height: 4.4), text: "冻结内容"), style: style),
            Annotation(payload: .mosaic(rect: CGRect(x: 0.1, y: 0.2, width: 3.3, height: 4.4), blockSize: 8), style: style),
            Annotation(payload: .highlight(rect: CGRect(x: 0.1, y: 0.2, width: 3.3, height: 4.4)), style: style)
        ]
    }

    @Test func resizeAnchorsAllAnnotationKindsAndUndoRestoresExactValues() throws {
        let initial = try region(SessionTestSupport.capture())
        let style = CaptureStyle(cornerRadius: 3, shadow: .medium, borderWidth: 2, borderColor: .blue)
        let editor = AnnotationEditor(capture: try initial.croppedCapture(), captureStyle: style, regionSelection: initial)
        let originals = marks()
        originals.forEach { editor.insert($0) }
        editor.undoManager.removeAllActions()
        let selected = editor.selectedID
        #expect(editor.beginSelectionAdjustment(resizing: .topLeft))
        for step in 1...4 {
            try editor.updateSelectionAdjustment(by: CGSize(width: CGFloat(step), height: CGFloat(step)))
            let expected = originals.map { AnnotationGeometry.translated($0, by: CGSize(width: -CGFloat(step), height: CGFloat(step))) }
            #expect(editor.document.annotations == expected)
            #expect(editor.document.annotations.map(\.style) == originals.map(\.style))
            #expect(editor.selectedID == selected)
        }
        let after = editor.document.annotations
        let rect = try #require(editor.regionSelection?.pixelRect)
        editor.endSelectionAdjustment()
        #expect(editor.document.captureStyle == style)
        // Marks outside the shrunken crop remain value objects, not discarded/clamped.
        #expect(AnnotationGeometry.bounds(editor.document.annotations[1]).minX < 0)
        let revision = editor.document.revision
        editor.undo()
        #expect(editor.document.annotations == originals)
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.document.revision > revision)
        #expect(!editor.undoManager.canUndo)
        editor.redo()
        #expect(editor.document.annotations == after)
        #expect(editor.regionSelection?.pixelRect == rect)
        #expect(!editor.undoManager.canRedo)
        editor.undo()
        #expect(editor.document.annotations == originals)
    }

    @Test func cancelledAndNoOpResizesPreserveRedoAndExactFractionalMarks() throws {
        let initial = try region(SessionTestSupport.capture())
        let editor = AnnotationEditor(capture: try initial.croppedCapture(), regionSelection: initial)
        let originals = marks()
        originals.forEach { editor.insert($0) }
        editor.undoManager.removeAllActions()
        #expect(editor.beginSelectionAdjustment(resizing: .topLeft))
        try editor.updateSelectionAdjustment(by: CGSize(width: 3, height: 2))
        editor.endSelectionAdjustment()
        let committed = editor.document.annotations
        let committedRect = editor.regionSelection?.pixelRect
        editor.undo()
        #expect(editor.undoManager.canRedo)
        #expect(editor.beginSelectionAdjustment(resizing: .topLeft))
        try editor.updateSelectionAdjustment(by: CGSize(width: -4, height: -3))
        editor.cancelSelectionAdjustment()
        #expect(editor.document.annotations == originals)
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.undoManager.canRedo)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.beginSelectionAdjustment(resizing: .topLeft))
        try editor.updateSelectionAdjustment(by: CGSize(width: 4, height: 3))
        try editor.updateSelectionAdjustment(by: .zero)
        let revision = editor.document.revision
        try editor.updateSelectionAdjustment(by: CGSize(width: 0.1, height: 0.1))
        editor.endSelectionAdjustment()
        #expect(editor.document.revision == revision)
        #expect(editor.document.annotations == originals)
        #expect(editor.undoManager.canRedo)
        #expect(!editor.undoManager.canUndo)
        editor.redo()
        #expect(editor.document.annotations == committed)
        #expect(editor.regionSelection?.pixelRect == committedRect)
    }

    @Test func fullSourceCanShrinkAndCommitEndsAdjustment() throws {
        let source = try SessionTestSupport.capture()
        let initial = try region(source, rect: CGRect(x: 0, y: 0, width: 32, height: 24))
        let editor = AnnotationEditor(capture: source, regionSelection: initial)
        #expect(!editor.canMoveCaptureSelection)
        #expect(editor.canResizeCaptureSelection)
        #expect(editor.beginSelectionAdjustment(resizing: .bottomRight))
        try editor.updateSelectionAdjustment(by: CGSize(width: -4, height: 3))
        editor.commitTextEditing()
        let committed = editor.regionSelection?.pixelRect
        try editor.updateSelectionAdjustment(by: CGSize(width: -8, height: 6))
        #expect(editor.regionSelection?.pixelRect == committed)
        editor.undo()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(!editor.undoManager.canUndo)
        editor.isInteractionEnabled = false
        #expect(!editor.canResizeCaptureSelection)
        #expect(!editor.beginSelectionAdjustment(resizing: .left))
        editor.invalidate()
        #expect(editor.regionSelection == nil)
        #expect(!editor.canResizeCaptureSelection)
    }

    @Test(arguments: [CaptureMode.window, .fullScreen])
    func originalNativeMetadataSurvivesCancelNoOpAndUndo(_ mode: CaptureMode) throws {
        let original = try SessionTestSupport.capture()
        let source = CapturedImage(id: original.id, createdAt: original.createdAt, mode: mode,
                                   image: original.image, sourceScale: original.sourceScale, displayID: original.displayID)
        let initial = try region(source, rect: CGRect(x: 0, y: 0, width: 32, height: 24))
        let editor = AnnotationEditor(capture: source, regionSelection: initial)
        #expect(editor.beginSelectionAdjustment(resizing: .left))
        try editor.updateSelectionAdjustment(by: CGSize(width: 3, height: 0))
        #expect(editor.document.capture.mode == .region)
        editor.cancelSelectionAdjustment()
        #expect(editor.document.capture.mode == mode)
        #expect(editor.beginSelectionAdjustment(resizing: .left))
        try editor.updateSelectionAdjustment(by: CGSize(width: 3, height: 0))
        try editor.updateSelectionAdjustment(by: .zero)
        editor.endSelectionAdjustment()
        #expect(editor.document.capture.mode == mode)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.beginSelectionAdjustment(resizing: .left))
        try editor.updateSelectionAdjustment(by: CGSize(width: 3, height: 0))
        editor.endSelectionAdjustment()
        editor.undo()
        #expect(editor.document.capture.mode == mode)
        #expect(editor.document.capture.id == source.id)
        #expect(editor.document.capture.createdAt == source.createdAt)
        editor.redo()
        #expect(editor.document.capture.mode == .region)
        #expect(editor.document.capture.image.width == 29)
    }

    @Test func fullDisplayManualRegionDoesNotBecomeFullScreenOnUndo() throws {
        let original = try SessionTestSupport.capture()
        let source = CapturedImage(id: original.id, createdAt: original.createdAt, mode: .fullScreen,
                                   image: original.image, sourceScale: original.sourceScale, displayID: original.displayID)
        let initial = try region(source, rect: CGRect(x: 0, y: 0, width: 32, height: 24))
        let editor = AnnotationEditor(capture: try initial.croppedCapture(), regionSelection: initial)
        #expect(editor.document.capture.mode == .region)
        #expect(editor.beginSelectionAdjustment(resizing: .right))
        try editor.updateSelectionAdjustment(by: CGSize(width: -4, height: 0))
        editor.endSelectionAdjustment()
        editor.undo()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.document.capture.mode == .region)
        #expect(editor.document.capture.image.width == 32)
        editor.redo()
        #expect(editor.document.capture.mode == .region)
        #expect(editor.document.capture.image.width == 28)
    }
}
