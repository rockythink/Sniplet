import AppKit
import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }

            captureAppearance
                .tabItem { Label("截图外观", systemImage: "photo.artframe") }

            shortcuts
                .tabItem { Label("快捷键", systemImage: "keyboard") }

            privacyAndHistory
                .tabItem { Label("隐私与历史", systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 520)
        .onAppear { coordinator.permissions.refresh() }
        .onChange(of: coordinator.preferences.historyEnabled) { _, _ in coordinator.historyPreferenceChanged() }
        .onChange(of: coordinator.preferences.ocrEnabled) { _, _ in coordinator.historyPreferenceChanged() }
    }

    private var general: some View {
        @Bindable var preferences = coordinator.preferences
        return Form {
            Section {
                caption("按 \(regionShortcut) 拖动选区域，或单击选窗口；原位标注后复制、保存、钉住或拖出。全部在本机处理。")
            }
            Section("屏幕录制权限") {
                LabeledContent("当前状态", value: coordinator.permissions.isAvailable ? "可用" : "尚不可用")
                HStack {
                    Button("打开系统设置", action: coordinator.permissions.openSystemSettings)
                    Button("重新检查", action: coordinator.permissions.refresh)
                }
                caption("隐私与安全性 → 屏幕录制。开启后仍不可用时，请退出并重新打开 Sniplet。")
                if coordinator.permissions.settingsOpenFailed {
                    Text("无法打开系统设置，请从 Apple 菜单手动打开。")
                        .foregroundStyle(.red)
                }
            }
            Section("功能开关") {
                Toggle(isOn: $preferences.ocrEnabled) {
                    Text("文字识别（OCR）")
                    Text("关闭后隐藏「复制文字」，并暂停历史的文字索引。")
                }
                Toggle(isOn: $preferences.transientCopyEnabled) {
                    Text("复制的截图标记为临时内容")
                    Text("Copyla 等剪贴板工具默认不收录临时内容，避免同一张图记两份；粘贴不受影响。")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section {
                caption("需包含 ⌘ 或 ⌃；与已知快捷键冲突时保留原绑定。不常用的入口可以清除，菜单栏仍可触发。")
            }
            Section("区域截图（常用）") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .region)
                caption("拖动框选，或单击截取所在窗口。")
            }
            Section("窗口截图") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .window)
                caption("只点选单个窗口，含标题栏、不带投影。")
            }
            Section("整屏截图") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .fullScreen)
                caption("截取鼠标所在的整块显示器。")
            }
        }
        .formStyle(.grouped)
    }

    private var captureAppearance: some View {
        @Bindable var preferences = coordinator.preferences
        return Form {
            Section("截图选区提示框") {
                ColorPicker("选区框颜色", selection: selectionFrameColor, supportsOpacity: false)
                Picker("选区框线型", selection: $preferences.selectionAppearance.lineStyle) {
                    ForEach(CaptureSelectionAppearance.LineStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                selectionFramePreview
                caption("只影响截图时的提示框，不会印进最终图片。")
                Button("恢复选区框默认设置") {
                    preferences.selectionAppearance = .standard
                }
            }
            Section("新截图默认美化") {
                CaptureStyleControls(style: $preferences.defaultCaptureStyle)
                caption("用于之后的新截图；单张截图可在工具条的 ✨ 美化中调整。")
            }
        }
        .formStyle(.grouped)
    }

    private var regionShortcut: String {
        coordinator.shortcuts.isBound(.region) ? coordinator.shortcuts.description(for: .region) : "区域截图快捷键"
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionFrameColor: Binding<Color> {
        Binding(
            get: {
                let color = coordinator.preferences.selectionAppearance.normalized.color
                return Color(.sRGB, red: Double(color.red), green: Double(color.green),
                             blue: Double(color.blue), opacity: 1)
            },
            set: { value in
                guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
                coordinator.preferences.selectionAppearance.color = AnnotationColor(
                    red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            }
        )
    }

    private var selectionFramePreview: some View {
        let appearance = coordinator.preferences.selectionAppearance.normalized
        return LabeledContent("提示框预览") {
            HStack(spacing: 0) {
                Color(white: 0.94)
                Color(white: 0.16)
            }
            .overlay {
                Rectangle()
                    .strokeBorder(Color(cgColor: appearance.color.cgColor),
                                  style: StrokeStyle(lineWidth: 1,
                                                     lineCap: appearance.lineStyle == .dotted ? .round : .butt,
                                                     dash: appearance.lineStyle.dashPattern))
                    .padding(16)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("选区提示框预览")
            .accessibilityValue(appearance.lineStyle.label)
        }
    }

    private var privacyAndHistory: some View {
        @Bindable var preferences = coordinator.preferences
        return Form {
            Section("本地历史") {
                Toggle(isOn: $preferences.historyEnabled) {
                    Text("保存完成后的截图")
                    Text("保留最近 500 张、合计不超过 1 GiB 的最终图与识别文字。关闭只停止新增，不删除已有记录。")
                }
                Button("清空历史…", role: .destructive, action: coordinator.clearHistory)
                    .disabled(coordinator.historyStore == nil)
                if let error = coordinator.historyError {
                    Text(error).font(.callout).foregroundStyle(.red)
                    if coordinator.historyStore == nil {
                        Button("重试打开历史", action: coordinator.initializeHistory)
                    } else {
                        Button("重试清理", action: coordinator.retryHistoryCleanup)
                    }
                }
                ForEach(coordinator.historyRecoveryMessages, id: \.self) { message in
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("本机处理边界") {
                caption("复制仅限本机，不参与通用剪贴板同步；受保护的窗口不会被绕过。")
                caption("马赛克是视觉像素化，不保证不可恢复；导出到其他应用后由对方处理。")
            }
        }
        .formStyle(.grouped)
    }
}
