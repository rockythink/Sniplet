import SwiftUI

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
                .frame(minWidth: 32, minHeight: 32)
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
