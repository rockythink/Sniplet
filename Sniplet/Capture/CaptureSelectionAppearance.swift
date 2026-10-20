import CoreGraphics
import Foundation

/// Opaque, fixed-sRGB selection hints. Never part of the captured or rendered image.
nonisolated struct CaptureSelectionAppearance: Codable, Equatable, Sendable {
    nonisolated enum LineStyle: String, Codable, CaseIterable, Sendable {
        case solid, dashed, dotted

        var label: String {
            switch self {
            case .solid: "实线"
            case .dashed: "虚线"
            case .dotted: "点线"
            }
        }

        private static let solidPattern: [CGFloat] = []
        private static let dashedPattern: [CGFloat] = [5, 3]
        private static let dottedPattern: [CGFloat] = [1, 3]

        var dashPattern: [CGFloat] {
            switch self {
            case .solid: Self.solidPattern
            case .dashed: Self.dashedPattern
            case .dotted: Self.dottedPattern
            }
        }
    }

    var color: AnnotationColor
    var lineStyle: LineStyle

    static let standard = Self(color: AnnotationColor(red: 0.18, green: 0.8, blue: 0.36),
                               lineStyle: .dashed)

    /// Invalid components recover independently to the standard color; finite values are clamped.
    var normalized: Self {
        Self(color: AnnotationColor(red: Self.component(color.red, fallback: Self.standard.color.red),
                                    green: Self.component(color.green, fallback: Self.standard.color.green),
                                    blue: Self.component(color.blue, fallback: Self.standard.color.blue),
                                    alpha: 1),
             lineStyle: lineStyle)
    }

    private static func component(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }
}
