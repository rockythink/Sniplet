import CoreGraphics
import CoreText
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
        case let .counter(center):
            let radius = counterRadius(annotation.style)
            return CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        }
    }

    /// Counters scale with the text size, so a badge reads like a label of the same size.
    static func counterRadius(_ style: AnnotationStyle) -> CGFloat { style.fontSize * 0.75 }

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
        case .counter:
            path.addEllipse(in: bounds(annotation))
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
        case let .counter(center):
            return hypot(point.x - center.x, point.y - center.y) <= counterRadius(annotation.style) + tolerance
        }
    }

    /// Drawing tools only grab a mark by its outline, so a drag inside a rectangle,
    /// mosaic or highlight still starts a new mark. Pen strokes are never grabbed.
    static func outlineHit(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
        switch annotation.payload {
        // A badge is small and solid, so the whole badge counts as its outline.
        case .arrow, .counter: return hit(annotation, at: point, tolerance: tolerance)
        case .pen: return false
        case let .rectangle(rect), let .text(rect, _), let .mosaic(rect, _), let .highlight(rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        }
    }

    static func handles(_ annotation: Annotation) -> [(AnnotationHandle, CGPoint)] {
        switch annotation.payload {
        case let .arrow(a, b): return [(.start, a), (.end, b)]
        // Text boxes always fit their content, so a hand-set size would not survive the next edit.
        case .pen, .text, .counter: return []
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
        case let .counter(center): .counter(center: move(center))
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

/// One font and one measurement for the live text input, the canvas and the final render,
/// so a text mark always shows exactly what was typed, without clipping or rewrapping.
nonisolated enum AnnotationTextLayout {
    /// Point sizes offered by the toolbar steppers; stored sizes are these times the source scale.
    static let pointSizes: [CGFloat] = [12, 14, 16, 20, 24, 32, 40, 48, 64, 80]

    static func font(_ style: AnnotationStyle) -> CTFont {
        CTFontCreateUIFontForLanguage(style.isBold ? .emphasizedSystem : .system, style.fontSize, nil)
            ?? CTFontCreateWithName((style.isBold ? "Helvetica-Bold" : "Helvetica") as CFString, style.fontSize, nil)
    }

    static func attributedString(_ text: String, style: AnnotationStyle) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor(style).cgColor
        ])
    }

    /// Black or white on a background block, picked by the block's luminance.
    static func textColor(_ style: AnnotationStyle) -> AnnotationColor {
        guard style.hasTextBackground else { return style.color }
        let color = style.color
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.6 ? .black : .white
    }

    /// Space between the background block's edge and the text; zero without a background.
    static func padding(_ style: AnnotationStyle) -> CGSize {
        guard style.hasTextBackground else { return .zero }
        return CGSize(width: (style.fontSize * 0.35).rounded(), height: (style.fontSize * 0.2).rounded())
    }

    static func backgroundCornerRadius(_ style: AnnotationStyle) -> CGFloat { style.fontSize * 0.25 }

    /// The smallest box at `origin` showing all of `text`; it wraps only at the image edge.
    static func fittedRect(_ text: String, style: AnnotationStyle, origin: CGPoint, in bounds: CGRect) -> CGRect {
        let pad = padding(style)
        let maxWidth = max(style.fontSize + 2 * pad.width, bounds.maxX - origin.x)
        // An empty text or a trailing newline still needs room for the caret's line.
        let measured = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(measured, style: style))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth - 2 * pad.width, height: .greatestFiniteMagnitude), nil)
        // Slack keeps CoreText from dropping the last line or wrapping on rounding.
        let slack = max(2, style.fontSize / 8)
        return CGRect(x: origin.x, y: origin.y,
                      width: min(maxWidth, max(style.fontSize, ceil(size.width) + slack) + 2 * pad.width),
                      height: ceil(size.height) + slack + 2 * pad.height)
    }

    /// Text marks follow their content; other marks are returned unchanged.
    static func refitted(_ annotation: Annotation, in bounds: CGRect) -> Annotation {
        guard case let .text(rect, text) = annotation.payload else { return annotation }
        var result = annotation
        result.payload = .text(rect: fittedRect(text, style: annotation.style, origin: rect.origin, in: bounds), text: text)
        return result
    }
}
