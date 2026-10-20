import SwiftUI

/// A small synthetic sample, never a screenshot or an export-quality raster preview.
struct CaptureStylePreview: View {
    let style: CaptureStyle
    private let sampleSize = CGSize(width: 176, height: 60)

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
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("样式示意 · 非截图内容")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("截图美化样式示意，使用示例内容，不读取屏幕")
    }

    private var sample: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 23))
                .foregroundStyle(Color(red: 0.22, green: 0.38, blue: 0.55))
                .frame(width: 44, height: 44)
                .background(Color(red: 0.82, green: 0.89, blue: 0.95), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text("Sniplet").font(.system(size: 12, weight: .semibold))
                Text("截图美化").font(.system(size: 10))
            }
            .foregroundStyle(Color(white: 0.22))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: sampleSize.width, height: sampleSize.height)
        .background(Color(red: 0.94, green: 0.96, blue: 0.98))
    }
}
