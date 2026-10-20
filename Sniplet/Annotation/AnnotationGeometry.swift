import CoreGraphics
import Foundation

nonisolated enum AnnotationHandle: Equatable, Sendable {
    case start, end, corner(Int)
}

nonisolated enum AnnotationGeometry {
    static func imageTolerance(screenPoints: CGFloat, backingScale: CGFloat, magnification: CGFloat) -> CGFloat {
        screenPoints * backingScale / magnification
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
    }

    static func bounds(_ annotation: Annotation) -> CGRect {
        switch annotation.payload {
        case let .arrow(a, b):
            return path(annotation).boundingBoxOfPath.insetBy(dx: -annotation.style.lineWidth, dy: -annotation.style.lineWidth)
                .union(rect(from: a, to: b))
        case let .pen(points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, p in
                result.union(CGRect(x: p.x, y: p.y, width: 0.001, height: 0.001))
            }.insetBy(dx: -annotation.style.lineWidth / 2, dy: -annotation.style.lineWidth / 2)
        case let .rectangle(rect), let .text(rect, _), let .mosaic(rect, _), let .highlight(rect): return rect
        }
    }

    static func path(_ annotation: Annotation) -> CGPath {
        let path = CGMutablePath()
        switch annotation.payload {
        case let .arrow(a, b):
            path.move(to: a)
            path.addLine(to: b)
            let angle = atan2(b.y-a.y, b.x-a.x)
            let length = min(hypot(b.x-a.x, b.y-a.y), max(10, annotation.style.lineWidth * 4))
            for sign in [CGFloat(-1), CGFloat(1)] {
                path.move(to: b)
                let headAngle = angle + sign * CGFloat.pi / 6
                path.addLine(to: CGPoint(x: b.x-length*cos(headAngle), y: b.y-length*sin(headAngle)))
            }
        case let .pen(points):
            if let first = points.first {
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                if points.count == 1 { path.addLine(to: CGPoint(x: first.x+0.01, y: first.y)) }
            }
        case let .rectangle(rect), let .text(rect, _), let .mosaic(rect, _), let .highlight(rect):
            path.addRect(rect)
        }
        return path
    }

    static func hit(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        switch annotation.payload {
        case .arrow, .pen:
            return path(annotation).copy(strokingWithWidth: annotation.style.lineWidth+2*tolerance,
                                         lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        case let .rectangle(rect):
            // Interior is intentionally available for dragging the rectangular object.
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case let .text(rect, _), let .mosaic(rect, _), let .highlight(rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func handles(_ annotation: Annotation) -> [(AnnotationHandle, CGPoint)] {
        switch annotation.payload {
        case let .arrow(a, b): return [(.start, a), (.end, b)]
        case .pen: return []
        default:
            let r = bounds(annotation)
            return [(.corner(0), CGPoint(x: r.minX, y: r.minY)),
                    (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(2), CGPoint(x: r.maxX, y: r.maxY)),
                    (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
        }
    }

    static func translated(_ annotation: Annotation, by delta: CGSize) -> Annotation {
        var result = annotation
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x+delta.width, y: p.y+delta.height) }
        func moveRect(_ r: CGRect) -> CGRect { r.offsetBy(dx: delta.width, dy: delta.height) }
        result.payload = switch annotation.payload {
        case let .arrow(a, b): .arrow(start: move(a), end: move(b))
        case let .pen(points): .pen(points: points.map(move))
        case let .rectangle(r): .rectangle(rect: moveRect(r))
        case let .text(r, text): .text(rect: moveRect(r), text: text)
        case let .mosaic(r, size): .mosaic(rect: moveRect(r), blockSize: size)
        case let .highlight(r): .highlight(rect: moveRect(r))
        }
        return result
    }

    static func resized(_ annotation: Annotation, handle: AnnotationHandle, to point: CGPoint) -> Annotation {
        var result = annotation
        if case let .arrow(a, b) = annotation.payload {
            if handle == .start { result.payload = .arrow(start: point, end: b) }
            if handle == .end { result.payload = .arrow(start: a, end: point) }
            return result
        }
        guard case let .corner(index) = handle else { return result }
        let r = bounds(annotation)
        let opposite = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                        CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][index]
        var newRect = rect(from: opposite, to: point)
        newRect.size.width = max(1, newRect.width)
        newRect.size.height = max(1, newRect.height)
        result.payload = switch annotation.payload {
        case .rectangle: .rectangle(rect: newRect)
        case let .text(_, text): .text(rect: newRect, text: text)
        case let .mosaic(_, size): .mosaic(rect: newRect, blockSize: size)
        case .highlight: .highlight(rect: newRect)
        default: annotation.payload
        }
        return result
    }
}
