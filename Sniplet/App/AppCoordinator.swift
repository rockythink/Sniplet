import AppKit
import Observation

@Observable
final class AppCoordinator {
    let permissions = CapturePermissionStore()
    let preferences = AppPreferences()
    private(set) var isCapturing = false
    private(set) var historyStore: HistoryStore?
    private(set) var historyIndexer: HistoryIndexer?
    private(set) var historyLoading = false
    private(set) var historyError: String?
    private(set) var historyRecoveryMessages: [String] = []
    private(set) var pinCount = 0

    @ObservationIgnored lazy var shortcuts = GlobalHotKeyManager { [weak self] mode in
        self?.requestCapture(mode)
    }
    @ObservationIgnored private lazy var captureWorkflow = CaptureWorkflowController(service: captureService)
    private let captureService = CaptureService()
    private let renderer = ImageRenderer()
    private let encoder = ImageEncoder()
    private let ocr = OCRService()
    private let files = FileExportService()
    private let pins = PinnedImageController()
    private var editor: InlineEditorController?
    private var historyWindow: HistoryWindowController?
    private var recoveryPanels: [UUID: InlineEditorController] = [:]
    private var captureTask: Task<Void, Never>?
    private var historyInitializationTask: Task<Void, Never>?
    private var historyOutputTask: Task<Void, Never>?
    private var historyMaintenanceTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var initializationID: UUID?
    private var requestID: UUID?
    private var pendingCapture: CaptureRequest?
    private var trackingMenus: [ObjectIdentifier: NSMenu] = [:]
    private var previousApplication: NSRunningApplication?
    private var started = false
    private var quitting = false

    private struct CaptureRequest {
        let id = UUID()
        let mode: CaptureMode
        let displayID: CGDirectDisplayID
        var regionRect: CGRect?
    }

    var canCapture: Bool { !isCapturing && editor?.session.isBusy != true && !quitting }
    var hasPreviousRegion: Bool { preferences.lastCaptureRegion != nil }

    func start() {
        guard !started, !AppRuntime.isUnitTesting else { return }
        started = true
        pins.onCountChange = { [weak self] count in self?.pinCount = count }
        permissions.refresh()
        shortcuts.registerSavedShortcuts()
        initializeHistory()
        DispatchQueue.main.async { [weak self] in self?.showFirstLaunchGuidance() }
    }

    func menuBeganTracking(_ menu: NSMenu) {
        trackingMenus[ObjectIdentifier(menu)] = menu
    }

    func menuEndedTracking(_ menu: NSMenu) {
        trackingMenus.removeValue(forKey: ObjectIdentifier(menu))
        startPendingCapture()
    }

