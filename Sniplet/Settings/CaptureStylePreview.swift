import SwiftUI

/// A small synthetic sample, never a screenshot or an export-quality raster preview.
/// A miniature app window on a tinted backdrop, so corner radius, shadow and both
/// white and gray borders all read clearly.
struct CaptureStylePreview: View {
    let style: CaptureStyle
    private let sampleSize = CGSize(width: 184, height: 104)

    var body: some View {
        // Half-size point geometry keeps even the strongest shadow inside this small sample.
        let geometry = style.geometry(imageSize: sampleSize, sourceScale: 0.5)
        let outline = RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .circular)
        VStack(spacing: 4) {
            ZStack {
                ForEach(geometry.shadowLayers.indices, id: \.self) { index in
                    let layer = geometry.shadowLayers[index]
                    outline
                        .fill(.black.opacity(layer.opacity))
                        .blur(radius: layer.blur)
                        .offset(x: layer.offset.width, y: -layer.offset.height)
                }
                sample
                    .clipShape(outline)
                    .overlay {
                        outline.strokeBorder(Color(cgColor: style.borderColor.cgColor),
                                             lineWidth: geometry.borderWidth)
                    }
            }
            .frame(width: sampleSize.width, height: sampleSize.height)
            .padding(backgroundInsets(geometry))
            .background(backgroundFill)
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .background(backdrop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("样式示意 · 非截图内容")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("截图美化样式示意，使用示例内容，不读取屏幕")
    }

    /// The chosen backdrop around the sample, as wide as the export's padding.
    private func backgroundInsets(_ geometry: CaptureStyleGeometry) -> EdgeInsets {
        guard style.background != .none else { return EdgeInsets() }
        let bounds = geometry.presentationBounds
        return EdgeInsets(top: -bounds.minY, leading: -bounds.minX,
                          bottom: bounds.maxY - sampleSize.height, trailing: bounds.maxX - sampleSize.width)
    }

    @ViewBuilder private var backgroundFill: some View {
        let colors = style.background.colors.map { Color(cgColor: $0) }
        if colors.count == 1 { colors[0] }
        else if colors.count > 1 { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    }

    /// Fixed colors: the sample stands for a light screenshot in either appearance.
    private var backdrop: LinearGradient {
        LinearGradient(colors: [Color(red: 0.80, green: 0.88, blue: 0.85), Color(red: 0.74, green: 0.80, blue: 0.90)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static let ink = Color(red: 0.16, green: 0.20, blue: 0.19)
    private static let line = Color(red: 0.84, green: 0.86, blue: 0.86)
    private static let brand = Color(red: 0.09, green: 0.45, blue: 0.35)

    private var sample: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 16)
            .background(Color(white: 0.95))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    bar(Self.brand.opacity(0.85), width: 26)
                    bar(Self.line, width: 30)
                    bar(Self.line, width: 22)
                    bar(Self.line, width: 28)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 46, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(Color(white: 0.97))
                VStack(alignment: .leading, spacing: 6) {
                    bar(Self.ink, width: 64, height: 5)
                    bar(Self.line, width: 104)
                    bar(Self.line, width: 84)
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(Array([14, 22, 18, 30, 26].enumerated()), id: \.offset) { index, height in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Self.brand.opacity(index == 3 ? 1 : 0.45))
                                .frame(width: 9, height: CGFloat(height))
                        }
                    }
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white)
            }
        }
        .frame(width: sampleSize.width, height: sampleSize.height)
    }

    private func bar(_ color: Color, width: CGFloat, height: CGFloat = 4) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}
