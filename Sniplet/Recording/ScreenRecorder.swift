import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Pure geometry for a recording: what part of the display to stream and at what size.
nonisolated enum RecordingGeometry {
    /// H.264 hardware encoders top out around 4K; larger areas are scaled down to fit.
    static let maxPixels: CGFloat = 3840 * 2160
    static let maxSide: CGFloat = 4096

    /// Just above the area's top-right corner; below it when there is no room above;
    /// inside the corner when the area fills the screen. Always on the visible screen.
    static func stopButtonFrame(size: CGSize, area: CGRect, visible: CGRect, gap: CGFloat = 6) -> CGRect {
        var origin = CGPoint(x: area.maxX - size.width, y: area.maxY + gap)
        if origin.y + size.height > visible.maxY {
            origin.y = area.minY - gap - size.height
            if origin.y < visible.minY {
                origin = CGPoint(x: area.maxX - size.width - gap, y: area.maxY - size.height - gap)
            }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// `rect` is in global AppKit points; ScreenCaptureKit wants display-local points, top-left origin.
    static func sourceRect(for rect: CGRect, screenFrame: CGRect) -> CGRect {
        let clipped = rect.intersection(screenFrame)
        return CGRect(x: clipped.minX - screenFrame.minX, y: screenFrame.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }

    /// Even pixel dimensions (required by 4:2:0 encoding), scaled down only when too large.
    static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        var width = points.width * scale
        var height = points.height * scale
        guard width.isFinite, height.isFinite, width >= 2, height >= 2 else { return nil }
        let shrink = min(1, maxSide / max(width, height), (maxPixels / (width * height)).squareRoot())
        width *= shrink
        height *= shrink
        let even = { (value: CGFloat) in max(2, Int(value.rounded(.down)) & ~1) }
        return (even(width), even(height))
    }
}

nonisolated enum RecordingError: LocalizedError {
    case areaTooSmall
    case noFrames
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .areaTooSmall: "录制区域太小，请重新框选。"
        case .noFrames: "没有录到画面，请重试。"
        case let .writerFailed(message): "录屏文件写入失败：" + message
        }
    }
}

/// Owns the stream and writer for one recording at a time.
actor ScreenRecordingEngine {
    private var stream: SCStream?
    private var sink: RecordingSink?

    func start(displayID: CGDirectDisplayID, rect: CGRect, screenFrame: CGRect, to url: URL,
               onFailure: @escaping @Sendable (Error) -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        // Excluding the whole app also hides windows opened later: the border, overlays, editors.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let source = RecordingGeometry.sourceRect(for: rect, screenFrame: screenFrame)
        guard let size = RecordingGeometry.outputSize(points: source.size, scale: CGFloat(filter.pointPixelScale)) else {
            throw RecordingError.areaTooSmall
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.queueDepth = 6

        let sink = try RecordingSink(url: url, width: size.width, height: size.height, onFailure: onFailure)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()
        self.stream = stream
        self.sink = sink
    }

    /// Finishes the file even after the stream failed, keeping whatever was recorded.
    func stop() async throws {
        guard let sink else { return }
        let stream = self.stream
        self.stream = nil
        self.sink = nil
        try? await stream?.stopCapture()
        try await sink.finish()
    }
}

/// Writer state is touched only on `queue`, where ScreenCaptureKit also delivers frames.
nonisolated final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Sniplet.Recording", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let onFailure: @Sendable (Error) -> Void
    private var started = false
    private var finished = false

    init(url: URL, width: Int, height: Int, onFailure: @escaping @Sendable (Error) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Screen content is mostly still; this keeps text crisp without large files.
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 3),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("无法创建视频轨道") }
        writer.add(input)
        self.onFailure = onFailure
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            guard writer.startWriting() else {
                finished = true
                onFailure(RecordingError.writerFailed(writer.error?.localizedDescription ?? "未知错误"))
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        // Real-time input: dropping a frame under load beats stalling the capture queue.
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error)
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                finished = true
                guard started else { continuation.resume(throwing: RecordingError.noFrames); return }
                guard writer.status == .writing else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecordingError.writerFailed(
                        writer.error?.localizedDescription ?? "未知错误"))
                    return
                }
                input.markAsFinished()
                // Frames arrive only when the screen changes; hold the last one until now.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                writer.finishWriting { [self] in
                    if writer.status == .completed { continuation.resume() }
                    else {
                        continuation.resume(throwing: RecordingError.writerFailed(
                            writer.error?.localizedDescription ?? "未知错误"))
                    }
                }
            }
        }
    }
}

/// Recording files live in the app's temporary directory until saved or discarded.
nonisolated enum RecordingFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Sniplet-Recordings", isDirectory: true)
    }

    static func newURL(createdAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(ExportFilename.mp4(createdAt: createdAt))
    }

    /// Nothing outlives a launch: an unsaved recording from a previous run is gone with its panel.
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A click-through outline around the area being recorded, plus a small stop button
/// beside it. The recording excludes both: the whole app is filtered out.
@MainActor final class RecordingBorderPanel {
    private var panel: NSPanel?
    private var stopPanel: NSPanel?
    private var area: CGRect = .zero

    func show(around rect: CGRect) {
        area = rect
        let panel = AreaPanels.outline(around: rect, color: .systemRed)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Clicking it never activates Sniplet, so the app being recorded keeps focus.
    func showStopButton(startedAt: Date, onStop: @escaping () -> Void) {
        let host = NSHostingView(rootView: RecordingStopButton(startedAt: startedAt, onStop: onStop))
        let size = host.fittingSize
        let visible = NSScreen.screens.first(where: { $0.frame.intersects(area) })?.visibleFrame ?? area
        let panel = AreaPanels.make(frame: RecordingGeometry.stopButtonFrame(size: size, area: area, visible: visible))
        panel.contentView = host
        panel.orderFrontRegardless()
        stopPanel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        stopPanel?.orderOut(nil)
        stopPanel = nil
    }
}

private struct RecordingStopButton: View {
    let startedAt: Date
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill").foregroundStyle(.red)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("停止 \(RecordedVideo.format(context.date.timeIntervalSince(startedAt).rounded(.down)))")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.red.opacity(0.6), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .padding(4)
        .fixedSize()
        .help("停止录屏（也可以再按 ⇧⌘A）")
        .accessibilityLabel("停止录屏")
    }
}
