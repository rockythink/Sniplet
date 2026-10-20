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
            Section("Sniplet 做什么") {
                Text("按下快捷键后：选一块区域或轻点一个窗口，直接在原位标注、美化，然后复制、保存、钉住或拖出。全部处理都在本机完成，没有账号和云同步。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("日常只需要记住一个入口：区域截图（默认 ⇧⌘A）。拖动选区域，或轻点直接截整窗。另外两个入口不常用可以清除，清除后仍能从菜单栏触发。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("屏幕录制权限") {
                LabeledContent("当前状态", value: coordinator.permissions.isAvailable ? "可用" : "尚不可用")
                Text("仅在主动截图时读取屏幕。不录制视频或音频；图像、文字识别和历史均在本机处理。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("打开系统设置", action: coordinator.permissions.openSystemSettings)
                    Button("重新检查", action: coordinator.permissions.refresh)
                }
                Text("系统设置 → 隐私与安全性 → 屏幕录制（或屏幕与系统音频录制）。开启后请重试，必要时退出并手动重新打开 Sniplet。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if coordinator.permissions.settingsOpenFailed {
                    Text("无法打开系统设置，请从 Apple 菜单手动打开。")
                        .foregroundStyle(.red)
                }
            }
            Section("功能开关") {
                Toggle("文字识别（OCR）", isOn: $preferences.ocrEnabled)
                Text("关闭后隐藏截图工具条上的「复制文字」，历史也暂停后台文字索引；已识别条目仍可搜索。与 Copyla 一起用时，如果习惯用 Copyla 识别文字，可以关掉这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("复制的截图标记为临时内容", isOn: $preferences.transientCopyEnabled)
                Text("复制图像或文字时附带「临时」标记：Copyla 等剪贴板工具默认不收录、不弹提示，本机粘贴不受影响。两个应用一起用时可避免同一张图记两份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("如果同时使用 Copyla 等剪贴板工具，可按需调整上面的开关。两个应用相互独立，不互相检测。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("三个截图入口") {
                Text("先只记住区域截图就够了；另外两个是偶尔才用的入口。快捷键需包含 Command 或 Control，系统或其他应用占用时会显示冲突并保留旧绑定；无法枚举所有第三方占用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("区域截图 · 日常使用") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .region)
                Text("拖动框选一块区域，或轻点直接截取所在窗口。选区限制在起始屏幕，不跨屏拼接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("窗口截图 · 专点一个窗口") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .window)
                Text("进入后只能点选单个普通窗口，包含标题栏、不带投影。不需要时清除快捷键即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("整屏截图 · 整块显示器") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .fullScreen)
                Text("截取鼠标所在的一整块显示器，没有选区步骤。不需要时清除快捷键即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("仅调整截图时的选区提示，不会成为最终图片的边框，也不会进入导出或文字识别。成图样式请使用下方「新截图默认美化」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("恢复选区框默认设置") {
                    preferences.selectionAppearance = .standard
                }
            }
            Section("新截图默认美化") {
                CaptureStyleControls(style: $preferences.defaultCaptureStyle)
                Text("立即保存，仅用于之后新建的截图，不会修改当前截图。截图后也可在「美化」中单独调整。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Toggle("保存完成后的截图", isOn: $preferences.historyEnabled)
                Text("只保存最终成图与其识别文字，最近 500 张且合计最多 1 GiB。关闭只停止新增和后台索引，不删除已有记录。编辑中崩溃或强退无法恢复未完成截图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("复制默认标记为仅本机（host-only），不进入通用剪贴板同步。系统可能隐藏受保护窗口，Sniplet 不绕过保护。马赛克是视觉像素化，并非密码学意义的不可恢复。你主动保存到云盘或粘贴到其他联网应用后，由接收方处理数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
