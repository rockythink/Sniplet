import CoreGraphics

/// Crop hit geometry uses unflipped AppKit points; visual top is `maxY`.
nonisolated enum CaptureSelectionResizeGeometry {
    static let edgeWidth: CGFloat = 8
    static let handleSize: CGFloat = 7
    private static let corners: [CaptureSelectionResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    private static let edges: [CaptureSelectionResizeHandle] = [.top, .right, .bottom, .left]
    private static let controls = corners + edges

    static func point(for handle: CaptureSelectionResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Keep real source-edge handles usable below the menu bar and above the Dock.
    /// Sources extending beyond the actual viewport do not gain invented crop edges.
    static func controlPoint(for handle: CaptureSelectionResizeHandle, selection: CGRect,
                             clippingRect: CGRect, bounds: CGRect, interactionBounds: CGRect?) -> CGPoint? {
        let anchor = point(for: handle, in: selection)
        let clip = clippingRect.intersection(bounds)
        guard !clip.isNull, !clip.isEmpty,
              anchor.x >= clip.minX, anchor.x <= clip.maxX,
              anchor.y >= clip.minY, anchor.y <= clip.maxY else { return nil }
        guard let interactionBounds else { return anchor }
        let usable = interactionBounds.intersection(clip)
        guard !usable.isNull, !usable.isEmpty else { return nil }
        let half = handleSize / 2
        let minX = min(usable.minX + half, usable.midX)
        let maxX = max(usable.maxX - half, usable.midX)
        let minY = min(usable.minY + half, usable.midY)
        let maxY = max(usable.maxY - half, usable.midY)
        return CGPoint(x: min(max(anchor.x, minX), maxX), y: min(max(anchor.y, minY), maxY))
    }

    static func hit(at point: CGPoint, selection rect: CGRect,
                    clippingRect: CGRect, bounds: CGRect, interactionBounds: CGRect? = nil) -> CaptureSelectionResizeHandle? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              point.x.isFinite, point.y.isFinite else { return nil }
        let clip = clippingRect.intersection(bounds)
        guard !clip.isNull, !clip.isEmpty,
              point.x >= clip.minX, point.x <= clip.maxX,
              point.y >= clip.minY, point.y <= clip.maxY else { return nil }
        if interactionBounds != nil {
            var control: CaptureSelectionResizeHandle?
            var nearest = CGFloat.infinity
            for (index, handle) in controls.enumerated() {
                if index == corners.count, let control { return control }
                guard let anchor = controlPoint(for: handle, selection: rect,
                    clippingRect: clippingRect, bounds: bounds, interactionBounds: interactionBounds) else { continue }
                let dx = abs(point.x - anchor.x), dy = abs(point.y - anchor.y)
                guard dx <= edgeWidth, dy <= edgeWidth else { continue }
                let squared = dx * dx + dy * dy
                if squared < nearest { control = handle; nearest = squared }
            }
            if let control { return control }
        }

        // A band on BOTH sides of each edge keeps full-display crops shrinkable.
        // Nearest corner wins overlapping tiny-crop targets; ties use this fixed order.
        var nearest: CaptureSelectionResizeHandle?
        var distance = CGFloat.infinity
        for handle in corners {
            let anchor = Self.point(for: handle, in: rect)
            let dx = abs(point.x - anchor.x)
            let dy = abs(point.y - anchor.y)
            guard dx <= edgeWidth, dy <= edgeWidth else { continue }
            let squaredDistance = dx * dx + dy * dy
            if squaredDistance < distance {
                nearest = handle
                distance = squaredDistance
            }
        }
        if let nearest { return nearest }

        // Compare only genuine edges, not viewport clipping boundaries. This also
        // provides deterministic precedence when opposite bands overlap.
        distance = .infinity
        for handle in edges {
            let edgeDistance: CGFloat
            let alongEdge: Bool
            switch handle {
            case .top:
                edgeDistance = abs(point.y - rect.maxY)
                alongEdge = point.x >= rect.minX && point.x <= rect.maxX
            case .right:
                edgeDistance = abs(point.x - rect.maxX)
                alongEdge = point.y >= rect.minY && point.y <= rect.maxY
            case .bottom:
                edgeDistance = abs(point.y - rect.minY)
                alongEdge = point.x >= rect.minX && point.x <= rect.maxX
            case .left:
                edgeDistance = abs(point.x - rect.minX)
                alongEdge = point.y >= rect.minY && point.y <= rect.maxY
            default:
                continue
            }
            guard alongEdge, edgeDistance <= edgeWidth else { continue }
            if edgeDistance < distance {
                nearest = handle
                distance = edgeDistance
            }
        }
        return nearest
    }
}

/// Immutable mapping for one gesture; live crop/zoom changes must not compound its delta.
nonisolated struct CaptureSelectionResizeMapping {
    private let sourcePointsPerViewPoint: CGSize
    private let controlOffset: CGSize

    init?(handle: CaptureSelectionResizeHandle, selection: CGRect, sourceSize: CGSize,
          clippingRect: CGRect, bounds: CGRect, interactionBounds: CGRect?) {
        guard selection.width.isFinite, selection.height.isFinite,
              selection.width > 0, selection.height > 0,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let anchor = CaptureSelectionResizeGeometry.point(for: handle, in: selection)
        // A genuine visible edge remains draggable when its midpoint is offscreen.
        let control = CaptureSelectionResizeGeometry.controlPoint(for: handle, selection: selection,
            clippingRect: clippingRect, bounds: bounds, interactionBounds: interactionBounds) ?? anchor
        controlOffset = CGSize(width: control.x - anchor.x, height: control.y - anchor.y)
        sourcePointsPerViewPoint = CGSize(width: sourceSize.width / selection.width,
                                         height: sourceSize.height / selection.height)
    }

    func displacement(from start: CGPoint, to point: CGPoint) -> CGSize {
        CGSize(width: (point.x - start.x + controlOffset.width) * sourcePointsPerViewPoint.width,
               height: (point.y - start.y + controlOffset.height) * sourcePointsPerViewPoint.height)
    }
}
