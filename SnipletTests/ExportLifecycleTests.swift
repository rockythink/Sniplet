import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Sniplet

nonisolated struct ExportLifecycleTests {
    @Test func promiseWritesExactlyTheFrozenPNGOnce() async throws {
        let snapshot = try await fixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("promised.png")
        let context = PromiseContext(snapshot: snapshot, tracker: PromiseWriteTracker(), onFailure: { _, _ in
            Issue.record("A successful promise must not report recovery failure")
        })
        let report = try await performWrite(context, to: url)
        #expect(report.callbackCount == 1)
        #expect(!report.failed)
        #expect(context.tracker.pendingWriteCount == 0)
        let data = try Data(contentsOf: url)
        #expect(data == snapshot.pngData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == snapshot.capture.image.width)
        #expect(image.height == snapshot.capture.image.height)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["promised.png"])
    }

    @Test @MainActor func failedWriteReportsOnceAndRecoversOnlyFinalSnapshot() async throws {
        let snapshot = try await fixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingParent = directory.appendingPathComponent("not-created/result.png")
        let tracker = PromiseWriteTracker()
        let (stream, continuation) = AsyncStream<EncodedCapture>.makeStream()
        let context = PromiseContext(snapshot: snapshot, tracker: tracker) { recovered, _ in
            continuation.yield(recovered)
            continuation.finish()
        }
        let report = try await performWrite(context, to: missingParent)
        #expect(report.callbackCount == 1)
        #expect(report.failed)
        var iterator = stream.makeAsyncIterator()
        let recovered = try #require(await iterator.next())
        #expect(recovered.capture.id == snapshot.capture.id)
        #expect(recovered.capture.revision == snapshot.capture.revision)
        #expect(recovered.pngData == snapshot.pngData)
        #expect(recovered.tiffData == snapshot.tiffData)
        await tracker.waitForPendingWrites()
        #expect(tracker.pendingWriteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: missingParent.path))
    }

    @Test @MainActor func providerKeepsItsWeakDelegateAliveAndOffersOnlyFrozenRepresentations() async throws {
        let snapshot = try await fixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await DragExportFileStore(root: directory).stage(snapshot)
        weak var weakContext: PromiseContext?
        var provider: SnapshotFilePromiseProvider?
        do {
            let context = PromiseContext(snapshot: snapshot, onFailure: { _, _ in })
            weakContext = context
            provider = SnapshotFilePromiseProvider(context: context, fileURL: file)
        }
        #expect(weakContext != nil)
        // File-only receivers get the same final PNG, not the editable source.
        let fileString = try #require(provider?.pasteboardPropertyList(forType: .fileURL) as? String)
        let receivedURL = try #require(URL(string: fileString))
        #expect(try Data(contentsOf: receivedURL) == snapshot.pngData)
        provider = nil
        #expect(weakContext == nil)
        #expect(try Data(contentsOf: receivedURL) == snapshot.pngData)
    }

    @Test @MainActor func aStartedWriteRetainsContextAfterSourceProviderIsReleased() async throws {
        let snapshot = try await fixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("after-source-closed.png")
        let source = try await DragExportFileStore(root: directory.appendingPathComponent("source")).stage(snapshot)
        let queue = OperationQueue()
        queue.isSuspended = true
        let report: PromiseWriteReport = await withCheckedContinuation { continuation in
            let context = PromiseContext(snapshot: snapshot, tracker: PromiseWriteTracker(), onFailure: { _, _ in })
            var provider: SnapshotFilePromiseProvider? = SnapshotFilePromiseProvider(context: context, fileURL: source)
            weak var weakContext: PromiseContext?
            weakContext = provider?.userInfo as? PromiseContext
            queue.addOperation { [context] in
                var count = 0
                var failed = false
                context.write(to: destination) { error in
                    count += 1
                    failed = error != nil
                }
                continuation.resume(returning: PromiseWriteReport(callbackCount: count, failed: failed))
            }
            provider = nil
            #expect(weakContext != nil)
            queue.isSuspended = false
        }
        #expect(report.callbackCount == 1)
        #expect(!report.failed)
        #expect(try Data(contentsOf: destination) == snapshot.pngData)
    }

    @Test @MainActor func quitDrainWaitsUntilFailedPromiseHasDeliveredItsRecoveryImage() async throws {
        let snapshot = try await fixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = PromiseWriteTracker()
        let recovery = PromiseRecoveryObservation()
        let context = PromiseContext(snapshot: snapshot, tracker: tracker) { image, _ in
            recovery.snapshot = image
        }
        // The recovery callback is queued on this actor; it cannot run until we yield.
        context.write(to: directory.appendingPathComponent("missing/result.png")) { error in
            #expect(error != nil)
        }
        #expect(tracker.pendingWriteCount == 1)
        #expect(recovery.snapshot == nil)
        await tracker.waitForPendingWrites()
        #expect(recovery.snapshot?.pngData == snapshot.pngData)
        #expect(tracker.pendingWriteCount == 0)
    }

    private func fixture() async throws -> EncodedCapture {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        let image = try #require(context.makeImage())
        let capture = RenderedCapture(id: UUID(), revision: 9, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      mode: .region, image: image, sourceScale: 2)
        let encoder = ImageEncoder()
        return try await EncodedCapture(capture: capture, pngData: encoder.png(image), tiffData: encoder.tiff(image))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor private final class PromiseRecoveryObservation {
    var snapshot: EncodedCapture?
}

nonisolated private struct PromiseWriteReport: Sendable {
    let callbackCount: Int
    let failed: Bool
}

@concurrent
nonisolated private func performWrite(_ context: PromiseContext, to url: URL) async throws -> PromiseWriteReport {
    // Use the Objective-C callback entry point from a background executor, as
    // NSFileProviderXPCMessenger does before requesting the actual promised PNG.
    let provider = NSFilePromiseProvider()
    provider.fileType = "public.png"
    provider.delegate = context
    let selector = NSSelectorFromString("operationQueueForFilePromiseProvider:")
    guard let queue = context.perform(selector, with: provider)?.takeUnretainedValue() as? OperationQueue else {
        throw CocoaError(.featureUnsupported)
    }
    return await withCheckedContinuation { continuation in
        queue.addOperation {
            let writeProvider = NSFilePromiseProvider()
            var count = 0
            var failed = false
            context.filePromiseProvider(writeProvider, writePromiseTo: url) { error in
                count += 1
                failed = error != nil
            }
            continuation.resume(returning: PromiseWriteReport(callbackCount: count, failed: failed))
        }
    }
}
