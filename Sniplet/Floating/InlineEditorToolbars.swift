import SwiftUI

/// Native hosting subviews of the transferred selection surface, not a detached editor.
/// Horizontal annotations + vertical actions follow CapCap ToolbarLayout/EditWindowController
/// (MIT), commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
struct InlineAnnotationToolbar: View {
    let session: EditorSession
    let focusCanvas: () -> Void
    /// The bar widens while text controls show, so the host re-measures it.
    let stateChanged: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let editor = session.editor {
                AnnotationToolbar(editor: editor, focusCanvas: focusCanvas)
                InlineBeautificationButton(editor: editor, saveDefault: { session.saveDefaultCaptureStyle() })
            } else {
                Label("最终图像 · 只读", systemImage: "lock")
                    .font(.callout)
                    .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 16, weight: .medium))
        .padding(.trailing, 8)
        .disabled(session.isBusy)
        .fixedSize()
        .accessibilityLabel("截图标注工具")
        .onChange(of: session.editor?.showsTextFormat) { _, _ in stateChanged() }
    }
}

private struct InlineBeautificationButton: View {
    let editor: AnnotationEditor
    var saveDefault: (() -> Void)? = nil
    @State private var showsStyle = false
    @State private var savedDefault = false

    var body: some View {
        Button {
            editor.commitTextEditing()
            showsStyle.toggle()
        } label: {
            Image(systemName: "sparkles").frame(width: 32, height: 32)
        }
        .buttonStyle(InlineToolbarButtonStyle(isSelected: showsStyle || editor.document.captureStyle != .plain))
        .help("美化这张截图：选择预设，或调整圆角、阴影、边框和背景")
        .accessibilityLabel("截图美化")
        .popover(isPresented: $showsStyle) {
            VStack(alignment: .leading, spacing: 10) {
                CaptureStyleControls(style: Binding(
                    get: { editor.document.captureStyle },
                    set: { editor.setCaptureStyle($0) }
                ), onEditingChanged: { editing in
                    if editing { editor.beginCaptureStyleTransaction() }
                    else { editor.endCaptureStyleTransaction() }
                }, showsPreview: false)
                if let saveDefault {
                    Divider()
                    HStack {
                        Button(savedDefault ? "已设为默认样式" : "设为之后截图的默认") {
                            saveDefault()
                            savedDefault = true
                        }
                        .disabled(savedDefault)
                        .help("把当前圆角、阴影、边框和背景保存为新截图的默认美化，之后不用再逐张调整")
                        if savedDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("已保存")
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
            .onChange(of: editor.document.captureStyle) { _, _ in savedDefault = false }
        }
    }
}

struct InlineActionToolbar: View {
    let session: EditorSession
    let preferences: AppPreferences
    let finish: () -> Void
    let cancel: () -> Void
    let stateChanged: () -> Void
    /// Fresh captures only: swap this screenshot for a recording of the same area.
    var recordRegion: (() -> Void)? = nil
    /// Fresh captures only: capture the same area again after this many seconds.
    var delayRegion: ((Int) -> Void)? = nil
    @State private var showsStatus = false
    @State private var showsOCR = false

    var body: some View {
        VStack(spacing: 4) {
            // Save and drag-out share one button: a click saves, a drag carries the image out.
            // Intentionally never conditionally replace, disable or re-identify this
            // native view while async prepareDrag changes the session's busy state.
            DragExportHandle(onClick: { session.output(.quickSave) },
                             isClickEnabled: session.canOutput && !session.isBusy,
                             prepare: session.prepareDrag,
                             onAccepted: session.dragAccepted,
                             onCancelled: session.dragCancelled,
                             onFailure: { capture, error in session.promiseFailed(capture, message: error) },
                             onPreparationFailure: session.dragPreparationFailed)
                .frame(width: 32, height: 32)
            action("钉图", symbol: "pin", help: "钉住最终成图") { session.output(.pin) }
            if session.isOCREnabled {
                action("复制文字", symbol: "text.viewfinder", help: "完全在本机识别并复制最终成图的文字") {
                    showsOCR = true
                    showsStatus = true
                    session.copyRecognizedText()
                }
                .disabled(session.isRecognizing)
            }
            // Only shown once there is something to report or reopen (errors, OCR result).
            if hasStatus {
                Button { showsStatus.toggle() } label: {
                    Image(systemName: hasError ? "exclamationmark.triangle" : "text.bubble")
                        .foregroundStyle(hasError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .frame(width: 32, height: 32)
                }
                .help(hasError ? "查看输出错误与历史重试" : "查看文字识别结果")
                .accessibilityLabel("截图状态与重试")
            }
            if let recordRegion, session.editor != nil {
                action("录制这块区域", symbol: "record.circle",
                       help: "放弃这张截图，改为录制同一块区域；点红框旁的「停止」、再按 ⇧⌘A 或从菜单栏停止", action: recordRegion)
                    .disabled(session.isBusy)
            }
            if let delayRegion, session.editor != nil {
                Menu {
                    ForEach(AppPreferences.captureDelayChoices, id: \.self) { seconds in
                        Button("\(seconds) 秒后截取这块区域") { delayRegion(seconds) }
                    }
                } label: {
                    Image(systemName: "timer").frame(width: 32, height: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("延迟截图：选框留在原处、中间倒计时，这期间可以照常操作其他 App；时间到自动截下这块区域")
                .accessibilityLabel("延迟截取这块区域")
                .disabled(session.isBusy)
            }
            Divider().frame(width: 24)
            Button(action: cancel) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .help("丢弃截图，不新增历史（Esc；绘图工具下第一次 Esc 先回到选择）")
            .accessibilityLabel("丢弃截图")
            .disabled(session.isBusy)
            // Without history, finishing without copying equals discarding, so only offer it
            // when it keeps something. ⌘Return still reaches finish() and confirms the discard.
            if session.keepsHistory {
                action("只存入历史", symbol: "tray.and.arrow.down",
                       help: "不复制，只把最终图存入历史并关闭（⌘Return）", action: finish)
            }
            // Progress replaces the primary icon instead of reserving an empty row below it.
            Button { session.output(.copyImage) } label: {
                Image(systemName: "checkmark")
                    .opacity(session.isBusy ? 0 : 1)
                    .overlay {
                        if session.isBusy {
                            ProgressView().controlSize(.small).accessibilityLabel("正在输出")
                        }
                    }
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(InlineToolbarButtonStyle(isProminent: true))
            .help("复制最终图像并关闭（Return 或 ⌘C）")
            .accessibilityLabel("复制并完成")
            .disabled(!session.canOutput || session.isBusy)
        }
        .buttonStyle(InlineToolbarButtonStyle())
        .font(.system(size: 16, weight: .medium))
        .padding(6)
        .fixedSize()
        .accessibilityLabel("截图输出操作")
        .popover(isPresented: $showsStatus, arrowEdge: .leading) {
            InlineCaptureStatus(session: session, showsOCR: showsOCR)
                .padding(14)
                .frame(width: 360)
        }
        .onChange(of: hasStatus) { _, _ in stateChanged() }
        .onChange(of: session.isBusy) { _, _ in stateChanged() }
        .onChange(of: session.editor == nil) { _, _ in stateChanged() }
        .onChange(of: session.keepsHistory) { _, _ in stateChanged() }
        .onChange(of: preferences.selectionAppearance) { _, _ in stateChanged() }
        .onChange(of: session.outputError) { _, error in if error != nil { showsStatus = true } }
        .onChange(of: session.historyError) { _, error in if error != nil { showsStatus = true } }
        .onAppear { if session.outputError != nil || session.historyError != nil { showsStatus = true } }
    }

    private var hasError: Bool { session.outputError != nil || session.historyError != nil }
    private var hasStatus: Bool { hasError || showsOCR }

    private func action(_ title: String, symbol: String, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 32) }
            .help(help)
            .accessibilityLabel(title)
            .disabled(!session.canOutput || session.isBusy)
    }
}

private struct InlineCaptureStatus: View {
    let session: EditorSession
    let showsOCR: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Int(session.imageSize.width)) × \(Int(session.imageSize.height)) 像素")
                .font(.headline.monospacedDigit())
            Text(session.phase == .finalized ? "最终图像 · 只读" : "只有最终成图进入历史")
                .font(.caption)
                .foregroundStyle(.secondary)
            if session.isBusy { ProgressView("正在输出…").controlSize(.small) }
            if let error = session.outputError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("输出错误：\(error)")
            }
            if let error = session.historyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("历史错误：\(error)")
                Button("重试保存历史", action: session.retryHistory).disabled(session.isBusy)
            }
            if showsOCR {
                Divider()
                OCRResultView(result: session.ocrResult, isRecognizing: session.isRecognizing,
                              errorMessage: session.ocrError, retry: session.copyRecognizedText)
                    .frame(maxHeight: 240)
            }
        }
    }
}
