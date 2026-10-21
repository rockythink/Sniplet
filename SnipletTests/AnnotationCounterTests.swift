import AppKit
import Testing
@testable import Sniplet

@MainActor struct AnnotationCounterTests {
    private func editor() throws -> AnnotationEditor {
        let context = try AnnotationCompositor.bitmap(width: 400, height: 300)
        let image = try #require(context.makeImage())
        return AnnotationEditor(capture: CapturedImage(id: UUID(), createdAt: Date(), mode: .region,
                                                       image: image, sourceScale: 2, displayID: 1))
    }

    private func counter(_ x: CGFloat) -> Annotation {
        Annotation(payload: .counter(center: CGPoint(x: x, y: 100)), style: AnnotationStyle(fontSize: 32))
    }

    @Test func countersNumberByOrderAndRenumberAfterDeleteAndUndo() throws {
        let editor = try editor()
        let marks = [counter(50), counter(150), counter(250)]
        editor.insert(marks[0])
        editor.insert(Annotation(payload: .rectangle(rect: CGRect(x: 10, y: 10, width: 20, height: 20))))
        editor.insert(marks[1])
        editor.insert(marks[2])
        #expect(marks.map { editor.document.counterNumber(of: $0.id) } == [1, 2, 3])
        #expect(editor.document.counterNumber(of: editor.document.annotations[1].id) == nil)
        editor.select(marks[1].id)
        editor.deleteSelected()
        #expect(editor.document.counterNumber(of: marks[2].id) == 2)
        editor.undo()
        #expect(marks.map { editor.document.counterNumber(of: $0.id) } == [1, 2, 3])
    }

    @Test func counterIsGrabbedWholeAndHasNoResizeHandles() {
        let mark = counter(100)
        let radius = AnnotationGeometry.counterRadius(mark.style)
        #expect(AnnotationGeometry.handles(mark).isEmpty)
        #expect(AnnotationGeometry.outlineHit(mark, at: CGPoint(x: 100, y: 100), tolerance: 2))
        #expect(!AnnotationGeometry.outlineHit(mark, at: CGPoint(x: 100 + radius + 5, y: 100), tolerance: 2))
        let moved = AnnotationGeometry.translated(mark, by: CGSize(width: 10, height: -5))
        #expect(moved.payload == .counter(center: CGPoint(x: 110, y: 95)))
        #expect(AnnotationTool.forShortcut("N") == .counter)
    }

    @Test func badgeRendersItsColorWithAContrastingNumber() throws {
        let editor = try editor()
        let mark = counter(100)
        editor.insert(mark)
        let context = try AnnotationCompositor.bitmap(width: 400, height: 300)
        AnnotationCompositor.drawOrdinary(editor.document, in: context)
        let image = try #require(context.makeImage())
        let radius = Int(AnnotationGeometry.counterRadius(mark.style))
        // Between the ring and the digit: the badge's red.
        let fill = try SessionTestSupport.pixel(image, x: 100 - radius / 2 - 3, y: 100 + radius / 2)
        #expect(fill[0] > 180 && fill[1] < 80 && fill[3] == 255)
        // Somewhere along the digit's vertical stroke the white number shows.
        var sawDigit = false
        for x in 92...108 where try SessionTestSupport.pixel(image, x: x, y: 100)[1] > 200 { sawDigit = true }
        #expect(sawDigit)
    }
}
