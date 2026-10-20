import CoreGraphics

/// Maps the renderer's source-pixel corner radius into the actual zoomed canvas footprint.
nonisolated struct InlineSelectionOutline {
    let imageRect: CGRect
    let cornerRadii: CGSize

    init?(imageRect: CGRect, imageSize: CGSize, style: CaptureStyle, sourceScale: CGFloat) {
        guard imageRect.width > 0, imageRect.height > 0,
              imageRect.minX.isFinite, imageRect.minY.isFinite,
              imageRect.width.isFinite, imageRect.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite else { return nil }
        let scale = sourceScale.isFinite && sourceScale > 0 ? sourceScale : 1
        let radius = min(style.normalized.cornerRadius * scale, min(imageSize.width, imageSize.height) / 2)
        self.imageRect = imageRect
        cornerRadii = CGSize(width: radius * imageRect.width / imageSize.width,
                             height: radius * imageRect.height / imageSize.height)
    }

    var path: CGPath {
        CGPath(roundedRect: imageRect, cornerWidth: cornerRadii.width,
               cornerHeight: cornerRadii.height, transform: nil)
    }
}
