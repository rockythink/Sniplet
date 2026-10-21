import AppKit
import QuartzCore
import SwiftUI

/// CapCap's editor attaches its canvas and BOTH toolbars to the existing SelectionView.
/// This adapts that handoff, not its recording/upload/global-monitor features.
/// Source: realskyrin/CapCap EditWindowController.swift 315–502 (MIT),
/// commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
@MainActor final class InlineEditorController: NSObject, NSWindowDelegate {
    let session: EditorSession
    private let preferences: AppPreferences
    var onClose: (() -> Void)?
    /// The adjusted selection's global AppKit rect, after each move or resize.
    var onRegionChange: ((CGRect) -> Void)?
    var window: NSWindow? { host.panel }
    private let host: InlineCaptureHost
    private var sourceRect: CGRect
    private var sourceImageSize: CGSize
    private var presentationBounds: CGRect
    private var visibleFrame: CGRect
    private var scrollView: AnnotationScrollView?
    private var finalImageView: NSImageView?
    private var primaryBar: InlineToolbarContainer?
    private var sideBar: InlineToolbarContainer?
    private var chrome: InlineSelectionChrome?
    private var selectionDragView: CaptureSelectionDragView?
    private var hasAdjustedSelectionPresentation = false
    private var selectionScreenIsUnchanged = true
    private var selectionMoveError: String?
    private var isClosing = false
    private var isPresented = false
    private var sessionRefreshScheduled = false

    init(session: EditorSession, preferences: AppPreferences, screen: NSScreen, sourceRect: CGRect,
         host: InlineCaptureHost? = nil) {
        self.session = session
        self.preferences = preferences
        self.sourceRect = sourceRect
        self.host = host ?? InlineCaptureHost(screenFrame: screen.frame, displayID: DisplayGeometry.displayID(for: screen))
        visibleFrame = screen.visibleFrame
        if let document = session.editor?.document {
            sourceImageSize = document.imageBounds.size
            presentationBounds = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                                 sourceScale: document.capture.sourceScale).presentationBounds
        } else {
            // Promise recovery uses only the final bitmap; never recaptures the screen.
            sourceImageSize = session.imageSize
            presentationBounds = CGRect(origin: .zero, size: session.imageSize)
        }
        super.init()
        session.onClose = { [weak self] in self?.closeCompleted() }
        NotificationCenter.default.addObserver(self, selector: #selector(displayParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        host.close()
    }

