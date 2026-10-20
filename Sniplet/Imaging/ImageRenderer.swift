import CoreGraphics
import CoreImage
import CoreText
import Foundation

nonisolated enum AnnotationRenderingError: LocalizedError {
    case allocation, mosaic
    var errorDescription: String? {
        switch self {
        case .allocation: "无法分配图像内存，请关闭其他图片后重试。"
        case .mosaic: "无法完成马赛克合成，请重试。"
        }
    }
}

/// Immutable alpha dependencies shared by synchronous exports and asynchronous previews.
/// Border RGB never changes alpha coverage, including for transparent source images.
nonisolated struct AnnotationShadowKey: Equatable, Sendable {
    let source: CGImage
    let radius: CGFloat
    let borderWidth: CGFloat
    let borderAlpha: CGFloat
    let shadow: CaptureStyle.Shadow
    let sourceScale: CGFloat

    init(source: CGImage, style: CaptureStyle, sourceScale: CGFloat, geometry: CaptureStyleGeometry) {
        self.source = source
        radius = geometry.cornerRadius
        borderWidth = geometry.borderWidth
        borderAlpha = geometry.borderWidth > 0 ? style.borderColor.cgColor.alpha : 0
        shadow = style.shadow
        self.sourceScale = sourceScale.isFinite && sourceScale > 0 ? sourceScale : 1
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source === rhs.source && lhs.radius == rhs.radius
            && lhs.borderWidth == rhs.borderWidth && lhs.borderAlpha == rhs.borderAlpha
            && lhs.shadow == rhs.shadow && lhs.sourceScale == rhs.sourceScale
    }
}

/// Export-local mutable resources; never shared across actors or annotated revisions.
nonisolated final class AnnotationPresentationCache {
    private var key: AnnotationShadowKey?
    private(set) var cornerMask: CGImage?
    private(set) var shadowImage: CGImage?
    private var preparedGeometry: CaptureStyleGeometry?

    func clear() {
        key = nil
        cornerMask = nil
        shadowImage = nil
        preparedGeometry = nil
    }

    fileprivate func prepare(_ document: AnnotationDocument,
                             geometry proposedGeometry: CaptureStyleGeometry? = nil) throws -> CaptureStyleGeometry {
        let style = document.captureStyle.normalized
        let geometry = proposedGeometry ?? style.geometry(imageSize: document.imageBounds.size,
                                                          sourceScale: document.capture.sourceScale)
        let newKey = AnnotationShadowKey(source: document.capture.image, style: style,
                                         sourceScale: document.capture.sourceScale, geometry: geometry)
        if key == newKey, let preparedGeometry { return preparedGeometry }
        let reuseMask = key?.radius == newKey.radius && key?.source.width == newKey.source.width
            && key?.source.height == newKey.source.height
        let mask = reuseMask ? cornerMask : (geometry.cornerRadius > 0
            ? try AnnotationCompositor.makeCornerMask(size: document.imageBounds.size, radius: geometry.cornerRadius) : nil)
        let shadow = geometry.shadowLayers.isEmpty ? nil
            : try AnnotationCompositor.makeShadow(document, geometry: geometry, mask: mask)
        cornerMask = mask
        shadowImage = shadow
        key = newKey
        preparedGeometry = geometry
        return geometry
    }
}

