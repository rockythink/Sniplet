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

    var cornerRadius: CGFloat = 0
    var shadow: Shadow = .off
    /// Zero disables the border. The border is drawn INSIDE the original image footprint.
    var borderWidth: CGFloat = 0
    var borderColor: BorderColor = .white
    static let plain = Self()

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
        let bounds = CGRect(x: -ceil(left), y: -ceil(top),
                            width: imageSize.width + ceil(left) + ceil(right),
                            height: imageSize.height + ceil(top) + ceil(bottom)).integral
        return CaptureStyleGeometry(presentationBounds: bounds, contentBounds: content,
                                    cornerRadius: radius, borderWidth: border, shadowLayers: layers)
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
}

nonisolated struct CaptureShadowLayer: Sendable {
    let blur: CGFloat
    let opacity: CGFloat
    /// Quartz unflipped shadow coordinates (negative y means downward).
    let offset: CGSize
    let fringeBase: CGFloat
    var fringe: CGFloat { blur * 1.2 + fringeBase }
}
