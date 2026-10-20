import AppKit
import Foundation
import Testing
@testable import Sniplet

@MainActor struct CaptureStyleEditingTests {
    private func capture() throws -> CapturedImage {
        let context = try AnnotationCompositor.bitmap(width: 120, height: 80)
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .region,
                             image: try #require(context.makeImage()), sourceScale: 2, displayID: 1)
    }

    @Test func styleIsOneUndoItemWithSynchronousMonotonicRevisionAndLayout() throws {
        let capture = try capture()
        let editor = AnnotationEditor(capture: capture)
        let styled = CaptureStyle(cornerRadius: 12, shadow: .medium, borderWidth: 2, borderColor: .blue)
        var revisions: [UInt64] = []
        var dirty: [CGRect] = []
        editor.revisionHandler = { revisions.append($0) }
        editor.changeHandler = { dirty.append($0) }
        editor.setCaptureStyle(styled)
        #expect(editor.document.captureStyle == styled)
        #expect(editor.document.imageBounds == CGRect(x: 0, y: 0, width: 120, height: 80))
        #expect(revisions == [1])
        let expanded = styled.geometry(imageSize: CGSize(width: 120, height: 80), sourceScale: 2).presentationBounds
        #expect(dirty.last?.contains(expanded) == true)
        editor.undo()
        #expect(editor.document.captureStyle == .plain)
        #expect(!editor.undoManager.canUndo)
        editor.redo()
        #expect(editor.document.captureStyle == styled)
        #expect(revisions == [1, 2, 3])
        #expect(dirty.count == 3)
        #expect(dirty.allSatisfy { $0.contains(expanded) })
        editor.setCaptureStyle(styled)
        #expect(revisions == [1, 2, 3])
        editor.undo()
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 4))
        #expect(!editor.undoManager.canRedo)
        #expect(editor.document.revision == 5)
        editor.invalidate()
        editor.setCaptureStyle(.plain)
        #expect(editor.document.revision == 5)
    }

    @Test func styleCommitsActiveGestureBeforeRegisteringItsOwnUndo() throws {
        let editor = AnnotationEditor(capture: try capture())
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 4, y: 5, width: 30, height: 20)))
        editor.beginTransaction(id: mark.id, actionName: "创建标注")
        editor.updateTransaction(mark)
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 8))
        #expect(!editor.hasTransaction)
        #expect(editor.document.annotations == [mark])
        editor.undo()
        #expect(editor.document.captureStyle == .plain)
        #expect(editor.document.annotations == [mark])
        editor.undo()
        #expect(editor.document.annotations.isEmpty)
        editor.redo()
        #expect(editor.document.annotations == [mark])
        editor.redo()
        #expect(editor.document.captureStyle.cornerRadius == 8)
    }

    @Test func manyLiveStyleUpdatesBecomeOneUndoAndRedo() throws {
        let initial = CaptureStyle(cornerRadius: 4, shadow: .subtle)
        let editor = AnnotationEditor(capture: try capture(), captureStyle: initial)
        editor.beginCaptureStyleTransaction()
        editor.beginCaptureStyleTransaction()
        for radius: CGFloat in [8, 12, 16, 24] {
            editor.setCaptureStyle(CaptureStyle(cornerRadius: radius, shadow: .subtle))
        }
        #expect(editor.document.captureStyle.cornerRadius == 24)
        #expect(editor.document.revision == 4)
        #expect(!editor.undoManager.canUndo)
        editor.endCaptureStyleTransaction()
        editor.endCaptureStyleTransaction()
        editor.undo()
        #expect(editor.document.captureStyle == initial)
        #expect(editor.document.revision == 5)
        #expect(!editor.undoManager.canUndo)
        editor.redo()
        #expect(editor.document.captureStyle == CaptureStyle(cornerRadius: 24, shadow: .subtle))
        #expect(editor.document.revision == 6)
        #expect(!editor.undoManager.canRedo)
    }

    @Test func noOpStyleGesturesKeepExistingRedoBranchWithoutCreatingUndo() throws {
        let editor = AnnotationEditor(capture: try capture())
        let previous = CaptureStyle(cornerRadius: 4)
        editor.setCaptureStyle(previous)
        editor.undo()
        editor.beginCaptureStyleTransaction()
        editor.endCaptureStyleTransaction()
        #expect(!editor.undoManager.canUndo)
        #expect(editor.undoManager.canRedo)
        editor.beginCaptureStyleTransaction()
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 16))
        editor.setCaptureStyle(.plain)
        editor.endCaptureStyleTransaction()
        #expect(editor.document.captureStyle == .plain)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.undoManager.canRedo)
        editor.redo()
        #expect(editor.document.captureStyle == previous)
    }

    @Test func undoCommitsAnInProgressStyleGestureAndLateSliderEndAddsNothing() throws {
        let editor = AnnotationEditor(capture: try capture())
        editor.beginCaptureStyleTransaction()
        editor.setCaptureStyle(CaptureStyle(borderWidth: 1))
        editor.setCaptureStyle(CaptureStyle(borderWidth: 2))
        editor.undo()
        #expect(editor.document.captureStyle == .plain)
        #expect(!editor.undoManager.canUndo)
        editor.endCaptureStyleTransaction()
        #expect(!editor.undoManager.canUndo)
        editor.redo()
        #expect(editor.document.captureStyle == CaptureStyle(borderWidth: 2))
        editor.invalidate()
        editor.endCaptureStyleTransaction()
        #expect(!editor.undoManager.canUndo)
        #expect(!editor.undoManager.canRedo)
    }

    @Test func outputFreezeCommitsLiveStyleGestureAsOneUndoableFinalSnapshot() async throws {
        let source = try SessionTestSupport.capture()
        let session = EditorSession(capture: source, services: SessionTestSupport.services())
        let editor = try #require(session.editor)
        editor.beginCaptureStyleTransaction()
        for radius: CGFloat in [2, 4, 8] {
            editor.setCaptureStyle(CaptureStyle(cornerRadius: radius))
        }
        let encoded = try await session.prepareDrag()
        #expect(session.phase == .exporting)
        #expect(encoded.capture.revision == 3)
        #expect(try SessionTestSupport.pixel(SessionTestSupport.image(encoded.pngData), x: 0, y: 0)[3] == 0)
        editor.setCaptureStyle(.plain)
        editor.endCaptureStyleTransaction()
        #expect(editor.document.captureStyle == CaptureStyle(cornerRadius: 8))
        session.dragCancelled()
        editor.undo()
        #expect(editor.document.captureStyle == .plain)
        #expect(!editor.undoManager.canUndo)
        let restored = try await session.prepareDrag()
        #expect(restored.capture.revision > encoded.capture.revision)
        #expect(try SessionTestSupport.pixel(SessionTestSupport.image(restored.pngData), x: 0, y: 0)[3] == 255)
        session.dragCancelled()
    }

    @Test func disabledEditingPreservesStyleAndUndoHistory() throws {
        let initial = CaptureStyle(cornerRadius: 16, shadow: .subtle)
        let editor = AnnotationEditor(capture: try capture(), captureStyle: initial)
        editor.isInteractionEnabled = false
        editor.beginCaptureStyleTransaction()
        editor.setCaptureStyle(.plain)
        editor.endCaptureStyleTransaction()
        #expect(editor.document.captureStyle == initial)
        #expect(editor.document.revision == 0)
        #expect(!editor.undoManager.canUndo)
        editor.isInteractionEnabled = true
        editor.setCaptureStyle(.plain)
        editor.undo()
        #expect(editor.document.captureStyle == initial)
        #expect(!editor.undoManager.canUndo)

        editor.beginCaptureStyleTransaction()
        editor.setCaptureStyle(CaptureStyle(cornerRadius: 8))
        editor.invalidate()
        editor.endCaptureStyleTransaction()
        #expect(!editor.undoManager.canUndo)
    }

    @Test func savedStyleCanBeReopenedChangedAndReset() throws {
        let name = "SnipletTests.CaptureStyle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        let chosen = CaptureStyle(cornerRadius: 24, shadow: .strong, borderWidth: 1.5, borderColor: .gray)
        preferences.defaultCaptureStyle = chosen
        let restored = AppPreferences(defaults: defaults)
        #expect(restored.defaultCaptureStyle == chosen)
        let changed = CaptureStyle(cornerRadius: 4)
        restored.defaultCaptureStyle = changed
        #expect(AppPreferences(defaults: defaults).defaultCaptureStyle == changed)
        preferences.defaultCaptureStyle = .plain
        #expect(AppPreferences(defaults: defaults).defaultCaptureStyle == .plain)
    }

    @Test func unreadableDefaultsRecoverPlainAndNumericValuesAreBounded() throws {
        let name = "SnipletTests.CaptureStyleCorrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for bad in [Data("not json".utf8), Data("{\"shadow\":\"missing\"}".utf8)] {
            defaults.set(bad, forKey: "capture.defaultStyle")
            #expect(AppPreferences(defaults: defaults).defaultCaptureStyle == .plain)
        }
        defaults.set("wrong type", forKey: "capture.defaultStyle")
        #expect(AppPreferences(defaults: defaults).defaultCaptureStyle == .plain)
        let style = CaptureStyle(cornerRadius: 999, shadow: .strong, borderWidth: -10)
        defaults.set(try JSONEncoder().encode(style), forKey: "capture.defaultStyle")
        let normalized = AppPreferences(defaults: defaults).defaultCaptureStyle
        #expect(normalized.cornerRadius == 48)
        #expect(normalized.borderWidth == 0)
        #expect(CaptureStyle(cornerRadius: .nan, borderWidth: .infinity).normalized == .plain)
    }
}
