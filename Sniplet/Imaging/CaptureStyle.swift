import CoreGraphics
import Foundation

/// Decoration values are logical points; document/annotation coordinates remain source pixels.
nonisolated struct CaptureStyle: Equatable, Codable, Sendable {
    nonisolated enum Shadow: String, CaseIterable, Codable, Sendable {
        case off, subtle, medium, strong
        var label: String {
            switch self { case .off: "关闭"; case .subtle: "轻"; case .medium: "中"; case .strong: "强" }
        }
        var size: CGFloat {
            switch self { case .off: 0; case .subtle: 12; case .medium: 24; case .strong: 40 }
        }
    }

    nonisolated enum BorderColor: String, CaseIterable, Codable, Sendable {
        case white, gray, black, blue
        var label: String {
            switch self { case .white: "白色"; case .gray: "灰色"; case .black: "黑色"; case .blue: "蓝色" }
        }
        var cgColor: CGColor {
            let components: [CGFloat] = switch self {
            case .white: [1, 1, 1, 1]
            case .gray: [0.5, 0.5, 0.5, 1]
            case .black: [0, 0, 0, 1]
            case .blue: [0.08, 0.35, 0.95, 1]
            }
            return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
        }
    }

    /// Fills the padding around the capture, so chat apps that flatten transparency
    /// (WeChat paints it white) still show the shadow on an intended backdrop.
    nonisolated enum Background: String, CaseIterable, Codable, Sendable {
        case none, white, mist, graphite, sky, peach
        var label: String {
            switch self {
            case .none: "透明"; case .white: "白色"; case .mist: "浅灰"; case .graphite: "深色"
            case .sky: "蓝紫渐变"; case .peach: "暖橙渐变"
            }
        }
        /// One color is solid; two run diagonally from the top-left.
        var colors: [CGColor] {
            let rgb: [[CGFloat]] = switch self {
            case .none: []
            case .white: [[1, 1, 1]]
            case .mist: [[0.93, 0.94, 0.95]]
            case .graphite: [[0.17, 0.18, 0.20]]
            case .sky: [[0.55, 0.72, 0.98], [0.74, 0.62, 0.96]]
            case .peach: [[1.0, 0.80, 0.62], [0.98, 0.62, 0.70]]
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            return rgb.map { CGColor(colorSpace: space, components: $0 + [1])! }
        }
    }

    /// Logical points of backdrop around the capture when a background is chosen.
    static let backgroundPadding: CGFloat = 32

    var cornerRadius: CGFloat = 0
    var shadow: Shadow = .off
    /// Zero disables the border. The border is drawn INSIDE the original image footprint.
    var borderWidth: CGFloat = 0
    var borderColor: BorderColor = .white
    var background: Background = .none
    static let plain = Self()

    /// Nothing to draw beyond the capture itself.
    var isPlain: Bool {
        let style = normalized
        return style.cornerRadius == 0 && style.borderWidth == 0 && style.shadow == .off && style.background == .none
    }

    var normalized: Self {
        var result = self
        result.cornerRadius = cornerRadius.isFinite ? min(max(cornerRadius, 0), 48) : 0
        result.borderWidth = borderWidth.isFinite ? min(max(borderWidth, 0), 8) : 0
        return result
    }

    func geometry(imageSize: CGSize, sourceScale: CGFloat) -> CaptureStyleGeometry {
        let style = normalized
        let scale = sourceScale.isFinite && sourceScale > 0 ? sourceScale : 1
        let content = CGRect(origin: .zero, size: imageSize)
        let radius = min(style.cornerRadius * scale, min(imageSize.width, imageSize.height) / 2)
        let border = min(style.borderWidth * scale, min(imageSize.width, imageSize.height) / 2)
        let layers = Self.shadowLayers(size: style.shadow.size, scale: scale)
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        for layer in layers {
            let fringe = layer.fringe
            left = max(left, fringe + max(-layer.offset.width, 0))
            right = max(right, fringe + max(layer.offset.width, 0))
            top = max(top, fringe + max(layer.offset.height, 0))
            bottom = max(bottom, fringe + max(-layer.offset.height, 0))
        }
        if style.background != .none {
            let padding = Self.backgroundPadding * scale
            left = max(left, padding); right = max(right, padding)
            top = max(top, padding); bottom = max(bottom, padding)
        }
        let bounds = CGRect(x: -ceil(left), y: -ceil(top),
                            width: imageSize.width + ceil(left) + ceil(right),
                            height: imageSize.height + ceil(top) + ceil(bottom)).integral
        return CaptureStyleGeometry(presentationBounds: bounds, contentBounds: content,
                                    cornerRadius: radius, borderWidth: border, shadowLayers: layers,
                                    background: style.background)
    }

    // Adapted from CapCap WindowEffects.layers/shadowOutsets/shadowFringe, MIT,
    // Copyright (c) 2026 realskyrin, commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
    // Keep all constants in logical points before converting to source pixels.
    private static func shadowLayers(size: CGFloat, scale: CGFloat) -> [CaptureShadowLayer] {
        guard size > 0 else { return [] }
        return [
            CaptureShadowLayer(blur: size * 0.45 * scale, opacity: 0.20, offset: .zero, fringeBase: 5 * scale),
            CaptureShadowLayer(blur: size * 0.52 * scale, opacity: 0.56,
                               offset: CGSize(width: 0, height: -size * 0.24 * scale), fringeBase: 5 * scale),
            CaptureShadowLayer(blur: max(size * 0.12, 2) * scale, opacity: 0.24,
                               offset: CGSize(width: 0, height: -max(size * 0.07, 1) * scale), fringeBase: 5 * scale)
        ]
    }
}

nonisolated struct CaptureStyleGeometry: Sendable {
    /// Integral source-pixel bounds. Padding may make the origin negative.
    let presentationBounds: CGRect
    let contentBounds: CGRect
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let shadowLayers: [CaptureShadowLayer]
    let background: CaptureStyle.Background

    var isPlain: Bool { cornerRadius == 0 && borderWidth == 0 && shadowLayers.isEmpty && background == .none }
}

/// Styles saved before a field existed decode with that field's default, not as a failure
/// that would reset the user's whole default style.
nonisolated extension CaptureStyle {
    private enum DecodingKeys: String, CodingKey {
        case cornerRadius, shadow, borderWidth, borderColor, background
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        self.init()
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? cornerRadius
        shadow = try container.decodeIfPresent(Shadow.self, forKey: .shadow) ?? shadow
        borderWidth = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? borderWidth
        borderColor = try container.decodeIfPresent(BorderColor.self, forKey: .borderColor) ?? borderColor
        background = try container.decodeIfPresent(Background.self, forKey: .background) ?? background
    }
}

nonisolated struct CaptureShadowLayer: Sendable {
    let blur: CGFloat
    let opacity: CGFloat
    /// Quartz unflipped shadow coordinates (negative y means downward).
    let offset: CGSize
    let fringeBase: CGFloat
    var fringe: CGFloat { blur * 1.2 + fringeBase }
}
