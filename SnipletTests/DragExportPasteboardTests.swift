import AppKit
import Testing
@testable import Sniplet

@MainActor struct DragExportPasteboardTests {
    @Test func fileOnlyReceiverGetsOneReadableFinalImageAfterSourceCloses() async throws {
        let source = try SessionTestSupport.capture()
        var document = AnnotationDocument(capture: source)
        document.annotations = [Annotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 16, height: 16), blockSize: 8))]
        let final = try await ImageRenderer().render(document)
        let snapshot = try await EncodedCapture(capture: final, pngData: ImageEncoder().png(final.image))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try await DragExportFileStore(root: root).stage(snapshot)
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents(); board.releaseGlobally() }
        board.prepareForNewContents(with: .currentHostOnly)
        var provider: SnapshotFilePromiseProvider? = SnapshotFilePromiseProvider(
            context: PromiseContext(snapshot: snapshot, onFailure: { _, _ in Issue.record("Unexpected file promise failure") }),
            fileURL: file)
        try #require(board.writeObjects([try #require(provider)]))
        let urls = try #require(board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL])
        try #require(urls.count == 1)
        let receivedURL = try #require(urls.first)
        board.clearContents()
        provider = nil
        let image = try SessionTestSupport.image(Data(contentsOf: receivedURL))
        #expect(image.width == final.image.width && image.height == final.image.height)
        #expect(try SessionTestSupport.pixel(image, x: 10, y: 10) == SessionTestSupport.pixel(final.image, x: 10, y: 10))
        #expect(try SessionTestSupport.pixel(image, x: 10, y: 10) != SessionTestSupport.pixel(source.image, x: 10, y: 10))
    }
}
