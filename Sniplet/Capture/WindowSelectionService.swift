import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated struct WindowCandidate: Sendable {
    let id: CGWindowID
    let bounds: CGRect
}

/// CGWindow order is preserved; ScreenCaptureKit determines which IDs are capturable.
actor WindowSelectionService {
    func candidates() async throws -> [WindowCandidate] {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let ids = Set(content.windows.map(\.windowID))
        return Self.ordinaryWindows(capturableIDs: ids)
    }

    nonisolated static func ordinaryWindows(capturableIDs: Set<CGWindowID>) -> [WindowCandidate] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return entries.compactMap { entry in
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  capturableIDs.contains(id),
                  (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            return WindowCandidate(id: id, bounds: bounds)
        }
    }

    nonisolated static func hit(at point: CGPoint, candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.bounds.contains(point) }
    }
}