/// One coordinate system and one compositor for the canvas and every exported snapshot.
/// All entry points expect image-pixel coordinates with the origin at the top left.
nonisolated enum AnnotationCompositor {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnnotationRenderingError.allocation
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Shared preview/export presentation in ORIGINAL image coordinates.
    /// Prepare immutable alpha resources before drawing, so failures never silently drop style.
    static func drawPresentation(_ document: AnnotationDocument, in context: CGContext,
                                 ciContext: CIContext, cache: AnnotationPresentationCache? = nil) throws {
        let style = document.captureStyle.normalized
        if style.cornerRadius == 0, style.borderWidth == 0, style.shadow == .off {
            cache?.clear()
            try drawContent(document, in: context, ciContext: ciContext)
            return
        }
        let resources = cache ?? AnnotationPresentationCache()
        let geometry = try resources.prepare(document)
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .none
        if let shadow = resources.shadowImage {
            drawImage(shadow, in: geometry.presentationBounds, context: context)
        }
        // Raster mask coverage, rather than a hard Quartz path clip, antialiases the corners.
        // The transparency group applies that coverage once to all marks and mosaics together.
        if let mask = resources.cornerMask { context.clip(to: document.imageBounds, mask: mask) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        do {
            try drawContent(document, in: context, ciContext: ciContext)
            drawBorder(document.captureStyle, geometry: geometry, in: context)
        } catch {
            context.endTransparencyLayer()
            throw error
        }
        context.endTransparencyLayer()
    }

    /// Canvas-only path: live content, current corner coverage and border, exact shadow if ready.
    /// Never prepares a shadow or reuses a fully composited image on the event loop.
    static func drawPreview(_ document: AnnotationDocument, in context: CGContext, ciContext: CIContext,
                            geometry: CaptureStyleGeometry, cornerMask: CGImage?, shadow: CGImage?) throws {
        if geometry.cornerRadius == 0, geometry.borderWidth == 0, geometry.shadowLayers.isEmpty {
            try drawContent(document, in: context, ciContext: ciContext)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .none
        if let shadow { drawImage(shadow, in: geometry.presentationBounds, context: context) }
        if let cornerMask { context.clip(to: document.imageBounds, mask: cornerMask) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        try drawContent(document, in: context, ciContext: ciContext)
        drawBorder(document.captureStyle, geometry: geometry, in: context)
    }

    // Adapted from CapCap BeautifyRenderer.CornerMask, MIT, Copyright (c) 2026
    // realskyrin, commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
    // Keep a native-pixel mask independent of dirty rectangles and preview zoom.
    static func makeCornerMask(size: CGSize, radius: CGFloat) throws -> CGImage {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw AnnotationRenderingError.allocation
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        guard let mask = context.makeImage() else { throw AnnotationRenderingError.allocation }
        return mask
    }

    private static func drawBorder(_ style: CaptureStyle, geometry: CaptureStyleGeometry, in context: CGContext) {
        let width = geometry.borderWidth
        guard width > 0 else { return }
        let rect = geometry.contentBounds.insetBy(dx: width / 2, dy: width / 2)
        let radius = max(0, geometry.cornerRadius - width / 2)
        context.setStrokeColor(style.borderColor.cgColor)
        context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    /// Shadow resources depend only on the immutable screenshot alpha, radius and border.
    /// Annotation redraws therefore never allocate/render a full-size image.
    static func makeShadow(_ document: AnnotationDocument, geometry: CaptureStyleGeometry,
                           mask: CGImage?) throws -> CGImage {
        try makeShadow(source: document.capture.image, style: document.captureStyle,
                       geometry: geometry, mask: mask)
    }

    static func makeShadow(source original: CGImage, style: CaptureStyle, geometry: CaptureStyleGeometry,
                           mask: CGImage?) throws -> CGImage {
        let content = geometry.contentBounds
        let source: CGImage
        if mask != nil || geometry.borderWidth > 0 {
            let clipped = try bitmap(width: original.width, height: original.height)
            if let mask { clipped.clip(to: content, mask: mask) }
            clipped.beginTransparencyLayer(auxiliaryInfo: nil)
            drawImage(original, in: content, context: clipped)
            drawBorder(style, geometry: geometry, in: clipped)
            clipped.endTransparencyLayer()
            guard let image = clipped.makeImage() else { throw AnnotationRenderingError.allocation }
            source = image
        } else {
            source = original
        }
        let bounds = geometry.presentationBounds
        guard let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnnotationRenderingError.allocation
        }
        // Use unflipped Quartz coordinates for the extracted CapCap shadow algorithm.
        let rect = CGRect(x: -bounds.minX, y: bounds.maxY - content.height,
                          width: content.width, height: content.height)
        for layer in geometry.shadowLayers { drawShadowOnly(source, rect: rect, layer: layer, in: context) }
        guard let image = context.makeImage() else { throw AnnotationRenderingError.allocation }
        return image
    }

    // Adapted directly from CapCap WindowEffects.drawShadowOnly (MIT), Copyright
    // (c) 2026 realskyrin, commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
    // Displaced actual-alpha casting avoids a black source rim; destinationOut
    // hollows each shadow with fractional coverage, not a jagged inverse path.
    private static func drawShadowOnly(_ image: CGImage, rect: CGRect, layer: CaptureShadowLayer,
                                       in context: CGContext) {
        let outset = layer.fringe + max(abs(layer.offset.width), abs(layer.offset.height))
        let clip = rect.insetBy(dx: -outset, dy: -outset)
        let displacement = clip.width + outset
        context.saveGState()
        context.clip(to: clip)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: layer.offset.width - displacement, height: layer.offset.height),
                          blur: layer.blur, color: CGColor(gray: 0, alpha: layer.opacity))
        context.draw(image, in: rect.offsetBy(dx: displacement, dy: 0))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.destinationOut)
        context.draw(image, in: rect)
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func drawOrdinary(_ document: AnnotationDocument, in context: CGContext) {
        drawImage(document.capture.image, in: document.imageBounds, context: context)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in document.annotations {
            context.saveGState()
            context.setStrokeColor(annotation.style.color.cgColor)
            context.setFillColor(annotation.style.color.cgColor)
            context.setLineWidth(annotation.style.lineWidth)
            switch annotation.payload {
            case .arrow, .rectangle, .pen:
                context.addPath(AnnotationGeometry.path(annotation))
                context.strokePath()
            case let .highlight(rect):
                context.setFillColor(AnnotationColor.highlight.cgColor)
                context.fill(rect)
            case let .text(rect, text):
                context.clip(to: rect)
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                let font = CTFontCreateUIFontForLanguage(.system, annotation.style.fontSize, nil)
                    ?? CTFontCreateWithName("Helvetica" as CFString, annotation.style.fontSize, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.style.color.cgColor
                ]
                let string = NSAttributedString(string: text, attributes: attributes)
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
            case .mosaic: break
            }
            context.restoreGState()
        }
    }

    private static func drawContent(_ document: AnnotationDocument, in context: CGContext, ciContext: CIContext) throws {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: document.imageBounds)
        drawOrdinary(document, in: context)
        let clip = context.boundingBoxOfClipPath.intersection(document.imageBounds)
        for annotation in document.annotations {
            guard case let .mosaic(rect, blockSize) = annotation.payload else { continue }
            let target = rect.standardized.intersection(document.imageBounds).intersection(clip)
            guard !target.isEmpty, !target.isNull else { continue }
            let size = max(1, blockSize)
            // A small native-pixel tile, padded enough to sample complete grid cells.
            // Never allocate a fresh full-size composite for a mouse movement.
            let expanded = target.insetBy(dx: -size * 2, dy: -size * 2).integral.intersection(document.imageBounds)
            let tile = try bitmap(width: Int(expanded.width), height: Int(expanded.height))
            tile.translateBy(x: -expanded.minX, y: -expanded.minY)
            drawOrdinary(document, in: tile)
            guard let source = tile.makeImage() else { throw AnnotationRenderingError.allocation }
            let height = document.imageBounds.height
            let ciSource = CIImage(cgImage: source).transformed(by: CGAffineTransform(
                translationX: expanded.minX, y: height-expanded.maxY))
            // Top-left (0,0) of the immutable source anchors the grid, even when moved.
            let output = ciSource.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: size,
                kCIInputCenterKey: CIVector(x: 0, y: height)
            ])
            let ciRect = CGRect(x: target.minX, y: height-target.maxY, width: target.width, height: target.height).integral
            guard let pixelated = ciContext.createCGImage(output, from: ciRect,
                                                          format: .RGBA8, colorSpace: colorSpace) else {
                throw AnnotationRenderingError.mosaic
            }
            let drawRect = CGRect(x: ciRect.minX, y: height-ciRect.maxY, width: ciRect.width, height: ciRect.height)
            context.saveGState()
            context.clip(to: target)
            context.interpolationQuality = .none
            drawImage(pixelated, in: drawRect, context: context)
            context.restoreGState()
        }
    }
}

