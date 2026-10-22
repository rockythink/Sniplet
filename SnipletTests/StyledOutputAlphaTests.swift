import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Sniplet

/// The padding a shadow adds must stay transparent all the way to the encoded files.
struct StyledOutputAlphaTests {
    private func opaqueCapture(scale: CGFloat) throws -> CapturedImage {
        let context = try AnnotationCompositor.bitmap(width: 200, height: 120)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        let image = try #require(context.makeImage())
        return CapturedImage(id: UUID(), createdAt: Date(), mode: .region, image: image, sourceScale: scale, displayID: 1)
    }

    private func decodedAlpha(_ data: Data, x: Int, y: Int) throws -> (alpha: UInt8, info: CGImageAlphaInfo) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try AnnotationCompositor.bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Bitmap rows are top-down in memory.
        return (bytes[(y * context.bytesPerRow) + x * 4 + 3], image.alphaInfo)
    }

    @Test(arguments: CaptureStylePreset.allCases, [CGFloat(1), 2])
    func presetPaddingStaysTransparentInPNGAndTIFF(preset: CaptureStylePreset, scale: CGFloat) async throws {
        let style = preset.style
        guard style.shadow != .off else { return }
        let rendered = try await ImageRenderer().render(AnnotationDocument(capture: opaqueCapture(scale: scale),
                                                                           captureStyle: style)).image
        let encoder = ImageEncoder()
        for data in [try await encoder.png(rendered), try await encoder.tiff(rendered)] {
            for (x, y) in [(0, 0), (rendered.width - 1, 0), (0, rendered.height - 1), (rendered.width - 1, rendered.height - 1)] {
                let result = try decodedAlpha(data, x: x, y: y)
                #expect(result.alpha == 0, "\(preset) @\(scale)x corner (\(x),\(y)) alpha \(result.alpha) info \(result.info.rawValue)")
                #expect(result.info != .none && result.info != .noneSkipLast && result.info != .noneSkipFirst)
            }
        }
    }

    @Test(arguments: CaptureStyle.Background.allCases.filter { $0 != .none })
    func aBackgroundFillsThePaddingSoChatAppsHaveNothingToFlatten(background: CaptureStyle.Background) async throws {
        let style = CaptureStyle(cornerRadius: 20, shadow: .medium, background: background)
        let rendered = try await ImageRenderer().render(AnnotationDocument(capture: opaqueCapture(scale: 2),
                                                                           captureStyle: style)).image
        let data = try await ImageEncoder().png(rendered)
        for (x, y) in [(0, 0), (rendered.width - 1, 0), (0, rendered.height - 1), (rendered.width / 2, rendered.height - 1)] {
            #expect(try decodedAlpha(data, x: x, y: y).alpha == 255, "\(background) (\(x),\(y))")
        }
    }

    @Test func backgroundPaddingIsAtLeastThePaddingOnEverySide() {
        let size = CGSize(width: 200, height: 120)
        let plain = CaptureStyle(background: .white).geometry(imageSize: size, sourceScale: 2).presentationBounds
        #expect(plain == CGRect(x: -64, y: -64, width: 328, height: 248))
        // A strong shadow can need more room below than the padding; it still fits.
        let shadowed = CaptureStyle(shadow: .strong, background: .sky).geometry(imageSize: size, sourceScale: 2)
        let shadowOnly = CaptureStyle(shadow: .strong).geometry(imageSize: size, sourceScale: 2)
        #expect(shadowed.presentationBounds.contains(shadowOnly.presentationBounds))
        #expect(shadowed.presentationBounds.minX <= -64 && shadowed.presentationBounds.minY <= -64)
        #expect(!CaptureStyle(background: .white).isPlain && CaptureStyle.plain.isPlain)
    }

    @Test func stylesSavedBeforeBackgroundsStillDecode() throws {
        let saved = Data(#"{"cornerRadius":12,"shadow":"medium","borderWidth":1,"borderColor":"gray"}"#.utf8)
        let style = try JSONDecoder().decode(CaptureStyle.self, from: saved)
        #expect(style == CaptureStyle(cornerRadius: 12, shadow: .medium, borderWidth: 1, borderColor: .gray))
        let roundTrip = CaptureStyle(cornerRadius: 8, background: .peach)
        #expect(try JSONDecoder().decode(CaptureStyle.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }
}
