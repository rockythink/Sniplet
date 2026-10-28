import AppKit
import SwiftUI

/// First-launch welcome: where Sniplet lives, Screen Recording, then a first real capture.
/// It can be closed at any step and reopened from Settings or the guide.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(coordinator: AppCoordinator, step: WelcomeStep) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 Sniplet"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        // Closing releases this hosting view, so never do it inside one of its button actions.
        window.contentView = NSHostingView(rootView: WelcomeView(coordinator: coordinator, initialStep: step, close: { [weak self] in
            DispatchQueue.main.async { self?.close() }
        }))
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}

struct WelcomeView: View {
    static let size = CGSize(width: 560, height: 440)

    let coordinator: AppCoordinator
    let close: () -> Void
    @State private var step: WelcomeStep

    init(coordinator: AppCoordinator, initialStep: WelcomeStep, close: @escaping () -> Void) {
        self.coordinator = coordinator
        self.close = close
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .menuBar: WelcomeMenuBarStep(regionShortcut: regionShortcut)
                case .permission: WelcomePermissionStep(coordinator: coordinator)
                case .firstCapture: WelcomeFirstCaptureStep(coordinator: coordinator)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(WelcomeStep.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 \(step.rawValue + 1) 步，共 \(WelcomeStep.allCases.count) 步")
            Spacer()
            if let previous = step.previous {
                Button("上一步") { step = previous }
            }
            if let next = step.next {
                Button("下一步") { step = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("完成", action: close)
                Button("现在截一张") {
                    close()
                    coordinator.requestCapture(.region)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var regionShortcut: String? {
        coordinator.shortcuts.isBound(.region) ? coordinator.shortcuts.description(for: .region) : nil
    }
}

private struct WelcomeHeader: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WelcomeMenuBarStep: View {
    let regionShortcut: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WelcomeHeader(symbol: "menubar.rectangle", title: "Sniplet 在菜单栏里",
                          message: "Sniplet 没有 Dock 图标，平时待在屏幕右上角的菜单栏。点这个图标可以截图、查看历史和打开设置。")
            HStack(spacing: 14) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .frame(width: 34, height: 26)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Sniplet 菜单栏图标")
                Text(regionShortcut.map { "最快的方式是直接按 \($0) 开始截图，不用先点图标。" }
                     ?? "也可以在设置 → 快捷键里给区域截图设一个快捷键。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label {
                Text("菜单栏太满、图标被刘海挡住时，再打开一次 Sniplet（启动台、聚焦搜索或「应用程序」文件夹），就会打开使用指南。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

private struct WelcomePermissionStep: View {
    let coordinator: AppCoordinator

    var body: some View {
        let permissions = coordinator.permissions
        VStack(alignment: .leading, spacing: 22) {
            WelcomeHeader(symbol: "rectangle.dashed.badge.record", title: "允许屏幕录制",
                          message: "macOS 把截图需要的权限叫作「屏幕录制」。Sniplet 只在你截图或录屏时读取屏幕，录屏不录声音，画面和文字都只在本机处理。")
            switch WelcomePermissionPhase(isAvailable: permissions.isAvailable, hasRequested: permissions.hasRequestedAccess) {
            case .granted:
                Label("已允许，可以截图了", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            case .notRequested:
                VStack(alignment: .leading, spacing: 8) {
                    Button("允许屏幕录制", action: permissions.requestAccess)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    caption("系统会弹出询问框；选「打开系统设置」，再打开 Sniplet 的开关。")
                }
            case .pending:
                VStack(alignment: .leading, spacing: 10) {
                    Text("在系统设置 → 隐私与安全性 → 屏幕录制里打开 Sniplet。打开后这里还没变成「已允许」时，重新打开 Sniplet 就会生效。")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("打开系统设置", action: permissions.openSystemSettings)
                        Button("重新打开 Sniplet") { coordinator.relaunch(resumingWelcomeAt: .permission) }
                    }
                    if permissions.settingsOpenFailed {
                        Text("无法打开系统设置，请从 Apple 菜单手动打开。").foregroundStyle(.red)
                    }
                }
            }
            if !permissions.isAvailable {
                caption("也可以先跳过，第一次截图时会再提醒你。")
            }
        }
        // A grant made in System Settings is picked up while this step is visible.
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct WelcomeFirstCaptureStep: View {
    let coordinator: AppCoordinator

    var body: some View {
        let login = coordinator.launchAtLogin
        VStack(alignment: .leading, spacing: 18) {
            WelcomeHeader(symbol: "crop", title: "试一下",
                          message: "下面三条记住就够用，其余的用到时再说。")
            VStack(alignment: .leading, spacing: 10) {
                tip("rectangle.dashed", "拖动框选区域 · 单击截取窗口 · 在空白处单击截整屏")
                tip("doc.on.doc", "Return 或 ⌘C 复制 · ⌘S 存到文件夹 · 按住保存按钮直接拖出")
                tip("questionmark.circle", "Esc 放弃这张截图；菜单栏「使用指南…」随时可查")
            }
            LabeledContent("区域截图快捷键") {
                ShortcutRecorderView(manager: coordinator.shortcuts, mode: .region)
            }
            if coordinator.shortcuts.bindings[.region] == ShortcutBinding.defaultBinding(for: .region) {
                caption("⇧⌘A 会覆盖 Finder 的「前往应用程序」，可以在这里换一个。")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("登录时打开 Sniplet", isOn: Binding(get: { login.isEnabled }, set: login.setEnabled))
                if login.requiresApproval {
                    Button("在系统设置中允许登录时打开…", action: login.openSystemSettings)
                        .buttonStyle(.link)
                }
                if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: login.refresh)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
        }
    }
}

private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
