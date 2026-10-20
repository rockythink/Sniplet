import Foundation
import os

/// File-URL-only drop targets need an existing final PNG, not a file promise.
/// Adapted from CapCap PinImageDragPayload (MIT), commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
actor DragExportFileStore {
    static let shared = DragExportFileStore()
    private let root: URL
    private static let retention: TimeInterval = 600
    private static let logger = Logger(subsystem: "com.elazer.Sniplet", category: "DragExportCleanup")

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Sniplet-Drag", isDirectory: true)) {
        self.root = root
    }

    func stage(_ snapshot: EncodedCapture) throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try removeExpiredFiles()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(ExportFilename.png(createdAt: snapshot.capture.createdAt))
        do {
            try snapshot.pngData.write(to: file, options: .atomic)
            try Task.checkCancellation()
            return file
        } catch {
            Self.remove(directory)
            throw error
        }
    }

    func discard(_ file: URL) { Self.remove(file.deletingLastPathComponent()) }

    /// Receivers can open the URL after the drag source and editor have closed.
    /// Delay removal as CapCap does; the next drag also reaps files left by an exit.
    nonisolated func retainForReceiver(_ file: URL) {
        let directory = file.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.retention) {
            Self.remove(directory)
        }
    }

    private func removeExpiredFiles() throws {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isDirectoryKey]
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) {
            let values = try directory.resourceValues(forKeys: keys)
            if values.isDirectory == true, let created = values.creationDate,
               Date().timeIntervalSince(created) >= Self.retention {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    nonisolated private static func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { logger.error("Unable to remove a final-image drag staging directory; cleanup will retry on the next drag.") }
    }
}
