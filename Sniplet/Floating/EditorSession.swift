import AppKit
import Observation

nonisolated enum EditorPhase: Sendable {
    case editing, exporting, finalized, closed
}

nonisolated enum EditorOutput: Sendable {
    case copyImage, save, pin, finish
}

struct EditorServices {
    let renderer: ImageRenderer
    let encoder: ImageEncoder
    let ocr: OCRService
    let files: FileExportService
    let pin: (RenderedCapture) -> Void
    var isOCREnabled: () -> Bool = { true }
    let shouldStoreHistory: () -> Bool
    let persist: (RenderedCapture, Data) async throws -> Void
    var saveDefaultStyle: (CaptureStyle) -> Void = { _ in }
}

@Observable
final class EditorSession {
    let id: UUID
    private(set) var phase: EditorPhase
    private(set) var isTerminating = false
    private(set) var editor: AnnotationEditor?
    private(set) var finalCapture: RenderedCapture?
    private(set) var outputError: String?
    private(set) var historyError: String?
    private(set) var isRecognizing = false
    private(set) var ocrResult: OCRResult?
    private(set) var ocrError: String?
    private(set) var historyStored = false
    var onClose: (() -> Void)?
    var onPromiseFailure: ((EncodedCapture, String, Bool) -> Void)?
    var onFinishAttempt: ((Bool) -> Void)?

    private let services: EditorServices
    private var cachedCapture: RenderedCapture?
    private var cachedPNG: Data?
    private var pngKey: CaptureRevision?
    private var exportKey: CaptureRevision?
    private var exportID: UUID?
    private var exportOrigin: EditorPhase = .editing
    private var ocrKey: CaptureRevision?
    private var ocrTicket: OCRTicket?
    private var operationTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?

    init(capture: CapturedImage, captureStyle: CaptureStyle = .plain,
         regionSelection: CaptureRegionSelection? = nil, services: EditorServices) {
        id = capture.id
        editor = AnnotationEditor(capture: capture, captureStyle: captureStyle, regionSelection: regionSelection)
        phase = .editing
        self.services = services
        editor?.revisionHandler = { [weak self] _ in self?.documentDidChange() }
    }

    init(finalCapture: RenderedCapture, pngData: Data, error: String?,
         historyStored: Bool, services: EditorServices) {
        id = finalCapture.id
        phase = .finalized
        self.finalCapture = finalCapture
        cachedCapture = finalCapture
        cachedPNG = pngData
        pngKey = CaptureRevision(finalCapture)
        outputError = error
        self.historyStored = historyStored
        self.services = services
    }

    var currentKey: CaptureRevision? {
        if let editor { return CaptureRevision(id: id, revision: editor.document.revision) }
        return finalCapture.map(CaptureRevision.init)
    }

    var isBusy: Bool { phase != .closed && (isTerminating || phase == .exporting || operationTask != nil) }
    var canOutput: Bool { !isTerminating && (phase == .editing || phase == .finalized) }
    var isOCREnabled: Bool { services.isOCREnabled() }

