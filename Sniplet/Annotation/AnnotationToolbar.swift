import SwiftUI

/// The tool row: selection, the drawing tools, then undo and redo.
struct AnnotationToolbar: View {
    @Bindable var editor: AnnotationEditor
    var focusCanvas: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: InlineToolbarMetrics.spacing) {
            toolButton(.select)
            InlineToolbarSeparator()
            ForEach(AnnotationTool.allCases.filter { $0 != .select }, id: \.self) { toolButton($0) }
            InlineToolbarSeparator()
            AnnotationUndoButtons(editor: editor, focusCanvas: focusCanvas)
        }
        .disabled(!editor.isValid || !editor.isInteractionEnabled)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            editor.commitTextEditing()
            editor.selectedTool = tool
            focusCanvas?()
        } label: {
            InlineToolbarIcon(tool.symbol)
                .symbolRenderingMode(.monochrome)
                .contentShape(Rectangle())
        }
        .buttonStyle(InlineToolbarButtonStyle(isSelected: editor.selectedTool == tool))
        .help("\(tool.label)（\(tool.shortcutKey.uppercased())）")
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(editor.selectedTool == tool ? [.isSelected] : [])
    }
}

/// Style options for the mark being typed, the selected mark, or the active tool's next mark,
/// laid out in a row instead of a popover: each option is one click and shows its current value.
/// No commit here: style changes reach text that is still being typed.
struct AnnotationStyleBar: View {
    let editor: AnnotationEditor

    /// Highlights keep a fixed translucent yellow, and selecting with nothing selected
    /// edits nothing, so neither shows the row.
    static func hasControls(for kind: AnnotationKind?) -> Bool {
        guard let kind else { return false }
        return kind != .highlight
    }

    var body: some View {
        HStack(spacing: InlineToolbarMetrics.spacing) {
            switch editor.styleTarget {
            case .arrow, .rectangle, .pen:
                AnnotationColorSwatches(editor: editor)
                InlineToolbarSeparator()
                AnnotationLineWidthButtons(editor: editor)
            case .text:
                AnnotationColorSwatches(editor: editor)
                InlineToolbarSeparator()
                AnnotationSizeStepper(editor: editor, subject: "文字", hasShortcuts: true)
                InlineToolbarSeparator()
                AnnotationTextToggles(editor: editor)
            case .counter:
                AnnotationColorSwatches(editor: editor)
                InlineToolbarSeparator()
                AnnotationSizeStepper(editor: editor, subject: "序号", hasShortcuts: false)
            case .mosaic:
                AnnotationMosaicButtons(editor: editor)
            case .highlight, nil:
                EmptyView()
            }
        }
        .buttonStyle(InlineToolbarButtonStyle())
        .disabled(!editor.isValid || !editor.isInteractionEnabled)
    }
}

/// The palette itself, not a single swatch that opens one: a lone filled dot reads as a
/// record button, and so does a ringed one. The current color is marked like a selected tool,
/// plus a check.
private struct AnnotationColorSwatches: View {
    let editor: AnnotationEditor
    static let palette: [(label: String, color: AnnotationColor)] = [
        ("红", .red), ("黄", .yellow), ("绿", .green), ("蓝", .blue), ("黑", .black), ("白", .white)
    ]

    var body: some View {
        let current = editor.activeStyle.color
        HStack(spacing: InlineToolbarMetrics.spacing) {
            ForEach(Self.palette.indices, id: \.self) { index in
                let entry = Self.palette[index]
                let selected = current == entry.color
                Button {
                    var style = editor.activeStyle
                    style.color = entry.color
                    editor.setStyle(style)
                } label: {
                    Circle()
                        .fill(Color(cgColor: entry.color.cgColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(entry.color == .white || entry.color == .yellow ? .black : .white)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .frame(width: InlineToolbarMetrics.button, height: InlineToolbarMetrics.button)
                }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: selected))
                .help(entry.label)
                .accessibilityLabel("颜色：\(entry.label)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标注颜色")
    }
}

/// Each option draws its own stroke weight.
private struct AnnotationLineWidthButtons: View {
    let editor: AnnotationEditor
    private static let widths = [1, 2, 4, 8]

    var body: some View {
        let scale = editor.document.capture.sourceScale
        let current = Int((editor.activeStyle.lineWidth / scale).rounded())
        HStack(spacing: InlineToolbarMetrics.spacing) {
            ForEach(Self.widths, id: \.self) { width in
                Button {
                    var style = editor.activeStyle
                    style.lineWidth = CGFloat(width) * scale
                    editor.setStyle(style)
                } label: {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 16, height: CGFloat(width))
                        .frame(width: InlineToolbarMetrics.button, height: InlineToolbarMetrics.button)
                }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: current == width))
                .help("描边 \(width) 点")
                .accessibilityLabel("描边 \(width) 点")
                .accessibilityAddTraits(current == width ? [.isSelected] : [])
            }
        }
    }
}

