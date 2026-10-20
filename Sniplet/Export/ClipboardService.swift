import AppKit
import UniformTypeIdentifiers

@MainActor
struct ClipboardService {
    /// Process-wide preference: nspasteboard.org transient marker. Clipboard managers
    /// (Copyla included, by default) skip such entries; local paste is unaffected.
    static var marksCopiesTransient = false

    func copyImage(pngData: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setData(pngData, forType: .png) else {
            throw ClipboardError.failed
        }
        markTransient(on: pasteboard)
    }

    func copyText(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.setString(text, forType: .string) else {
            throw ClipboardError.failed
        }
        markTransient(on: pasteboard)
    }

    private func markTransient(on pasteboard: NSPasteboard) {
        guard Self.marksCopiesTransient, let type = UTType("org.nspasteboard.TransientType") else { return }
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(type.identifier))
    }
}

nonisolated enum ClipboardError: LocalizedError {
    case failed

    var errorDescription: String? { "复制失败，内容仍保留在 Sniplet 中，请重试。" }
}
