import AppKit
import CoreText
import Testing
@testable import Sniplet

@MainActor struct AnnotationTextFormatTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func editor() throws -> AnnotationEditor {
        let context = try AnnotationCompositor.bitmap(width: 400, height: 300)
        let image = try #require(context.makeImage())
        return AnnotationEditor(capture: CapturedImage(id: UUID(), createdAt: Date(), mode: .region,
                                                       image: image, sourceScale: 2, displayID: 1))
    }

    private func visibleLength(_ text: String, style: AnnotationStyle, in rect: CGRect) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(AnnotationTextLayout.attributedString(text, style: style))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        return CTFrameGetVisibleStringRange(frame).length
    }

    @Test func fittedBoxShowsEveryLineAndWrapsOnlyAtTheImageEdge() {
        let style = AnnotationStyle(fontSize: 32)
        let origin = CGPoint(x: 20, y: 20)
        let short = AnnotationTextLayout.fittedRect("Hi", style: style, origin: origin, in: bounds)
        let long = AnnotationTextLayout.fittedRect("Sniplet 截图标注文字", style: style, origin: origin, in: bounds)
        #expect(short.origin == origin)
        #expect(long.width > short.width)
        #expect(long.maxX <= bounds.maxX)
        let lines = "第一行\n第二行\n第三行，比较长的一行文字会在图片边缘换行"
        let box = AnnotationTextLayout.fittedRect(lines, style: style, origin: origin, in: bounds)
        #expect(box.maxX <= bounds.maxX)
        #expect(visibleLength(lines, style: style, in: box) == (lines as NSString).length)
        // A trailing newline already reserves the caret's next line.
        let open = AnnotationTextLayout.fittedRect("Hi\n", style: style, origin: origin, in: bounds)
        #expect(open.height > short.height)
        let empty = AnnotationTextLayout.fittedRect("", style: style, origin: origin, in: bounds)
        #expect(empty.width >= style.fontSize && empty.height >= style.fontSize)
    }

    @Test func biggerOrBolderTextGetsABiggerBox() {
        let text = "Bold 粗体"
        let regular = AnnotationTextLayout.fittedRect(text, style: AnnotationStyle(fontSize: 24), origin: .zero, in: bounds)
        let bigger = AnnotationTextLayout.fittedRect(text, style: AnnotationStyle(fontSize: 48), origin: .zero, in: bounds)
        let bold = AnnotationTextLayout.fittedRect(text, style: AnnotationStyle(fontSize: 24, isBold: true),
                                                   origin: .zero, in: bounds)
        #expect(bigger.width > regular.width && bigger.height > regular.height)
        #expect(bold.width >= regular.width)
        #expect(visibleLength(text, style: AnnotationStyle(fontSize: 24, isBold: true), in: bold) == (text as NSString).length)
    }

    @Test func selectedTextRefitsOnStyleChangeAsOneUndoStep() throws {
        let editor = try editor()
        let style = AnnotationStyle(fontSize: 32)
        let rect = AnnotationTextLayout.fittedRect("标注", style: style, origin: CGPoint(x: 10, y: 10), in: bounds)
        let text = Annotation(payload: .text(rect: rect, text: "标注"), style: style)
        editor.insert(text)
        #expect(editor.showsTextFormat)
        #expect(editor.stepFontSize(larger: true))
        let grown = try #require(editor.selectedAnnotation)
        #expect(abs(grown.style.fontSize - 20 * 2) < 0.001)  // 32 px at 2x is 16 pt; the next step is 20 pt
        #expect(AnnotationGeometry.bounds(grown).width > rect.width)
        #expect(AnnotationGeometry.bounds(grown).origin == rect.origin)
        editor.toggleBold()
        #expect(editor.selectedAnnotation?.style.isBold == true)
        editor.undo()
        editor.undo()
        #expect(editor.selectedAnnotation == text)
    }

    @Test func fontSizeStepsStopAtBothEnds() throws {
        let editor = try editor()
        var steps = 0
        while editor.stepFontSize(larger: false) { steps += 1 }
        #expect(abs(editor.style.fontSize - AnnotationTextLayout.pointSizes[0] * 2) < 0.001)
        #expect(steps == 2)
        while editor.stepFontSize(larger: true) {}
        #expect(abs(editor.style.fontSize - AnnotationTextLayout.pointSizes.last! * 2) < 0.001)
    }

    @Test func openTextInputTakesStyleChangesWithoutAnUndoStep() throws {
        let editor = try editor()
        var received: [AnnotationStyle] = []
        editor.textStyleHandler = { received.append($0); return true }
        editor.toggleBold()
        editor.stepFontSize(larger: true)
        #expect(received.count == 2)
        #expect(received.last?.isBold == true)
        #expect(editor.style == received.last)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.document.annotations.isEmpty)
    }
}
