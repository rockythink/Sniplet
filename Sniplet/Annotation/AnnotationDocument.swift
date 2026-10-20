import CoreGraphics
import Foundation

nonisolated enum AnnotationKind: String, CaseIterable, Sendable {
    case arrow, rectangle, pen, text, mosaic, highlight

    var label: String {
        switch self {
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .pen: "画笔"
        case .text: "文字"
        case .mosaic: "马赛克"
        case .highlight: "高亮"
        }
    }
}

nonisolated enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, rectangle, pen, text, mosaic, highlight
    var kind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
    var label: String { kind?.label ?? "选择" }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3"
        case .highlight: "highlighter"
        }
    }
}

/// Fixed sRGB components, independent of the interface appearance.
nonisolated struct AnnotationColor: Codable, Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1
    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 1, green: 1, blue: 1)
    static let red = Self(red: 0.9, green: 0.12, blue: 0.12)
    static let blue = Self(red: 0.08, green: 0.35, blue: 0.95)
    static let highlight = Self(red: 1, green: 0.85, blue: 0, alpha: 0.3)
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }
}

nonisolated struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 16
}

nonisolated enum AnnotationPayload: Equatable, Sendable {
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case pen(points: [CGPoint])
    case text(rect: CGRect, text: String)
    case mosaic(rect: CGRect, blockSize: CGFloat)
    case highlight(rect: CGRect)

    var kind: AnnotationKind {
        switch self {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .pen: .pen
        case .text: .text
        case .mosaic: .mosaic
        case .highlight: .highlight
        }
    }
}

nonisolated struct Annotation: Identifiable, Equatable, Sendable {
    var id = UUID()
    var payload: AnnotationPayload
    var style = AnnotationStyle()
    var kind: AnnotationKind { payload.kind }
}

nonisolated struct AnnotationDocument: Sendable {
    var capture: CapturedImage
    var annotations: [Annotation] = []
    var revision: UInt64 = 0
    var captureStyle: CaptureStyle = .plain
    var imageBounds: CGRect {
        CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height)
    }
}
