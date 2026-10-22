import AppKit

/// Permission prompts, menu scheduling and hiding existing Sniplet panels belong to the caller.
@MainActor final class CaptureWorkflowController: NSObject {
    private let service: CaptureService
    private let windows = WindowSelectionService()
    private let overlay = SelectionOverlayController()
    private var task: Task<CaptureOutcome?, Error>?
    private var sessionID: UUID?
    private var layoutChanged = false

    init(service: CaptureService) {
        self.service = service
        super.init()
    }

    /// `previousRegion` needs `regionRect`, the remembered selection in global AppKit points on `displayID`.
    /// `freezeFirst` (after a countdown) snapshots before any Sniplet window appears.
    func capture(mode: CaptureMode, displayID: CGDirectDisplayID, regionRect: CGRect? = nil,
                 freezeFirst: Bool = false,
                 selectionAppearance: CaptureSelectionAppearance) async throws -> CaptureOutcome? {
        guard task == nil else { return nil }
        let id = UUID()
        sessionID = id
        layoutChanged = false
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let operation = Task<CaptureOutcome?, Error> { [self] in
            let screens = CaptureScreen.current()
            guard !screens.isEmpty else { throw CaptureError.displayUnavailable }
            var host: InlineCaptureHost?
            var regionSelection: CaptureRegionSelection?
            var didTransfer = false
            defer { if !didTransfer { host?.close() } }
            let selects = mode == .region || mode == .window
            var frozen: [CGDirectDisplayID: CapturedImage] = [:]
            var frozenWindows: Set<CGWindowID>?
            if freezeFirst {
                // Coming forward dismisses other apps' menus and popovers, so displays are
                // captured before any Sniplet window appears; own windows are already excluded.
                frozenWindows = try await service.prepare(requiredWindowIDs: [])
                frozen = try await service.captureDisplays(selects ? screens.map(\.id) : [displayID])
                try Task.checkCancellation()
            }
            if selects {
                overlay.beginSelection(screens: screens, windowMode: mode == .window,
                                       selectionAppearance: selectionAppearance)
                for image in frozen.values { overlay.deliverSnapshot(image) }
            } else if let screen = screens.first(where: { $0.id == displayID }) {
                let feedback = InlineCaptureHost(screenFrame: screen.frame, displayID: screen.id,
                                                 selectionAppearance: selectionAppearance)
                feedback.rootView?.instruction = mode == .previousRegion ? "正在截取上次的区域…" : "正在截取当前屏幕…"
                feedback.present()
                host = feedback
            }
            await Task.yield()
            let listedWindows: Set<CGWindowID>
            if let frozenWindows {
                listedWindows = frozenWindows
            } else {
                let requiredWindows = overlay.presentedWindowIDs.union(host?.panelWindowID.map { [$0] } ?? [])
                listedWindows = try await service.prepare(requiredWindowIDs: requiredWindows)
            }
            if selects {
                overlay.deliverCandidates(WindowSelectionService.ordinaryWindows(capturableIDs: listedWindows))
            }
            let capture: CapturedImage
            let footprint: CGRect
            switch mode {
            case .fullScreen:
                guard screens.contains(where: { $0.id == displayID }) else { throw CaptureError.displayUnavailable }
                capture = try await service.captureDisplay(displayID)
                try Task.checkCancellation()
                guard let screen = screens.first(where: { $0.id == displayID }), let host else {
                    throw CaptureError.displayUnavailable
                }
                host.setSnapshot(capture.image)
                footprint = screen.frame
                guard let region = CaptureRegionSelection(source: capture, screenFrame: screen.frame,
                                                           selectionRect: screen.frame) else { throw CaptureError.cropFailed }
                regionSelection = region
            case .previousRegion:
                guard let regionRect, let screen = screens.first(where: { $0.id == displayID }),
                      screen.frame.insetBy(dx: -1, dy: -1).contains(regionRect), let host else { throw CaptureError.displayUnavailable }
                let snapshot: CapturedImage
                if let image = frozen[displayID] { snapshot = image }
                else { snapshot = try await service.captureDisplay(displayID) }
                try Task.checkCancellation()
                host.setSnapshot(snapshot.image)
                guard let region = CaptureRegionSelection(source: snapshot, screenFrame: screen.frame,
                                                           selectionRect: regionRect) else { throw CaptureError.cropFailed }
                regionSelection = region
                footprint = region.screenRect
                capture = try region.croppedCapture()
            case .region, .window:
                let primary: CapturedImage
                if let image = frozen[displayID] { primary = image }
                else { primary = try await service.captureDisplay(displayID) }
                overlay.deliverSnapshot(primary)
                let others = screens.map(\.id).filter { $0 != displayID && frozen[$0] == nil }
                let remaining = Task { [overlay, service, frozen] in
                    let images = try await service.captureDisplays(others)
                    for image in images.values { overlay.deliverSnapshot(image) }
                    return images.merging(frozen) { live, _ in live }
                }
                let selection = await overlay.waitForSelection()
                guard let selection else { remaining.cancel(); return nil }
                defer { remaining.cancel() }
                host = overlay.takeSelectedHost()
                guard let selectedHost = host else { throw CancellationError() }
                selectedHost.rootView?.onCancel = { [weak self] in self?.cancel() }
                try Task.checkCancellation()
                switch selection {
                case let .region(snapshot, rect, screen):
                    guard let region = CaptureRegionSelection(source: snapshot, screenFrame: screen.frame,
                                                               selectionRect: rect) else {
                        throw CaptureError.cropFailed
                    }
                    regionSelection = region
                    footprint = region.screenRect
                    capture = try region.croppedCapture()
                case let .window(candidate, screen):
                    if selectedHost.rootView?.hasSnapshot != true {
                        let backdrop = screen.id == displayID ? primary : try await remaining.value[screen.id]
                        if let backdrop {
                            selectedHost.setSnapshot(backdrop.image)
                        } else {
                            selectedHost.setSnapshot((try await service.captureDisplay(screen.id)).image)
                        }
                    }
                    remaining.cancel()
                    let captured = try await service.captureWindow(candidate.id)
                    footprint = DisplayGeometry.appKitRect(captured.bounds, screenFrame: screen.frame,
                                                           displayBounds: screen.quartzBounds)
                    capture = captured.image
                    guard let region = CaptureRegionSelection(source: capture, screenFrame: footprint,
                                                               selectionRect: footprint) else { throw CaptureError.cropFailed }
                    regionSelection = region
                }
            }
            try Task.checkCancellation()
            guard let host else { throw CancellationError() }
            host.lockSelection(footprint)
            didTransfer = true
            return CaptureOutcome(capture: capture, screenRect: footprint, host: host, regionSelection: regionSelection)
        }
        task = operation
        defer {
            NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            overlay.cancel()
            task = nil
            sessionID = nil
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
                Task { @MainActor [weak self] in
                    guard self?.sessionID == id else { return }
                    self?.overlay.cancel()
                }
            }
            if layoutChanged {
                result?.host.close()
                throw CaptureError.displayUnavailable
            }
            guard sessionID == id, !operation.isCancelled, !Task.isCancelled else {
                result?.host.close()
                return nil
            }
            return result
        } catch {
            if layoutChanged { throw CaptureError.displayUnavailable }
            if operation.isCancelled || Task.isCancelled || error is CancellationError { return nil }
            throw error
        }
    }

    func cancel() {
        task?.cancel()
        overlay.cancel()
    }

    @objc private func screenParametersChanged() {
        guard task != nil else { return }
        layoutChanged = true
        cancel()
    }
}
