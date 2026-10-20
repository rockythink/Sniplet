import Foundation
import Testing
@testable import Sniplet

@MainActor struct EditorSessionTests {
    @Test func exportFreezeBlocksEditsAndCancellationRestoresEditing() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 2, width: 10, height: 10)))
        editor.insert(mark)
        let frozen = try #require(try session.beginExport())
        editor.deleteSelected()
        editor.undo()
        #expect(editor.document.annotations == frozen.annotations)
        #expect(session.phase == .exporting)
        session.cancelExport()
        editor.deleteSelected()
        #expect(session.phase == .editing)
        #expect(editor.document.annotations.isEmpty)
        editor.undo()
        #expect(editor.document.annotations == [mark])
    }

    @Test func terminationLockRejectsOCRAndEditsUntilQuitIsCancelled() throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 2, width: 10, height: 10)))
        editor.insert(mark)
        let ticket = try #require(session.beginOCR())
        session.setTerminationRequested(true)
        editor.deleteSelected()
        #expect(editor.document.annotations == [mark])
        #expect(throws: CancellationError.self) { try session.beginExport() }
        #expect(!session.acceptOCR(OCRResult(text: "旧识别", missingLanguages: []), for: ticket))
        session.setTerminationRequested(false)
        editor.deleteSelected()
        #expect(editor.document.annotations.isEmpty)
        #expect(session.phase == .editing)
    }

    @Test func cancelledOutputNeverReusesPNGFromBeforeMosaicEdit() async throws {
        let capture = try SessionTestSupport.capture()
        let session = EditorSession(capture: capture, services: SessionTestSupport.services())
        let first = try await session.prepareDrag()
        session.dragCancelled()
        let editor = try #require(session.editor)
        editor.insert(Annotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 16, height: 16), blockSize: 8)))
        // Export immediately after mutation, without view-driven cache invalidation.
        let second = try await session.prepareDrag()
        let before = try SessionTestSupport.image(first.pngData)
        let after = try SessionTestSupport.image(second.pngData)
        #expect(try SessionTestSupport.pixel(before, x: 10, y: 10) == SessionTestSupport.pixel(capture.image, x: 10, y: 10))
        #expect(try SessionTestSupport.pixel(after, x: 10, y: 10) != SessionTestSupport.pixel(before, x: 10, y: 10))
        #expect(try SessionTestSupport.pixel(after, x: 24, y: 18) == SessionTestSupport.pixel(capture.image, x: 24, y: 18))
        #expect(try SessionTestSupport.pixel(after, x: 10, y: 10) == SessionTestSupport.pixel(second.capture.image, x: 10, y: 10))
        session.dragCancelled()
    }

    @Test func styleChangesInvalidatePNGWithoutChangingImageSizeAndUndoRestoresPixels() async throws {
        let capture = try SessionTestSupport.capture()
        let session = EditorSession(capture: capture, services: SessionTestSupport.services())
        let original = try await session.prepareDrag()
        session.dragCancelled()
        let editor = try #require(session.editor)
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 8))
        let rounded = try await session.prepareDrag()
        let before = try SessionTestSupport.image(original.pngData)
        let after = try SessionTestSupport.image(rounded.pngData)
        #expect(after.width == before.width)
        #expect(after.height == before.height)
        #expect(try SessionTestSupport.pixel(before, x: 0, y: 0)[3] == 255)
        #expect(try SessionTestSupport.pixel(after, x: 0, y: 0)[3] == 0)
        #expect(try SessionTestSupport.pixel(after, x: 16, y: 12) == SessionTestSupport.pixel(capture.image, x: 16, y: 12))
        session.dragCancelled()
        editor.undo()
        let restored = try await session.prepareDrag()
        let restoredImage = try SessionTestSupport.image(restored.pngData)
        #expect(restored.capture.revision > rounded.capture.revision)
        #expect(try SessionTestSupport.pixel(restoredImage, x: 0, y: 0) == SessionTestSupport.pixel(capture.image, x: 0, y: 0))
        session.dragCancelled()
    }

    @Test func completedSnapshotCannotReturnToEditableOriginal() async throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        let encoded = try await session.prepareDrag()
        session.stageFinal(encoded.capture, pngData: encoded.pngData)
        #expect(session.phase == .finalized)
        #expect(session.editor == nil)
        #expect(session.finalCapture?.image.width == 32)
        session.cancelExport()
        #expect(session.phase == .finalized)
        #expect(!session.acceptRendered(encoded.capture))
        session.discard()
        #expect(session.phase == .closed)
        #expect(session.finalCapture == nil)
        #expect(throws: CancellationError.self) { try session.beginExport() }
    }

    @Test func historyFailureRetainsOnlyFinalImageAndRetryClosesAfterRealWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("destination")
        try Data([1]).write(to: blocked)
        let writer = SessionTestWriter(destination: blocked.appendingPathComponent("final.png"))
        let services = SessionTestSupport.services(history: true, persist: { _, png in try await writer.write(png) })
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: services)
        let first = await withCheckedContinuation { continuation in
            session.onFinishAttempt = { continuation.resume(returning: $0) }
            session.output(.finish)
        }
        #expect(!first)
        #expect(session.phase == .finalized)
        #expect(session.editor == nil)
        #expect(!session.historyStored)
        let final = try #require(session.finalCapture)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let retried = await withCheckedContinuation { continuation in
            session.onFinishAttempt = { continuation.resume(returning: $0) }
            session.retryHistory()
        }
        #expect(retried)
        #expect(session.phase == .closed)
        let stored = try SessionTestSupport.image(Data(contentsOf: blocked.appendingPathComponent("final.png")))
        #expect(try SessionTestSupport.pixel(stored, x: 10, y: 10) == SessionTestSupport.pixel(final.image, x: 10, y: 10))
    }

    @Test func alreadyCancelledDragDoesNotCommitUnfinishedAnnotationOrLockEditing() async throws {
        let session = EditorSession(capture: try SessionTestSupport.capture(), services: SessionTestSupport.services())
        defer { session.discard() }
        let editor = try #require(session.editor)
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 3, width: 12, height: 8)))
        editor.beginTransaction(id: mark.id)
        editor.updateTransaction(mark)
        let task = Task { @MainActor in try await session.prepareDrag() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A released drag must not prepare output")
        } catch is CancellationError { }
        #expect(session.phase == .editing)
        #expect(session.canOutput)
        #expect(editor.isInteractionEnabled)
        #expect(editor.hasTransaction)
        #expect(!editor.undoManager.canUndo)
        editor.endTransaction()
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
    }
}

private actor SessionTestWriter {
    let destination: URL
    init(destination: URL) { self.destination = destination }
    func write(_ data: Data) throws { try data.write(to: destination, options: .atomic) }
}
