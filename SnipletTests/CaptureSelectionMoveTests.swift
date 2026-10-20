import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor
struct CaptureSelectionMoveTests {
    private func makeSource(width: Int = 64, height: Int = 48) throws -> CapturedImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(x % 256)
                bytes[index + 1] = UInt8(y % 256)
                bytes[index + 2] = UInt8((x * 7 + y * 13) % 256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: AnnotationCompositor.colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent))
        return CapturedImage(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             mode: .region, image: image, sourceScale: 2, displayID: 7)
    }

    private func selection(_ source: CapturedImage, frame: CGRect,
                           rect: CGRect) throws -> CaptureRegionSelection {
        try #require(CaptureRegionSelection(source: source, screenFrame: frame, selectionRect: rect))
    }

    private func makeEditor(_ selection: CaptureRegionSelection) throws -> AnnotationEditor {
        AnnotationEditor(capture: try selection.croppedCapture(), regionSelection: selection)
    }

    @Test func movedSelectionRecropsNewPixelsFromTheSameFrozenFrame() throws {
        let source = try makeSource()
        let frame = CGRect(x: 100, y: 200, width: 64, height: 48)
        let initial = try selection(source, frame: frame, rect: CGRect(x: 108, y: 216, width: 16, height: 12))
        #expect(initial.pixelRect == CGRect(x: 8, y: 20, width: 16, height: 12))
        #expect(initial.screenRect == CGRect(x: 108, y: 216, width: 16, height: 12))

        let cropped = try initial.croppedCapture()
        #expect(cropped.id == source.id)
        #expect(cropped.createdAt == source.createdAt)
        #expect(cropped.mode == .region)
        #expect(cropped.sourceScale == source.sourceScale)
        #expect(cropped.displayID == source.displayID)
        #expect(try SessionTestSupport.pixel(cropped.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 8, y: 20))

        let moved = initial.moved(by: CGSize(width: 12, height: 8))
        #expect(moved.pixelRect == CGRect(x: 20, y: 12, width: 16, height: 12))
        #expect(moved.screenRect == CGRect(x: 120, y: 224, width: 16, height: 12))
        #expect(moved.pixelRect.width == initial.pixelRect.width)
        #expect(moved.pixelRect.height == initial.pixelRect.height)

        let movedCapture = try moved.croppedCapture()
        #expect(try SessionTestSupport.pixel(movedCapture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 20, y: 12))
        #expect(try SessionTestSupport.pixel(movedCapture.image, x: 0, y: 0)
            != SessionTestSupport.pixel(cropped.image, x: 0, y: 0))
    }

    @Test func appKitYAxisIsInvertedAgainstTopLeftPixelRows() throws {
        let source = try makeSource(width: 200, height: 100)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let initial = try selection(source, frame: frame, rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(initial.pixelRect == CGRect(x: 20, y: 40, width: 40, height: 40))
        #expect(initial.screenRect == CGRect(x: 10, y: 10, width: 20, height: 20))

        // Moving up in AppKit points means moving toward smaller top-left pixel y.
        let raised = initial.moved(by: CGSize(width: 0, height: 5))
        #expect(raised.pixelRect == CGRect(x: 20, y: 30, width: 40, height: 40))
        #expect(raised.screenRect == CGRect(x: 10, y: 15, width: 20, height: 20))

        // A band against the AppKit top edge is row zero of the image.
        let topBand = try selection(source, frame: frame, rect: CGRect(x: 0, y: 40, width: 20, height: 10))
        #expect(topBand.pixelRect == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(topBand.screenRect.maxY == frame.maxY)
    }

    @Test func fractionalScaleMoveKeepsExactPixelDimensions() throws {
        let source = try makeSource(width: 201, height: 101)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let initial = try selection(source, frame: frame, rect: CGRect(x: 10.3, y: 7.1, width: 30.7, height: 18.9))
        #expect(initial.pixelRect == CGRect(x: 20, y: 48, width: 63, height: 39))
        let editor = try makeEditor(initial)
        #expect(editor.beginSelectionAdjustment())

        for step in 1...8 {
            try editor.updateSelectionAdjustment(by: CGSize(width: 0.37 * CGFloat(step),
                                                      height: -0.83 * CGFloat(step)))
            let current = try #require(editor.regionSelection)
            #expect(current.pixelRect.width == initial.pixelRect.width)
            #expect(current.pixelRect.height == initial.pixelRect.height)
            #expect(current.pixelRect.minX == current.pixelRect.minX.rounded())
            #expect(current.pixelRect.minY == current.pixelRect.minY.rounded())
            #expect(current.screenRect.width == initial.screenRect.width)
            #expect(current.screenRect.height == initial.screenRect.height)
        }
        editor.endSelectionAdjustment()
        let current = try #require(editor.regionSelection)
        #expect(current.pixelRect.minX > initial.pixelRect.minX)
        #expect(current.pixelRect.minY > initial.pixelRect.minY)
        #expect(editor.document.capture.image.width == Int(initial.pixelRect.width))
        #expect(editor.document.capture.image.height == Int(initial.pixelRect.height))
    }

    @Test func movementClampsAtFrozenSourceEdgesOnNegativeOriginDisplays() throws {
        let source = try makeSource(width: 100, height: 100)
        let frame = CGRect(x: -200, y: -100, width: 100, height: 100)
        let initial = try selection(source, frame: frame, rect: CGRect(x: -190, y: -80, width: 20, height: 20))
        #expect(initial.pixelRect == CGRect(x: 10, y: 60, width: 20, height: 20))

        let topLeft = initial.moved(by: CGSize(width: -1_000, height: 1_000))
        #expect(topLeft.pixelRect == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(topLeft.screenRect == CGRect(x: -200, y: -20, width: 20, height: 20))
        let topLeftCapture = try topLeft.croppedCapture()
        #expect(try SessionTestSupport.pixel(topLeftCapture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 0, y: 0))

        let bottomRight = initial.moved(by: CGSize(width: 1_000, height: -1_000))
        #expect(bottomRight.pixelRect == CGRect(x: 80, y: 80, width: 20, height: 20))
        #expect(bottomRight.screenRect == CGRect(x: -120, y: -100, width: 20, height: 20))
        let bottomRightCapture = try bottomRight.croppedCapture()
        #expect(try SessionTestSupport.pixel(bottomRightCapture.image, x: 19, y: 19)
            == SessionTestSupport.pixel(source.image, x: 99, y: 99))
    }

    @Test func oneGestureHasOneUndoAndRedo() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let editor = try makeEditor(initial)

        #expect(editor.beginSelectionAdjustment())
        for step in 1...4 {
            try editor.updateSelectionAdjustment(by: CGSize(width: CGFloat(step) * 3,
                                                      height: CGFloat(step) * 1.5))
        }
        editor.endSelectionAdjustment()

        let movedRect = CGRect(x: 20, y: 18, width: 16, height: 12)
        #expect(editor.regionSelection?.pixelRect == movedRect)
        #expect(editor.document.capture.image.width == 16)
        #expect(editor.document.capture.image.height == 12)
        #expect(try SessionTestSupport.pixel(editor.document.capture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 20, y: 18))

        editor.undo()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.document.capture.image.width == 16)
        #expect(try SessionTestSupport.pixel(editor.document.capture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 8, y: 24))
        #expect(editor.undoManager.canRedo)

        editor.redo()
        #expect(editor.regionSelection?.pixelRect == movedRect)
        #expect(try SessionTestSupport.pixel(editor.document.capture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(source.image, x: 20, y: 18))
        #expect(!editor.undoManager.canRedo)
    }

    @Test func noOpMoveKeepsTheRedoBranch() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let editor = try makeEditor(initial)
        #expect(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: 10, height: 0))
        editor.endSelectionAdjustment()
        let movedRect = try #require(editor.regionSelection?.pixelRect)
        editor.undo()
        #expect(editor.undoManager.canRedo)
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)

        #expect(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: 3, height: 0))
        try editor.updateSelectionAdjustment(by: .zero)
        editor.endSelectionAdjustment()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.undoManager.canRedo)
        #expect(!editor.undoManager.canUndo)

        editor.redo()
        #expect(editor.regionSelection?.pixelRect == movedRect)
    }

    @Test func cancelRestoresOriginalPixelsWithoutAddingUndo() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let fresh = try makeEditor(initial)
        let originalImage = fresh.document.capture.image
        let initialRevision = fresh.document.revision
        #expect(fresh.beginSelectionAdjustment())
        try fresh.updateSelectionAdjustment(by: CGSize(width: 7, height: 4))
        #expect(fresh.regionSelection?.pixelRect != initial.pixelRect)
        fresh.cancelSelectionAdjustment()
        #expect(fresh.regionSelection?.pixelRect == initial.pixelRect)
        #expect(fresh.document.revision > initialRevision)
        #expect(try SessionTestSupport.pixel(fresh.document.capture.image, x: 0, y: 0)
            == SessionTestSupport.pixel(originalImage, x: 0, y: 0))
        #expect(!fresh.undoManager.canUndo)
        #expect(!fresh.undoManager.canRedo)

        let editor = try makeEditor(initial)
        #expect(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: 7, height: 4))
        editor.endSelectionAdjustment()
        let committedRect = try #require(editor.regionSelection?.pixelRect)
        #expect(editor.undoManager.canUndo)

        #expect(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: -9, height: -6))
        editor.cancelSelectionAdjustment()
        #expect(editor.regionSelection?.pixelRect == committedRect)
        #expect(editor.undoManager.canUndo)
        editor.undo()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
    }


    @Test func movingKeepsAnnotationsLocalAndPreservesCaptureStyle() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let style = CaptureStyle(cornerRadius: 12, shadow: .medium, borderWidth: 2, borderColor: .blue)
        let editor = AnnotationEditor(capture: try initial.croppedCapture(),
                                      captureStyle: style, regionSelection: initial)
        let storedStyle = editor.document.captureStyle
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 3, width: 5, height: 6)))
        editor.insert(mark)
        let annotations = editor.document.annotations
        let imageBounds = editor.document.imageBounds

        #expect(editor.beginSelectionAdjustment())
        try editor.updateSelectionAdjustment(by: CGSize(width: 4, height: 3))
        editor.endSelectionAdjustment()

        #expect(editor.document.annotations == annotations)
        #expect(editor.document.captureStyle == storedStyle)
        #expect(editor.document.imageBounds == imageBounds)
        #expect(editor.document.capture.image.width == 16)
        #expect(editor.document.capture.image.height == 12)

        editor.undo()
        #expect(editor.document.annotations == annotations)
        #expect(editor.document.captureStyle == storedStyle)
        #expect(editor.document.imageBounds == imageBounds)
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
    }

    @Test func movementIsUnavailableForFixedOrFullSourceCrops() throws {
        let source = try makeSource()
        let fixed = AnnotationEditor(capture: source)
        #expect(!fixed.canMoveCaptureSelection)
        #expect(!fixed.beginSelectionAdjustment())

        let fullFrame = CGRect(x: 0, y: 0, width: 64, height: 48)
        let full = try selection(source, frame: fullFrame, rect: fullFrame)
        let fullEditor = try makeEditor(full)
        #expect(!fullEditor.canMoveCaptureSelection)
        #expect(!fullEditor.beginSelectionAdjustment())

        let oneAxis = try selection(source, frame: fullFrame, rect: CGRect(x: 0, y: 10, width: 64, height: 20))
        let oneAxisEditor = try makeEditor(oneAxis)
        #expect(oneAxisEditor.canMoveCaptureSelection)
        #expect(oneAxisEditor.beginSelectionAdjustment())
        try oneAxisEditor.updateSelectionAdjustment(by: CGSize(width: 12, height: 0))
        oneAxisEditor.endSelectionAdjustment()
        #expect(oneAxisEditor.regionSelection?.pixelRect == oneAxis.pixelRect)
        let previous = try #require(oneAxisEditor.regionSelection?.pixelRect)
        #expect(oneAxisEditor.beginSelectionAdjustment())
        try oneAxisEditor.updateSelectionAdjustment(by: CGSize(width: 0, height: 5))
        oneAxisEditor.endSelectionAdjustment()
        #expect(oneAxisEditor.regionSelection?.pixelRect != previous)
    }

    @Test func reentrantCommitHandlerNeitherRecursesNorLosesTheTransaction() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let editor = try makeEditor(initial)
        var depth = 0
        var maximumDepth = 0
        editor.commitTextHandler = {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            editor.commitTextEditing()
            depth -= 1
        }
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 3, width: 5, height: 6)))
        editor.beginTransaction(id: mark.id, actionName: "创建标注")
        editor.updateTransaction(mark)
        editor.commitTextEditing()

        #expect(maximumDepth == 1)
        #expect(!editor.hasTransaction)
        #expect(editor.document.annotations == [mark])
        #expect(editor.undoManager.canUndo)
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
    }

    @Test func beginningSelectionMoveCommitsPendingWorkAndCommitEndsTheGesture() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let editor = try makeEditor(initial)
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 3, width: 5, height: 6)))
        editor.beginTransaction(id: mark.id, actionName: "创建标注")
        editor.updateTransaction(mark)

        #expect(editor.beginSelectionAdjustment())
        #expect(!editor.hasTransaction)
        #expect(editor.document.annotations == [mark])
        try editor.updateSelectionAdjustment(by: CGSize(width: 6, height: 0))
        editor.commitTextEditing()

        let moved = try #require(editor.regionSelection?.pixelRect)
        #expect(moved != initial.pixelRect)
        #expect(editor.undoManager.canUndo)
        editor.undo()
        #expect(editor.regionSelection?.pixelRect == initial.pixelRect)
        #expect(editor.document.annotations == [mark])
    }

    @Test func invalidateDropsRegionContext() throws {
        let source = try makeSource()
        let initial = try selection(source, frame: CGRect(x: 0, y: 0, width: 64, height: 48),
                                    rect: CGRect(x: 8, y: 12, width: 16, height: 12))
        let editor = try makeEditor(initial)
        #expect(editor.beginSelectionAdjustment())
        editor.invalidate()
        #expect(editor.regionSelection == nil)
        #expect(!editor.canMoveCaptureSelection)
        #expect(!editor.beginSelectionAdjustment())
        #expect(!editor.undoManager.canUndo)
    }
}
