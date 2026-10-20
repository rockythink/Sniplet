/// Edges and corners of a frozen capture selection. Top is the visual AppKit top.
nonisolated enum CaptureSelectionResizeHandle: CaseIterable, Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
