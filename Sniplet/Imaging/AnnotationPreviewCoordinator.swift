import CoreGraphics
import Foundation

/// Only immutable source-alpha resources cross the worker boundary, never annotations.
nonisolated struct AnnotationShadowRequest: Sendable {
    let key: AnnotationShadowKey
    let style: CaptureStyle
    let geometry: CaptureStyleGeometry
    let cornerMask: CGImage?

    init(source: CGImage, style: CaptureStyle, sourceScale: CGFloat,
         geometry: CaptureStyleGeometry, cornerMask: CGImage?) {
        key = AnnotationShadowKey(source: source, style: style, sourceScale: sourceScale, geometry: geometry)
        self.style = style
        self.geometry = geometry
        self.cornerMask = cornerMask
    }
}

/// A single lifetime worker with one in-flight request and one replaceable pending request.
/// Stale completions cannot put an old shadow back onto a new style or a detached canvas.
final class AnnotationPreviewCoordinator {
    nonisolated enum State: Equatable, Sendable { case idle, updating, ready, failed(String) }
    typealias Builder = @Sendable (AnnotationShadowRequest) async throws -> CGImage

    private let stream: AsyncStream<AnnotationShadowRequest?>
    private let continuation: AsyncStream<AnnotationShadowRequest?>.Continuation
    private let builder: Builder
    private var worker: Task<Void, Never>?
    private var desiredKey: AnnotationShadowKey?
    private var isDetached = false
    private(set) var shadow: CGImage?
    private(set) var state: State = .idle
    var onChange: ((State) -> Void)?

    init(builder: @escaping Builder = { try await AnnotationPreviewCoordinator.buildShadow($0) }) {
        let channel = AsyncStream<AnnotationShadowRequest?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = channel.stream
        continuation = channel.continuation
        self.builder = builder
    }

    func update(_ request: AnnotationShadowRequest?) {
        guard !isDetached, desiredKey != request?.key else { return }
        desiredKey = request?.key
        shadow = nil
        state = request == nil ? .idle : .updating
        if worker == nil, request != nil {
            let stream = stream
            let builder = builder
            worker = Task { [weak self] in
                for await request in stream {
                    guard !Task.isCancelled else { return }
                    guard let request, self?.needsPreparation(request) == true else { continue }
                    do {
                        let image = try await builder(request)
                        guard !Task.isCancelled else { return }
                        self?.complete(request, result: .success(image))
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.complete(request, result: .failure(error))
                    }
                }
            }
        }
        continuation.yield(request)
        onChange?(state)
    }

    func detach() {
        isDetached = true
        desiredKey = nil
        shadow = nil
        continuation.yield(nil)
        state = .idle
        continuation.finish()
        worker?.cancel()
        worker = nil
        onChange?(.idle)
        onChange = nil
    }

    private func needsPreparation(_ request: AnnotationShadowRequest) -> Bool {
        !isDetached && desiredKey == request.key && state == .updating
    }

    private func complete(_ request: AnnotationShadowRequest, result: Result<CGImage, any Error>) {
        guard !isDetached, desiredKey == request.key else { return }
        switch result {
        case let .success(image):
            shadow = image
            state = .ready
        case let .failure(error):
            shadow = nil
            state = .failed(error.localizedDescription)
        }
        onChange?(state)
    }

    @concurrent
    private static func buildShadow(_ request: AnnotationShadowRequest) async throws -> CGImage {
        try Task.checkCancellation()
        let image = try AnnotationCompositor.makeShadow(source: request.key.source, style: request.style,
                                                         geometry: request.geometry, mask: request.cornerMask)
        try Task.checkCancellation()
        return image
    }

    deinit {
        continuation.finish()
        worker?.cancel()
    }
}
