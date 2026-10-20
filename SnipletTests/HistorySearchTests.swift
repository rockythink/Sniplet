import Foundation
import Testing
@testable import Sniplet

@Suite("Local history substring search")
struct HistorySearchTests {
    @Test(arguments: ["本地", "繁體", "SNIPLET", "12345", "cafe", "  Sniplet 12345\n"])
    func readyTextMatchesLiteralChineseCaseAndDiacritics(_ query: String) {
        let summary = sample(status: .ready, text: "本地识别 / 繁體中文 / Sniplet 12345 / Café")
        #expect(summary.matches(query))
    }

    @Test(arguments: [HistoryOCRStatus.pending, .failed, .empty])
    func unfinishedOrFailedIndexNeverMatchesStaleText(_ status: HistoryOCRStatus) {
        let summary = sample(status: status, text: "private stale text")
        #expect(!summary.matches("private stale"))
        #expect(summary.matches("1970-01-01"))
        #expect(summary.matches("Sniplet-"))
    }

    @Test(arguments: ["", " ", "\n\t"])
    func emptyTrimmedQueryReturnsEveryStatus(_ query: String) {
        for status in [HistoryOCRStatus.pending, .ready, .empty, .failed] {
            #expect(sample(status: status, text: "").matches(query))
        }
    }

    @Test func filenamesDatesAndLiteralPunctuationAreSearchableWithoutRegexSemantics() {
        let summary = sample(status: .ready, text: "foo[0].bar + $value")
        #expect(summary.matches(summary.filename))
        #expect(summary.matches("1970-01-01"))
        #expect(summary.matches("foo[0].bar"))
        #expect(summary.matches("+ $value"))
        #expect(!summary.matches("foo.*bar"))
        #expect(!summary.matches("not present"))
    }

    private func sample(status: HistoryOCRStatus, text: String) -> HistorySummary {
        HistorySummary(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), mode: .region,
                       pixelWidth: 100, pixelHeight: 80, byteCount: 800,
                       ocrStatus: status, ocrText: text)
    }
}
