import CoreGraphics
import Foundation
import Vision
import os

nonisolated struct OCRResult: Equatable, Sendable {
    let text: String
    let missingLanguages: [String]
}

nonisolated enum OCRServiceError: LocalizedError, Sendable {
    case languageSupportUnavailable
    case preferredLanguagesUnavailable
    case recognitionFailed
    case missingResults

    var errorDescription: String? {
        switch self {
        case .languageSupportUnavailable:
            "无法查询本机文字识别语言，请重试。"
        case .preferredLanguagesUnavailable:
            "本机不支持所需的中文或英文识别语言，无法识别文字。"
        case .recognitionFailed:
            "本机文字识别失败，请重试。"
        case .missingResults:
            "文字识别未返回结果，请重试。"
        }
    }
}

/// Both editor OCR and history indexing share this serial, off-main Vision executor.
actor OCRService {
    func recognize(_ image: CGImage) async throws -> OCRResult {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try performRecognition(image, cancelled: cancelled)
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private func performRecognition(_ image: CGImage, cancelled: OSAllocatedUnfairLock<Bool>) throws -> OCRResult {
        try Task.checkCancellation()
        // There are no suspension points while a request runs. This actor therefore
        // never executes two synchronous Vision requests at the same time.
        return try autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = false
            request.progressHandler = { request, _, _ in
                if cancelled.withLock({ $0 }) { request.cancel() }
            }

            let supported: Set<String>
            do {
                supported = Set(try request.supportedRecognitionLanguages())
            } catch {
                throw OCRServiceError.languageSupportUnavailable
            }
            let preferred = ["zh-Hans", "zh-Hant", "en-US"]
            let languages = preferred.filter { supported.contains($0) }
            guard !languages.isEmpty else {
                throw OCRServiceError.preferredLanguagesUnavailable
            }
            request.recognitionLanguages = languages
            let missing = preferred.filter { !supported.contains($0) }

            try Task.checkCancellation()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                try Task.checkCancellation()
                throw OCRServiceError.recognitionFailed
            }
            try Task.checkCancellation()
            guard let observations = request.results else {
                throw OCRServiceError.missingResults
            }

            var fragments: [OCRTextFragment] = []
            fragments.reserveCapacity(observations.count)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first,
                      !candidate.string.isEmpty else { continue }
                let box = observation.boundingBox
                // Vision uses a normalized lower-left origin; ordering uses top-left.
                let topLeft = CGRect(x: box.minX, y: 1 - box.maxY,
                                     width: box.width, height: box.height)
                fragments.append(OCRTextFragment(text: candidate.string, boundingBox: topLeft))
            }
            return OCRResult(text: OCRReadingOrder.text(from: fragments), missingLanguages: missing)
        }
    }
}
