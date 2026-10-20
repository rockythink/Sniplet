import CoreGraphics
import Testing
@testable import Sniplet

@MainActor struct AnnotationToolResetTests {
    @Test func createdAnnotationBecomesImmediatelyMovable() throws {
        let editor = AnnotationEditor(capture: try SessionTestSupport.capture())
        editor.selectedTool = .rectangle
        let item = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 2, width: 12, height: 8)))
        editor.beginTransaction(id: item.id, actionName: "创建矩形")
        editor.updateTransaction(item)
        editor.select(item.id)
        editor.endTransaction()
        #expect(editor.selectedTool == .select)
        #expect(editor.selectedAnnotation?.id == item.id)
        // The next select-tool drag moves this object instead of creating a second one.
        let moved = AnnotationGeometry.translated(item, by: CGSize(width: 4, height: 3))
        editor.beginTransaction(id: item.id)
        editor.updateTransaction(moved)
        editor.endTransaction()
        #expect(editor.document.annotations == [moved])
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