    /// Saves the current capture's normalized style for future captures (not history edits).
    func saveDefaultCaptureStyle() {
        guard let style = editor?.document.captureStyle.normalized else { return }
        services.saveDefaultStyle(style)
    }
    var keepsHistory: Bool { services.shouldStoreHistory() }
    var imageSize: CGSize {
        if let document = editor?.document {
            return document.captureStyle.geometry(imageSize: document.imageBounds.size,
                                                   sourceScale: document.capture.sourceScale).presentationBounds.size
        }
        guard let image = finalCapture?.image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    func setTerminationRequested(_ requested: Bool) {
        isTerminating = requested
        editor?.isInteractionEnabled = !requested && phase == .editing
        if requested { invalidateOCR() }
    }

    private func documentDidChange() {
        guard let key = currentKey else { return }
        if cachedCapture.map(CaptureRevision.init) != key {
            cachedCapture = nil
            cachedPNG = nil
        }
        if ocrKey != key { invalidateOCR() }
    }

    /// Freezes a complete edit transaction before any asynchronous output work.
    func beginExport() throws -> AnnotationDocument? {
        guard canOutput else { throw CancellationError() }
        editor?.commitTextEditing()
        editor?.isInteractionEnabled = false
        guard let key = currentKey else { throw CancellationError() }
        exportOrigin = phase
        exportKey = key
        exportID = UUID()
        phase = .exporting
        outputError = nil
        invalidateOCR()
        return editor?.document
    }

    func accepts(_ key: CaptureRevision) -> Bool {
        phase == .exporting && exportKey == key && currentKey == key
    }

    @discardableResult
    func acceptRendered(_ capture: RenderedCapture) -> Bool {
        guard accepts(CaptureRevision(capture)) else { return false }
        cachedCapture = capture
        return true
    }

    func cancelExport() {
        guard phase == .exporting else { return }
        phase = exportOrigin
        exportKey = nil
        exportID = nil
        editor?.isInteractionEnabled = !isTerminating && phase == .editing
    }

    /// The only transition which discards the editable original and undo chain.
    func stageFinal(_ capture: RenderedCapture, pngData: Data?) {
        guard accepts(CaptureRevision(capture)) else { return }
        editor?.invalidate()
        editor = nil
        finalCapture = capture
        cachedCapture = capture
        if let pngData {
            cachedPNG = pngData
            pngKey = CaptureRevision(capture)
        }
        phase = .finalized
        exportKey = nil
        exportID = nil
    }

    func output(_ action: EditorOutput) {
        guard operationTask == nil, canOutput else { return }
        let document: AnnotationDocument?
        do { document = try beginExport() }
        catch { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                let capture = try await self.renderFrozen(document)
                let needsPNG = action == .copyImage || action == .save || self.services.shouldStoreHistory()
                let png = needsPNG ? try await self.png(for: capture) : nil
                guard self.accepts(CaptureRevision(capture)) else { return }
                switch action {
                case .copyImage:
                    try ClipboardService().copyImage(pngData: png!)
                case .save:
                    guard try await self.services.files.save(pngData: png!, createdAt: capture.createdAt) else {
                        self.cancelExport()
                        self.completeFinishAttempt(false)
                        return
                    }
                case .pin:
                    self.services.pin(capture)
                case .finish:
                    break
                }
                guard self.accepts(CaptureRevision(capture)) else { return }
                self.stageFinal(capture, pngData: png)
                await self.persistAndClose()
            } catch {
                guard self.phase != .closed else { return }
                self.cancelExport()
                if !(error is CancellationError) { self.outputError = error.localizedDescription }
                self.completeFinishAttempt(false)
            }
        }
    }

    func prepareDrag() async throws -> EncodedCapture {
        try Task.checkCancellation()
        let document = try beginExport()
        let requestID = exportID
        do {
            let capture = try await renderFrozen(document)
            let png = try await png(for: capture)
            let tiff = try await services.encoder.tiff(capture.image)
            try Task.checkCancellation()
            guard exportID == requestID, accepts(CaptureRevision(capture)) else { throw CancellationError() }
            return EncodedCapture(capture: capture, pngData: png, tiffData: tiff)
        } catch {
            // A cancelled older drag must not cancel a newer export of the same revision.
            if exportID == requestID {
                cancelExport()
                if !(error is CancellationError) { outputError = error.localizedDescription }
            }
            throw error
        }
    }

