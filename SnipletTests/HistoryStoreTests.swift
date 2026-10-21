import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Sniplet

@Suite("Bounded final-image history")
struct HistoryStoreTests {
    @Test func smallCountLimitEvictsOldestAndDuplicateInsertIsIdempotent() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root, limits: HistoryLimits(maxCount: 2, maxBytes: 1_000_000))
        let first = try await historyFixture(at: 1)
        let second = try await historyFixture(at: 2)
        let third = try await historyFixture(at: 3)
        try await store.insert(first.capture, pngData: first.png)
        try await store.insert(second.capture, pngData: second.png)
        try await store.insert(second.capture, pngData: second.png)
        #expect(try await store.summaries().count == 2)
        try await store.insert(third.capture, pngData: third.png)
        let summaries = try await store.summaries()
        #expect(summaries.map(\.id) == [third.capture.id, second.capture.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images/\(first.capture.id).png").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails/\(first.capture.id).png").path))
    }

    @Test func byteLimitCountsBothFilesAndRejectsSingleOversizeWithoutPartialRecord() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await historyFixture(at: 1)
        let second = try await historyFixture(at: 2)
        let encoder = ImageEncoder()
        let thumbnail = try await encoder.thumbnail(first.capture.image, maxPixelSize: 320)
        let bytes = Int64(first.png.count + thumbnail.count)
        let store = try await HistoryStoreFactory.make(rootURL: root, limits: HistoryLimits(maxCount: 20, maxBytes: bytes + 1))
        try await store.insert(first.capture, pngData: first.png)
        #expect(try await store.summaries().first?.byteCount == bytes)
        try await store.insert(second.capture, pngData: second.png)
        #expect(try await store.summaries().map(\.id) == [second.capture.id])

        let smallRoot = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: smallRoot) }
        let tooSmall = try await HistoryStoreFactory.make(rootURL: smallRoot, limits: HistoryLimits(maxCount: 2, maxBytes: bytes - 1))
        await #expect(throws: HistoryError.self) { try await tooSmall.insert(first.capture, pngData: first.png) }
        #expect(try await tooSmall.summaries().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: smallRoot.appendingPathComponent("images").path).isEmpty)
    }

    @Test func stagedWriteFailureNeverCreatesSearchableHalfRecordOrDamagesExistingImage() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let first = try await historyFixture(at: 1)
        let second = try await historyFixture(at: 2)
        try await store.insert(first.capture, pngData: first.png)
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.removeItem(at: staging)
        try Data("not a directory".utf8).write(to: staging)
        await #expect(throws: (any Error).self) { try await store.insert(second.capture, pngData: second.png) }
        #expect(try await store.summaries().map(\.id) == [first.capture.id])
        #expect(try await store.pngData(for: first.capture.id) == first.png)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images/\(second.capture.id).png").path))
    }

    @Test func secondFileCommitFailureRollsBackAlreadyMovedFinalImage() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let fixture = try await historyFixture(at: 1)
        let conflictingThumbnail = root.appendingPathComponent("thumbnails/\(fixture.capture.id).png")
        try FileManager.default.createDirectory(at: conflictingThumbnail, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.insert(fixture.capture, pngData: fixture.png) }
        #expect(try await store.summaries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images/\(fixture.capture.id).png").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty)
    }

    @Test func concurrentDuplicateCompletionCommitsOneID() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let fixture = try await historyFixture(at: 1)
        async let first: Void = store.insert(fixture.capture, pngData: fixture.png)
        async let second: Void = store.insert(fixture.capture, pngData: fixture.png)
        _ = try await (first, second)
        #expect(try await store.summaries().map(\.id) == [fixture.capture.id])
    }

    @Test func cleanupIntentWriteFailureDoesNotDeleteMetadataAndPausesNewHistory() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let first = try await historyFixture(at: 1)
        let second = try await historyFixture(at: 2)
        try await store.insert(first.capture, pngData: first.png)
        let ledger = root.appendingPathComponent("cleanup.json")
        if FileManager.default.fileExists(atPath: ledger.path) { try FileManager.default.removeItem(at: ledger) }
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await store.delete(first.capture.id) }
        #expect(try await store.summaries().map(\.id) == [first.capture.id])
        #expect(try await store.pngData(for: first.capture.id) == first.png)
        #expect((await store.status()).cleanupError != nil)
        await #expect(throws: HistoryError.self) { try await store.insert(second.capture, pngData: second.png) }
        try FileManager.default.removeItem(at: ledger)
        try JSONEncoder().encode([UUID]()).write(to: ledger)
        try await store.retryCleanup()
        #expect(try await store.pngData(for: first.capture.id) == first.png)
        try await store.insert(second.capture, pngData: second.png)
        #expect(try await store.summaries().count == 2)
    }

    @Test func recoveryRemovesMissingFinalAndOrphansAndRebuildsThumbnailFromFinal() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let missing = try await historyFixture(at: 1)
        let retained = try await historyFixture(at: 2, width: 640, height: 400)
        try await store.insert(missing.capture, pngData: missing.png)
        try await store.insert(retained.capture, pngData: retained.png)
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/\(missing.capture.id).png"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("thumbnails/\(retained.capture.id).png"))
        let orphan = UUID()
        let orphanURL = root.appendingPathComponent("images/\(orphan).png")
        try retained.png.write(to: orphanURL)
        let staged = root.appendingPathComponent("staging/\(UUID()).png")
        try retained.png.write(to: staged)
        let recovered = try await HistoryStoreFactory.make(rootURL: root)
        #expect(try await recovered.summaries().map(\.id) == [retained.capture.id])
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails/\(missing.capture.id).png").path))
        let thumb = try await recovered.thumbnailImage(for: retained.capture.id)
        #expect(max(thumb.width, thumb.height) == 320)
        let final = try await recovered.loadImage(retained.capture.id)
        #expect(final.image.width == 640)
        #expect(final.image.height == 400)
        #expect(try await recovered.pngData(for: retained.capture.id) == retained.png)
    }

    @Test func corruptFinalDoesNotDisableOtherHistoryAndIsPreservedForExplicitDeletion() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let healthy = try await historyFixture(at: 1, width: 640, height: 400)
        let damaged = try await historyFixture(at: 2)
        try await store.insert(healthy.capture, pngData: healthy.png)
        try await store.insert(damaged.capture, pngData: damaged.png)
        for _ in 0..<2 {
            let work = try #require(try await store.nextPendingOCR())
            try await store.completeOCR(work, text: work.id == damaged.capture.id ? "unreadable-only" : "healthy-text", failed: false)
        }
        let damagedURL = root.appendingPathComponent("images/\(damaged.capture.id).png")
        let corruptData = Data("unreadable final image".utf8)
        try corruptData.write(to: damagedURL)
        for id in [healthy.capture.id, damaged.capture.id] {
            try FileManager.default.removeItem(at: root.appendingPathComponent("thumbnails/\(id).png"))
        }
        let recovered = try await HistoryStoreFactory.make(rootURL: root)
        let summaries = try await recovered.summaries()
        #expect(summaries.map(\.id) == [damaged.capture.id, healthy.capture.id])
        #expect(summaries.first?.ocrStatus == .failed)
        #expect(try await recovered.summaries(matching: "unreadable-only").isEmpty)
        #expect(try await recovered.summaries(matching: "healthy-text").map(\.id) == [healthy.capture.id])
        #expect(try Data(contentsOf: damagedURL) == corruptData)
        #expect(try await recovered.pngData(for: healthy.capture.id) == healthy.png)
        #expect(try await recovered.thumbnailImage(for: healthy.capture.id).width == 320)
        await #expect(throws: HistoryError.self) { _ = try await recovered.loadImage(damaged.capture.id) }
        try await recovered.delete(damaged.capture.id)
        #expect(!FileManager.default.fileExists(atPath: damagedURL.path))
        #expect(try await recovered.summaries().map(\.id) == [healthy.capture.id])
    }

    @Test func corruptLedgerStillRemovesMissingFinalMetadataBeforeExplicitCleanup() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let missing = try await historyFixture(at: 1)
        let healthy = try await historyFixture(at: 2)
        try await store.insert(missing.capture, pngData: missing.png)
        try await store.insert(healthy.capture, pngData: healthy.png)
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/\(missing.capture.id).png"))
        try Data("damaged cleanup manifest".utf8).write(to: root.appendingPathComponent("cleanup.json"))
        let recovered = try await HistoryStoreFactory.make(rootURL: root)
        #expect(try await recovered.summaries().map(\.id) == [healthy.capture.id])
        #expect((await recovered.status()).cleanupError != nil)
        #expect(try await recovered.pngData(for: healthy.capture.id) == healthy.png)
        try await recovered.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails/\(missing.capture.id).png").path))
        #expect(try await recovered.pngData(for: healthy.capture.id) == healthy.png)
    }

    @Test func cleanupRetryReconcilesFinalImageLostSinceStartup() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let missing = try await historyFixture(at: 1)
        let healthy = try await historyFixture(at: 2)
        try await store.insert(missing.capture, pngData: missing.png)
        try await store.insert(healthy.capture, pngData: healthy.png)
        try FileManager.default.removeItem(at: root.appendingPathComponent("images/\(missing.capture.id).png"))
        try await store.retryCleanup()
        #expect(try await store.summaries().map(\.id) == [healthy.capture.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("thumbnails/\(missing.capture.id).png").path))
        #expect(try await store.pngData(for: healthy.capture.id) == healthy.png)
    }

    @Test func unreadableDatabasePreservesFinalThumbnailAndStaging() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["images", "thumbnails", "staging"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let bytes = Data("private final snapshot sentinel".utf8)
        let id = UUID()
        let files = ["images/\(id).png", "thumbnails/\(id).png", "staging/\(id).png"]
        for file in files { try bytes.write(to: root.appendingPathComponent(file)) }
        let corruptDatabase = Data("this is not a SQLite database".utf8)
        try corruptDatabase.write(to: root.appendingPathComponent("history.store"))
        await #expect(throws: (any Error).self) { _ = try await HistoryStoreFactory.make(rootURL: root) }
        for file in files { #expect(try Data(contentsOf: root.appendingPathComponent(file)) == bytes) }
        #expect(try Data(contentsOf: root.appendingPathComponent("history.store")) == corruptDatabase)
    }

    @Test func durableCleanupIntentRetriesOnStartupAndNeverRemovesLiveRecords() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let live = try await historyFixture(at: 1)
        try await store.insert(live.capture, pngData: live.png)
        let orphan = UUID()
        let orphanURL = root.appendingPathComponent("images/\(orphan).png")
        try live.png.write(to: orphanURL)
        // Simulate termination after a saved metadata deletion, plus an intent whose save did not happen.
        let ledger = root.appendingPathComponent("cleanup.json")
        try JSONEncoder().encode([orphan, live.capture.id]).write(to: ledger, options: .atomic)
        let recovered = try await HistoryStoreFactory.make(rootURL: root)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(try await recovered.pngData(for: live.capture.id) == live.png)
        #expect(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: ledger)).isEmpty)
    }

    @Test func unreadableCleanupManifestPausesInsertAndCanBeRepairedWithoutDeletingLiveFiles() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let first = try await historyFixture(at: 1)
        let second = try await historyFixture(at: 2)
        try await store.insert(first.capture, pngData: first.png)
        let ledger = root.appendingPathComponent("cleanup.json")
        try Data("damaged cleanup manifest".utf8).write(to: ledger)
        let paused = try await HistoryStoreFactory.make(rootURL: root)
        #expect((await paused.status()).cleanupError != nil)
        await #expect(throws: HistoryError.self) { try await paused.insert(second.capture, pngData: second.png) }
        #expect(try await paused.pngData(for: first.capture.id) == first.png)
        try await paused.retryCleanup()
        try await paused.insert(second.capture, pngData: second.png)
        #expect(try await paused.summaries().count == 2)
    }

    @Test func deletedAndClearedOCRClaimsNeverResurrectAndFailedRequiresExplicitRetry() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let first = try await historyFixture(at: 1)
        try await store.insert(first.capture, pngData: first.png)
        let deletedWork = try #require(try await store.nextPendingOCR())
        try await store.delete(first.capture.id)
        try await store.completeOCR(deletedWork, text: "must never reappear", failed: false)
        #expect(try await store.summaries(matching: "reappear").isEmpty)
        #expect(try await store.summaries().isEmpty)

        let second = try await historyFixture(at: 2)
        try await store.insert(second.capture, pngData: second.png)
        let failedWork = try #require(try await store.nextPendingOCR())
        try await store.completeOCR(failedWork, text: nil, failed: true)
        #expect(try await store.summaries().first?.ocrStatus == .failed)
        #expect(try await store.nextPendingOCR() == nil)
        try await store.retryOCR(second.capture.id)
        let retried = try #require(try await store.nextPendingOCR())
        #expect(retried.token != failedWork.token)
        try await store.completeOCR(failedWork, text: "stale token", failed: false)
        #expect(try await store.summaries().first?.ocrStatus == .pending)
        try await store.clear()
        try await store.completeOCR(retried, text: "resurrect", failed: false)
        #expect(try await store.summaries().isEmpty)
    }

    @Test func successfulEmptyOCRDiffersFromFailureAndCancellationCanResumePending() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let fixture = try await historyFixture(at: 1)
        try await store.insert(fixture.capture, pngData: fixture.png)
        let first = try #require(try await store.nextPendingOCR())
        await store.releaseOCR(first)
        let second = try #require(try await store.nextPendingOCR())
        #expect(first.token != second.token)
        try await store.completeOCR(second, text: "  \n", failed: false)
        #expect(try await store.summaries().first?.ocrStatus == .empty)
        try await store.retryOCR(fixture.capture.id)
        #expect(try await store.nextPendingOCR() == nil)
    }
}

