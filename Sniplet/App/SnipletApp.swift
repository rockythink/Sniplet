import AppKit
import SwiftUI

@main
struct SnipletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!AppRuntime.isUnitTesting)) {
            SnipletMenu(coordinator: delegate.coordinator)
        } label: {
            Label("Sniplet", systemImage: "crop")
                .accessibilityLabel("Sniplet 截图")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            if AppRuntime.isUnitTesting { EmptyView() }
            else { SettingsView(coordinator: delegate.coordinator) }
        }
    }
}

private struct SnipletMenu: View {
    let coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach([CaptureMode.region, .window, .fullScreen], id: \.self) { mode in
            Button("\(title(mode))    \(coordinator.shortcuts.description(for: mode))") {
                coordinator.requestCapture(mode)
            }
            .disabled(!coordinator.canCapture)
        }
        Divider()
        Button("截图历史…", action: coordinator.showHistory)
        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("退出 Sniplet") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func title(_ mode: CaptureMode) -> String {
        switch mode {
        case .region: "截取区域"
        case .window: "截取窗口"
        case .fullScreen: "截取当前屏幕"
        }
    }
}

struct HistoryContainerView: View {
    let coordinator: AppCoordinator

    var body: some View {
        Group {
            if let store = coordinator.historyStore, let indexer = coordinator.historyIndexer {
                HistoryView(store: store, indexer: indexer,
                            onCopy: { coordinator.outputHistory($0, action: .copyImage) },
                            onSave: { coordinator.outputHistory($0, action: .save) },
                            onPin: { coordinator.outputHistory($0, action: .pin) })
            } else if coordinator.historyLoading {
                ProgressView("正在打开本地历史…")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("本地历史暂不可用").font(.headline)
                    Text(coordinator.historyError ?? "存储尚未初始化")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试打开", action: coordinator.initializeHistory)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
