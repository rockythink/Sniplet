import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor struct SelectionCaptureOutputTests {
    @Test func movedCropInvalidatesPNGAndOCRWhileKeepingStylesAndMosaic() async throws {
        let source = try SessionTestSupport.capture()
        let screen = CGRect(x: -200, y: 50, width: 32, height: 24)
        let region = try #require(CaptureRegionSelection(source: source, screenFrame: screen,
            selectionRect: CGRect(x: -198, y: 60, width: 16, height: 12)))
        let style = CaptureStyle(cornerRadius: 3, shadow: .subtle, borderWidth: 1, borderColor: .gray)
        let session = EditorSession(capture: try region.croppedCapture(), captureStyle: style,
                                    regionSelection: region, services: SessionTestSupport.services())
        defer { session.discard() }
        let editor = try #require(session.editor)
        let mosaic = Annotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 4, height: 4), blockSize: 8))
        editor.insert(mosaic)
        let first = try await session.prepareDrag()
        session.dragCancelled()
        let oldTicket = try #require(session.beginOCR())
        try #require(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: 4, height: -3))
        editor.endSelectionAdjustment()
        #expect(!session.acceptOCR(OCRResult(text: "旧区域文字", missingLanguages: []), for: oldTicket))
        #expect(editor.document.annotations == [mosaic])
        #expect(editor.document.captureStyle == style)
        let moved = try await session.prepareDrag()
        session.dragCancelled()
        let before = try SessionTestSupport.image(first.pngData)
        let after = try SessionTestSupport.image(moved.pngData)
        let bounds = style.geometry(imageSize: CGSize(width: 16, height: 12), sourceScale: 1).presentationBounds
        let x = Int(-bounds.minX) + 8
        let y = Int(-bounds.minY) + 6
        #expect(after.width == before.width && after.height == before.height)
        #expect(try SessionTestSupport.pixel(after, x: x, y: y) == SessionTestSupport.pixel(source.image, x: 14, y: 11))
        #expect(try SessionTestSupport.pixel(before, x: x, y: y) == SessionTestSupport.pixel(source.image, x: 10, y: 8))
        #expect(try SessionTestSupport.pixel(after, x: x, y: y) != SessionTestSupport.pixel(before, x: x, y: y))
        editor.undo()
        #expect(!session.acceptOCR(OCRResult(text: "仍然过期", missingLanguages: []), for: oldTicket))
        let restored = try await session.prepareDrag()
        session.dragCancelled()
        let restoredImage = try SessionTestSupport.image(restored.pngData)
        #expect(try SessionTestSupport.pixel(restoredImage, x: x, y: y) == SessionTestSupport.pixel(before, x: x, y: y))
    }

    @Test func resizingInvalidatesRealSessionPNGAndCompletedAndPendingOCR() async throws {
        let source = try SessionTestSupport.capture()
        let region = try #require(CaptureRegionSelection(source: source,
            screenFrame: CGRect(x: -80, y: -40, width: 32, height: 24),
            pixelRect: CGRect(x: 8, y: 6, width: 12, height: 10)))
        let style = CaptureStyle(cornerRadius: 2, shadow: .subtle, borderWidth: 1, borderColor: .blue)
        let session = EditorSession(capture: try region.croppedCapture(), captureStyle: style,
                                    regionSelection: region, services: SessionTestSupport.services())
        defer { session.discard() }
        let editor = try #require(session.editor)
        let first = try await session.prepareDrag()
        session.dragCancelled()
        let completed = try #require(session.beginOCR())
        #expect(session.acceptOCR(OCRResult(text: "旧裁剪内容", missingLanguages: []), for: completed))
        #expect(session.ocrResult != nil)
        #expect(editor.beginSelectionAdjustment(resizing: .topLeft))
        try editor.updateSelectionAdjustment(by: CGSize(width: -3, height: 2))
        editor.endSelectionAdjustment()
        #expect(session.ocrResult == nil)
        #expect(!session.acceptOCR(OCRResult(text: "迟到的旧结果", missingLanguages: []), for: completed))
        #expect(editor.document.captureStyle == style)
        let changed = try await session.prepareDrag()
        session.dragCancelled()
        #expect(changed.pngData != first.pngData)
        let before = try SessionTestSupport.image(first.pngData)
        let after = try SessionTestSupport.image(changed.pngData)
        let geometry = style.geometry(imageSize: CGSize(width: 15, height: 12), sourceScale: 1)
        #expect(after.width == Int(geometry.presentationBounds.width))
        #expect(after.height == Int(geometry.presentationBounds.height))
        #expect(after.width != before.width && after.height != before.height)
        let x = Int(-geometry.presentationBounds.minX) + 7
        let y = Int(-geometry.presentationBounds.minY) + 5
        #expect(try SessionTestSupport.pixel(after, x: x, y: y)
            == SessionTestSupport.pixel(source.image, x: 12, y: 9))
        let pending = try #require(session.beginOCR())
        editor.undo()
        #expect(!session.isRecognizing && session.ocrResult == nil)
        #expect(!session.acceptOCR(OCRResult(text: "撤销前的结果", missingLanguages: []), for: pending))
        let restored = try await session.prepareDrag()
        session.dragCancelled()
        let restoredImage = try SessionTestSupport.image(restored.pngData)
        #expect(restoredImage.width == before.width && restoredImage.height == before.height)
        let oldGeometry = style.geometry(imageSize: CGSize(width: 12, height: 10), sourceScale: 1)
        let oldX = Int(-oldGeometry.presentationBounds.minX) + 6
        let oldY = Int(-oldGeometry.presentationBounds.minY) + 5
        #expect(try SessionTestSupport.pixel(restoredImage, x: oldX, y: oldY)
            == SessionTestSupport.pixel(before, x: oldX, y: oldY))
        editor.redo()
        let redone = try await session.prepareDrag()
        session.dragCancelled()
        let redoneImage = try SessionTestSupport.image(redone.pngData)
        #expect(redoneImage.width == after.width && redoneImage.height == after.height)
        #expect(try SessionTestSupport.pixel(redoneImage, x: x, y: y)
            == SessionTestSupport.pixel(after, x: x, y: y))
    }

    @Test func offCropMarksAreClippedFromStyledOutputAndReappearOnExpansion() async throws {
        let source = try SessionTestSupport.capture()
        let region = try #require(CaptureRegionSelection(source: source,
            screenFrame: CGRect(x: 0, y: 0, width: 32, height: 24),
            pixelRect: CGRect(x: 8, y: 6, width: 12, height: 10)))
        // Shadow padding makes any failure to clip off-crop marks observable in export.
        let style = CaptureStyle(cornerRadius: 0, shadow: .medium, borderWidth: 0, borderColor: .gray)
        let session = EditorSession(capture: try region.croppedCapture(), captureStyle: style,
                                    regionSelection: region, services: SessionTestSupport.services())
        defer { session.discard() }
        let editor = try #require(session.editor)
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 1, y: 2, width: 4, height: 5)),
                              style: AnnotationStyle(color: .black, lineWidth: 2, fontSize: 16))
        editor.insert(mark)
        #expect(editor.beginSelectionAdjustment(resizing: .left))
        try editor.updateSelectionAdjustment(by: CGSize(width: 8, height: 0))
        editor.endSelectionAdjustment()
        #expect(editor.document.annotations.count == 1)
        #expect(AnnotationGeometry.bounds(editor.document.annotations[0]).maxX < 0)
        let cropped = try await session.prepareDrag()
        session.dragCancelled()
        let image = try SessionTestSupport.image(cropped.pngData)
        var withoutMarks = editor.document
        withoutMarks.annotations = []
        let baseline = try await ImageRenderer().render(withoutMarks)
        #expect(image.width == baseline.image.width && image.height == baseline.image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                #expect(try SessionTestSupport.pixel(image, x: x, y: y)
                    == SessionTestSupport.pixel(baseline.image, x: x, y: y))
            }
        }
        #expect(editor.beginSelectionAdjustment(resizing: .left))
        try editor.updateSelectionAdjustment(by: CGSize(width: -8, height: 0))
        editor.endSelectionAdjustment()
        #expect(editor.document.annotations == [mark])
        let expanded = try await session.prepareDrag()
        session.dragCancelled()
        let expandedImage = try SessionTestSupport.image(expanded.pngData)
        let bounds = style.geometry(imageSize: CGSize(width: 12, height: 10), sourceScale: 1).presentationBounds
        let markPixel = try SessionTestSupport.pixel(expandedImage, x: Int(-bounds.minX) + 1,
                                                     y: Int(-bounds.minY) + 4)
        #expect(Array(markPixel.prefix(3)) == [0, 0, 0])
        #expect(try markPixel != SessionTestSupport.pixel(source.image, x: 9, y: 10))
    }
}