    func present() {
        guard !isClosing, !host.isClosed else { return }
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        host.lockSelection(sourceRect)
        host.present()
        guard let panel = host.panel, let root = host.rootView else { return }
        root.hasEditorContent = true
        panel.delegate = self
        // Floating is below modalPanel; native save panels and alerts remain usable.
        panel.level = .floating
        panel.onCopy = { [weak self] in self?.copyImage() }
        panel.onSave = { [weak self] in self?.session.output(.save) }
        panel.onFinish = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancelCapture() }
        root.onCancel = { [weak self] in self?.cancelCapture() }
        if !isPresented {
            isPresented = true
            let primary = NSHostingView(rootView: InlineAnnotationToolbar(
                session: session, focusCanvas: { [weak self] in self?.focusCanvas() },
                stateChanged: { [weak self] in self?.scheduleSessionRefresh() }
            ))
            let actions = NSHostingView(rootView: InlineActionToolbar(
                session: session,
                preferences: preferences,
                finish: { [weak self] in self?.finish() },
                cancel: { [weak self] in self?.cancelCapture() },
                stateChanged: { [weak self] in self?.scheduleSessionRefresh() }
            ))
            primaryBar = InlineToolbarContainer(content: primary, horizontal: true)
            sideBar = InlineToolbarContainer(content: actions, horizontal: false)
            let chrome = InlineSelectionChrome(frame: root.bounds)
            self.chrome = chrome
            root.addSubview(chrome)
            if let primaryBar { root.addSubview(primaryBar) }
            if let sideBar { root.addSubview(sideBar) }
        }
        refreshSessionState()
        panel.makeFirstResponder((scrollView?.canvas as NSView?) ?? root)
    }

    private func scheduleSessionRefresh() {
        guard !isClosing, !sessionRefreshScheduled else { return }
        sessionRefreshScheduled = true
        // SwiftUI onChange runs during view reconciliation. Measuring fittingSize
        // there re-enters NSHostingView layout and can collapse the action bar.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sessionRefreshScheduled = false
            self.refreshSessionState()
        }
    }

    private func refreshSessionState() {
        guard !isClosing, let root = host.rootView else { return }
        if let editor = session.editor {
            if scrollView == nil {
                let scroll = AnnotationScrollView(editor: editor)
                scroll.canvas.onConfirmScreenshot = { [weak self] in self?.copyImage() }
                scroll.canvas.onCancelScreenshot = { [weak self] in self?.cancelCapture() }
                scroll.canvas.onSelectionMoveError = { [weak self] message in self?.showSelectionMoveError(message) }
                root.addSubview(scroll, positioned: .below, relativeTo: chrome)
                scrollView = scroll
                scroll.canvas.onPreviewStateChange = { [weak self] _ in self?.updateSelectionChrome() }
                scroll.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(canvasViewportChanged(_:)),
                    name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                editor.captureStyleHandler = { [weak self] _ in
                    self?.layoutInlineViews()
                }
                editor.regionSelectionHandler = { [weak self] region in
                    guard let self, !self.isClosing, let scroll = self.scrollView,
                          let root = self.host.rootView else { return }
                    self.selectionMoveError = nil
                    self.onRegionChange?(region.screenRect)
                    let previousSource = self.sourceRect
                    let previousDisplayed = scroll.canvas.convert(
                        CGRect(origin: .zero, size: self.sourceImageSize), to: root)
                    let previousScale = CGSize(width: self.sourceRect.width / self.sourceImageSize.width,
                                               height: self.sourceRect.height / self.sourceImageSize.height)
                    self.sourceImageSize = region.pixelRect.size
                    if self.selectionScreenIsUnchanged {
                        self.sourceRect = region.screenRect
                    } else {
                        let resized = CGRect(origin: self.sourceRect.origin,
                            size: CGSize(width: self.sourceImageSize.width * previousScale.width,
                                         height: self.sourceImageSize.height * previousScale.height))
                        self.sourceRect = EditorToolbarPlacement.relocatedSourceRect(resized,
                            from: self.host.screenFrame, to: self.visibleFrame)
                    }
                    if self.selectionScreenIsUnchanged {
                        self.hasAdjustedSelectionPresentation = true
                        scroll.preserveSelectionPresentation()
                        let origin = CGPoint(
                            x: previousDisplayed.minX + (self.sourceRect.minX - previousSource.minX)
                                * previousDisplayed.width / previousSource.width,
                            y: previousDisplayed.maxY + (self.sourceRect.maxY - previousSource.maxY)
                                * previousDisplayed.height / previousSource.height)
                        self.layoutInlineViews(remeasureToolbars: false, imageOrigin: origin)
                    } else {
                        self.layoutInlineViews(remeasureToolbars: false)
                    }
                }
                let drag = CaptureSelectionDragView(editor: editor)
                drag.onError = { [weak self] message in self?.showSelectionMoveError(message) }
                drag.permitsResizeAtPoint = { [weak self] point in
                    guard let self, let root = self.host.rootView, let scroll = self.scrollView,
                          let annotation = scroll.canvas.editor.selectedAnnotation else { return true }
                    let pixelPoint = scroll.canvas.convert(point, from: root)
                    guard scroll.canvas.editor.document.imageBounds.contains(pixelPoint) else { return true }
                    let tolerance = AnnotationGeometry.imageTolerance(screenPoints: 6,
                        backingScale: self.host.panel?.backingScaleFactor ?? 1,
                        magnification: scroll.magnification)
                    return !AnnotationGeometry.handles(annotation).contains {
                        hypot($0.1.x - pixelPoint.x, $0.1.y - pixelPoint.y) <= tolerance
                    }
                }
                root.addSubview(drag, positioned: .below, relativeTo: chrome)
                selectionDragView = drag
            }
            scrollView?.canvas.isEditable = !session.isBusy
        } else {
            host.setSnapshot(nil)
            selectionDragView?.removeFromSuperview()
            selectionDragView = nil
            if let scrollView {
                scrollView.canvas.editor.captureStyleHandler = nil
                scrollView.canvas.editor.regionSelectionHandler = nil
                scrollView.canvas.detach()
                scrollView.removeFromSuperview()
                self.scrollView = nil
            }
            if finalImageView == nil, let final = session.finalCapture {
                let image = NSImageView()
                image.image = NSImage(cgImage: final.image, size: session.imageSize)
                image.imageScaling = .scaleAxesIndependently
                image.setAccessibilityLabel("只读最终图像")
                root.addSubview(image, positioned: .below, relativeTo: chrome)
                finalImageView = image
            }
        }
        layoutInlineViews()
    }

    private func layoutInlineViews(remeasureToolbars: Bool = true, imageOrigin: CGPoint? = nil) {
        guard let root = host.rootView else { return }
        if remeasureToolbars {
            primaryBar?.measurePreferredSize()
            sideBar?.measurePreferredSize()
        }
        if let document = session.editor?.document {
            presentationBounds = document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                                 sourceScale: document.capture.sourceScale).presentationBounds
        }
        let globalPresentation = CaptureFootprint.presentationRect(presentationBounds,
                                                                   imageSize: sourceImageSize, sourceRect: sourceRect)
        let localPresentation = globalPresentation.offsetBy(dx: -host.screenFrame.minX, dy: -host.screenFrame.minY)
        let viewport = hasAdjustedSelectionPresentation ? root.bounds : localPresentation
        if scrollView?.frame != viewport { scrollView?.frame = viewport }
        scrollView?.synchronizePresentation()
        if let imageOrigin { scrollView?.positionImageOrigin(imageOrigin, in: root) }
        if finalImageView?.frame != localPresentation { finalImageView?.frame = localPresentation }
        // Anchor controls to the current crop, not the changing shadow outsets.
        // The popover's button must never move while its own slider is being dragged.
        let reference: CGRect
        if hasAdjustedSelectionPresentation, let scroll = scrollView {
            reference = scroll.canvas.convert(scroll.canvas.editor.document.imageBounds, to: root)
        } else {
            reference = sourceRect.offsetBy(dx: -host.screenFrame.minX, dy: -host.screenFrame.minY)
        }
        let safe = visibleFrame.offsetBy(dx: -host.screenFrame.minX, dy: -host.screenFrame.minY)
        let frames = EditorToolbarPlacement.frames(
            referenceRect: reference, in: safe,
            primarySize: primaryBar?.preferredSize ?? CGSize(width: 600, height: 44),
            sideSize: sideBar?.preferredSize ?? CGSize(width: 44, height: 300))
        if primaryBar?.frame != frames.primary { primaryBar?.frame = frames.primary }
        if sideBar?.frame != frames.side { sideBar?.frame = frames.side }
        if chrome?.frame != root.bounds { chrome?.frame = root.bounds }
        if selectionDragView?.frame != root.bounds { selectionDragView?.frame = root.bounds }
        updateSelectionChrome()
    }

    /// Global screen rect the final image occupies at source scale, including style padding,
    /// so a pin replaces the capture where it was taken.
    var pinAnchorRect: CGRect {
        CaptureFootprint.presentationRect(presentationBounds, imageSize: sourceImageSize, sourceRect: sourceRect)
    }

    private func focusCanvas() {
        guard let canvas = scrollView?.canvas else { return }
        host.panel?.makeFirstResponder(canvas)
    }

    @objc private func canvasViewportChanged(_ notification: Notification) {
        updateSelectionChrome()
    }

    private func updateSelectionChrome() {
        guard !isClosing, let chrome else { return }
        let appearance = preferences.selectionAppearance.normalized
        host.rootView?.selectionAppearance = appearance
        selectionDragView?.selectionAppearance = appearance
        if let scroll = scrollView {
            let document = scroll.canvas.editor.document
            let canMoveSelection = selectionScreenIsUnchanged && !session.isBusy && scroll.canvas.editor.canMoveCaptureSelection
            scroll.canvas.allowsCaptureSelectionMove = canMoveSelection
            let canResizeSelection = selectionScreenIsUnchanged && !session.isBusy && scroll.canvas.editor.canResizeCaptureSelection
            selectionDragView?.isEnabled = canResizeSelection
            selectionDragView?.selectionRect = scroll.canvas.convert(document.imageBounds, to: host.rootView)
            selectionDragView?.clippingRect = scroll.frame
            selectionDragView?.interactionBounds = visibleFrame.offsetBy(dx: -host.screenFrame.minX,
                                                                         dy: -host.screenFrame.minY)
            let hint = selectionMoveError.map { "调整选区失败：\($0)" }
                ?? (canResizeSelection
                    ? (canMoveSelection ? "拖边线或角点改大小 · 选择工具下拖空白移动" : "拖边线或角点调整截图范围")
                    : nil)
            chrome.update(imageRect: scroll.canvas.convert(document.imageBounds, to: chrome),
                          imageSize: document.imageBounds.size, style: document.captureStyle,
                          sourceScale: document.capture.sourceScale, clippedTo: scroll.frame,
                          pixelSize: session.imageSize, previewState: scroll.canvas.previewState,
                          interactionHint: hint, selectionAppearance: appearance)
        } else if let image = finalImageView {
            chrome.update(imageRect: image.frame, imageSize: session.imageSize,
                          style: .plain, sourceScale: 1, clippedTo: image.frame,
                          pixelSize: session.imageSize, selectionAppearance: appearance)
        }
    }

    private func showSelectionMoveError(_ message: String) {
        selectionMoveError = message
        updateSelectionChrome()
    }

    private func copyImage() {
        guard !session.isBusy else { return }
        session.output(.copyImage)
    }

    /// Explicit X/Escape discards without inserting history. Text/gesture Escape is
    /// consumed by the canvas before this callback reaches the screenshot lifecycle.
    private func cancelCapture() {
        guard !session.isBusy else { return }
        if session.phase == .finalized, !session.historyStored, !confirmDiscard() { return }
        session.discard()
    }

    func finish() {
        guard !session.isBusy else { return }
        if session.phase == .finalized {
            guard session.historyStored || confirmDiscard() else { return }
            session.discard()
        } else if session.keepsHistory || confirmDiscard() {
            session.output(.finish)
        }
    }

    func confirmDiscard() -> Bool {
        guard !session.isBusy else { return false }
        let alert = NSAlert()
        alert.messageText = "关闭后不会保留这张截图"
        alert.informativeText = "历史保存已关闭，或最终图像尚未保存成功。可以取消并返回截图复制或另存。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "丢弃截图")
        return alert.runForSniplet() == .alertSecondButtonReturn
    }

    private func closeCompleted() {
        guard !isClosing else { return }
        isClosing = true
        NotificationCenter.default.removeObserver(self)
        scrollView?.canvas.editor.captureStyleHandler = nil
        scrollView?.canvas.editor.regionSelectionHandler = nil
        selectionDragView?.removeFromSuperview()
        selectionDragView = nil
        scrollView?.canvas.detach()
        scrollView = nil
        finalImageView = nil
        primaryBar = nil
        sideBar = nil
        chrome = nil
        host.close()
        onRegionChange = nil
        let completion = onClose
        onClose = nil
        completion?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        guard !session.isBusy else { return false }
        if session.phase == .finalized {
            if session.historyStored || confirmDiscard() { session.discard() }
        } else if session.keepsHistory {
            session.output(.finish)
        } else if confirmDiscard() {
            session.discard()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // External close still releases all resources and the session exactly once.
        guard !isClosing else { return }
        session.discard()
        closeCompleted()
    }

    @objc private func displayParametersChanged() {
        guard !isClosing else { return }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { DisplayGeometry.displayID(for: $0) == host.displayID }) ?? screens.first else {
            // No accessible screen: never leave a blocking overlay behind, and keep
            // the unsaved session for the next display notification.
            host.panel?.orderOut(nil)
            return
        }
        let oldFrame = host.screenFrame
        if oldFrame != screen.frame || host.displayID != DisplayGeometry.displayID(for: screen) {
            selectionScreenIsUnchanged = false
            session.editor?.cancelSelectionAdjustment()
            sourceRect = EditorToolbarPlacement.relocatedSourceRect(sourceRect, from: oldFrame, to: screen.visibleFrame)
            host.relocate(to: screen.frame, displayID: DisplayGeometry.displayID(for: screen))
            hasAdjustedSelectionPresentation = false
            scrollView?.refit()
        }
        visibleFrame = screen.visibleFrame
        host.lockSelection(sourceRect)
        layoutInlineViews()
        if isPresented { host.panel?.orderFrontRegardless() }
    }
}