    func dragAccepted() {
        guard let capture = cachedCapture, accepts(CaptureRevision(capture)), operationTask == nil else { return }
        stageFinal(capture, pngData: cachedPNG)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            await self.persistAndClose()
        }
    }

    func dragCancelled() { cancelExport() }

    func dragPreparationFailed(_ message: String) {
        cancelExport()
        outputError = message
    }

    func promiseFailed(_ capture: EncodedCapture, message: String) {
        // A file promise can fail after this session has closed. Recovery uses
        // only the immutable final snapshot, never the released editor.
        onPromiseFailure?(capture, message, historyStored)
    }

    func retryHistory() {
        guard phase == .finalized, !isTerminating, operationTask == nil else { return }
        guard services.shouldStoreHistory() else {
            historyError = "历史保存已关闭，请先在设置中开启再重试。"
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            await self.persistAndClose()
        }
    }

    private func renderFrozen(_ document: AnnotationDocument?) async throws -> RenderedCapture {
        if let capture = cachedCapture, accepts(CaptureRevision(capture)) { return capture }
        guard let document else { throw CancellationError() }
        let capture = try await services.renderer.render(document)
        try Task.checkCancellation()
        guard acceptRendered(capture) else { throw CancellationError() }
        return capture
    }

    private func png(for capture: RenderedCapture) async throws -> Data {
        if let cachedPNG, pngKey == CaptureRevision(capture) { return cachedPNG }
        let data = try await services.encoder.png(capture.image)
        try Task.checkCancellation()
        guard currentKey == CaptureRevision(capture), phase != .closed else { throw CancellationError() }
        cachedPNG = data
        pngKey = CaptureRevision(capture)
        return data
    }

    private func persistAndClose() async {
        guard phase == .finalized, let capture = finalCapture else { return }
        if services.shouldStoreHistory() && !historyStored {
            do {
                let data = try await png(for: capture)
                try await services.persist(capture, data)
                guard phase != .closed else { return }
                historyStored = true
                historyError = nil
            } catch {
                guard phase != .closed else { return }
                historyError = "图片已完成，历史保存失败：" + error.localizedDescription
                completeFinishAttempt(false)
                return
            }
        }
        if outputError == nil {
            completeFinishAttempt(true)
            discard()
        } else {
            completeFinishAttempt(false)
        }
    }

    private func completeFinishAttempt(_ succeeded: Bool) {
        let completion = onFinishAttempt
        onFinishAttempt = nil
        completion?(succeeded)
    }

    func beginOCR() -> OCRTicket? {
        guard canOutput, !isRecognizing else { return nil }
        guard services.isOCREnabled() else {
            ocrError = "文字识别已在设置中关闭。"
            return nil
        }
        editor?.commitTextEditing()
        guard let key = currentKey else { return nil }
        let ticket = OCRTicket(capture: key)
        isRecognizing = true
        ocrError = nil
        ocrResult = nil
        ocrKey = key
        ocrTicket = ticket
        return ticket
    }

    func copyRecognizedText() {
        let previousKey = ocrKey
        let previousResult = ocrResult
        guard let ticket = beginOCR() else { return }
        if previousKey == ticket.capture, let previousResult {
            guard acceptOCR(previousResult, for: ticket) else { return }
            ocrTicket = nil
            copyOCRIfNonempty(previousResult)
            return
        }
        ocrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.ocrTicket == ticket {
                    self.isRecognizing = false
                    self.ocrTask = nil
                    self.ocrTicket = nil
                }
            }
            do {
                // The helper's document/render frame ends before Vision begins.
                let image = try await self.imageForOCR(ticket.capture)
                let result = try await self.services.ocr.recognize(image)
                try Task.checkCancellation()
                guard self.acceptOCR(result, for: ticket) else { return }
                self.copyOCRIfNonempty(result)
            } catch {
                guard self.ocrTicket == ticket, self.currentKey == ticket.capture,
                      self.canOutput, !(error is CancellationError) else { return }
                self.ocrError = error.localizedDescription
            }
        }
    }

    private func imageForOCR(_ key: CaptureRevision) async throws -> CGImage {
        try Task.checkCancellation()
        guard currentKey == key, canOutput else { throw CancellationError() }
        if let finalCapture { return finalCapture.image }
        if let cachedCapture, CaptureRevision(cachedCapture) == key { return cachedCapture.image }
        guard let document = editor?.document else { throw CancellationError() }
        let rendered = try await services.renderer.render(document)
        try Task.checkCancellation()
        guard currentKey == key, canOutput else { throw CancellationError() }
        cachedCapture = rendered
        return rendered.image
    }

    @discardableResult
    func acceptOCR(_ result: OCRResult, for ticket: OCRTicket) -> Bool {
        guard canOutput, currentKey == ticket.capture, ocrTicket == ticket else { return false }
        ocrResult = result
        isRecognizing = false
        return true
    }

    private func copyOCRIfNonempty(_ result: OCRResult) {
        guard !result.text.isEmpty else { return }
        do { try ClipboardService().copyText(result.text) }
        catch { ocrError = error.localizedDescription }
    }

    private func invalidateOCR() {
        ocrTask?.cancel()
        ocrTask = nil
        ocrKey = nil
        ocrTicket = nil
        isRecognizing = false
        ocrResult = nil
        ocrError = nil
    }

    func discard() {
        guard phase != .closed else { return }
        phase = .closed
        completeFinishAttempt(false)
        exportKey = nil
        exportID = nil
        operationTask?.cancel()
        operationTask = nil
        invalidateOCR()
        editor?.invalidate()
        editor = nil
        cachedCapture = nil
        cachedPNG = nil
        pngKey = nil
        finalCapture = nil
        onClose?()
    }
}
