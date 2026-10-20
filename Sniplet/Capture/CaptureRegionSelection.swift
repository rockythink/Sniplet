import CoreGraphics
import Foundation

/// An immutable crop window onto one frozen source image.
///
/// `pixelRect` uses the top-left image-pixel origin, while `screenRect` is the matching
/// footprint in global AppKit points. Adjusting the selection never recaptures the screen:
/// it only changes the integer pixel crop against the same frozen `source`.
nonisolated struct CaptureRegionSelection: Sendable {
    let source: CapturedImage
    /// The frozen source's global AppKit footprint; it may start at a negative origin.
    let screenFrame: CGRect
    /// Integral crop within the source bounds; initial point selections round outward.
    let pixelRect: CGRect

    init?(source: CapturedImage, screenFrame: CGRect, selectionRect: CGRect) {
        guard Self.isUsable(screenFrame) else { return nil }
        guard let pixels = DisplayGeometry.pixelRect(for: selectionRect,
                                                     screenFrame: screenFrame,
                                                     imageWidth: source.image.width,
                                                     imageHeight: source.image.height),
              let selection = Self(source: source, screenFrame: screenFrame, pixelRect: pixels) else { return nil }
        self = selection
    }

    /// Used for exact restoration from an undo rectangle.
    init?(source: CapturedImage, screenFrame: CGRect, pixelRect: CGRect) {
        guard Self.isUsable(screenFrame), Self.isUsable(pixelRect),
              pixelRect.width >= 1, pixelRect.height >= 1,
              Self.isInteger(pixelRect.minX), Self.isInteger(pixelRect.minY),
              Self.isInteger(pixelRect.width), Self.isInteger(pixelRect.height),
              pixelRect.minX >= 0, pixelRect.minY >= 0,
              pixelRect.maxX <= CGFloat(source.image.width),
              pixelRect.maxY <= CGFloat(source.image.height) else { return nil }
        self.source = source
        self.screenFrame = screenFrame
        self.pixelRect = pixelRect
    }

    /// Inverse of outward pixel rounding: the crop's actual global AppKit footprint.
    var screenRect: CGRect {
        let sx = screenFrame.width / CGFloat(source.image.width)
        let sy = screenFrame.height / CGFloat(source.image.height)
        return CGRect(x: screenFrame.minX + pixelRect.minX * sx,
                      y: screenFrame.maxY - pixelRect.maxY * sy,
                      width: pixelRect.width * sx,
                      height: pixelRect.height * sy)
    }

    /// `delta` is the total AppKit point displacement since the gesture began:
    /// x grows right, y grows up. Pixel origins round and clamp inside the source,
    /// while the cropped pixel dimensions never change.
    func moved(by delta: CGSize) -> Self {
        guard delta.width.isFinite, delta.height.isFinite else { return self }
        let sx = CGFloat(source.image.width) / screenFrame.width
        let sy = CGFloat(source.image.height) / screenFrame.height
        let dx = (delta.width * sx).rounded()
        let dy = (-delta.height * sy).rounded()
        let maxX = max(0, CGFloat(source.image.width) - pixelRect.width)
        let maxY = max(0, CGFloat(source.image.height) - pixelRect.height)
        let x = min(max(0, pixelRect.minX + dx), maxX)
        let y = min(max(0, pixelRect.minY + dy), maxY)
        guard x != pixelRect.minX || y != pixelRect.minY else { return self }
        return Self(source: source, screenFrame: screenFrame,
                    pixelRect: CGRect(x: x, y: y, width: pixelRect.width, height: pixelRect.height)) ?? self
    }

    /// Resizes chosen edges by the total global AppKit displacement since mouseDown.
    /// The opposite edges remain fixed. Edges round to source pixels, stop at the
    /// source boundary, and cannot cross the opposite edge or leave less than one pixel.
    func resized(from handle: CaptureSelectionResizeHandle, by delta: CGSize) -> Self {
        guard delta.width.isFinite, delta.height.isFinite else { return self }
        let dx = (delta.width * CGFloat(source.image.width) / screenFrame.width).rounded()
        let dy = (-delta.height * CGFloat(source.image.height) / screenFrame.height).rounded()
        var left = pixelRect.minX
        var right = pixelRect.maxX
        var top = pixelRect.minY
        var bottom = pixelRect.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft:
            left = min(max(0, left + dx), right - 1)
        case .topRight, .right, .bottomRight:
            right = max(min(CGFloat(source.image.width), right + dx), left + 1)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            top = min(max(0, top + dy), bottom - 1)
        case .bottomLeft, .bottom, .bottomRight:
            bottom = max(min(CGFloat(source.image.height), bottom + dy), top + 1)
        case .left, .right: break
        }
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard rect != pixelRect else { return self }
        return Self(source: source, screenFrame: screenFrame, pixelRect: rect) ?? self
    }

    func croppedCapture() throws -> CapturedImage {
        guard let image = source.image.cropping(to: pixelRect),
              image.width == Int(pixelRect.width),
              image.height == Int(pixelRect.height) else { throw CaptureError.cropFailed }
        return CapturedImage(id: source.id, createdAt: source.createdAt, mode: .region,
                             image: image, sourceScale: source.sourceScale,
                             displayID: source.displayID)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
            && rect.minX.isFinite && rect.minY.isFinite && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func isInteger(_ value: CGFloat) -> Bool {
        value.isFinite && value.rounded() == value
    }
}
