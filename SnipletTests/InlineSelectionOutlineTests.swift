import CoreGraphics
import Testing
@testable import Sniplet

struct InlineSelectionOutlineTests {
    @Test(arguments: [CGFloat(1), 1.5, 2], [CGFloat(0.25), 1, 2])
    func outlineCornersTrackSourceScaleAndCanvasZoom(_ sourceScale: CGFloat, _ zoom: CGFloat) throws {
        let size = CGSize(width: 240, height: 160)
        let displayed = CGRect(x: -380, y: 70, width: size.width / sourceScale * zoom,
                               height: size.height / sourceScale * zoom)
        let outline = try #require(InlineSelectionOutline(imageRect: displayed, imageSize: size,
            style: CaptureStyle(cornerRadius: 12), sourceScale: sourceScale))
        #expect(abs(outline.cornerRadii.width - 12 * zoom) < 0.000001)
        #expect(abs(outline.cornerRadii.height - 12 * zoom) < 0.000001)
        let nearCorner = CGPoint(x: displayed.minX + outline.cornerRadii.width * 0.1,
                                 y: displayed.minY + outline.cornerRadii.height * 0.1)
        #expect(!outline.path.contains(nearCorner))
        #expect(outline.path.contains(CGPoint(x: displayed.midX, y: displayed.midY)))
        let plain = try #require(InlineSelectionOutline(imageRect: displayed, imageSize: size,
                                                        style: .plain, sourceScale: sourceScale))
        #expect(plain.path.contains(nearCorner))
    }

    @Test func tinyImageUsesTheSameClampedRadiusAsTheRenderedImage() throws {
        let size = CGSize(width: 7, height: 5)
        let style = CaptureStyle(cornerRadius: 48)
        let geometry = style.geometry(imageSize: size, sourceScale: 2)
        let outline = try #require(InlineSelectionOutline(
            imageRect: CGRect(x: 10, y: 20, width: 3.5, height: 2.5),
            imageSize: size, style: style, sourceScale: 2))
        #expect(outline.cornerRadii == CGSize(width: geometry.cornerRadius / 2, height: geometry.cornerRadius / 2))
        #expect(outline.cornerRadii == CGSize(width: 1.25, height: 1.25))
        #expect(!outline.path.contains(CGPoint(x: 10.1, y: 20.1)))
        #expect(outline.path.contains(CGPoint(x: 11.75, y: 21.25)))
    }

    @Test func nonUniformDisplayTransformPreservesImageCornerCoverage() throws {
        let displayed = CGRect(x: -500, y: -120, width: 100, height: 25)
        let outline = try #require(InlineSelectionOutline(
            imageRect: displayed, imageSize: CGSize(width: 200, height: 100),
            style: CaptureStyle(cornerRadius: 12), sourceScale: 2))
        #expect(outline.cornerRadii == CGSize(width: 12, height: 6))
        #expect(outline.path.boundingBoxOfPath == displayed)
        #expect(!outline.path.contains(CGPoint(x: -499, y: -119)))
        #expect(outline.path.contains(CGPoint(x: -450, y: -119)))
    }
}
