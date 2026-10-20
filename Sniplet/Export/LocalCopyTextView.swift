import AppKit
import SwiftUI

/// Keeps native selection, input methods and text undo; only Copy changes policy.
class LocalCopyTextView: NSTextView {
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let selection = Range(range, in: string) else { return }
        do {
            try ClipboardService().copyText(String(string[selection]))
        } catch {
            NSSound.beep()
        }
    }
}

struct LocalSelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = LocalCopyTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("识别文字")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? LocalCopyTextView, view.string != text else { return }
        view.string = text
    }
}
