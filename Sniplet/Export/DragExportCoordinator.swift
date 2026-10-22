import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated struct EncodedCapture: Sendable {
    let capture: RenderedCapture
    let pngData: Data
    let tiffData: Data?

    init(capture: RenderedCapture, pngData: Data, tiffData: Data? = nil) {
        self.capture = capture
        self.pngData = pngData
        self.tiffData = tiffData
    }
}

/// Tracks only writes which AppKit has actually requested, not unconsumed promises.
/// Synchronous accounting makes a quit request observe a write before its I/O starts.
nonisolated final class PromiseWriteTracker: Sendable {
    static let shared = PromiseWriteTracker()
    private struct State {
        var count = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var pendingWriteCount: Int { state.withLock { $0.count } }

    func beganWrite() { state.withLock { $0.count += 1 } }

    func endedWrite() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            precondition(state.count > 0)
            state.count -= 1
            guard state.count == 0 else { return [] }
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            let alreadyDrained = state.withLock { state in
                if state.count == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyDrained { continuation.resume() }
        }
    }
}

/// The provider owns this context through userInfo; its delegate reference is weak.
/// This context never retains the provider or the editor and owns only final bytes.
nonisolated final class PromiseContext: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let snapshot: EncodedCapture
    let tracker: PromiseWriteTracker
    private static let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.elazer.Sniplet.file-promises"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let onFailure: @MainActor @Sendable (EncodedCapture, String) -> Void

    init(
        snapshot: EncodedCapture,
        tracker: PromiseWriteTracker = .shared,
        onFailure: @escaping @MainActor @Sendable (EncodedCapture, String) -> Void
    ) {
        self.snapshot = snapshot
        self.tracker = tracker
        self.onFailure = onFailure
        super.init()
    }

    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        ExportFilename.png(createdAt: snapshot.capture.createdAt)
    }

    // FileCoordination queries this through Objective-C on a background queue, despite
    // the SDK's UI-actor annotation. It only reads an immutable, thread-safe queue.
    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.writeQueue }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        write(to: url, completionHandler: completionHandler)
    }

    /// Called on the dedicated promise queue; also permits real filesystem tests.
    func write(to url: URL, completionHandler: ((any Error)?) -> Void) {
        tracker.beganWrite()
        // Keep the context alive through completion even when the panel/source is gone.
        defer { withExtendedLifetime(self) {} }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            // A promise extension may grant only this exact URL, not a sibling
            // temporary file. Atomic replacement is reserved for save-panel URLs.
            try snapshot.pngData.write(to: url)
            completionHandler(nil)
            tracker.endedWrite()
        } catch {
            completionHandler(error)
            Task { @MainActor [self] in
                onFailure(snapshot, "拖出文件写入失败，请另存或重新拖出。")
                // Quit must not finish before the failure preview is delivered.
                tracker.endedWrite()
            }
        }
    }
}

/// One logical item offers an existing final PNG URL, native image data and a file promise.
nonisolated final class SnapshotFilePromiseProvider: NSFilePromiseProvider {
    let snapshot: EncodedCapture
    let fileURL: URL

    init(context: PromiseContext, fileURL: URL) {
        snapshot = context.snapshot
        self.fileURL = fileURL
        super.init()
        fileType = UTType.png.identifier
        delegate = context
        userInfo = context
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png]
        if snapshot.tiffData != nil { types.append(.tiff) }
        for type in super.writableTypes(for: pasteboard) where !types.contains(type) { types.append(type) }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == .fileURL || type == .png || type == .tiff { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return fileURL.absoluteString }
        if type == .png { return snapshot.pngData }
        if type == .tiff { return snapshot.tiffData }
        return super.pasteboardPropertyList(forType: type)
    }
}

@MainActor
private final class DragFeedback {
    enum Outcome { case pending, accepted, cancelled }
    var outcome = Outcome.pending
    private var failure: (EncodedCapture, String)?
    var onAccepted: (() -> Void)?
    var onCancelled: (() -> Void)?
    let onFailure: (EncodedCapture, String) -> Void

    init(onAccepted: @escaping () -> Void, onCancelled: @escaping () -> Void,
         onFailure: @escaping (EncodedCapture, String) -> Void) {
        self.onAccepted = onAccepted
        self.onCancelled = onCancelled
        self.onFailure = onFailure
    }

    func failed(_ snapshot: EncodedCapture, _ message: String) {
        switch outcome {
        case .pending: failure = (snapshot, message)
        case .accepted: onFailure(snapshot, message)
        case .cancelled: break
        }
    }

