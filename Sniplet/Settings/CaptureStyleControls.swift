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
            Text("留白随阴影自动调整；边框位于图片内侧。微信等会把透明留白铺成白色，选一个背景就能避开。")
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
            GridRow {
                Text("背景")
                HStack(spacing: 6) {
                    ForEach(CaptureStyle.Background.allCases, id: \.self) { background in
                        BackgroundSwatch(background: background, isSelected: style.background == background) {
                            editingChanged(false)
                            style.background = background
                        }
                    }
                }
            }
        }
    }

    private func editingChanged(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        onEditingChanged?(editing)
    }
}

/// A round swatch per backdrop; "transparent" shows a checkerboard.
private struct BackgroundSwatch: View {
    let background: CaptureStyle.Background
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 20, height: 20)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5) }
                .padding(2)
                .overlay { if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .help(background.label)
        .accessibilityLabel("背景：\(background.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var fill: some View {
        let colors = background.colors.map { Color(cgColor: $0) }
        if colors.isEmpty {
            Canvas { context, size in
                let cell = size.width / 4
                for row in 0..<4 {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                                 width: cell, height: cell)), with: .color(.gray.opacity(0.35)))
                    }
                }
            }
            .background(.white)
        } else if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
