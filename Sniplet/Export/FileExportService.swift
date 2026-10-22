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

    /// ⌘S: straight into the chosen folder, asking for one only the first time.
    /// Nil when the user dismisses that one-time folder choice.
    func quickSave(pngData: Data, createdAt: Date, folder: QuickSaveFolder, askIfNeeded: Bool = true) async throws -> URL? {
        var target = folder.resolve()
        if target == nil, askIfNeeded { target = await folder.choose() }
        guard let target else { return nil }
        return try await writer.write(pngData, into: target, preferredName: ExportFilename.png(createdAt: createdAt))
    }
}

actor ExportFileWriter {
    /// Writes into a security-scoped folder under a name that never replaces an existing file.
    func write(_ data: Data, into folder: URL, preferredName: String) throws -> URL {
        try Task.checkCancellation()
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        var taken = Set<URL>()
        while true {
            let url = QuickSaveNaming.availableURL(in: folder, preferredName: preferredName) {
                taken.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            // Exclusive create (no .atomic, which cannot be combined with it): a name that
            // appears in the meantime is skipped rather than replaced.
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                taken.insert(url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum ExportFilename {
    static func png(createdAt: Date) -> String { "Sniplet-\(stamp(createdAt)).png" }
    static func mp4(createdAt: Date) -> String { "Sniplet-\(stamp(createdAt)).mp4" }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
