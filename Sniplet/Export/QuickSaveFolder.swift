import AppKit
import Observation

/// The folder ⌘S saves into without a dialog. The sandbox only lets Sniplet back into a
/// folder the user picked, so it is kept as a security-scoped bookmark.
@MainActor @Observable final class QuickSaveFolder {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "export.quickSaveFolder"
    /// For Settings; nil until a folder is chosen.
    private(set) var displayPath: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayPath = resolve()?.path
    }

    /// The chosen folder, refreshing a stale bookmark; nil if none or it no longer resolves.
    func resolve() -> URL? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    /// Asks once; the answer is remembered for every later ⌘S.
    func choose(message: String = "选择 ⌘S 直接存放截图的文件夹") async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = message
        panel.directoryURL = resolve()
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
        displayPath = nil
    }

    func remember(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        defaults.set(data, forKey: Self.key)
        displayPath = url.path
    }
}

nonisolated enum QuickSaveNaming {
    /// Never overwrites: "Sniplet-….png", then "Sniplet-… 2.png", "… 3", and so on.
    static func availableURL(in folder: URL, preferredName: String,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(preferredName)
        var index = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}
