import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

actor CaptureService {
    private var content: SCShareableContent?

    /// One on-screen inventory for the whole gesture. Off-screen enumeration is intentionally
    /// avoided: it can take longer than the screenshot itself on a busy window server.
    func prepare(requiredWindowIDs: Set<CGWindowID>) async throws -> Set<CGWindowID> {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let listed = Set(content.windows.map(\.windowID))
            if requiredWindowIDs.isSubset(of: listed) {
                self.content = content
                return listed
            }
            if attempt == 0 { await Task.yield() }
        }
        content = nil
        throw CaptureError.applicationUnavailable
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CapturedImage {
        if content == nil { _ = try await prepare(requiredWindowIDs: []) }
        guard let content else { throw CaptureError.displayUnavailable }
        return try await capture(displayID, content: content)
    }

    func captureDisplays(_ displayIDs: [CGDirectDisplayID]) async throws -> [CGDirectDisplayID: CapturedImage] {
        guard let content else { throw CaptureError.displayUnavailable }
        let jobs = try displayIDs.map { try screenshotJob($0, content: content) }
        return try await withThrowingTaskGroup(of: CapturedImage.self) { group in
            for job in jobs {
                group.addTask {
                    try Task.checkCancellation()
                    let image = try await SCScreenshotManager.captureImage(contentFilter: job.filter,
                                                                           configuration: job.configuration)
                    return CapturedImage(id: UUID(), createdAt: Date(), mode: .fullScreen,
                                         image: image, sourceScale: job.scale, displayID: job.displayID)
                }
            }
            var images: [CGDirectDisplayID: CapturedImage] = [:]
            for try await image in group { images[image.displayID] = image }
            return images
        }
    }


    func captureWindow(_ windowID: CGWindowID) async throws -> (image: CapturedImage, bounds: CGRect) {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionUnavailable }
        // Confirmation must see a window that still exists, so this lookup is not reused
        // from the older selection inventory.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        self.content = content
        try Task.checkCancellation()
        let candidates = WindowSelectionService.ordinaryWindows(capturableIDs: Set(content.windows.map(\.windowID)))
        guard candidates.contains(where: { $0.id == windowID }),
              let window = content.windows.first(where: { $0.windowID == windowID }),
              let display = content.displays.max(by: {
                  Self.intersectionArea($0.frame, window.frame) < Self.intersectionArea($1.frame, window.frame)
              }), Self.intersectionArea(display.frame, window.frame) > 0 else {
            throw CaptureError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let width = ceil(filter.contentRect.width * scale)
        let height = ceil(filter.contentRect.height * scale)
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
              width > 0, height > 0, width < CGFloat(Int.max), height < CGFloat(Int.max) else {
            throw CaptureError.invalidDimensions
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let captured = CapturedImage(id: UUID(), createdAt: Date(), mode: .window,
                                     image: image, sourceScale: scale, displayID: display.displayID)
        return (captured, window.frame)
    }

    private func capture(_ displayID: CGDirectDisplayID, content: SCShareableContent) async throws -> CapturedImage {
        let job = try screenshotJob(displayID, content: content)
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: job.filter, configuration: job.configuration)
        try Task.checkCancellation()
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .fullScreen,
                             image: image, sourceScale: job.scale, displayID: displayID)
    }

    /// Filter and configuration are immutable after this handoff. Concurrent captures only read them.
    private func screenshotJob(_ displayID: CGDirectDisplayID, content: SCShareableContent) throws -> ScreenshotJob {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
        if excluded.isEmpty {
            let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            guard let visible, !visible.contains(where: {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID
                    && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) < Int(CGWindowLevelForKey(.statusWindow))
            }) else { throw CaptureError.applicationUnavailable }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        let width = ceil(filter.contentRect.width * scale)
        let height = ceil(filter.contentRect.height * scale)
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
              width > 0, height > 0, width < CGFloat(Int.max), height < CGFloat(Int.max) else {
            throw CaptureError.invalidDimensions
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return ScreenshotJob(displayID: displayID, filter: filter, configuration: configuration, scale: scale)
    }

    private struct ScreenshotJob: @unchecked Sendable {
        let displayID: CGDirectDisplayID
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let scale: CGFloat
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let rect = first.intersection(second)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
