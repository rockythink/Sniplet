import CoreGraphics

/// Adapted from realskyrin/CapCap EditorToolbarPlacement (MIT), commit
/// 7dd035225eaa41e6da8a5156556a8c4dd7bd028b. Keeps CapCap's 8-point gap,
/// below/above primary and right/left side placement; clamps sizes as well as origins
/// and reserves a separate lane when a tiny display cannot fit either vertical band.
nonisolated enum EditorToolbarPlacement {
    static let edgeMargin: CGFloat = 8

    struct Frames: Equatable {
        var primary: CGRect
        var side: CGRect
    }

    static func usableBounds(_ bounds: CGRect, topSafeInset: CGFloat = 0) -> CGRect {
        let mx = min(edgeMargin, max(0, (bounds.width-1)/2))
        let my = min(edgeMargin, max(0, (bounds.height-1)/2))
        let top = min(max(0, topSafeInset), max(0, bounds.height-2*my-1))
        return CGRect(x: bounds.minX+mx, y: bounds.minY+my,
                      width: max(1, bounds.width-2*mx), height: max(1, bounds.height-2*my-top))
    }

    static func primaryToolbarRect(referenceRect: CGRect, in bounds: CGRect,
                                   size: CGSize, topSafeInset: CGFloat) -> CGRect {
        let area = usableBounds(bounds, topSafeInset: topSafeInset)
        let width = min(max(1, size.width), area.width)
        let height = min(max(1, size.height), area.height)
        let x = clamp(referenceRect.maxX-width, area.minX, area.maxX-width)
        var y = referenceRect.minY-height-edgeMargin
        if y < area.minY { y = min(referenceRect.maxY+edgeMargin, area.maxY-height) }
        y = clamp(y, area.minY, area.maxY-height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func sideToolbarRect(referenceRect: CGRect, in bounds: CGRect,
                                size: CGSize, avoiding primaryFrame: CGRect? = nil) -> CGRect {
        let area = usableBounds(bounds)
        let width = min(max(1, size.width), area.width)
        var height = min(max(1, size.height), area.height)
        var x = referenceRect.maxX+edgeMargin
        if x+width > area.maxX { x = referenceRect.minX-width-edgeMargin }
        x = clamp(x, area.minX, area.maxX-width)
        var y = clamp(referenceRect.minY, area.minY, area.maxY-height)
        var rect = CGRect(x: x, y: y, width: width, height: height)
        if let primary = primaryFrame, rect.intersects(primary) {
            let above = max(0, area.maxY-primary.maxY-edgeMargin)
            let below = max(0, primary.minY-area.minY-edgeMargin)
            if above >= height { y = primary.maxY+edgeMargin }
            else if below >= height { y = primary.minY-edgeMargin-height }
            else if max(above, below) >= 1 {
                height = max(above, below)
                y = above >= below ? primary.maxY+edgeMargin : area.minY
            }
            rect = CGRect(x: x, y: y, width: width, height: height)
        }
        return rect
    }

    static func frames(referenceRect: CGRect, in bounds: CGRect, primarySize: CGSize,
                       sideSize: CGSize, topSafeInset: CGFloat = 0) -> Frames {
        let area = usableBounds(bounds, topSafeInset: topSafeInset)
        // When there is no room outside the capture (full screen or a very large region),
        // bring both bars inside the image instead of clamping them against the screen edges.
        let primaryFitsOutside = referenceRect.minY-primarySize.height-edgeMargin >= area.minY
            || referenceRect.maxY+primarySize.height+edgeMargin <= area.maxY
        let sideFitsOutside = referenceRect.maxX+sideSize.width+edgeMargin <= area.maxX
            || referenceRect.minX-sideSize.width-edgeMargin >= area.minX
        guard primaryFitsOutside, sideFitsOutside else {
            return insideFrames(referenceRect: referenceRect, in: bounds, primarySize: primarySize,
                                sideSize: sideSize, topSafeInset: topSafeInset)
        }
        var primary = primaryToolbarRect(referenceRect: referenceRect, in: bounds,
                                         size: primarySize, topSafeInset: topSafeInset)
        // Use the same safe bounds for both bars, without applying the margin twice.
        var side = sideToolbarRect(referenceRect: referenceRect,
                               in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                                          height: max(1, bounds.height-max(0, topSafeInset))),
                               size: sideSize, avoiding: primary)
        if side.intersects(primary) {
            // On very short screens both bars scroll in independent horizontal lanes.
            // A sub-point gap is meaningful only for pathological synthetic test bounds.
            let gap = min(edgeMargin, area.width/4)
            let sideWidth = min(side.width, max(0.25, (area.width-gap)/2))
            primary.size.width = max(0.25, area.width-sideWidth-gap)
            primary.origin.x = area.minX
            side = CGRect(x: area.maxX-sideWidth, y: area.minY, width: sideWidth,
                          height: min(side.height, area.height))
        }
        return Frames(primary: primary, side: side)
    }

    /// Full-screen and oversized captures: primary sits at the bottom inside edge and the
    /// side bar stacks directly above it on the same inside edge. Both remain inside the
    /// visible safe area and never overlap.
    private static func insideFrames(referenceRect: CGRect, in bounds: CGRect,
                                     primarySize: CGSize, sideSize: CGSize,
                                     topSafeInset: CGFloat) -> Frames {
        let area = usableBounds(bounds, topSafeInset: topSafeInset)
        let inset = edgeMargin + 4
        let clipped = referenceRect.insetBy(dx: inset, dy: inset).intersection(area)
        let inner = clipped.isNull || clipped.isEmpty ? area : clipped
        let primaryWidth = min(max(1, primarySize.width), inner.width)
        let primaryHeight = min(max(1, primarySize.height), inner.height)
        var primary = CGRect(x: inner.maxX-primaryWidth, y: inner.minY,
                             width: primaryWidth, height: primaryHeight)
        let sideWidth = min(max(1, sideSize.width), inner.width)
        let sideHeight = min(max(1, sideSize.height), inner.height)
        let sideY = min(primary.maxY + inset, max(inner.minY, inner.maxY - sideHeight))
        var side = CGRect(x: inner.maxX-sideWidth, y: sideY, width: sideWidth, height: sideHeight)
        if side.intersects(primary) {
            // Degenerate screens: split the width into two lanes inside the safe area.
            let gap = min(edgeMargin, area.width/4)
            let laneWidth = min(side.width, max(0.25, (area.width-gap)/2))
            primary.size.width = max(0.25, area.width-laneWidth-gap)
            primary.origin = CGPoint(x: area.minX, y: area.minY)
            primary.size.height = min(primary.size.height, area.height)
            side = CGRect(x: area.maxX-laneWidth, y: area.minY, width: laneWidth,
                          height: min(side.height, area.height))
        }
        return Frames(primary: primary, side: side)
    }

    static func relocatedSourceRect(_ source: CGRect, from oldScreen: CGRect, to visibleFrame: CGRect) -> CGRect {
        let scale = min(1, visibleFrame.width/max(1, source.width), visibleFrame.height/max(1, source.height))
        let size = CGSize(width: max(1, source.width*scale), height: max(1, source.height*scale))
        return CGRect(x: clamp(visibleFrame.minX+source.minX-oldScreen.minX, visibleFrame.minX, visibleFrame.maxX-size.width),
                      y: clamp(visibleFrame.minY+source.minY-oldScreen.minY, visibleFrame.minY, visibleFrame.maxY-size.height),
                      width: size.width, height: size.height)
    }

    private static func clamp(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> CGFloat {
        max(minimum, min(maximum, value))
    }
}
