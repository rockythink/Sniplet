import AppKit

/// The whole pin is the image: dragging moves the window, zooming resizes it, and the
/// controls only appear while the pointer is over the pin.
@MainActor
final class PinnedImageView: NSView {
    private let capture: RenderedCapture
    private let encoder: ImageEncoder
    private let onClose: () -> Void
    private let controls = NSVisualEffectView()
    private let percentage = NSButton(title: "100%", target: nil, action: nil)
    private var hoverTracking: NSTrackingArea?
    private var copyTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    /// Window size relative to the image's natural point size on the current display.
    private(set) var zoom: CGFloat = 1

    init(capture: RenderedCapture, encoder: ImageEncoder, onClose: @escaping () -> Void) {
        self.capture = capture
        self.encoder = encoder
        self.onClose = onClose
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("钉图，\(capture.image.width) × \(capture.image.height) 像素。拖动移动，捏合缩放，Esc 关闭")

        let menu = NSMenu(title: "钉图")
        menu.addItem(withTitle: "复制图像", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "实际大小", action: #selector(actualSize), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭钉图", action: #selector(closeImage), keyEquivalent: "").target = self
        self.menu = menu

        let zoomOut = symbolButton("minus.magnifyingglass", action: #selector(zoomOut), help: "缩小（⌘−）")
        let zoomIn = symbolButton("plus.magnifyingglass", action: #selector(zoomIn), help: "放大（⌘+）")
        percentage.target = self
        percentage.action = #selector(actualSize)
        percentage.isBordered = false
        percentage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentage.toolTip = "实际大小：一图像像素对应一屏幕像素（⌘0）"
        percentage.setContentHuggingPriority(.required, for: .horizontal)
        let copy = symbolButton("doc.on.doc", action: #selector(copyImage), help: "复制图像，仅限本机（⌘C）")
        let close = symbolButton("xmark", action: #selector(closeImage), help: "关闭钉图（Esc）")
        let stack = NSStackView(views: [zoomOut, zoomIn, percentage, copy, close])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.detachesHiddenViews = true
        // Small pins drop the zoom controls first; copy and close always stay reachable.
        for view in [zoomOut, zoomIn, percentage] { stack.setVisibilityPriority(.detachOnlyIfNecessary, for: view) }
        stack.translatesAutoresizingMaskIntoConstraints = false

        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.appearance = NSAppearance(named: .vibrantDark)
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 7
        controls.layer?.masksToBounds = true
        controls.alphaValue = 0
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        addSubview(controls)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6)
        ])
        updatePercentage()
    }

    required init?(coder: NSCoder) { nil }

    private func symbolButton(_ symbol: String, action: Selector, help: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var naturalSize: CGSize {
        let backing = window?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(capture.image.width) / backing, height: CGFloat(capture.image.height) / backing)
    }

    /// Adopts the zoom implied by the controller's initial (possibly screen-fitted) frame.
    func synchronizeZoomWithWindow() {
        guard let window, naturalSize.width > 0 else { return }
        zoom = window.frame.width / naturalSize.width
        updatePercentage()
    }

    /// Keeps the same relative zoom when the pin moves to a display with another scale.
    func backingScaleDidChange() { setZoom(zoom) }

    func invalidate() {
        copyTask?.cancel()
        copyTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(capture.image, in: bounds)
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func magnify(with event: NSEvent) { setZoom(zoom * (1 + event.magnification)) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.isKeyWindow == true, flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c" where flags == .command: copyImage()
        case "w" where flags == .command: onClose()
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "0" where flags == .command: actualSize()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc private func zoomIn() { setZoom(zoom * 1.25) }
    @objc private func zoomOut() { setZoom(zoom / 1.25) }
    @objc private func actualSize() { setZoom(1) }
    @objc private func closeImage() { onClose() }

    private func setZoom(_ value: CGFloat) {
        guard let window else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let natural = naturalSize
        zoom = PinnedImageLayout.clampedZoom(value, natural: natural, visible: visible.size)
        let frame = PinnedImageLayout.zoomedFrame(window.frame, natural: natural, zoom: zoom, visible: visible)
        if frame != window.frame { window.setFrame(frame, display: true) }
        window.invalidateShadow()
        updatePercentage()
    }

    private func updatePercentage() {
        guard feedbackTask == nil else { return }
        percentage.title = "\(Int((zoom * 100).rounded()))%"
        percentage.setAccessibilityValue(percentage.title)
    }

    /// Brief inline confirmation in the percentage slot instead of a separate error row.
    private func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        percentage.title = message
        setControlsVisible(true)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.feedbackTask = nil
            self.updatePercentage()
        }
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
                self.copyTask = nil
                self.showFeedback("已复制")
            } catch {
                guard let self else { return }
                self.copyTask = nil
                guard !(error is CancellationError) else { return }
                self.showFeedback("复制失败")
            }
        }
    }
}
