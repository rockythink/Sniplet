import Foundation
import Testing
@testable import Sniplet

@MainActor struct OCRConsistencyTests {
    private let result = OCRResult(text: "不可显示的旧文本", missingLanguages: [])

    @Test func movingMosaicRejectsLateTextBeforeViewInvalidation() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        editor.insert(Annotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 8, height: 8), blockSize: 8)))
        let key = try #require(session.beginOCR())
        editor.moveSelected(by: CGSize(width: 8, height: 0))
        #expect(!session.acceptOCR(result, for: key))
        #expect(session.ocrResult == nil)
        #expect(!session.isRecognizing)
    }

    @Test func undoRedoDoNotResurrectTextFromOldRevision() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        editor.insert(Annotation(payload: .text(rect: CGRect(x: 1, y: 1, width: 20, height: 18), text: "敏感文字")))
        let key = try #require(session.beginOCR())
        editor.undo()
        editor.redo()
        #expect(editor.document.revision > key.capture.revision)
        #expect(!session.acceptOCR(result, for: key))
        #expect(session.ocrResult == nil)
    }

    @Test func closingAndNewSessionRejectOldCompletion() throws {
        let old = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let oldKey = try #require(old.beginOCR())
        old.discard()
        #expect(!old.acceptOCR(result, for: oldKey))
        #expect(old.ocrResult == nil)
        let current = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        _ = current.beginOCR()
        #expect(!current.acceptOCR(result, for: oldKey))
        #expect(current.ocrResult == nil)
    }

    @Test func startingOutputInvalidatesPendingRecognitionEvenAtSameRevision() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let key = try #require(session.beginOCR())
        _ = try session.beginExport()
        #expect(!session.acceptOCR(result, for: key))
        session.cancelExport()
        #expect(!session.acceptOCR(result, for: key))
        #expect(session.ocrResult == nil)
    }

    @Test func restartedRecognitionAtSameRevisionRejectsPreviousRequest() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let previous = try #require(session.beginOCR())
        _ = try session.beginExport()
        session.cancelExport()
        let current = try #require(session.beginOCR())
        #expect(previous.capture == current.capture)
        #expect(!session.acceptOCR(result, for: previous))
        #expect(session.isRecognizing)
        let fresh = OCRResult(text: "当前识别", missingLanguages: [])
        #expect(session.acceptOCR(fresh, for: current))
        #expect(session.ocrResult == fresh)
        #expect(!session.isRecognizing)
    }

    @Test func changingAndUndoingScreenshotStyleCannotResurrectCachedOrPendingText() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        let before = try #require(session.beginOCR())
        #expect(session.acceptOCR(result, for: before))
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 8))
        #expect(session.ocrResult == nil)
        #expect(!session.acceptOCR(result, for: before))
        let rounded = try #require(session.beginOCR())
        editor.undo()
        #expect(!session.acceptOCR(result, for: rounded))
        #expect(session.ocrResult == nil)
        #expect(editor.document.revision > rounded.capture.revision)
        let current = try #require(session.beginOCR())
        let fresh = OCRResult(text: "当前成图文字", missingLanguages: [])
        #expect(session.acceptOCR(fresh, for: current))
        #expect(session.ocrResult == fresh)
    }
}
