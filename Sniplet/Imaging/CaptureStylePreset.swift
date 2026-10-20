/// Complete style choices shared by new-capture defaults and the current capture's controls.
nonisolated enum CaptureStylePreset: CaseIterable, Hashable, Sendable {
    case original, soft, outlined, presentation

    var label: String {
        switch self {
        case .original: "原图"
        case .soft: "轻柔"
        case .outlined: "细框"
        case .presentation: "展示"
        }
    }

    var style: CaptureStyle {
        switch self {
        case .original: .plain
        case .soft: CaptureStyle(cornerRadius: 12, shadow: .subtle)
        case .outlined: CaptureStyle(cornerRadius: 12, shadow: .off, borderWidth: 1, borderColor: .gray)
        case .presentation: CaptureStyle(cornerRadius: 20, shadow: .medium, borderWidth: 1, borderColor: .white)
        }
    }

    static func matching(_ style: CaptureStyle) -> Self? {
        allCases.first { $0.style == style }
    }
}
