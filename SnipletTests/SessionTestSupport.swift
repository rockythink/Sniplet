import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Sniplet

@MainActor enum SessionTestSupport {
    static func capture() throws -> CapturedImage {
        let width = 32, height = 24
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 17 + y * 3) % 256)
                bytes[i + 1] = UInt8((y * 23 + x * 7) % 256)
                bytes[i + 2] = UInt8((x * 11 + y * 19) % 256)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                        bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CapturedImage(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             mode: .region, image: image, sourceScale: 1, displayID: 1)
    }

    static func services(history: Bool = false,
                         ocrEnabled: Bool = true,
                         persist: @escaping (RenderedCapture, Data) async throws -> Void = { _, _ in
                             throw UnexpectedSessionEffect.persistence
                         }) -> EditorServices {
        EditorServices(renderer: ImageRenderer(), encoder: ImageEncoder(), ocr: OCRService(),
                       files: FileExportService(), pin: { _ in
                           preconditionFailure("Session unit tests must never create a pin window")
                       }, isOCREnabled: { ocrEnabled },
                       shouldStoreHistory: { history }, persist: persist)
    }

    static func image(_ png: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let one = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1,
                                                bitsPerComponent: 8, bytesPerRow: 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private enum UnexpectedSessionEffect: Error { case persistence }
}
