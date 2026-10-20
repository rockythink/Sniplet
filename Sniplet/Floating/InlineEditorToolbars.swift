import SwiftUI

/// Native hosting subviews of the transferred selection surface, not a detached editor.
/// Horizontal annotations + vertical actions follow CapCap ToolbarLayout/EditWindowController
/// (MIT), commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
struct InlineAnnotationToolbar: View {
    let session: EditorSession
    let focusCanvas: () -> Void
    let zoom: (CanvasZoomCommand) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let editor = session.editor {
                AnnotationToolbar(editor: editor, focusCanvas: focusCanvas)
                InlineBeautificationButton(editor: editor, saveDefault: { session.saveDefaultCaptureStyle() })
                Menu {
                    Button("适合选区") { zoom(.fit) }
                    Button("100% · 一像素对应一屏幕像素") { zoom(.actual) }
                    Divider()
                    ForEach([25, 50, 100, 200, 400], id: \.self) { percent in
                        Button("\(percent)%") { zoom(.percent(percent)) }
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass").frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .help("画布缩放与平移；导出尺寸不变")
                .accessibilityLabel("画布缩放")
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
            Label("美化", systemImage: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 6)
                .frame(height: 32)
        }
        .buttonStyle(InlineToolbarButtonStyle(isSelected: showsStyle || editor.document.captureStyle != .plain))
        .help("美化这张截图：选择预设，或调整圆角、阴影和边框")
        .accessibilityLabel("截图美化")
        .popover(isPresented: $showsStyle) {
            VStack(alignment: .leading, spacing: 10) {
                CaptureStyleControls(style: Binding(
                    get: { editor.document.captureStyle },
                    set: { editor.setCaptureStyle($0) }
                ), onEditingChanged: { editing in
                    if editing { editor.beginCaptureStyleTransaction() }
                    else { editor.endCaptureStyleTransaction() }
                })
                if let saveDefault {
                    Divider()
                    HStack {
                        Button(savedDefault ? "已设为默认样式" : "设为之后截图的默认") {
                            saveDefault()
                            savedDefault = true
                        }
                        .disabled(savedDefault)
                        .help("把当前圆角、阴影和边框保存为新截图的默认美化，之后不用再逐张调整")
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
    @State private var showsStatus = false
    @State private var showsOCR = false

    var body: some View {
        VStack(spacing: 4) {
            action("保存 PNG", symbol: "square.and.arrow.down", help: "保存最终 PNG（⌘S）") { session.output(.save) }
            action("钉图", symbol: "pin", help: "钉住最终成图") { session.output(.pin) }
            if session.isOCREnabled {
                action("复制文字", symbol: "text.viewfinder", help: "完全在本机识别并复制最终成图的文字") {
                    showsOCR = true
                    showsStatus = true
                    session.copyRecognizedText()
                }
                .disabled(session.isRecognizing)
            }
            Divider().frame(width: 24)
            // Intentionally never conditionally replace, disable or re-identify this
            // native view while async prepareDrag changes the session's busy state.
            DragExportHandle(prepare: session.prepareDrag,
                             onAccepted: session.dragAccepted,
                             onCancelled: session.dragCancelled,
                             onFailure: { capture, error in session.promiseFailed(capture, message: error) },
                             onPreparationFailure: session.dragPreparationFailed)
                .frame(width: 32, height: 32)
                .help("拖出最终图像；取消拖放继续编辑")
            Button { showsStatus.toggle() } label: {
                Image(systemName: session.outputError != nil || session.historyError != nil ? "exclamationmark.triangle" : "info.circle")
                    .frame(width: 32, height: 32)
            }
            .help("输出状态、错误、历史重试与文字识别结果")
            .accessibilityLabel("截图状态与重试")
            .popover(isPresented: $showsStatus, arrowEdge: .leading) {
                InlineCaptureStatus(session: session, showsOCR: showsOCR)
                    .padding(14)
                    .frame(width: 360)
            }
            action("完成截图", symbol: "checkmark.circle", help: "完成截图（⌘Return）；不复制图像", action: finish)
            Divider().frame(width: 24)
            Button(action: cancel) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .help("丢弃截图，不新增历史（Esc）")
            .accessibilityLabel("丢弃截图")
            .disabled(session.isBusy)
            action("复制图像", symbol: "checkmark", help: "复制最终图像（Return 或 ⌘C）并完成截图") {
                session.output(.copyImage)
            }
            Group {
                if session.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("正在输出")
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: 32, height: 16)
        }
        .buttonStyle(InlineToolbarButtonStyle())
        .font(.system(size: 16, weight: .medium))
        .padding(6)
        .fixedSize()
        .accessibilityLabel("截图输出操作")
        .onChange(of: session.isBusy) { _, _ in stateChanged() }
        .onChange(of: session.editor == nil) { _, _ in stateChanged() }
        .onChange(of: preferences.selectionAppearance) { _, _ in stateChanged() }
        .onChange(of: session.outputError) { _, error in if error != nil { showsStatus = true } }
        .onChange(of: session.historyError) { _, error in if error != nil { showsStatus = true } }
        .onAppear { if session.outputError != nil || session.historyError != nil { showsStatus = true } }
    }

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
