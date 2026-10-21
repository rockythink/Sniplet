import SwiftUI

/// Shared by Settings (future captures only) and the inline editor's per-capture popup.
struct CaptureStyleControls: View {
    @Binding var style: CaptureStyle
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// The inline editor previews on the real capture, so only Settings shows the sample.
    var showsPreview = true
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("美化预设", selection: presetSelection) {
                ForEach(CaptureStylePreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(Optional(preset))
                }
                if CaptureStylePreset.matching(style) == nil {
                    Text("自定义").tag(Optional<CaptureStylePreset>.none)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("选择预设会应用整套样式；下方参数可继续微调")

            if showsPreview { CaptureStylePreview(style: style) }
            fineControls
            Text("透明留白随阴影自动调整；边框位于图片内侧。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
        .frame(minWidth: 260, idealWidth: 300)
        .onDisappear { editingChanged(false) }
    }

    private var presetSelection: Binding<CaptureStylePreset?> {
        Binding(
            get: { CaptureStylePreset.matching(style) },
            set: { preset in
                guard let preset else { return }
                // A preset is one complete change, separate from any active slider drag.
                editingChanged(false)
                style = preset.style
            }
        )
    }

    private var fineControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("圆角")
                HStack {
                    Slider(value: $style.cornerRadius, in: 0...48, step: 1, onEditingChanged: editingChanged)
                        .accessibilityLabel("圆角半径（点）")
                    Text("\(Int(style.normalized.cornerRadius)) pt")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
            GridRow {
                Text("阴影")
                Picker("阴影强度", selection: $style.shadow) {
                    ForEach(CaptureStyle.Shadow.allCases, id: \.self) { shadow in
                        Text(shadow.label).tag(shadow)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            GridRow {
                Text("边框")
                HStack {
                    Slider(value: $style.borderWidth, in: 0...8, step: 0.5, onEditingChanged: editingChanged)
                        .accessibilityLabel("边框宽度（点，零为关闭）")
                    Text(style.borderWidth == 0 ? "关闭" : String(format: "%.1f pt", style.normalized.borderWidth))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
            GridRow {
                Text("边框颜色")
                Picker("边框颜色", selection: $style.borderColor) {
                    ForEach(CaptureStyle.BorderColor.allCases, id: \.self) { color in
                        Text(color.label).tag(color)
                    }
                }
                .labelsHidden().disabled(style.borderWidth == 0)
            }
        }
    }

    private func editingChanged(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        onEditingChanged?(editing)
    }
}