    func ended(accepted: Bool) {
        guard case .pending = outcome else { return }
        let acceptedAction = onAccepted
        let cancelledAction = onCancelled
        onAccepted = nil
        onCancelled = nil
        outcome = accepted ? .accepted : .cancelled
        if accepted {
            acceptedAction?()
            if let failure { onFailure(failure.0, failure.1) }
        } else {
            cancelledAction?()
        }
        failure = nil
    }
}

/// A press only arms the handle. A real drag prepares the immutable final output,
/// then starts at the current pointer while the physical mouse button is still held.
/// A click without a drag runs `onClick` instead (the editor's save action).
struct DragExportHandle: NSViewRepresentable {
    var onClick: (@MainActor () -> Void)? = nil
    var isClickEnabled = true
    var isSurface = false
    let prepare: @MainActor () async throws -> EncodedCapture
    let onAccepted: @MainActor () -> Void
    let onCancelled: @MainActor () -> Void
    let onFailure: @MainActor (EncodedCapture, String) -> Void
    let onPreparationFailure: @MainActor (String) -> Void

    func makeNSView(context: Context) -> DragExportCoordinator {
        let view = DragExportCoordinator(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragExportCoordinator, context: Context) {
        view.onClick = onClick
        view.isClickEnabled = isClickEnabled
        view.isSurface = isSurface
        view.prepare = prepare
        view.onAccepted = onAccepted
        view.onCancelled = onCancelled
        view.onFailure = onFailure
        view.onPreparationFailure = onPreparationFailure
    }

    static func dismantleNSView(_ view: DragExportCoordinator, coordinator: ()) {
        view.cancelPreparation()
    }
}

@MainActor
final class DragExportCoordinator: NSView, NSDraggingSource {
    var onClick: (@MainActor () -> Void)? {
        didSet { updateDescription() }
    }
    /// Gates only the click; dragging keeps its own preparation checks.
    var isClickEnabled = true {
        didSet { if oldValue != isClickEnabled { needsDisplay = true } }
    }
    /// An invisible drag area laid over an image preview instead of a toolbar button.
    var isSurface = false {
        didSet { if oldValue != isSurface { updateDescription(); needsDisplay = true } }
    }
    var prepare: (@MainActor () async throws -> EncodedCapture)?
    var onAccepted: (@MainActor () -> Void)?
    var onCancelled: (@MainActor () -> Void)?
    var onFailure: (@MainActor (EncodedCapture, String) -> Void)?
    var onPreparationFailure: (@MainActor (String) -> Void)?
    private var preparation: Task<Void, Never>?
    private var gestureID: UUID?
    private var snapshot: EncodedCapture?
    private var provider: SnapshotFilePromiseProvider?
    private var feedback: DragFeedback?
    private var dragLifetime: DragExportCoordinator?
    private var initialLocation: NSPoint = .zero
    private var latestDragEvent: NSEvent?
    private var temporaryFileURL: URL?
    private var isDragging = false
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    private static let dragIcon = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    private static let saveIcon = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    private static let preparingIcon = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateDescription()
    }

