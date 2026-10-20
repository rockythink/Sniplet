import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Sniplet

struct CaptureStyleRenderingTests {
    private func capture(scale: CGFloat = 1, width: Int = 120, height: Int = 90,
                         transparent: Bool = false, pattern: Bool = false) throws -> CapturedImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if !transparent {
                    bytes[i] = pattern ? UInt8((x * 17 + y * 3) % 256) : 255
                    bytes[i + 1] = pattern ? UInt8((x * 5 + y * 23) % 256) : 255
                    bytes[i + 2] = pattern ? UInt8((x * 11 + y * 7) % 256) : 255
                    bytes[i + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: AnnotationCompositor.colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .region,
                             image: image, sourceScale: scale, displayID: 1)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: AnnotationCompositor.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        try pixels(#require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))))
    }

    private func preview(_ document: AnnotationDocument, clip: CGRect? = nil,
                         cache: AnnotationPresentationCache? = nil) throws -> CGImage {
        let bounds = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                    sourceScale: document.capture.sourceScale).presentationBounds
        let context = try AnnotationCompositor.bitmap(width: Int(bounds.width), height: Int(bounds.height))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        if let clip { context.clip(to: clip) }
        try AnnotationCompositor.drawPresentation(document, in: context,
                                                  ciContext: CIContext(options: [.cacheIntermediates: false]), cache: cache)
        return try #require(context.makeImage())
    }

    @Test(arguments: [CGFloat(1), 1.5, 2])
    func plainPreservesEveryPixelAndExactDimensions(_ scale: CGFloat) async throws {
        for transparent in [false, true] {
            let source = try capture(scale: scale, transparent: transparent, pattern: true)
            let document = AnnotationDocument(capture: source)
            let output = try await ImageRenderer().render(document)
            #expect(output.image.width == source.image.width)
            #expect(output.image.height == source.image.height)
            #expect(try pixels(output.image) == pixels(source.image))
        }
    }

