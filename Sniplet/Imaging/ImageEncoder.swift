import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageEncoder {
    func png(_ image: CGImage) throws -> Data {
        try encode(image, type: .png)
    }

    func tiff(_ image: CGImage) throws -> Data {
        try encode(image, type: .tiff)
    }

    func thumbnail(_ image: CGImage, maxPixelSize: Int = 320) throws -> Data {
        try Task.checkCancellation()
        guard maxPixelSize > 0 else { throw EncodingError.failed }
        let factor = min(1, CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw EncodingError.failed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw EncodingError.failed }
        return try encode(thumbnail, type: .png)
    }

    private func encode(_ image: CGImage, type: UTType) throws -> Data {
        try Task.checkCancellation()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = image.copy(colorSpace: colorSpace) else {
            throw EncodingError.failed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw EncodingError.failed
        }
        // No source metadata, annotation objects, or OCR strings enter the output.
        CGImageDestinationAddImage(destination, converted, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodingError.failed }
        return data as Data
    }
}

nonisolated enum EncodingError: LocalizedError {
    case failed

    var errorDescription: String? { "无法编码图像，图像仍保留在浮窗中，请重试。" }
}
