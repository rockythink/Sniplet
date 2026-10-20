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
        let x0 = floor((clipped.minX - screenFrame.minX) * sx)
        let y0 = floor((screenFrame.maxY - clipped.maxY) * sy)
        let x1 = ceil((clipped.maxX - screenFrame.minX) * sx)
        let y1 = ceil((screenFrame.maxY - clipped.minY) * sy)
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

    static func selection(from start: CGPoint, to end: CGPoint, in screenFrame: CGRect) -> CGRect {
        let x = min(max(end.x, screenFrame.minX), screenFrame.maxX)
        let y = min(max(end.y, screenFrame.minY), screenFrame.maxY)
        return CGRect(x: min(start.x, x), y: min(start.y, y),
                      width: abs(start.x - x), height: abs(start.y - y))
    }

    @MainActor static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

nonisolated struct CaptureScreen: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let quartzBounds: CGRect

    @MainActor static func current() -> [CaptureScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = DisplayGeometry.displayID(for: screen) else { return nil }
            return CaptureScreen(id: id, frame: screen.frame, quartzBounds: CGDisplayBounds(id))
        }
    }
}
