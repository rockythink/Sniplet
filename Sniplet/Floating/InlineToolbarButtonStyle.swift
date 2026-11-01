import SwiftUI

/// One target size, glyph size and gap for every control on both inline bars, so mixed
/// buttons, menus and the AppKit drag handle line up on a single grid.
enum InlineToolbarMetrics {
    static let button: CGFloat = 32
    static let glyph: CGFloat = 16
    static let spacing: CGFloat = 4
    /// Space around a bar's controls; both bars are `button + 2 * inset` thick.
    static let inset: CGFloat = 6
}

/// A toolbar symbol at the shared glyph size, centred in the shared target.
struct InlineToolbarIcon: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: InlineToolbarMetrics.glyph, weight: .medium))
            .frame(width: InlineToolbarMetrics.button, height: InlineToolbarMetrics.button)
    }
}

/// A hairline between groups: vertical in a row, horizontal in the side column.
struct InlineToolbarSeparator: View {
    var inColumn = false

    var body: some View {
        if inColumn {
            Divider().frame(width: 20).padding(.vertical, 2)
        } else {
            Divider().frame(height: 20).padding(.horizontal, 2)
        }
    }
}

/// Stable pointer targets and immediate feedback without resizing the symbol on selection.
struct InlineToolbarButtonStyle: ButtonStyle {
    var isSelected = false
    /// The single primary action of a bar, drawn with the accent fill.
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, isSelected: isSelected, isProminent: isProminent)
    }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minWidth: InlineToolbarMetrics.button, minHeight: InlineToolbarMetrics.button)
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
                .background(background, in: RoundedRectangle(cornerRadius: 5))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var background: Color {
            guard isProminent else { return Color.primary.opacity(backgroundOpacity) }
            if configuration.isPressed { return Color.accentColor.opacity(0.75) }
            return Color.accentColor.opacity(isHovered ? 0.9 : 1)
        }

        private var backgroundOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.20 }
            if isSelected { return 0.13 }
            return isHovered ? 0.08 : 0
        }
    }
}
