import SwiftUI

/// A tip handed to a fresh capture's editor; `onShown` fires once it is actually visible.
struct EditorTipRequest {
    let tip: EditorTip
    let message: String
    let onShown: () -> Void
}

/// Editing chrome like the toolbars: never part of the rendered output or OCR.
struct EditorTipView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("使用提示")
    }
}

/// The `?` popover: every key that works while a capture is open.
struct EditorShortcutSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    group("输出", GuideContent.outputShortcuts)
                    group("编辑", GuideContent.editingShortcuts)
                }
                group("切换工具", GuideContent.toolShortcuts)
            }
            Text("完整说明在菜单栏「使用指南…」")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .fixedSize()
    }

    private func group(_ title: String, _ items: [GuideShortcut]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            GuideShortcutList(items: items)
        }
    }
}
