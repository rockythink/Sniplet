import SwiftUI

struct AnnotationToolbar: View {
    @Bindable var editor: AnnotationEditor
    var focusCanvas: (() -> Void)? = nil
    private static let palette: [(label: String, color: AnnotationColor)] = [
        ("黑", .black), ("白", .white), ("红", .red), ("蓝", .blue)
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Button {
                    editor.commitTextEditing()
                    editor.selectedTool = tool
                    focusCanvas?()
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: editor.selectedTool == tool))
                .help(tool.label)
                .accessibilityLabel(tool.label)
                .accessibilityAddTraits(editor.selectedTool == tool ? [.isSelected] : [])
            }
            Divider().frame(height: 24).padding(.horizontal, 4)
            AnnotationUndoButtons(editor: editor, focusCanvas: focusCanvas)
            Menu {
                ForEach(Self.palette.indices, id: \.self) { index in
                    let value = Self.palette[index]
                    Button(value.label) {
                        editor.commitTextEditing()
                        var style = editor.selectedAnnotation?.style ?? editor.style
                        style.color = value.color
                        editor.setStyle(style)
                    }
                }
            } label: { Image(systemName: "paintpalette").frame(width: 32, height: 32).contentShape(Rectangle()) }
            .help("标注颜色")
            .accessibilityLabel("标注颜色")
            Menu("样式") {
                Section("描边宽度") {
                    ForEach([1, 2, 4, 8], id: \.self) { width in
                        Button("\(width) 点") {
                            editor.commitTextEditing()
                            var style = editor.selectedAnnotation?.style ?? editor.style
                            style.lineWidth = CGFloat(width)*editor.document.capture.sourceScale
                            editor.setStyle(style)
                        }
                    }
                }
                Section("文字大小") {
                    ForEach([12, 16, 24, 32, 48], id: \.self) { size in
                        Button("\(size) 点") {
                            editor.commitTextEditing()
                            var style = editor.selectedAnnotation?.style ?? editor.style
                            style.fontSize = CGFloat(size)*editor.document.capture.sourceScale
                            editor.setStyle(style)
                        }
                    }
                }
                Section("马赛克块大小") {
                    ForEach([8, 16, 32], id: \.self) { size in
                        Button("\(size) 像素") {
                            editor.commitTextEditing()
                            editor.setMosaicBlockSize(CGFloat(size))
                        }
                    }
                }
            }
            .help("描边、文字大小与马赛克块大小；高亮固定为半透明黄")
            .accessibilityLabel("标注样式")
            .frame(minHeight: 32)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .disabled(!editor.isValid || !editor.isInteractionEnabled)
    }
}

/// Only undo availability observes every document revision, not the whole tool palette.
private struct AnnotationUndoButtons: View {
    let editor: AnnotationEditor
    let focusCanvas: (() -> Void)?

    var body: some View {
        let _ = editor.document.revision
        HStack(spacing: 4) {
            Button { editor.undo(); focusCanvas?() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 32)
            }
            .disabled(!editor.undoManager.canUndo)
            .help("撤销（⌘Z）")
            .accessibilityLabel("撤销")
            Button { editor.redo(); focusCanvas?() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 32, height: 32)
            }
            .disabled(!editor.undoManager.canRedo)
            .help("重做（⇧⌘Z）")
            .accessibilityLabel("重做")
        }
        .buttonStyle(InlineToolbarButtonStyle())
    }
}