    @Test(arguments: [CGFloat(1), 1.5, 2])
    func decorationUsesSourceScaleAndDoesNotResampleInterior(_ scale: CGFloat) async throws {
        let source = try capture(scale: scale, pattern: true)
        let style = CaptureStyle(cornerRadius: 9, shadow: .medium, borderWidth: 1.5, borderColor: .blue)
        let document = AnnotationDocument(capture: source, captureStyle: style)
        let geometry = style.geometry(imageSize: document.imageBounds.size, sourceScale: scale)
        #expect(geometry.cornerRadius == 9 * scale)
        #expect(geometry.borderWidth == 1.5 * scale)
        #expect(geometry.presentationBounds.integral == geometry.presentationBounds)
        #expect(geometry.presentationBounds.minX < 0)
        #expect(geometry.presentationBounds.minY < 0)
        #expect(geometry.presentationBounds.maxY - document.imageBounds.maxY > -geometry.presentationBounds.minY)
        let output = try await ImageRenderer().render(document)
        #expect(output.image.width == Int(geometry.presentationBounds.width))
        #expect(output.image.height == Int(geometry.presentationBounds.height))
        let crop = try #require(output.image.cropping(to: CGRect(x: 30 - geometry.presentationBounds.minX,
                                                                y: 30 - geometry.presentationBounds.minY,
                                                                width: 60, height: 30)))
        let original = try #require(source.image.cropping(to: CGRect(x: 30, y: 30, width: 60, height: 30)))
        #expect(try pixels(crop) == pixels(original))
    }

    @Test func radiusClampsOnTinyImagesWithoutAddingPadding() async throws {
        let source = try capture(scale: 2, width: 7, height: 5)
        let style = CaptureStyle(cornerRadius: 48)
        let geometry = style.geometry(imageSize: CGSize(width: 7, height: 5), sourceScale: 2)
        #expect(geometry.cornerRadius == 2.5)
        #expect(geometry.presentationBounds == CGRect(x: 0, y: 0, width: 7, height: 5))
        let output = try await ImageRenderer().render(AnnotationDocument(capture: source, captureStyle: style))
        #expect(output.image.width == 7)
        #expect(output.image.height == 5)
        #expect(try pixel(output.image, 3, 2) == [255, 255, 255, 255])
    }

    @Test func roundedCornersClipAllAnnotationsAndMosaicWithFractionalAlpha() async throws {
        let source = try capture()
        let annotations = [
            Annotation(payload: .highlight(rect: CGRect(x: 0, y: 0, width: 120, height: 90))),
            Annotation(payload: .mosaic(rect: CGRect(x: 0, y: 0, width: 120, height: 90), blockSize: 8))
        ]
        let document = AnnotationDocument(capture: source, annotations: annotations,
                                          captureStyle: CaptureStyle(cornerRadius: 16))
        let image = try await ImageRenderer().render(document).image
        #expect(try pixel(image, 0, 0)[3] == 0)
        #expect(try pixel(image, 119, 89)[3] == 0)
        #expect(try pixel(image, 60, 45)[3] == 255)
        let data = try pixels(image)
        #expect(stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 && data[$0] < 255 })
    }

    @Test(arguments: [CGFloat(1), 2])
    func borderIsInsideFootprintAndUsesFixedSRGB(_ scale: CGFloat) async throws {
        let source = try capture(scale: scale)
        let document = AnnotationDocument(capture: source,
                                          captureStyle: CaptureStyle(borderWidth: 2, borderColor: .blue))
        let image = try await ImageRenderer().render(document).image
        #expect(image.width == source.image.width)
        #expect(image.height == source.image.height)
        let border = try pixel(image, 0, 45)
        #expect(abs(Int(border[0]) - 20) <= 1)
        #expect(abs(Int(border[1]) - 89) <= 1)
        #expect(abs(Int(border[2]) - 242) <= 1)
        #expect(border[3] == 255)
        #expect(try pixel(image, Int(2 * scale) - 1, 45) == border)
        #expect(try pixel(image, Int(2 * scale) + 1, 45) == [255, 255, 255, 255])
    }

    @Test func shadowCastsFromActualAlphaAndNeverAddsBlackSourceRim() async throws {
        let style = CaptureStyle(cornerRadius: 12, shadow: .strong)
        let empty = try capture(transparent: true)
        let emptyImage = try await ImageRenderer().render(AnnotationDocument(capture: empty, captureStyle: style)).image
        #expect(try pixels(emptyImage).allSatisfy { $0 == 0 })
        let source = try capture()
        let document = AnnotationDocument(capture: source, captureStyle: style)
        let bounds = style.geometry(imageSize: document.imageBounds.size, sourceScale: 1).presentationBounds
        let output = try await ImageRenderer().render(document).image
        let x = Int(-bounds.minX), y = Int(-bounds.minY)
        #expect(try pixel(output, x, y + 45) == [255, 255, 255, 255])
        #expect(try pixel(output, x + 60, y + 45) == [255, 255, 255, 255])
        #expect(try pixel(output, x - 3, y + 45)[3] > 0)
        #expect(try pixel(output, 0, 0)[3] == 0)
        let bordered = AnnotationDocument(capture: empty,
                                          captureStyle: CaptureStyle(shadow: .medium, borderWidth: 2, borderColor: .white))
        let borderedOutput = try await ImageRenderer().render(bordered).image
        let borderedBounds = bordered.captureStyle.geometry(imageSize: bordered.imageBounds.size, sourceScale: 1).presentationBounds
        let borderX = Int(-borderedBounds.minX), borderY = Int(-borderedBounds.minY)
        #expect(try pixel(borderedOutput, borderX, borderY + 45) == [255, 255, 255, 255])
        #expect(try pixel(borderedOutput, borderX + 60, borderY + 45)[3] == 0)
    }

    @Test func transparentBandsKeepTheirActualSilhouetteAndStrengthControlsPadding() async throws {
        let context = try AnnotationCompositor.bitmap(width: 240, height: 90)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 120, y: 0, width: 120, height: 90))
        let source = CapturedImage(id: UUID(), createdAt: Date(), mode: .window,
                                   image: try #require(context.makeImage()), sourceScale: 1, displayID: 1)
        let strong = CaptureStyle(shadow: .strong)
        let subtle = CaptureStyle(shadow: .subtle)
        let bounds = strong.geometry(imageSize: CGSize(width: 240, height: 90), sourceScale: 1).presentationBounds
        let subtleBounds = subtle.geometry(imageSize: CGSize(width: 240, height: 90), sourceScale: 1).presentationBounds
        #expect(bounds.width > subtleBounds.width)
        #expect(bounds.height > subtleBounds.height)
        let output = try await ImageRenderer().render(AnnotationDocument(capture: source, captureStyle: strong)).image
        let x = Int(-bounds.minX), y = Int(-bounds.minY)
        // A rectangular proxy would incorrectly cast onto the far left of the transparent band.
        #expect(try pixel(output, x - 3, y + 45)[3] == 0)
        #expect(try pixel(output, x + 116, y + 45)[3] > 0)
        #expect(try pixel(output, x + 180, y + 45) == [255, 255, 255, 255])
    }

    @Test func partialDirtyPreviewEqualsFullPreviewAndExportIncludingShadow() async throws {
        let source = try capture(scale: 1.5, pattern: true)
        let document = AnnotationDocument(capture: source, annotations: [
            Annotation(payload: .mosaic(rect: CGRect(x: 4, y: 4, width: 50, height: 40), blockSize: 8)),
            Annotation(payload: .rectangle(rect: CGRect(x: 10, y: 10, width: 60, height: 40)))
        ], captureStyle: CaptureStyle(cornerRadius: 12, shadow: .medium, borderWidth: 1))
        let cache = AnnotationPresentationCache()
        let full = try preview(document, cache: cache)
        let final = try await ImageRenderer().render(document).image
        #expect(try pixels(full) == pixels(final))
        let bounds = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                    sourceScale: source.sourceScale).presentationBounds
        // Source starts well outside the dirty clip: shadow may not depend on it being visible.
        for dirty in [CGRect(x: -20, y: 20, width: 18, height: 35),
                      CGRect(x: 2, y: 2, width: 30, height: 30),
                      CGRect(x: 30, y: 86, width: 40, height: 20)] {
            let partial = try preview(document, clip: dirty, cache: cache)
            let crop = dirty.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let a = try #require(partial.cropping(to: crop))
            let b = try #require(full.cropping(to: crop))
            #expect(try pixels(a) == pixels(b))
        }
    }
    @Test(arguments: [false, true])
    func livePreviewKeepsCurrentMosaicAndCornersWhileShadowIsPending(_ shadowReady: Bool) async throws {
        let source = try capture(scale: 1.5, pattern: true)
        let style = CaptureStyle(cornerRadius: 14, shadow: .medium, borderWidth: 2, borderColor: .blue)
        let geometry = style.geometry(imageSize: CGSize(width: source.image.width, height: source.image.height),
                                      sourceScale: source.sourceScale)
        let mask = try AnnotationCompositor.makeCornerMask(size: geometry.contentBounds.size,
                                                           radius: geometry.cornerRadius)
        // These source-alpha resources are prepared before the latest mosaic edit.
        let shadow = shadowReady ? try AnnotationCompositor.makeShadow(
            source: source.image, style: style, geometry: geometry, mask: mask) : nil
        let current = AnnotationDocument(capture: source, annotations: [
            Annotation(payload: .mosaic(rect: CGRect(x: 1, y: 1, width: 90, height: 60), blockSize: 16)),
            Annotation(payload: .highlight(rect: CGRect(x: 0, y: 0, width: 120, height: 90)))
        ], captureStyle: style)
        let context = try AnnotationCompositor.bitmap(width: Int(geometry.presentationBounds.width),
                                                      height: Int(geometry.presentationBounds.height))
        context.translateBy(x: -geometry.presentationBounds.minX, y: -geometry.presentationBounds.minY)
        try AnnotationCompositor.drawPreview(current, in: context, ciContext: CIContext(),
                                              geometry: geometry, cornerMask: mask, shadow: shadow)
        let image = try #require(context.makeImage())
        if shadowReady {
            let final = try await ImageRenderer().render(current).image
            #expect(try pixels(image) == pixels(final))
        } else {
            var noShadowStyle = style
            noShadowStyle.shadow = .off
            let noShadow = AnnotationDocument(capture: source, annotations: current.annotations,
                                              captureStyle: noShadowStyle)
            let expected = try await ImageRenderer().render(noShadow).image
            let content = try #require(image.cropping(to: geometry.contentBounds.offsetBy(
                dx: -geometry.presentationBounds.minX, dy: -geometry.presentationBounds.minY)))
            #expect(try pixels(content) == pixels(expected))
            #expect(try pixel(image, 0, 0)[3] == 0)
        }
    }

    @Test func opaqueBorderPalettePreservesExactShadowsOnTransparentSource() async throws {
        let source = try capture(transparent: true)
        let cache = AnnotationPresentationCache()
        for color in CaptureStyle.BorderColor.allCases {
            let document = AnnotationDocument(capture: source, captureStyle: CaptureStyle(
                cornerRadius: 12, shadow: .medium, borderWidth: 3, borderColor: color))
            let cached = try preview(document, cache: cache)
            let final = try await ImageRenderer().render(document).image
            #expect(try pixels(cached) == pixels(final))
        }
    }
}
