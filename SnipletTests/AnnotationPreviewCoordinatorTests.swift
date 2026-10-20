import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

@MainActor
struct AnnotationPreviewCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func inFlightOldStyleCannotReplaceNewestStyleOrSource() async throws {
        let source = try image(alpha: 1)
        let newestSource = try image(alpha: 0.5)
        let first = try request(source: source, radius: 2)
        let skipped = try request(source: source, radius: 4)
        let latest = try request(source: newestSource, radius: 6)
        let gate = ShadowPreparationGate()
        let coordinator = AnnotationPreviewCoordinator { request in
            await gate.waitBeforeBuild(request.key.radius)
            return try await Self.build(request)
        }
        defer {
            coordinator.detach()
            Task { await gate.releaseAll() }
        }
        let events = AsyncStream<AnnotationPreviewCoordinator.State>.makeStream()
        coordinator.onChange = { events.continuation.yield($0) }
        var states = events.stream.makeAsyncIterator()
        var starts = gate.starts.makeAsyncIterator()

        coordinator.update(first)
        #expect(await starts.next() == 2)
        coordinator.update(skipped)
        coordinator.update(latest)
        await gate.release(2)
        // Receiving the next start means the old completion was already processed on MainActor.
        // The intermediate request was replaced, not queued for another expensive render.
        try #require(await starts.next() == 6)
        #expect(coordinator.state == .updating)
        #expect(coordinator.shadow == nil)
        await gate.release(6)
        while let state = await states.next() {
            if state == .ready { break }
        }
        let actual = try #require(coordinator.shadow)
        let expected = try await Self.build(latest)
        let actualBytes = try #require(actual.dataProvider?.data) as Data
        let expectedBytes = try #require(expected.dataProvider?.data) as Data
        #expect(actualBytes == expectedBytes)
        coordinator.detach()
        #expect(coordinator.state == .idle)
        #expect(coordinator.shadow == nil)
        coordinator.update(first)
        #expect(coordinator.state == .idle)
        #expect(coordinator.shadow == nil)
    }

    private func image(alpha: CGFloat) throws -> CGImage {
        let context = try AnnotationCompositor.bitmap(width: 48, height: 36)
        context.setFillColor(CGColor(gray: 1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 36))
        return try #require(context.makeImage())
    }

    private func request(source: CGImage, radius: CGFloat) throws -> AnnotationShadowRequest {
        let style = CaptureStyle(cornerRadius: radius, shadow: .subtle, borderWidth: 1)
        let geometry = style.geometry(imageSize: CGSize(width: source.width, height: source.height), sourceScale: 1)
        let mask = try AnnotationCompositor.makeCornerMask(size: geometry.contentBounds.size, radius: radius)
        return AnnotationShadowRequest(source: source, style: style, sourceScale: 1,
                                       geometry: geometry, cornerMask: mask)
    }

    @concurrent
    private static func build(_ request: AnnotationShadowRequest) async throws -> CGImage {
        try AnnotationCompositor.makeShadow(source: request.key.source, style: request.style,
                                             geometry: request.geometry, mask: request.cornerMask)
    }
}

private actor ShadowPreparationGate {
    nonisolated let starts: AsyncStream<CGFloat>
    private let continuation: AsyncStream<CGFloat>.Continuation
    private var waiting: [CGFloat: CheckedContinuation<Void, Never>] = [:]

    init() {
        let channel = AsyncStream<CGFloat>.makeStream()
        starts = channel.stream
        continuation = channel.continuation
    }

    func waitBeforeBuild(_ radius: CGFloat) async {
        await withCheckedContinuation { completion in
            waiting[radius] = completion
            continuation.yield(radius)
        }
    }

    func release(_ radius: CGFloat) {
        waiting.removeValue(forKey: radius)?.resume()
    }

    func releaseAll() {
        for completion in waiting.values { completion.resume() }
        waiting.removeAll()
        continuation.finish()
    }
}
