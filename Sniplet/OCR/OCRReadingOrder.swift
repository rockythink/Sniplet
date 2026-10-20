import CoreGraphics

/// A recognized fragment in normalized, top-left-origin image coordinates.
nonisolated struct OCRTextFragment: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
}

/// Horizontal reading order only; this intentionally does not infer columns or tables.
nonisolated enum OCRReadingOrder {
    private struct Row {
        // Keep the first member fixed: a tall later fragment must not merge two rows.
        let anchor: CGRect
        var fragments: [OCRTextFragment]
    }

    static func lines(from fragments: [OCRTextFragment]) -> [[OCRTextFragment]] {
        let sorted = fragments.sorted { precedes($0, $1, horizontally: false) }
        var rows: [Row] = []
        for fragment in sorted {
            var bestRow: Int?
            var bestOverlap: CGFloat = 0
            for index in rows.indices {
                let anchor = rows[index].anchor
                let shorterHeight = min(anchor.height, fragment.boundingBox.height)
                guard shorterHeight > 0 else { continue }
                let overlap = max(0, min(anchor.maxY, fragment.boundingBox.maxY)
                                  - max(anchor.minY, fragment.boundingBox.minY))
                let ratio = overlap / shorterHeight
                // Strictly greater preserves the first-created row on an equal ratio.
                if ratio >= 0.5, bestRow == nil || ratio > bestOverlap {
                    bestRow = index
                    bestOverlap = ratio
                }
            }
            if let bestRow {
                rows[bestRow].fragments.append(fragment)
            } else {
                rows.append(Row(anchor: fragment.boundingBox, fragments: [fragment]))
            }
        }
        return rows.map { row in
            row.fragments.sorted { precedes($0, $1, horizontally: true) }
        }
    }

    static func text(from fragments: [OCRTextFragment]) -> String {
        lines(from: fragments)
            .map { $0.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func precedes(_ lhs: OCRTextFragment, _ rhs: OCRTextFragment,
                                 horizontally: Bool) -> Bool {
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        let firstLeft = horizontally ? left.minX : left.minY
        let firstRight = horizontally ? right.minX : right.minY
        if firstLeft != firstRight { return firstLeft < firstRight }
        let secondLeft = horizontally ? left.minY : left.minX
        let secondRight = horizontally ? right.minY : right.minX
        if secondLeft != secondRight { return secondLeft < secondRight }
        // Geometry and lexical tie-breaks do not depend on Vision's array order.
        if left.height != right.height { return left.height < right.height }
        if left.width != right.width { return left.width < right.width }
        return lhs.text < rhs.text
    }
}