/// Text size, or a counter badge's size, which follows the same size steps.
private struct AnnotationSizeStepper: View {
    let editor: AnnotationEditor
    let subject: String
    let hasShortcuts: Bool

    var body: some View {
        let points = editor.activeStyle.fontSize / editor.document.capture.sourceScale
        let sizes = AnnotationTextLayout.pointSizes
        HStack(spacing: InlineToolbarMetrics.spacing) {
            Button { editor.stepFontSize(larger: false) } label: {
                InlineToolbarIcon("textformat.size.smaller")
            }
            .disabled(points <= sizes[0] + 0.01)
            .help("缩小\(subject)" + (hasShortcuts ? "（⌘−）" : ""))
            .accessibilityLabel("缩小\(subject)")
            Text("\(Int(points.rounded()))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(minWidth: 24)
                .help("\(subject)大小（点）")
                .accessibilityLabel("\(subject)大小 \(Int(points.rounded())) 点")
            Button { editor.stepFontSize(larger: true) } label: {
                InlineToolbarIcon("textformat.size.larger")
            }
            .disabled(points >= sizes[sizes.count - 1] - 0.01)
            .help("放大\(subject)" + (hasShortcuts ? "（⌘+）" : ""))
            .accessibilityLabel("放大\(subject)")
        }
    }
}

/// Changes apply live to the text being typed (it stays open) or to the selected text mark.
private struct AnnotationTextToggles: View {
    let editor: AnnotationEditor

    var body: some View {
        let style = editor.activeStyle
        HStack(spacing: InlineToolbarMetrics.spacing) {
            Button { editor.toggleBold() } label: { InlineToolbarIcon("bold") }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: style.isBold))
                .help("加粗（⌘B）")
                .accessibilityLabel("加粗")
                .accessibilityAddTraits(style.isBold ? [.isSelected] : [])
            Button { editor.toggleTextBackground() } label: { InlineToolbarIcon("character.textbox") }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: style.hasTextBackground))
                .help("文字底色：用当前颜色垫一块底，文字自动变黑或白，在复杂背景上更清楚")
                .accessibilityLabel("文字底色")
                .accessibilityAddTraits(style.hasTextBackground ? [.isSelected] : [])
        }
    }
}

/// Each option previews its block size as a small checkerboard: fewer cells, coarser blocks.
private struct AnnotationMosaicButtons: View {
    let editor: AnnotationEditor
    private static let sizes: [(pixels: Int, cells: Int, label: String)] = [(8, 6, "细"), (16, 4, "中"), (32, 2, "粗")]

    var body: some View {
        let current: Int = if let item = editor.selectedAnnotation, case let .mosaic(_, block) = item.payload {
            Int(block)
        } else {
            Int(editor.mosaicBlockSize)
        }
        HStack(spacing: InlineToolbarMetrics.spacing) {
            ForEach(Self.sizes, id: \.pixels) { size in
                Button { editor.setMosaicBlockSize(CGFloat(size.pixels)) } label: {
                    checkerboard(cells: size.cells)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .frame(width: InlineToolbarMetrics.button, height: InlineToolbarMetrics.button)
                }
                .buttonStyle(InlineToolbarButtonStyle(isSelected: current == size.pixels))
                .help("马赛克块\(size.label)（\(size.pixels) 像素）")
                .accessibilityLabel("马赛克块\(size.label)，\(size.pixels) 像素")
                .accessibilityAddTraits(current == size.pixels ? [.isSelected] : [])
            }
        }
    }

    private func checkerboard(cells: Int) -> some View {
        Canvas { context, canvasSize in
            let cell = canvasSize.width / CGFloat(cells)
            for row in 0..<cells {
                for column in 0..<cells {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    let opacity = (row + column).isMultiple(of: 2) ? 0.85 : 0.3
                    context.fill(Path(rect), with: .color(.primary.opacity(opacity)))
                }
            }
        }
    }
}

/// Only undo availability observes every document revision, not the whole tool palette.
private struct AnnotationUndoButtons: View {
    let editor: AnnotationEditor
    let focusCanvas: (() -> Void)?

    var body: some View {
        let _ = editor.document.revision
        HStack(spacing: InlineToolbarMetrics.spacing) {
            Button { editor.undo(); focusCanvas?() } label: {
                InlineToolbarIcon("arrow.uturn.backward")
            }
            .disabled(!editor.undoManager.canUndo)
            .help("撤销（⌘Z）")
            .accessibilityLabel("撤销")
            Button { editor.redo(); focusCanvas?() } label: {
                InlineToolbarIcon("arrow.uturn.forward")
            }
            .disabled(!editor.undoManager.canRedo)
            .help("重做（⇧⌘Z）")
            .accessibilityLabel("重做")
        }
        .buttonStyle(InlineToolbarButtonStyle())
    }
}
