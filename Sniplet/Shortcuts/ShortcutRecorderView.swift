import AppKit
import SwiftUI

@MainActor struct ShortcutRecorderView: View {
    let manager: GlobalHotKeyManager
    let mode: CaptureMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RecorderButtonBridge(title: manager.description(for: mode),
                                     recording: manager.recordingMode == mode,
                                     start: { manager.beginRecording(mode) },
                                     stop: { if manager.recordingMode == mode { manager.endRecording() } },
                                     recorded: { binding in
                                         manager.endRecording()
                                         manager.set(binding, for: mode)
                                     })
                    .frame(width: 180, height: 28)
                    .help("点按后录制包含 Command 或 Control 的快捷键；Escape 取消")
                Button("清除") { manager.clear(mode) }
                    .disabled(manager.recordingMode != nil || manager.bindings[mode] == nil)
                Button("恢复默认") { manager.restoreDefault(for: mode) }
                    .disabled(manager.recordingMode != nil)
            }
            if let error = manager.errors[mode] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("快捷键错误：\(error)")
            }
        }
        .onDisappear { if manager.recordingMode == mode { manager.endRecording() } }
    }
}

@MainActor private struct RecorderButtonBridge: NSViewRepresentable {
    let title: String
    let recording: Bool
    let start: () -> Void
    let stop: () -> Void
    let recorded: (ShortcutBinding) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton(frame: .zero)
        view.bezelStyle = .rounded
        view.target = view
        view.action = #selector(RecorderButton.clicked)
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onStart = start
        view.onStop = stop
        view.onRecorded = recorded
        view.recording = recording
        view.title = recording ? "请按快捷键…（Esc 取消）" : title
        view.setAccessibilityLabel(recording ? "正在录制快捷键" : "录制快捷键，当前\(title)")
        if recording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}

@MainActor private final class RecorderButton: NSButton {
    var recording = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRecorded: ((ShortcutBinding) -> Void)?
    private var pending: ShortcutBinding?
    override var acceptsFirstResponder: Bool { true }

    @objc func clicked() {
        if recording { pending = nil; onStop?() }
        else { window?.makeFirstResponder(self); onStart?() }
    }

    override func resignFirstResponder() -> Bool {
        if recording { pending = nil; onStop?() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }

    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { pending = nil; onStop?(); return }
        pending = ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: ShortcutBinding.modifiers(from: event.modifierFlags))
        title = "松开按键以确认…"
    }

    override func keyUp(with event: NSEvent) {
        // Install only after release, so recording a binding never triggers a capture itself.
        guard recording, let binding = pending, binding.keyCode == UInt32(event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        pending = nil
        onRecorded?(binding)
    }
}
