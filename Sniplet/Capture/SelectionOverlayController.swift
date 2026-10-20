import AppKit

nonisolated enum CaptureSelection: Sendable {
    case region(CapturedImage, CGRect, CaptureScreen)
    case window(WindowCandidate, CaptureScreen)
}

/// Small pure gesture state shared by the overlay and no-display lifecycle tests.
/// CapCap confirms a hovered window on mouse-up, unless movement crossed the click threshold.
/// Adapted from realskyrin/CapCap SelectionView (MIT), commit
/// 7dd035225eaa41e6da8a5156556a8c4dd7bd028b.
nonisolated struct CaptureSelectionGesture {
    let start: CGPoint
    private(set) var pendingWindow: WindowCandidate?
    private(set) var didDrag = false

    init(start: CGPoint, window: WindowCandidate?) {
        self.start = start
        pendingWindow = window
    }

    mutating func move(to point: CGPoint) {
        if abs(point.x-start.x) >= 4 || abs(point.y-start.y) >= 4 {
            pendingWindow = nil
            didDrag = true
        }
    }
}

/// The overlay owns all hosts until one is explicitly transferred. Completion locks the
/// selected host *without closing it*, and releases every other screen immediately.
@MainActor final class SelectionOverlayController {
    private let hosts = InlineCaptureHostSet()
    private var waiter: CheckedContinuation<CaptureSelection?, Never>?
    private var finished: CaptureSelection??
    private var selectedScreen: CGDirectDisplayID?
    private var gesture: CaptureSelectionGesture?
    private var selection: CGRect?
    private var snapshots: [CGDirectDisplayID: CapturedImage] = [:]
    private var candidates: [WindowCandidate] = []
    private var candidatesReady = false
    private var hovered: WindowCandidate?
    private var screens: [CaptureScreen] = []
    private var isWindowMode = false
    private var completedScreen: CGDirectDisplayID?
    private var deferredClick: (point: CGPoint, screen: CaptureScreen)?
    private var deferredRegion: (rect: CGRect, screen: CaptureScreen)?
    func beginSelection(screens: [CaptureScreen], windowMode: Bool,
                        selectionAppearance: CaptureSelectionAppearance) {
        cancel()
        finished = nil
        guard !Task.isCancelled, !screens.isEmpty else { return }
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        self.screens = screens
        isWindowMode = windowMode
        for screen in screens {
            let host = InlineCaptureHost(screenFrame: screen.frame, displayID: screen.id,
                                         selectionAppearance: selectionAppearance)
            guard let view = host.rootView else { continue }
            view.instruction = "正在准备截图…"
            view.setAccessibilityLabel(windowMode ? "选择窗口" : "选择截图区域")
            view.setAccessibilityHelp("单击选中悬停窗口，拖动创建区域。不跨屏拼接。Escape 取消。")
            view.onDown = { [weak self] point in self?.mouseDown(point, screen: screen) }
            view.onDrag = { [weak self] point in self?.mouseDragged(point) }
            view.onUp = { [weak self] point in self?.mouseUp(point) }
            view.onMove = { [weak self] point in self?.mouseMoved(point, screen: screen) }
            view.onCancel = { [weak self] in self?.cancel() }
            hosts.insert(host, for: screen.id)
            host.present()
            host.panel?.level = .popUpMenu
            host.panel?.makeFirstResponder(view)
        }
        if let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            hosts[screen.id]?.panel?.makeKey()
        }
    }

    var presentedWindowIDs: Set<CGWindowID> { hosts.windowIDs }

    func deliverCandidates(_ candidates: [WindowCandidate]) {
        guard finished == nil else { return }
        self.candidates = candidates
        candidatesReady = true
        if let deferred = deferredClick {
            deferredClick = nil
            finishClick(deferred.point, screen: deferred.screen)
            return
        }
        if selectedScreen == nil, let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            mouseMoved(NSEvent.mouseLocation, screen: screen)
        }
        refreshInstruction()
    }

    func deliverSnapshot(_ capture: CapturedImage) {
        guard finished == nil else { return }
        snapshots[capture.displayID] = capture
        hosts[capture.displayID]?.setSnapshot(capture.image)
        if let deferred = deferredRegion, deferred.screen.id == capture.displayID {
            deferredRegion = nil
            complete(.region(capture, deferred.rect, deferred.screen), rect: deferred.rect, screen: deferred.screen)
            return
        }
        refreshInstruction()
    }

    func selectRegion(screens: [CaptureScreen], candidates: [WindowCandidate],
                      selectionAppearance: CaptureSelectionAppearance = .standard) async -> CaptureSelection? {
        guard !screens.isEmpty else { return nil }
        beginSelection(screens: screens, windowMode: false, selectionAppearance: selectionAppearance)
        deliverCandidates(candidates)
        return await waitForSelection()
    }

    func selectWindow(screens: [CaptureScreen], candidates: [WindowCandidate],
                      selectionAppearance: CaptureSelectionAppearance = .standard) async -> CaptureSelection? {
        guard !screens.isEmpty else { return nil }
        beginSelection(screens: screens, windowMode: true, selectionAppearance: selectionAppearance)
        deliverCandidates(candidates)
        return await waitForSelection()
    }

    func waitForSelection() async -> CaptureSelection? {
        if let finished { return finished }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// This is the only ownership transfer. Workflow defer/cancel can now close all
    /// remaining hosts without touching the selected panel or its frozen bitmap.
    func takeSelectedHost() -> InlineCaptureHost? {
        guard let completedScreen else { return nil }
        self.completedScreen = nil
        return hosts.take(completedScreen)
    }

    func cancel() {
        let pending = waiter
        waiter = nil
        finished = .some(nil)
        hosts.close()
        resetSelection()
        pending?.resume(returning: nil)
    }

    private func mouseDown(_ point: CGPoint, screen: CaptureScreen) {
        guard selectedScreen == nil, finished == nil else { return }
        mouseMoved(point, screen: screen)
        selectedScreen = screen.id
        gesture = CaptureSelectionGesture(start: point, window: hovered)
        hosts.retainOnly(screen.id)
    }

    private func mouseDragged(_ point: CGPoint) {
        guard !isWindowMode, var gesture, let id = selectedScreen,
              let screen = screens.first(where: { $0.id == id }) else { return }
        gesture.move(to: point)
        self.gesture = gesture
        guard gesture.didDrag else { return }
        selection = DisplayGeometry.selection(from: gesture.start, to: point, in: screen.frame)
        guard let selection, let view = hosts[id]?.rootView else { return }
        view.isHoverHighlight = false
        view.selection = selection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        if let capture = snapshots[id],
           let pixels = DisplayGeometry.pixelRect(for: selection, screenFrame: screen.frame,
                                                  imageWidth: capture.image.width, imageHeight: capture.image.height) {
            view.instruction = "\(Int(pixels.width)) × \(Int(pixels.height)) 像素 · 不跨屏拼接 · Esc 取消"
        } else {
            view.instruction = "正在冻结画面…"
        }
    }

    private func mouseUp(_ point: CGPoint) {
        guard let id = selectedScreen, let screen = screens.first(where: { $0.id == id }), gesture != nil else { return }
        if !isWindowMode { mouseDragged(point) }
        if gesture?.didDrag == true {
            guard let selection, selection.width > 0, selection.height > 0 else { resetGesture(); return }
            if let capture = snapshots[id] {
                complete(.region(capture, selection, screen), rect: selection, screen: screen)
            } else {
                deferredRegion = (selection, screen)
                hosts[id]?.rootView?.instruction = "正在冻结画面…"
            }
        } else if !candidatesReady {
            deferredClick = (point, screen)
            hosts[id]?.rootView?.instruction = "正在识别窗口…"
        } else {
            finishClick(point, screen: screen)
        }
    }

    private func finishClick(_ point: CGPoint, screen: CaptureScreen) {
        let quartz = DisplayGeometry.quartzPoint(point, screenFrame: screen.frame, displayBounds: screen.quartzBounds)
        if let candidate = WindowSelectionService.hit(at: quartz, candidates: candidates) {
            let rect = DisplayGeometry.appKitRect(candidate.bounds, screenFrame: screen.frame, displayBounds: screen.quartzBounds)
            complete(.window(candidate, screen), rect: rect, screen: screen)
        } else {
            resetGesture()
        }
    }

    private func mouseMoved(_ point: CGPoint, screen: CaptureScreen) {
        guard selectedScreen == nil, finished == nil else { return }
        let quartz = DisplayGeometry.quartzPoint(point, screenFrame: screen.frame, displayBounds: screen.quartzBounds)
        hovered = WindowSelectionService.hit(at: quartz, candidates: candidates)
        let highlight = hovered.map {
            DisplayGeometry.appKitRect($0.bounds, screenFrame: screen.frame, displayBounds: screen.quartzBounds)
        }
        for item in screens {
            let rect = highlight.flatMap { DisplayGeometry.overlayRect(for: $0, in: item.frame) }
            let view = hosts[item.id]?.rootView
            view?.selection = rect
            view?.isHoverHighlight = rect != nil
        }
    }

    private func complete(_ result: CaptureSelection, rect: CGRect, screen: CaptureScreen) {
        guard finished == nil, let host = hosts[screen.id] else { return }
        host.lockSelection(rect)
        hosts.retainOnly(screen.id)
        completedScreen = screen.id
        finished = .some(result)
        let pending = waiter
        waiter = nil
        pending?.resume(returning: result)
    }

    private func resetSelection() {
        snapshots.removeAll()
        candidates.removeAll()
        candidatesReady = false
        hovered = nil
        selectedScreen = nil
        gesture = nil
        selection = nil
        deferredClick = nil
        deferredRegion = nil
        completedScreen = nil
        screens.removeAll()
    }

    private func resetGesture() {
        selectedScreen = nil
        gesture = nil
        selection = nil
        refreshInstruction()
    }

    private func refreshInstruction() {
        guard deferredRegion == nil, deferredClick == nil, selectedScreen == nil, finished == nil else { return }
        let ready = isWindowMode ? "单击截取普通窗口 · Esc 取消" : "拖动选择区域 · 单击截取窗口 · Esc 取消"
        for screen in screens {
            let preparing = snapshots[screen.id] == nil && !candidatesReady
            hosts[screen.id]?.rootView?.instruction = preparing ? "正在准备截图…" : ready
        }
    }
}
