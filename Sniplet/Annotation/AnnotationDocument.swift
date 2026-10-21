import CoreGraphics
import Foundation

nonisolated enum AnnotationKind: String, CaseIterable, Sendable {
    case arrow, rectangle, pen, text, counter, mosaic, highlight

    var label: String {
        switch self {
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .pen: "画笔"
        case .text: "文字"
        case .counter: "序号"
        case .mosaic: "马赛克"
        case .highlight: "高亮"
        }
    }
}

nonisolated enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, rectangle, pen, text, counter, mosaic, highlight
    var kind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
    var label: String { kind?.label ?? "选择" }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .counter: "1.circle"
        case .mosaic: "square.grid.3x3"
        case .highlight: "highlighter"
        }
    }
    /// Single-key tool switching on the canvas, shown in the toolbar help.
    var shortcutKey: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .pen: "p"
        case .text: "t"
        case .counter: "n"
        case .mosaic: "m"
        case .highlight: "h"
        }
    }
    static func forShortcut(_ key: String) -> Self? {
        allCases.first { String($0.shortcutKey) == key.lowercased() }
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
    static let yellow = Self(red: 1, green: 0.78, blue: 0)
    static let green = Self(red: 0.12, green: 0.68, blue: 0.3)
    static let highlight = Self(red: 1, green: 0.85, blue: 0, alpha: 0.3)
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }
}

nonisolated struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 16
    var isBold = false
    /// Text only: a rounded block of `color` behind the text, which then uses a contrasting color.
    var hasTextBackground = false
}

nonisolated enum AnnotationPayload: Equatable, Sendable {
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case pen(points: [CGPoint])
    case text(rect: CGRect, text: String)
    /// A numbered badge. Its number is its position among the document's counters, so
    /// deleting one renumbers the rest and undo restores them, with nothing to keep in sync.
    case counter(center: CGPoint)
    case mosaic(rect: CGRect, blockSize: CGFloat)
    case highlight(rect: CGRect)

    var kind: AnnotationKind {
        switch self {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .pen: .pen
        case .text: .text
        case .counter: .counter
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

    /// 1-based display number of a counter mark, or nil for any other mark.
    func counterNumber(of id: UUID) -> Int? {
        var number = 0
        for item in annotations where item.kind == .counter {
            number += 1
            if item.id == id { return number }
        }
        return nil
    }
}
