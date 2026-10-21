import CoreGraphics
import Testing
@testable import Sniplet

@MainActor struct AnnotationToolResetTests {
    @Test func createdAnnotationKeepsDrawingToolAndStaysAdjustable() throws {
        let editor = AnnotationEditor(capture: try SessionTestSupport.capture())
        editor.selectedTool = .rectangle
        let item = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 2, width: 12, height: 8)))
        editor.beginTransaction(id: item.id, actionName: "创建矩形")
        editor.updateTransaction(item)
        editor.select(item.id)
        editor.endTransaction()
        // Consecutive marks of one kind need no tool re-selection.
        #expect(editor.selectedTool == .rectangle)
        #expect(editor.selectedAnnotation?.id == item.id)
        // An outline drag with the drawing tool still moves the selected object.
        let moved = AnnotationGeometry.translated(item, by: CGSize(width: 4, height: 3))
        editor.beginTransaction(id: item.id)
        editor.updateTransaction(moved)
        editor.endTransaction()
        #expect(editor.document.annotations == [moved])
        #expect(editor.selectedTool == .rectangle)
    }

    @Test func firstEscapeLeavesTheDrawingToolBeforeDiscarding() throws {
        let editor = AnnotationEditor(capture: try SessionTestSupport.capture())
        editor.selectedTool = .mosaic
        #expect(editor.exitDrawingTool())
        #expect(editor.selectedTool == .select)
        // The next Escape is not consumed, so the canvas discards the capture.
        #expect(!editor.exitDrawingTool())
    }

    @Test func toolShortcutsAreUniqueAndCaseInsensitive() {
        #expect(Set(AnnotationTool.allCases.map(\.shortcutKey)).count == AnnotationTool.allCases.count)
        for tool in AnnotationTool.allCases {
            #expect(AnnotationTool.forShortcut(String(tool.shortcutKey)) == tool)
            #expect(AnnotationTool.forShortcut(String(tool.shortcutKey).uppercased()) == tool)
        }
        #expect(AnnotationTool.forShortcut("z") == nil)
        #expect(AnnotationTool.forShortcut("") == nil)
    }

    @Test func drawingToolsGrabOnlyTheOutline() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 30)
        for payload: AnnotationPayload in [.rectangle(rect: rect), .mosaic(rect: rect, blockSize: 8), .highlight(rect: rect)] {
            let item = Annotation(payload: payload)
            #expect(AnnotationGeometry.outlineHit(item, at: CGPoint(x: 10, y: 25), tolerance: 2))
            #expect(AnnotationGeometry.outlineHit(item, at: CGPoint(x: 49, y: 39), tolerance: 2))
            // Interior drags create a nested mark instead of moving this one.
            #expect(!AnnotationGeometry.outlineHit(item, at: CGPoint(x: 30, y: 25), tolerance: 2))
            #expect(!AnnotationGeometry.outlineHit(item, at: CGPoint(x: 60, y: 25), tolerance: 2))
        }
        let arrow = Annotation(payload: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 0)))
        #expect(AnnotationGeometry.outlineHit(arrow, at: CGPoint(x: 20, y: 1), tolerance: 2))
        #expect(!AnnotationGeometry.outlineHit(arrow, at: CGPoint(x: 20, y: 20), tolerance: 2))
        let pen = Annotation(payload: .pen(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)]))
        #expect(!AnnotationGeometry.outlineHit(pen, at: CGPoint(x: 20, y: 0), tolerance: 2))
    }

    @Test func cancelledCreationKeepsTheDrawingTool() throws {
        let editor = AnnotationEditor(capture: try SessionTestSupport.capture())
        editor.selectedTool = .pen
        let item = Annotation(payload: .pen(points: [CGPoint(x: 1, y: 1)]))
        editor.beginTransaction(id: item.id, actionName: "创建画笔")
        editor.updateTransaction(item)
        editor.cancelTransaction()
        #expect(editor.selectedTool == .pen)
        #expect(editor.document.annotations.isEmpty)
    }
}