@MainActor struct HistoryDragOutTests {
    @Test func dragOutOffersTheStoredPNGOfTheSelection() async throws {
        let root = try temporaryHistoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HistoryStoreFactory.make(rootURL: root)
        let fixture = try await historyFixture(at: 1_800_000_000)
        try await store.insert(fixture.capture, pngData: fixture.png)
        let model = HistoryViewModel(store: store)
        await #expect(throws: CancellationError.self) { try await model.encodedSelection() }
        model.selection = fixture.capture.id
        for _ in 0..<200 where model.selectedCapture == nil { try await Task.sleep(for: .milliseconds(5)) }
        let encoded = try await model.encodedSelection()
        #expect(encoded.pngData == fixture.png)
        #expect(encoded.capture.id == fixture.capture.id)
        #expect(encoded.capture.createdAt == fixture.capture.createdAt)
    }
}

private func temporaryHistoryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnipletHistoryTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func historyFixture(at timestamp: TimeInterval, width: Int = 32, height: Int = 24) async throws -> (capture: RenderedCapture, png: Data) {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.15, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let capture = RenderedCapture(id: UUID(), revision: 4, createdAt: Date(timeIntervalSince1970: timestamp), mode: .region, image: image, sourceScale: 2)
    let png = try await ImageEncoder().png(image)
    return (capture, png)
}
