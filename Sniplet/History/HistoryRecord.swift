import CoreGraphics
import Foundation
import SwiftData

@Model
nonisolated final class HistoryRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var modeRawValue: String
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int64
    var ocrStatusRawValue: String
    var ocrText: String

    init(capture: RenderedCapture, byteCount: Int64) {
        id = capture.id
        createdAt = capture.createdAt
        modeRawValue = capture.mode.rawValue
        pixelWidth = capture.image.width
        pixelHeight = capture.image.height
        self.byteCount = byteCount
        ocrStatusRawValue = HistoryOCRStatus.pending.rawValue
        ocrText = ""
    }
}

nonisolated enum HistoryOCRStatus: String, Sendable {
    case pending, ready, empty, failed

    var label: String {
        switch self {
        case .pending: "等待文字索引"
        case .ready: "文字可搜索"
        case .empty: "未识别到文字"
        case .failed: "文字识别失败"
        }
    }
}

nonisolated struct HistoryLimits: Sendable {
    let maxCount: Int
    let maxBytes: Int64
    static let production = HistoryLimits(maxCount: 500, maxBytes: 1_073_741_824)
}

nonisolated struct HistorySummary: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let mode: CaptureMode
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
    let ocrStatus: HistoryOCRStatus
    let ocrText: String

    // Foundation date formatters are thread-safe; reuse them instead of allocating
    // three formatters per row on every keystroke in a 500-item search.
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    var filename: String { "Sniplet-\(Self.filenameFormatter.string(from: createdAt)).png" }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if ocrStatus == .ready && ocrText.localizedStandardContains(query) { return true }
        return filename.localizedStandardContains(query)
            || Self.searchDateFormatter.string(from: createdAt).localizedStandardContains(query)
            || createdAt.formatted(.iso8601).localizedStandardContains(query)
    }
}

nonisolated struct HistoryOCRWork: Sendable {
    let id: UUID
    let token: UUID
    let image: CGImage
}

nonisolated struct HistoryStorageStatus: Sendable {
    let recoveryMessages: [String]
    let cleanupError: String?
}

nonisolated enum HistoryError: LocalizedError {
    case invalidLimits, itemTooLarge, missingRecord, invalidImage, invalidMetadata, cleanupRequired, changedDuringInsert

    var errorDescription: String? {
        switch self {
        case .invalidLimits: "历史保留上限必须大于零。"
        case .itemTooLarge: "这张图片与缩略图超过历史空间上限；仍可复制或保存图片。"
        case .missingRecord: "这条历史已删除或图片不可用。"
        case .invalidImage: "无法读取历史图片。"
        case .invalidMetadata: "历史元数据无法读取；未修改图片文件。"
        case .cleanupRequired: "历史文件清理未完成，已暂停新增历史。请重试清理或检查磁盘权限与可用空间。"
        case .changedDuringInsert: "历史在保存期间发生变化，请重试保存。"
        }
    }
}
