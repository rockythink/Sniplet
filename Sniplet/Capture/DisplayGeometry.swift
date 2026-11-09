import AppKit
import CoreGraphics

/// All pure transforms take an explicit screen: no global/main-screen scale assumptions.
nonisolated enum DisplayGeometry {
    static func pixelRect(for rect: CGRect, screenFrame: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard screenFrame.width > 0, screenFrame.height > 0, imageWidth > 0, imageHeight > 0,
              rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let clipped = rect.standardized.intersection(screenFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let sx = CGFloat(imageWidth) / screenFrame.width
        let sy = CGFloat(imageHeight) / screenFrame.height
        // Round outward, but not across float noise: a rect converted back from whole pixels
        // (such as a remembered selection at 1.5x) must land on the same pixels.
        let tolerance: CGFloat = 0.001
        let x0 = floor((clipped.minX - screenFrame.minX) * sx + tolerance)
        let y0 = floor((screenFrame.maxY - clipped.maxY) * sy + tolerance)
        let x1 = ceil((clipped.maxX - screenFrame.minX) * sx - tolerance)
        let y1 = ceil((screenFrame.maxY - clipped.minY) * sy - tolerance)
        let result = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        return result.isEmpty || result.isNull ? nil : result
    }

    static func quartzPoint(_ point: CGPoint, screenFrame: CGRect, displayBounds: CGRect) -> CGPoint {
        CGPoint(x: displayBounds.minX + point.x - screenFrame.minX,
                y: displayBounds.minY + screenFrame.maxY - point.y)
    }

    static func appKitRect(_ rect: CGRect, screenFrame: CGRect, displayBounds: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + rect.minX - displayBounds.minX,
               y: screenFrame.maxY - (rect.maxY - displayBounds.minY),
               width: rect.width, height: rect.height)
    }

    static func overlayRect(for globalRect: CGRect, in screenFrame: CGRect) -> CGRect? {
        let clipped = globalRect.intersection(screenFrame)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    /// Drag ends this close to a display edge land on it. The pointer stops a point short of the
    /// right and bottom edges, so without this no drag could ever cover the whole display.
    static let edgeSnap: CGFloat = 4

    static func selection(from start: CGPoint, to end: CGPoint, in screenFrame: CGRect) -> CGRect {
        let a = snapped(start, in: screenFrame)
        let b = snapped(end, in: screenFrame)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private static func snapped(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            let clamped = min(max(value, low), high)
            if clamped - low <= edgeSnap { return low }
            return high - clamped <= edgeSnap ? high : clamped
        }
        return CGPoint(x: axis(point.x, frame.minX, frame.maxX), y: axis(point.y, frame.minY, frame.maxY))
    }

    @MainActor static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

nonisolated struct CaptureScreen: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let quartzBounds: CGRect
    /// Height of the notch strip at the top of the display; zero on displays without one.
    let topInset: CGFloat

    @MainActor static func current() -> [CaptureScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = DisplayGeometry.displayID(for: screen) else { return nil }
            return CaptureScreen(id: id, frame: screen.frame, quartzBounds: CGDisplayBounds(id),
                                 topInset: screen.safeAreaInsets.top)
        }
    }
}
