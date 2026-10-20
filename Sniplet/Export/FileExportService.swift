import AppKit
import UniformTypeIdentifiers

@MainActor
struct FileExportService {
    private let writer = ExportFileWriter()

    func save(pngData: Data, createdAt: Date) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ExportFilename.png(createdAt: createdAt)
        panel.title = "保存截图"
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard response == .OK, let url = panel.url else { return false }
        try Task.checkCancellation()
        try await writer.write(pngData, to: url)
        return true
    }
}

actor ExportFileWriter {
    func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum ExportFilename {
    static func png(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Sniplet-\(formatter.string(from: createdAt)).png"
    }
}