actor ImageRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func render(_ document: AnnotationDocument) async throws -> RenderedCapture {
        try Task.checkCancellation()
        // Untouched plain output preserves even transparent source pixels exactly,
        // without a color conversion or a second full-size allocation.
        let geometry = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                       sourceScale: document.capture.sourceScale)
        if document.annotations.isEmpty, geometry.cornerRadius == 0,
           geometry.borderWidth == 0, geometry.shadowLayers.isEmpty {
            return RenderedCapture(id: document.capture.id, revision: document.revision,
                                   createdAt: document.capture.createdAt, mode: document.capture.mode,
                                   image: document.capture.image, sourceScale: document.capture.sourceScale)
        }
        let bounds = geometry.presentationBounds
        let resources: AnnotationPresentationCache?
        if geometry.cornerRadius > 0 || geometry.borderWidth > 0 || !geometry.shadowLayers.isEmpty {
            let prepared = AnnotationPresentationCache()
            _ = try prepared.prepare(document, geometry: geometry)
            resources = prepared
        } else {
            resources = nil
        }
        let context = try AnnotationCompositor.bitmap(width: Int(bounds.width), height: Int(bounds.height))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        try AnnotationCompositor.drawPresentation(document, in: context, ciContext: ciContext, cache: resources)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw AnnotationRenderingError.allocation }
        let result = RenderedCapture(id: document.capture.id, revision: document.revision,
                                     createdAt: document.capture.createdAt, mode: document.capture.mode,
                                     image: image, sourceScale: document.capture.sourceScale)
        return result
    }
}
