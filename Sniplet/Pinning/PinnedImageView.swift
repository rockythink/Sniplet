import AppKit

@MainActor
final class PinnedImageView: NSView {
    private let capture: RenderedCapture
    private let encoder: ImageEncoder
    private let onClose: () -> Void
    private let scroll = PinnedScrollView()
    private let imageView: PinnedImageCanvas
    private let percentage = NSTextField(labelWithString: "100%")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var copyTask: Task<Void, Never>?

    init(capture: RenderedCapture, encoder: ImageEncoder, onClose: @escaping () -> Void) {
        self.capture = capture
        self.encoder = encoder
        self.onClose = onClose
        imageView = PinnedImageCanvas(image: capture.image)
        super.init(frame: .zero)
        scroll.contentView = CenteredPinnedClipView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        scroll.documentView = imageView
        scroll.onMagnification = { [weak self] in self?.updatePercentage() }
        scroll.setAccessibilityLabel("钉图预览，可滚动平移和捏合缩放")
        imageView.onCopy = { [weak self] in self?.copyImage() }
        imageView.onClose = onClose

        let minus = button("−", action: #selector(zoomOut), help: "缩小")
        let plus = button("+", action: #selector(zoomIn), help: "放大")
        let actual = button("100%", action: #selector(actualPixels), help: "实际像素：一图像像素对应一屏幕像素")
        let fit = button("适配", action: #selector(fitImage), help: "适配窗口")
        let copy = button("复制", action: #selector(copyImage), help: "复制图像，仅限本机")
        let close = button("关闭", action: #selector(closeImage), help: "关闭这张钉图")
        percentage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentage.textColor = .secondaryLabelColor
        percentage.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        let controls = NSStackView(views: [minus, plus, actual, fit, percentage, spacer, copy, close])
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        controls.setHuggingPriority(.defaultLow, for: .horizontal)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true
        let stack = NSStackView(views: [controls, errorLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func button(_ title: String, action: Selector, help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    func configureForDisplay(fit: Bool) {
        let backing = window?.backingScaleFactor ?? 1
        imageView.setFrameSize(NSSize(width: CGFloat(capture.image.width) / backing,
                                     height: CGFloat(capture.image.height) / backing))
        layoutSubtreeIfNeeded()
        if fit { fitImage() }
        else { updatePercentage() }
    }

    func invalidate() {
        copyTask?.cancel()
        copyTask = nil
    }

    @objc private func zoomIn() { setZoom(scroll.magnification * 1.25) }
    @objc private func zoomOut() { setZoom(scroll.magnification / 1.25) }
    @objc private func actualPixels() { setZoom(1) }
    @objc private func closeImage() { onClose() }

    @objc private func fitImage() {
        let size = scroll.contentSize
        let imageSize = imageView.frame.size
        guard size.width > 0, size.height > 0, imageSize.width > 0, imageSize.height > 0 else { return }
        setZoom(min(size.width / imageSize.width, size.height / imageSize.height))
    }

    private func setZoom(_ scale: CGFloat) {
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(min(4, max(0.25, scale)), centeredAt: center)
        updatePercentage()
    }

    private func updatePercentage() {
        percentage.stringValue = "\(Int((scroll.magnification * 100).rounded()))%"
        percentage.setAccessibilityValue(percentage.stringValue)
    }

    @objc private func copyImage() {
        guard copyTask == nil else { return }
        let image = capture.image
        let encoder = encoder
        copyTask = Task { [weak self] in
            do {
                let png = try await encoder.png(image)
                try Task.checkCancellation()
                guard let self else { return }
                try ClipboardService().copyImage(pngData: png)
                self.errorLabel.isHidden = true
                self.copyTask = nil
            } catch {
                guard let self else { return }
                self.copyTask = nil
                guard !(error is CancellationError) else { return }
                self.errorLabel.stringValue = "复制失败，请重试。"
                self.errorLabel.isHidden = false
            }
        }
    }
}

@MainActor
private final class PinnedScrollView: NSScrollView {
    var onMagnification: (() -> Void)?
    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnification?()
    }
}

@MainActor
private final class CenteredPinnedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if let documentView {
            if result.width > documentView.frame.width {
                result.origin.x = (documentView.frame.width - result.width) / 2
            }
            if result.height > documentView.frame.height {
                result.origin.y = (documentView.frame.height - result.height) / 2
            }
        }
        return result
    }
}

@MainActor
private final class PinnedImageCanvas: NSView {
    private let image: CGImage
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    private var panOrigin: NSPoint?
    private var mouseOrigin: NSPoint?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("已合成的钉图，\(image.width) × \(image.height) 像素")
        let menu = NSMenu(title: "钉图")
        let copy = menu.addItem(withTitle: "复制图像", action: #selector(copyPinned), keyEquivalent: "")
        copy.target = self
        let close = menu.addItem(withTitle: "关闭钉图", action: #selector(closePinned), keyEquivalent: "")
        close.target = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        panOrigin = enclosingScrollView?.contentView.bounds.origin
        mouseOrigin = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView, let panOrigin, let mouseOrigin else { return }
        let scale = scroll.magnification
        let delta = NSPoint(x: (event.locationInWindow.x - mouseOrigin.x) / scale,
                            y: (event.locationInWindow.y - mouseOrigin.y) / scale)
        let proposed = NSRect(origin: NSPoint(x: panOrigin.x - delta.x, y: panOrigin.y + delta.y),
                              size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseOrigin != nil { NSCursor.pop() }
        mouseOrigin = nil
        panOrigin = nil
    }

    @objc private func copyPinned() { onCopy?() }
    @objc private func closePinned() { onClose?() }
}