    func requestCapture(_ mode: CaptureMode) {
        guard canCapture else { return }
        // A remembered region on a display that is gone or rearranged falls back to a fresh selection.
        if mode == .previousRegion, let rect = preferences.lastCaptureRegion?.rect,
           let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(rect) }),
           let displayID = Self.displayID(for: screen) {
            begin(CaptureRequest(mode: mode, displayID: displayID, regionRect: rect))
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              let displayID = Self.displayID(for: screen) else {
            showError(CaptureError.displayUnavailable.localizedDescription)
            return
        }
        begin(CaptureRequest(mode: mode == .previousRegion ? .region : mode, displayID: displayID))
    }

    private func begin(_ request: CaptureRequest) {
        previousApplication = NSWorkspace.shared.frontmostApplication
        pendingCapture = request
        isCapturing = true
        // Do not depend on duplicate begin notifications balancing a counter.
        // Explicitly finish tracked native menus, then sample in the next turn.
        for menu in trackingMenus.values { menu.cancelTrackingWithoutAnimation() }
        DispatchQueue.main.async { [weak self] in self?.startPendingCapture() }
    }

    private func startPendingCapture() {
        guard trackingMenus.isEmpty, captureTask == nil, let request = pendingCapture else { return }
        if let panel = editor {
            guard !panel.session.isBusy else { return }
            let alert = NSAlert()
            alert.messageText = "已有一张尚未关闭的截图"
            alert.informativeText = panel.session.phase == .finalized
                ? "最终图像有未处理的输出或历史状态。可以先关闭该预览再截图，或取消本次截图。"
                : "可以完成当前截图后继续，也可以明确丢弃。历史关闭时，完成后未另行输出的图像不会保留。"
            if panel.session.phase == .finalized {
                alert.addButton(withTitle: "关闭并继续")
                alert.addButton(withTitle: "取消")
                if alert.runForSniplet() == .alertFirstButtonReturn {
                    guard panel.session.historyStored || panel.confirmDiscard() else {
                        cancelPendingCapture()
                        return
                    }
                    panel.session.discard()
                } else { cancelPendingCapture(); return }
            } else {
                alert.addButton(withTitle: "完成并继续")
                alert.addButton(withTitle: "丢弃并继续")
                alert.addButton(withTitle: "取消")
                switch alert.runForSniplet() {
                case .alertFirstButtonReturn:
                    panel.session.onFinishAttempt = { [weak self] succeeded in
                        guard let self, self.pendingCapture?.id == request.id else { return }
                        if !succeeded { self.cancelPendingCapture() }
                    }
                    panel.session.output(.finish)
                    return
                case .alertSecondButtonReturn:
                    panel.session.discard()
                default:
                    cancelPendingCapture()
                    return
                }
            }
        }
        guard pendingCapture?.id == request.id, editor == nil else { return }
        pendingCapture = nil
        requestID = request.id
        guard permissions.authorizeForCapture(), requestID == request.id else {
            endCapture(request.id)
            return
        }
        // Do not hide the app here. Hiding delays the first visible overlay by a full
        // deactivate/activate cycle; ScreenCaptureKit excludes Sniplet's own windows instead.
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let outcome = try await self.captureWorkflow.capture(mode: request.mode,
                    displayID: request.displayID, regionRect: request.regionRect,
                    selectionAppearance: self.preferences.selectionAppearance) else {
                    self.endCapture(request.id)
                    return
                }
                var adopted = false
                defer { if !adopted { outcome.host.close() } }
                guard !Task.isCancelled, self.requestID == request.id else { return }
                let capture = outcome.capture
                let presentationID = outcome.host.displayID ?? capture.displayID
                guard let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == presentationID }) else {
                    throw CaptureError.displayUnavailable
                }
                self.endCapture(request.id)
                self.present(EditorSession(capture: capture, captureStyle: self.preferences.defaultCaptureStyle,
                                           regionSelection: outcome.regionSelection, services: self.editorServices),
                             on: screen, sourceRect: outcome.screenRect, host: outcome.host)
                adopted = true
                if capture.mode == .region, let region = outcome.regionSelection {
                    self.preferences.lastCaptureRegion = CaptureRegionMemory(rect: region.screenRect)
                    self.editor?.onRegionChange = { [weak self] rect in
                        self?.preferences.lastCaptureRegion = CaptureRegionMemory(rect: rect)
                    }
                }
            } catch {
                guard self.requestID == request.id else { return }
                self.endCapture(request.id)
                if error is CancellationError { return }
                self.permissions.refresh()
                self.showError(self.permissions.isAvailable ? error.localizedDescription : CaptureError.permissionUnavailable.localizedDescription)
            }
        }
    }

    private func cancelPendingCapture() {
        pendingCapture = nil
        isCapturing = false
    }

    private func endCapture(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        captureTask = nil
        isCapturing = false
        NSApp.unhideWithoutActivation()
    }

    func displayLayoutChanged() {
        let hadCapture = isCapturing
        cancelPendingCapture()
        requestID = nil
        captureTask?.cancel()
        captureTask = nil
        captureWorkflow.cancel()
        if hadCapture { showError("显示器布局已改变，本次截图已取消，请重试。") }
    }

    /// Recovery panels share these services, so match the panel that owns this capture.
    private func pinAnchor(for capture: RenderedCapture) -> CGRect? {
        let panels = [editor].compactMap { $0 } + Array(recoveryPanels.values)
        return panels.first { $0.session.id == capture.id }?.pinAnchorRect
    }

    private var editorServices: EditorServices {
        EditorServices(renderer: renderer, encoder: encoder, ocr: ocr, files: files,
                       pin: { [weak self] capture in self?.pins.pin(capture, at: self?.pinAnchor(for: capture)) },
                       isOCREnabled: { [weak self] in self?.preferences.ocrEnabled == true },
                       shouldStoreHistory: { [weak self] in self?.preferences.historyEnabled == true },
                       persist: { [weak self] capture, png in
                           guard let self else { throw CancellationError() }
                           guard self.preferences.historyEnabled else { return }
                           guard let store = self.historyStore else { throw AppError.historyUnavailable }
                           try await store.insert(capture, pngData: png)
                       }, saveDefaultStyle: { [weak self] style in
                           self?.preferences.defaultCaptureStyle = style
                       })
    }

    private func present(_ session: EditorSession, on screen: NSScreen, sourceRect: CGRect,
                         host: InlineCaptureHost? = nil, recovery: Bool = false) {
        if quitting { session.setTerminationRequested(true) }
        let panel = InlineEditorController(session: session, preferences: preferences, screen: screen,
                                          sourceRect: sourceRect, host: host)
        let previous = previousApplication
        panel.onClose = { [weak self, weak panel] in
            guard let self else { return }
            if self.editor === panel { self.editor = nil }
            if self.recoveryPanels[session.id] === panel { self.recoveryPanels.removeValue(forKey: session.id) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previous?.activate(options: [])
            }
            if self.pendingCapture != nil {
                DispatchQueue.main.async { [weak self] in self?.startPendingCapture() }
            }
        }
        session.onPromiseFailure = { [weak self] capture, message, stored in
            self?.recoverPromise(capture, message: message, historyStored: stored)
        }
        if recovery { recoveryPanels[session.id] = panel }
        else { editor = panel }
        panel.present()
    }

    private func recoverPromise(_ encoded: EncodedCapture, message: String, historyStored: Bool) {
        if let existing = recoveryPanels[encoded.capture.id] { existing.present(); return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first else { return }
        let session = EditorSession(finalCapture: encoded.capture, pngData: encoded.pngData,
                                    error: "拖出文件写入失败：" + message,
                                    historyStored: historyStored, services: editorServices)
        let size = CGSize(width: CGFloat(encoded.capture.image.width) / encoded.capture.sourceScale,
                          height: CGFloat(encoded.capture.image.height) / encoded.capture.sourceScale)
        let visible = screen.visibleFrame
        let fit = min(1, max(1, visible.width - 96) / size.width,
                      max(1, visible.height - 128) / size.height)
        let frame = CGRect(x: visible.midX - size.width * fit / 2,
                           y: visible.midY - size.height * fit / 2,
                           width: size.width * fit, height: size.height * fit)
        present(session, on: screen, sourceRect: frame, recovery: true)
    }

    func initializeHistory() {
        historyInitializationTask?.cancel()
        historyIndexer?.stop()
        let id = UUID()
        initializationID = id
        historyLoading = true
        historyError = nil
        historyInitializationTask = Task { [weak self] in
            do {
                let root = try await Self.historyRootURL()
                let store = try await HistoryStoreFactory.make(rootURL: root, limits: HistoryLimits(maxCount: 500, maxBytes: 1_073_741_824))
                try Task.checkCancellation()
                guard let self, self.initializationID == id else { return }
                self.historyStore = store
                let indexer = HistoryIndexer(store: store, ocr: self.ocr)
                self.historyIndexer = indexer
                let status = await store.status()
                self.historyRecoveryMessages = status.recoveryMessages
                self.historyError = status.cleanupError
                self.historyLoading = false
                self.historyInitializationTask = nil
                if self.preferences.historyEnabled { indexer.start() }
            } catch {
                guard let self, self.initializationID == id, !(error is CancellationError) else { return }
                self.historyLoading = false
                self.historyInitializationTask = nil
                self.historyError = "历史不可用，现有文件已保留：" + error.localizedDescription
            }
        }
    }

    @concurrent
    private static func historyRootURL() async throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent("Sniplet/History", isDirectory: true)
    }

    func showHistory() {
        if historyWindow == nil {
            let controller = HistoryWindowController(coordinator: self)
            controller.onClose = { [weak self] in self?.historyWindow = nil }
            historyWindow = controller
        }
        historyWindow?.present()
    }

    func retryHistoryCleanup() {
        guard let store = historyStore, historyMaintenanceTask == nil else { return }
        historyIndexer?.stop()
        historyMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.historyMaintenanceTask = nil
                if self.preferences.historyEnabled && self.preferences.ocrEnabled { self.historyIndexer?.start() }
            }
            do {
                try await store.retryCleanup()
                let status = await store.status()
                self.historyError = status.cleanupError
                self.historyRecoveryMessages = status.recoveryMessages
            } catch { self.historyError = error.localizedDescription }
        }
    }

    func historyPreferenceChanged() {
        if preferences.historyEnabled && preferences.ocrEnabled { historyIndexer?.start() }
        else { historyIndexer?.stop() }
    }

    func clearHistory() {
        guard let store = historyStore, historyMaintenanceTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "清空所有本地截图历史？"
        alert.informativeText = "删除历史记录、最终 PNG 和缩略图。已经钉在屏幕上的图像需另行关闭。此操作不可撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空历史")
        guard alert.runForSniplet() == .alertSecondButtonReturn else { return }
        historyIndexer?.stop()
        historyMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.historyMaintenanceTask = nil
                if self.preferences.historyEnabled && self.preferences.ocrEnabled { self.historyIndexer?.start() }
            }
            do { try await store.clear(); self.historyError = nil }
            catch { self.historyError = error.localizedDescription }
        }
    }

    func outputHistory(_ id: UUID, action: EditorOutput) {
        guard historyOutputTask == nil, let store = historyStore else { return }
        historyOutputTask = Task { [weak self] in
            guard let self else { return }
            defer { self.historyOutputTask = nil }
            do {
                switch action {
                case .copyImage:
                    try ClipboardService().copyImage(pngData: await store.pngData(for: id))
                case .save:
                    let rows = try await store.summaries(matching: "")
                    guard let row = rows.first(where: { $0.id == id }) else { throw AppError.historyUnavailable }
                    let data = try await store.pngData(for: id)
                    _ = try await self.files.save(pngData: data, createdAt: row.createdAt)
                case .pin:
                    self.pins.pin(try await store.loadImage(id))
                case .finish:
                    break
                }
            } catch { self.showError(error.localizedDescription) }
        }
    }

    func requestTermination(reply: @escaping (Bool) -> Void) {
        guard !quitting else { reply(false); return }
        if editor?.session.isBusy == true || recoveryPanels.values.contains(where: { $0.session.isBusy })
            || historyOutputTask != nil || historyMaintenanceTask != nil {
            reply(false)
            return
        }
        if let panel = editor, panel.session.phase == .editing {
            let alert = NSAlert()
            alert.messageText = "退出前如何处理当前截图？"
            alert.informativeText = preferences.historyEnabled ? "完成后保存最终图像到本地历史；也可以明确丢弃。" : "历史已关闭，退出后不会保留未另行输出的截图。"
            alert.addButton(withTitle: "完成并退出")
            alert.addButton(withTitle: "丢弃并退出")
            alert.addButton(withTitle: "取消")
            switch alert.runForSniplet() {
            case .alertFirstButtonReturn:
                panel.session.onFinishAttempt = { [weak self] succeeded in
                    if succeeded { self?.finishTermination(reply: reply) }
                    else { reply(false) }
                }
                panel.session.output(.finish)
                return
            case .alertSecondButtonReturn:
                panel.session.discard()
            default:
                reply(false)
                return
            }
        }
        finishTermination(reply: reply)
    }

    private func finishTermination(reply: @escaping (Bool) -> Void) {
        quitting = true
        cancelPendingCapture()
        requestID = nil
        captureTask?.cancel()
        captureWorkflow.cancel()
        editor?.session.setTerminationRequested(true)
        for panel in recoveryPanels.values { panel.session.setTerminationRequested(true) }
        quitTask = Task { [weak self] in
            await PromiseWriteTracker.shared.waitForPendingWrites()
            guard let self else { reply(false); return }
            let unsaved = ([self.editor].compactMap { $0 } + Array(self.recoveryPanels.values))
                .filter { $0.session.phase == .finalized && !$0.session.historyStored }
            if !unsaved.isEmpty {
                let alert = NSAlert()
                alert.messageText = "还有 \(unsaved.count) 张最终图像尚未保存历史"
                alert.informativeText = "退出后这些只读预览将无法恢复。可以取消退出，返回预览复制、另存或重试历史保存。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "丢弃并退出")
                if alert.runForSniplet() != .alertSecondButtonReturn {
                    self.quitting = false
                    self.editor?.session.setTerminationRequested(false)
                    for panel in self.recoveryPanels.values { panel.session.setTerminationRequested(false) }
                    self.quitTask = nil
                    reply(false)
                    return
                }
            }
            self.historyInitializationTask?.cancel()
            self.historyIndexer?.stop()
            self.shortcuts.unregisterAll()
            self.editor?.session.discard()
            for panel in Array(self.recoveryPanels.values) { panel.session.discard() }
            self.pins.closeAll()
            self.historyWindow?.close()
            self.quitTask = nil
            reply(true)
        }
    }

    func closeAllPins() { pins.closeAll() }

    private func showFirstLaunchGuidance() {
        let defaults = UserDefaults.standard
        switch LaunchGuidance.next(in: defaults) {
        case .none: return
        case .whatsNew: showWhatsNew()
        case .introduction: showIntroduction()
        }
        LaunchGuidance.markShown(in: defaults)
    }

    private func showWhatsNew() {
        let alert = NSAlert()
        alert.messageText = LaunchGuidance.whatsNewTitle
        alert.informativeText = LaunchGuidance.whatsNewText
        alert.addButton(withTitle: "好的")
        alert.runForSniplet()
    }

    private func showIntroduction() {
        let alert = NSAlert()
        alert.messageText = "Sniplet 已在菜单栏就绪"
        alert.informativeText = """
            从菜单栏或按 ⇧⌘A 开始截图，在选区原位标注，再复制、保存、钉图或拖出。⌃⌥⌘4 可直接重复上次的区域。

            · 单键切换工具：V 选择、A 箭头、R 矩形、P 画笔、T 文字、N 序号、M 马赛克、H 高亮
            · 绘图工具下第一次 Esc 回到选择，再按 Esc 丢弃截图
            · 钉图可拖动、捏合缩放，Esc 关闭

            ⇧⌘A 会覆盖 Finder 的「前往应用程序」，可在设置 → 快捷键中修改。只有主动截图时才请求屏幕录制权限，图像和文字仅在本机处理。
            """
        alert.addButton(withTitle: "知道了")
        alert.runForSniplet()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Sniplet 无法完成此操作"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runForSniplet()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

nonisolated enum AppError: LocalizedError {
    case historyUnavailable
    var errorDescription: String? { "历史存储尚不可用，请保留最终预览并在存储恢复后重试。" }
}