    private func updateDescription() {
        if isSurface {
            toolTip = "拖动图片到 Finder、聊天窗口或上传区"
            setAccessibilityRole(.image)
            setAccessibilityLabel("可拖出的截图")
            setAccessibilityHelp("按住并拖动，把这张截图拖到其他应用。")
        } else if onClick != nil {
            toolTip = "单击直接存到选定的文件夹（⌘S，首次会让你选文件夹；⇧⌘S 另存为）；按住拖动可直接拖到 Finder、聊天窗口或上传区"
            setAccessibilityLabel("保存或拖出图像")
            setAccessibilityHelp("按下直接把 PNG 存到选定的文件夹，Shift-Command-S 另存为。也可以按住并拖动，把最终图像拖到其他应用。")
        } else {
            toolTip = "按住并拖动最终图像到 Finder、聊天窗口或图片上传区；单击不会输出。"
            setAccessibilityLabel("拖出图像")
            setAccessibilityHelp("按住并拖动，最终图像准备完成后自动拖出。单击不会输出或收起工具条。")
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick, isClickEnabled else { return false }
        onClick()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        isSurface ? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) : NSSize(width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isSurface else { return }
        // Same feedback as InlineToolbarButtonStyle: hover and press tints only. A drag-only
        // handle keeps a resting tint, since nothing else marks it as interactive.
        let enabled = onClick == nil || isClickEnabled
        let fill: CGFloat = gestureID != nil ? 0.20 : isHovered && enabled ? 0.08 : onClick == nil ? 0.08 : 0
        if fill > 0 {
            NSColor.labelColor.withAlphaComponent(fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        // Template symbols draw black unless tinted; labelColor resolves per appearance here.
        let resting = onClick == nil ? Self.dragIcon : Self.saveIcon
        let icon = (preparation != nil ? Self.preparingIcon : resting)?
            .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
        icon?.draw(in: CGRect(x: bounds.midX-8, y: bounds.midY-8, width: 16, height: 16),
                   from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.4)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func resetCursorRects() { if onClick == nil { addCursorRect(bounds, cursor: .openHand) } }

    override func mouseDown(with event: NSEvent) {
        guard gestureID == nil, !isDragging, prepare != nil else { return }
        gestureID = UUID()
        initialLocation = convert(event.locationInWindow, from: nil)
        latestDragEvent = nil
        needsDisplay = true
        // A click only arms the handle. Rendering and session locking begin after
        // the pointer crosses the normal drag threshold, never on mouse-down.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let id = gestureID, let prepare else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - initialLocation.x, location.y - initialLocation.y) >= 3 else { return }
        latestDragEvent = event
        if snapshot != nil { beginPreparedDrag(); return }
        guard preparation == nil else { return }
        let accepted = onAccepted
        let cancelled = onCancelled
        let failed = onFailure
        feedback = DragFeedback(onAccepted: { accepted?() }, onCancelled: { cancelled?() },
                                onFailure: { failed?($0, $1) })
        preparation = Task { [weak self] in
            var stagedFile: URL?
            do {
                try Task.checkCancellation()
                let snapshot = try await prepare()
                try Task.checkCancellation()
                let file = try await DragExportFileStore.shared.stage(snapshot)
                stagedFile = file
                try Task.checkCancellation()
                guard let self, self.gestureID == id else {
                    await DragExportFileStore.shared.discard(file)
                    return
                }
                self.snapshot = snapshot
                self.temporaryFileURL = file
                self.preparation = nil
                self.needsDisplay = true
                // Do not require another mouse-move after async encoding. The
                // physical button check below prevents a released click becoming a drag.
                self.beginPreparedDrag()
            } catch {
                if let stagedFile { await DragExportFileStore.shared.discard(stagedFile) }
                guard let self, self.gestureID == id else { return }
                self.gestureID = nil
                self.latestDragEvent = nil
                self.preparation = nil
                self.feedback = nil
                self.needsDisplay = true
                if error is CancellationError { cancelled?() }
                else { self.onPreparationFailure?("无法准备拖出图像：\(error.localizedDescription)") }
            }
        }
        needsDisplay = true
    }

    private func beginPreparedDrag() {
        guard !isDragging, let snapshot, let feedback, let file = temporaryFileURL else { return }
        guard let window, let previous = latestDragEvent, window.isVisible,
              NSEvent.pressedMouseButtons & 1 != 0 else {
            cancelPreparation()
            return
        }
        let windowLocation = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: windowLocation,
            modifierFlags: previous.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: previous.eventNumber,
            clickCount: 1, pressure: previous.pressure) else { cancelPreparation(); return }
        let context = PromiseContext(snapshot: snapshot) { snapshot, message in feedback.failed(snapshot, message) }
        let provider = SnapshotFilePromiseProvider(context: context, fileURL: file)
        self.provider = provider
        let item = NSDraggingItem(pasteboardWriter: provider)
        let image = NSImage(cgImage: snapshot.capture.image, size: NSSize(
            width: snapshot.capture.image.width, height: snapshot.capture.image.height))
        let factor = min(1, 180 / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let location = convert(windowLocation, from: nil)
        item.setDraggingFrame(NSRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                                    width: size.width, height: size.height), contents: image)
        isDragging = true
        dragLifetime = self
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        // No drag threshold crossed: an ordinary click on a pointer still over the button.
        let clicked = gestureID != nil && latestDragEvent == nil
            && bounds.contains(convert(event.locationInWindow, from: nil))
        cancelPreparation()
        if clicked, isClickEnabled { onClick?() }
    }

    func cancelPreparation() {
        guard !isDragging, gestureID != nil else { return }
        gestureID = nil
        preparation?.cancel()
        preparation = nil
        latestDragEvent = nil
        if let file = temporaryFileURL {
            temporaryFileURL = nil
            Task { await DragExportFileStore.shared.discard(file) }
        }
        snapshot = nil
        feedback?.ended(accepted: false)
        feedback = nil
        needsDisplay = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let feedback = feedback
        isDragging = false
        gestureID = nil
        snapshot = nil
        latestDragEvent = nil
        if let file = temporaryFileURL {
            temporaryFileURL = nil
            if operation.isEmpty { Task { await DragExportFileStore.shared.discard(file) } }
            else { DragExportFileStore.shared.retainForReceiver(file) }
        }
        provider = nil
        self.feedback = nil
        dragLifetime = nil
        feedback?.ended(accepted: !operation.isEmpty)
        needsDisplay = true
    }
}
