import Foundation
import Testing
@testable import Sniplet

@MainActor struct DragExportFileStoreTests {
    private func snapshot() async throws -> EncodedCapture {
        let source = try SessionTestSupport.capture()
        let image = try await ImageRenderer().render(AnnotationDocument(capture: source))
        return try await EncodedCapture(capture: image, pngData: ImageEncoder().png(image.image))
    }

    @Test func cancellingOneDragDoesNotRemoveAnotherReceiversFinalPNG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DragExportFileStore(root: root)
        let snapshot = try await self.snapshot()
        let cancelled = try await store.stage(snapshot)
        let accepted = try await store.stage(snapshot)
        await store.discard(cancelled)
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        #expect(try Data(contentsOf: accepted) == snapshot.pngData)
        let image = try SessionTestSupport.image(Data(contentsOf: accepted))
        #expect(try SessionTestSupport.pixel(image, x: 10, y: 8) == SessionTestSupport.pixel(snapshot.capture.image, x: 10, y: 8))
    }

    @Test func nextDragReapsExpiredFinalFilesButPreservesRecentReceiversFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DragExportFileStore(root: root)
        let snapshot = try await self.snapshot()
        let expired = try await store.stage(snapshot)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: expired.deletingLastPathComponent().path)
        let recent = try await store.stage(snapshot)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        let next = try await store.stage(snapshot)
        #expect(try Data(contentsOf: recent) == snapshot.pngData)
        #expect(try Data(contentsOf: next) == snapshot.pngData)
    }
}
