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

    /// ⌘S for a recording: the same folder and naming as screenshots, under the file's own name.
    func quickSave(fileAt source: URL, folder: QuickSaveFolder, askIfNeeded: Bool = true) async throws -> URL? {
        var target = folder.resolve()
        if target == nil, askIfNeeded { target = await folder.choose(message: "选择 ⌘S 直接存放截图和录屏的文件夹") }
        guard let target else { return nil }
        return try await writer.copy(source, into: target, preferredName: source.lastPathComponent)
    }
}

actor ExportFileWriter {
    /// Writes into a security-scoped folder under a name that never replaces an existing file.
    func write(_ data: Data, into folder: URL, preferredName: String) throws -> URL {
        // Exclusive create (no .atomic, which cannot be combined with it).
        try create(in: folder, preferredName: preferredName) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    /// Copies a file the same way; `copyItem` never replaces an existing destination either.
    func copy(_ source: URL, into folder: URL, preferredName: String) throws -> URL {
        try create(in: folder, preferredName: preferredName) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    /// A name that appears between choosing it and creating the file is skipped, not replaced.
    private func create(in folder: URL, preferredName: String, _ make: (URL) throws -> Void) throws -> URL {
        try Task.checkCancellation()
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        var taken = Set<URL>()
        while true {
            let url = QuickSaveNaming.availableURL(in: folder, preferredName: preferredName) {
                taken.contains($0) || FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try make(url)
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
