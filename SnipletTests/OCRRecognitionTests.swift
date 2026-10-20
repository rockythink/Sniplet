import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Sniplet

struct OCRRecognitionTests {
    @Test func localVisionRecognizesClearEnglishAndDigits() async throws {
        let context = try #require(CGContext(data: nil, width: 1200, height: 240, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 240))
        let font = CTFontCreateWithName("Menlo" as CFString, 76, nil)
        let text = NSAttributedString(string: "Sniplet 12345", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 60, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try #require(context.makeImage())
        let result = try await OCRService().recognize(image)
        #expect(result.text == "Sniplet 12345")
    }

    @Test func aRealBlankImageIsSuccessfulEmptyRecognition() async throws {
        let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        let result = try await OCRService().recognize(#require(context.makeImage()))
        #expect(result.text == "")
    }
}
