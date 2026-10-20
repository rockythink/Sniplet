import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Sniplet

struct ImageRenderingTests {
    private func source(width: Int = 64, height: Int = 48) throws -> CapturedImage {
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y*width+x)*4
                bytes[index] = UInt8((x*17+y*3)%256)
                bytes[index+1] = UInt8((y*23+x*7)%256)
                bytes[index+2] = UInt8((x*11+y*19)%256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: width*4,
                                        space: AnnotationCompositor.colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .region, image: image, sourceScale: 2, displayID: 1)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: AnnotationCompositor.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }

    @Test func unannotatedOutputPreservesDimensionsOrientationAndMetadata() async throws {
        let capture = try source()
        let result = try await ImageRenderer().render(AnnotationDocument(capture: capture))
        #expect(result.id == capture.id)
        #expect(result.revision == 0)
        #expect(result.image.width == 64)
        #expect(result.image.height == 48)
        #expect(result.sourceScale == 2)
        for (x, y) in [(0, 0), (63, 0), (0, 47), (63, 47), (19, 25)] {
            #expect(try pixel(result.image, x: x, y: y) == pixel(capture.image, x: x, y: y))
        }
    }

    @Test func mosaicChangesOnlyCoverageAndOldRegionRestoresWhenMoved() async throws {
        let capture = try source()
        let renderer = ImageRenderer()
        let rect = CGRect(x: 8, y: 8, width: 16, height: 16)
        let annotation = Annotation(payload: .mosaic(rect: rect, blockSize: 8))
        var document = AnnotationDocument(capture: capture, annotations: [annotation], revision: 1)
        let first = try await renderer.render(document)
        for (x, y) in [(7, 8), (8, 7), (24, 12), (12, 24), (0, 0), (63, 47)] {
            #expect(try pixel(first.image, x: x, y: y) == pixel(capture.image, x: x, y: y))
        }
        #expect(try pixel(first.image, x: 10, y: 10) != pixel(capture.image, x: 10, y: 10))
        document.annotations = [AnnotationGeometry.translated(annotation, by: CGSize(width: 24, height: 8))]
        document.revision += 1
        let moved = try await renderer.render(document)
        #expect(try pixel(moved.image, x: 10, y: 10) == pixel(capture.image, x: 10, y: 10))
        #expect(try pixel(moved.image, x: 34, y: 18) != pixel(capture.image, x: 34, y: 18))
        document.annotations = [annotation]
        document.revision += 1
        let undone = try await renderer.render(document)
        for y in 0..<48 {
            for x in 0..<64 {
                #expect(try pixel(first.image, x: x, y: y) == pixel(undone.image, x: x, y: y))
            }
        }
    }

    @Test func mosaicGridIsAnchoredAndCoversAnnotationsDrawnAfterIt() async throws {
        let capture = try source()
        let renderer = ImageRenderer()
        let mosaic = Annotation(payload: .mosaic(rect: CGRect(x: 3, y: 3, width: 42, height: 34), blockSize: 8))
        let mark = Annotation(payload: .rectangle(rect: CGRect(x: 10, y: 10, width: 20, height: 15)),
                              style: AnnotationStyle(color: .white, lineWidth: 3))
        let first = try await renderer.render(AnnotationDocument(capture: capture, annotations: [mosaic, mark], revision: 1))
        let second = try await renderer.render(AnnotationDocument(capture: capture, annotations: [mark, mosaic], revision: 2))
        #expect(try pixel(first.image, x: 10, y: 10) == pixel(second.image, x: 10, y: 10))
        let shifted = Annotation(payload: .mosaic(rect: CGRect(x: 6, y: 6, width: 40, height: 35), blockSize: 8))
        let third = try await renderer.render(AnnotationDocument(capture: capture, annotations: [mark, shifted], revision: 3))
        for (x, y) in [(8, 8), (16, 18), (25, 22), (35, 30)] {
            #expect(try pixel(first.image, x: x, y: y) == pixel(third.image, x: x, y: y))
        }
    }

    @Test func previewAndFinalUseExactlyTheSameCompositorWithoutSelectionControls() async throws {
        let capture = try source()
        let annotations = [
            Annotation(payload: .arrow(start: CGPoint(x: 4, y: 4), end: CGPoint(x: 28, y: 20))),
            Annotation(payload: .rectangle(rect: CGRect(x: 2, y: 30, width: 20, height: 10))),
            Annotation(payload: .pen(points: [CGPoint(x: 30, y: 3), CGPoint(x: 40, y: 12), CGPoint(x: 50, y: 4)])),
            Annotation(payload: .text(rect: CGRect(x: 25, y: 24, width: 35, height: 20), text: "中 A"),
                       style: AnnotationStyle(color: .black, fontSize: 10)),
            Annotation(payload: .highlight(rect: CGRect(x: 5, y: 20, width: 20, height: 8))),
            Annotation(payload: .mosaic(rect: CGRect(x: 36, y: 8, width: 20, height: 18), blockSize: 8))
        ]
        let document = AnnotationDocument(capture: capture, annotations: annotations, revision: 7)
        let preview = try AnnotationCompositor.bitmap(width: 64, height: 48)
        try AnnotationCompositor.drawPresentation(document, in: preview, ciContext: CIContext(options: [.cacheIntermediates: false]))
        let previewImage = try #require(preview.makeImage())
        let final = try await ImageRenderer().render(document)
        #expect(final.revision == 7)
        for (x, y) in [(0, 0), (4, 4), (15, 34), (20, 24), (40, 20), (63, 47)] {
            #expect(try pixel(final.image, x: x, y: y) == pixel(previewImage, x: x, y: y))
        }
        // No selection/UI data is part of AnnotationDocument or the export compositor.
        #expect(try pixel(final.image, x: 0, y: 47) == pixel(capture.image, x: 0, y: 47))
    }
}