/// Bounded native scroll containers keep every toolbar action reachable on tiny screens,
/// rather than stretching a tiny capture or allowing the two bars to collide.
@MainActor private final class InlineToolbarContainer: NSVisualEffectView {
    private let scroll = NSScrollView()
    private let content: NSView
    private(set) var preferredSize = CGSize(width: 40, height: 40)

    func measurePreferredSize() {
        let size = content.fittingSize
        preferredSize = CGSize(width: max(40, size.width), height: max(40, size.height))
    }

    init(content: NSView, horizontal: Bool) {
        self.content = content
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = horizontal
        scroll.hasVerticalScroller = !horizontal
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        if content.frame.size != preferredSize { content.setFrameSize(preferredSize) }
    }
}

@MainActor private final class InlineSelectionChrome: NSView {
    private let outlineClip = CALayer()
    private let outline = CAShapeLayer()
    private let badge = NSTextField(labelWithString: "")
    private var previewState: AnnotationPreviewCoordinator.State = .idle
    private var selectionAppearance: CaptureSelectionAppearance?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosted vectors have no full-screen bitmap to redraw on each slider tick.
        layer = CALayer()
        wantsLayer = true
        outlineClip.masksToBounds = true
        outline.fillColor = nil
        outline.lineWidth = 1
        outlineClip.addSublayer(outline)
        layer?.addSublayer(outlineClip)
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.8)
        badge.drawsBackground = true
        badge.lineBreakMode = .byTruncatingTail
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.masksToBounds = true
        badge.setAccessibilityElement(true)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(imageRect: CGRect, imageSize: CGSize, style: CaptureStyle,
                sourceScale: CGFloat, clippedTo viewport: CGRect, pixelSize: CGSize,
                previewState: AnnotationPreviewCoordinator.State = .idle, interactionHint: String? = nil,
                selectionAppearance: CaptureSelectionAppearance) {
        guard let geometry = InlineSelectionOutline(imageRect: imageRect, imageSize: imageSize,
                                                     style: style, sourceScale: sourceScale) else {
            outlineClip.isHidden = true
            badge.isHidden = true
            return
        }
        let visible = imageRect.intersection(viewport).intersection(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        outlineClip.isHidden = visible.isEmpty || visible.isNull
        badge.isHidden = outlineClip.isHidden
        guard !outlineClip.isHidden else { return }
        if self.selectionAppearance != selectionAppearance {
            self.selectionAppearance = selectionAppearance
            outline.strokeColor = selectionAppearance.color.cgColor
            let dash = selectionAppearance.lineStyle.dashPattern
            outline.lineDashPattern = dash.isEmpty ? nil : dash.map { NSNumber(value: Double($0)) }
            outline.lineCap = selectionAppearance.lineStyle == .dotted ? .round : .butt
        }
        let clip = viewport.insetBy(dx: -1, dy: -1).intersection(bounds)
        outlineClip.frame = clip
        outline.frame = outlineClip.bounds
        outline.contentsScale = window?.backingScaleFactor ?? 1
        var transform = CGAffineTransform(translationX: -clip.minX, y: -clip.minY)
        outline.path = geometry.path.copy(using: &transform)
        let radius = style.normalized.cornerRadius
        let radiusSuffix = radius > 0 ? " · 圆角 \(Int(radius)) pt" : ""
        let statusSuffix: String
        switch previewState {
        case .idle, .ready: statusSuffix = ""
        case .updating: statusSuffix = " · 更新阴影…"
        case let .failed(message): statusSuffix = " · 美化预览失败：\(message)"
        }
        let hintSuffix = interactionHint.map { " · \($0)" } ?? ""
        badge.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))\(radiusSuffix)\(statusSuffix)\(hintSuffix)"
        badge.toolTip = badge.stringValue
        badge.setAccessibilityLabel(badge.stringValue)
        if self.previewState != previewState {
            self.previewState = previewState
            NSAccessibility.post(element: badge, notification: .valueChanged)
        }
        let size = badge.fittingSize
        let width = min(size.width + 8, max(1, bounds.width - 8))
        badge.frame = CGRect(x: min(max(4, visible.minX), max(4, bounds.maxX - width - 4)),
                             y: min(max(4, visible.maxY + 4), max(4, bounds.maxY - 24)),
                             width: width, height: 20)
    }
}
