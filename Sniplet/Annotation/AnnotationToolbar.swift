import SwiftUI

struct AnnotationToolbar: View {
    @Bindable var editor: AnnotationEditor
    var focusCanvas: (() -> Void)? = nil

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
                .help("\(tool.label)（\(tool.shortcutKey.uppercased())）")
                .accessibilityLabel(tool.label)
                .accessibilityAddTraits(editor.selectedTool == tool ? [.isSelected] : [])
            }
            if editor.showsTextFormat {
                Divider().frame(height: 24).padding(.horizontal, 4)
                AnnotationTextFormatButtons(editor: editor)
            }
            Divider().frame(height: 24).padding(.horizontal, 4)
            AnnotationUndoButtons(editor: editor, focusCanvas: focusCanvas)
            AnnotationStyleButton(editor: editor)
        }
        .buttonStyle(.borderless)
        // The host bar continues with the same 4-point spacing, so no trailing inset here.
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .disabled(!editor.isValid || !editor.isInteractionEnabled)
    }
}

/// Changes apply live to the text being typed (it stays open) or to the selected text mark.
private struct AnnotationTextFormatButtons: View {
    let editor: AnnotationEditor

    var body: some View {
        let style = editor.activeStyle
        let points = style.fontSize / editor.document.capture.sourceScale
        let sizes = AnnotationTextLayout.pointSizes
        HStack(spacing: 2) {
            Button { editor.stepFontSize(larger: false) } label: {
                Image(systemName: "textformat.size.smaller").frame(width: 32, height: 32)
            }
            .disabled(points <= sizes[0] + 0.01)
            .help("缩小文字（⌘−）")
            .accessibilityLabel("缩小文字")
            Text("\(Int(points.rounded()))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(minWidth: 24)
                .help("文字大小（点）")
                .accessibilityLabel("文字大小 \(Int(points.rounded())) 点")
            Button { editor.stepFontSize(larger: true) } label: {
                Image(systemName: "textformat.size.larger").frame(width: 32, height: 32)
            }
            .disabled(points >= sizes[sizes.count - 1] - 0.01)
            .help("放大文字（⌘+）")
            .accessibilityLabel("放大文字")
            Button { editor.toggleBold() } label: {
                Image(systemName: "bold").frame(width: 32, height: 32)
            }
            .buttonStyle(InlineToolbarButtonStyle(isSelected: style.isBold))
            .help("加粗（⌘B）")
            .accessibilityLabel("加粗")
            .accessibilityAddTraits(style.isBold ? [.isSelected] : [])
            Button { editor.toggleTextBackground() } label: {
                Image(systemName: "character.textbox").frame(width: 32, height: 32)
            }
            .buttonStyle(InlineToolbarButtonStyle(isSelected: style.hasTextBackground))
            .help("文字底色：用当前颜色垫一块底，文字自动变黑或白，在复杂背景上更清楚")
            .accessibilityLabel("文字底色")
            .accessibilityAddTraits(style.hasTextBackground ? [.isSelected] : [])
        }
        .buttonStyle(InlineToolbarButtonStyle())
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

/// Color, stroke, text and mosaic settings in one popover. The button shows the color the
/// next mark (or the selected mark) uses, and every option marks its current value.
private struct AnnotationStyleButton: View {
    let editor: AnnotationEditor
    @State private var showsStyle = false
    private static let palette: [(label: String, color: AnnotationColor)] = [
        ("红", .red), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black), ("白", .white)
    ]

    private var currentStyle: AnnotationStyle { editor.activeStyle }

    private var currentMosaicBlock: CGFloat {
        if let item = editor.selectedAnnotation, case let .mosaic(_, block) = item.payload { return block }
        return editor.mosaicBlockSize
    }

    private var scale: CGFloat { editor.document.capture.sourceScale }

    var body: some View {
        // No commit here: style changes reach text that is still being typed.
        Button {
            showsStyle.toggle()
        } label: {
            swatch(currentStyle.color, diameter: 18)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(InlineToolbarButtonStyle(isSelected: showsStyle))
        .help("颜色、描边、文字大小与马赛克块大小")
        .accessibilityLabel("标注样式")
        .accessibilityValue(Self.palette.first { $0.color == currentStyle.color }?.label ?? "自定义颜色")
        .popover(isPresented: $showsStyle) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("颜色")
                    HStack(spacing: 8) {
                        ForEach(Self.palette.indices, id: \.self) { index in
                            colorButton(Self.palette[index].label, Self.palette[index].color)
                        }
                    }
                }
                GridRow {
                    Text("描边")
                    segmented("描边宽度", values: [1, 2, 4, 8], unit: "",
                              current: Int((currentStyle.lineWidth / scale).rounded())) { width in
                        var style = currentStyle
                        style.lineWidth = CGFloat(width) * scale
                        editor.setStyle(style)
                    }
                }
                GridRow {
                    Text("文字")
                    segmented("文字大小", values: [12, 16, 24, 32, 48], unit: "",
                              current: Int((currentStyle.fontSize / scale).rounded())) { size in
                        var style = currentStyle
                        style.fontSize = CGFloat(size) * scale
                        editor.setStyle(style)
                    }
                }
                GridRow {
                    Text("马赛克")
                    segmented("马赛克块大小", values: [8, 16, 32], unit: " px",
                              current: Int(currentMosaicBlock)) { size in
                        editor.setMosaicBlockSize(CGFloat(size))
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("描边与文字以点为单位；高亮固定为半透明黄。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 320)
        }
    }

    private func swatch(_ color: AnnotationColor, diameter: CGFloat) -> some View {
        Circle()
            .fill(Color(cgColor: color.cgColor))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .frame(width: diameter, height: diameter)
    }

    private func colorButton(_ label: String, _ color: AnnotationColor) -> some View {
        let selected = currentStyle.color == color
        return Button {
            var style = currentStyle
            style.color = color
            editor.setStyle(style)
        } label: {
            swatch(color, diameter: 22)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color == .white || color == .yellow ? Color.black : Color.white)
                    }
                }
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func segmented(_ title: String, values: [Int], unit: String, current: Int,
                           apply: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { current }, set: { value in apply(value) })) {
            ForEach(values, id: \.self) { Text("\($0)\(unit)").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(title)
    }
}
