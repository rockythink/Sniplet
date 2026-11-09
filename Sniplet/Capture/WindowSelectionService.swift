import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated struct WindowCandidate: Sendable {
    let id: CGWindowID
    let bounds: CGRect
    let owner: pid_t
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

    /// `includingOwn` also offers Sniplet's own normal-level windows (settings, guide, history).
    /// Its overlays, editors and pins sit on higher levels and never qualify.
    nonisolated static func ordinaryWindows(capturableIDs: Set<CGWindowID>, includingOwn: Bool = false) -> [WindowCandidate] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return entries.compactMap {
            candidate(from: $0, capturableIDs: capturableIDs, ownPID: ownPID, includingOwn: includingOwn)
        }
    }

    nonisolated static func candidate(from entry: [String: Any], capturableIDs: Set<CGWindowID>,
                                      ownPID: pid_t, includingOwn: Bool) -> WindowCandidate? {
        guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              capturableIDs.contains(id),
              let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              includingOwn || owner != ownPID,
              (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
              let raw = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
              bounds.width > 0, bounds.height > 0 else { return nil }
        return WindowCandidate(id: id, bounds: bounds, owner: owner)
    }

    nonisolated static func hit(at point: CGPoint, candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.bounds.contains(point) }
    }

    /// The windows `window`'s app shows on `display` (Quartz), largest first, when together they
    /// cover all of it: the app is in full screen there. A full-screen app need not be one window:
    /// Chrome leaves the top strip out of its content window and covers it with toolbar windows.
    ///
    /// `topInset` is the notch strip: a full-screen Space leaves it empty, so no window covers it.
    /// A window zoomed under a notched display's menu bar with the Dock hidden also passes, and
    /// is cropped from the frozen display, which gives the same pixels.
    nonisolated static func fullScreenWindows(of window: WindowCandidate, candidates: [WindowCandidate],
                                              display: CGRect, topInset: CGFloat = 0) -> [WindowCandidate]? {
        let group = candidates.filter { $0.owner == window.owner && $0.bounds.intersects(display) }
        // A point of slack absorbs fractional window frames at the display edges.
        let target = CGRect(x: display.minX, y: display.minY + topInset,
                            width: display.width, height: display.height - topInset).insetBy(dx: 1, dy: 1)
        guard !target.isEmpty, covers(group.map(\.bounds), target) else { return nil }
        return group.sorted { area($0.bounds.intersection(display)) > area($1.bounds.intersection(display)) }
    }

    /// Exact union coverage on the grid of every rectangle edge; window counts stay small.
    nonisolated private static func covers(_ rects: [CGRect], _ target: CGRect) -> Bool {
        let parts = rects.map { $0.intersection(target) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Set(parts.flatMap { [$0.minX, $0.maxX] } + [target.minX, target.maxX]).sorted()
        let ys = Set(parts.flatMap { [$0.minY, $0.maxY] } + [target.minY, target.maxY]).sorted()
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            for (y0, y1) in zip(ys, ys.dropFirst()) {
                let center = CGPoint(x: (x0+x1)/2, y: (y0+y1)/2)
                guard parts.contains(where: { $0.contains(center) }) else { return false }
            }
        }
        return true
    }

    nonisolated private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
