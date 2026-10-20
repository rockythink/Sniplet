import SwiftUI

/// Stable pointer targets and immediate feedback without resizing the symbol on selection.
struct InlineToolbarButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, isSelected: isSelected)
    }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }

        private var backgroundOpacity: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.20 }
            if isSelected { return 0.13 }
            return isHovered ? 0.08 : 0
        }
    }
}
