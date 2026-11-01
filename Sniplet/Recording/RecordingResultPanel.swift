import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// A finished recording waiting in the temporary directory until it is saved or discarded.
nonisolated struct RecordedVideo: Sendable {
    let url: URL
    let createdAt: Date
    let duration: TimeInterval

    static func format(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// What a result card borrows from the coordinator: the screenshots' ⌘S folder, the
/// auto-save switch and the status toast, so a recording finishes the way a screenshot does.
struct RecordingOutputServices {
    /// Copies the file into the ⌘S folder; asks for one only when the Bool is true.
    var quickSave: (URL, Bool) async throws -> URL?
    var autoSaves: () -> Bool
    var reportQuickSave: (Result<URL, Error>) -> Void
    var flash: (String) -> Void
}

@MainActor @Observable final class RecordingResultModel {
    var savedURL: URL?
    var isBusy = false
    var isHovered = false
}

/// A floating card in the screen corner, finished like a screenshot: Return or ⌘C copies
/// the video and closes, ⌘S saves into the ⌘S folder, Esc discards, and the preview drags
/// out. Copying or dragging out closes the card but keeps the file for its receiver.
@MainActor final class RecordingResultPanel {
    let video: RecordedVideo
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    private let services: RecordingOutputServices
    private let model = RecordingResultModel()
    private var panel: RecordingResultWindow?
    private var preview: RecordingPreviewView?
    private var saveTask: Task<Void, Never>?
    private var autoClose: Task<Void, Never>?
    private static let width: CGFloat = 360
    private static let savedNoticeDuration: Duration = .seconds(4)

    init(video: RecordedVideo, services: RecordingOutputServices) {
        self.video = video
        self.services = services
    }

    /// Several unsaved recordings stack upwards from the bottom-right corner.
    func present(on screen: NSScreen, stackIndex: Int) {
        let preview = RecordingPreviewView(url: video.url, duration: video.duration)
        preview.onDragAccepted = { [weak self] in self?.dragAccepted() }
        self.preview = preview
        let host = NSHostingView(rootView: RecordingResultView(
            video: video, model: model, preview: preview,
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.quickSave() },
            onSaveAs: { [weak self] in self?.saveAs() },
            onDiscard: { [weak self] in self?.close(discarding: true) },
            onReveal: { [weak self] in self?.revealSaved() }))
        let size = CGSize(width: Self.width, height: host.fittingSize.height)
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - size.width - 16,
                           y: min(visible.maxY - size.height, visible.minY + 16 + CGFloat(stackIndex) * (size.height + 12)),
                           width: size.width, height: size.height)
        let panel = RecordingResultWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.onCopy = { [weak self] in self?.copyAndClose() }
        panel.onSave = { [weak self] in self?.quickSave() }
        panel.onSaveAs = { [weak self] in self?.saveAs() }
        panel.onCancel = { [weak self] in self?.close(discarding: true) }
        panel.onTogglePlayback = { [weak preview] in preview?.togglePlayback() }
        panel.contentView = host
        panel.setAccessibilityLabel("录屏结果")
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Discarding deletes the file now; otherwise it already lives on elsewhere.
    func close(discarding: Bool) {
        finish { if discarding { RecordingFiles.discard(self.video.url) } }
    }

    /// The file itself goes on the pasteboard, so Finder and chat apps paste a video attachment.
    private func copyAndClose() {
        guard !model.isBusy else { return }
        let source = model.savedURL ?? video.url
        do { try ClipboardService().copyFile(source) }
        catch { onError?(error.localizedDescription); return }
        services.flash("已拷贝录屏，可以粘贴到聊天窗口或访达")
        if model.savedURL != nil {
            close(discarding: true)
            return
        }
        let changeCount = NSPasteboard.general.changeCount
        autoSaveCopy()
        finish { RecordingFiles.release(self.video.url, clipboardChangeCount: changeCount) }
    }

    private func dragAccepted() {
        if model.savedURL != nil {
            close(discarding: true)
            return
        }
        autoSaveCopy()
        finish { RecordingFiles.release(self.video.url, clipboardChangeCount: nil) }
    }

    /// The optional auto-save copy, as for screenshots: never asks for a folder.
    private func autoSaveCopy() {
        guard services.autoSaves() else { return }
        let services = services
        let source = video.url
        Task {
            do {
                if let saved = try await services.quickSave(source, false) { services.reportQuickSave(.success(saved)) }
            } catch { services.reportQuickSave(.failure(error)) }
        }
    }

    private func quickSave() {
        guard saveTask == nil, model.savedURL == nil else { return }
        model.isBusy = true
        saveTask = Task { [weak self, services, video] in
            defer { self?.model.isBusy = false; self?.saveTask = nil }
            do {
                // Nil: the one-time folder choice was dismissed, so the card simply stays.
                guard let saved = try await services.quickSave(video.url, true) else { return }
                self?.showSaved(saved)
            } catch {
                self?.onError?("存储失败，录屏仍保留在 Sniplet 中：" + error.localizedDescription)
            }
        }
    }

    private func saveAs() {
        guard saveTask == nil, model.savedURL == nil else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = video.url.lastPathComponent
        savePanel.title = "存储录屏"
        NSApp.activate(ignoringOtherApps: true)
        model.isBusy = true
        saveTask = Task { [weak self, video] in
            defer { self?.model.isBusy = false; self?.saveTask = nil }
            let response = await withCheckedContinuation { continuation in
                savePanel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                try await Self.write(video.url, to: destination)
                self?.showSaved(destination)
            } catch {
                self?.onError?("存储失败，录屏仍保留在 Sniplet 中：" + error.localizedDescription)
            }
        }
    }

    /// The card confirms where the file went, then closes itself unless the pointer rests on it.
    private func showSaved(_ url: URL) {
        model.savedURL = url
        preview?.fileURL = url
        autoClose?.cancel()
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: Self.savedNoticeDuration)
            while self?.model.isHovered == true { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            self?.close(discarding: true)
        }
    }

    private func revealSaved() {
        guard let url = model.savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Releases the player, and with it the file, before `cleanup` touches the file.
    private func finish(_ cleanup: () -> Void) {
        guard let panel else { return }
        saveTask?.cancel()
        autoClose?.cancel()
        preview?.tearDown()
        preview = nil
        panel.contentView = nil
        panel.orderOut(nil)
        self.panel = nil
        cleanup()
        onClose?()
        onClose = nil
    }

    @concurrent
    private static func write(_ source: URL, to destination: URL) async throws {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        // The save panel already confirmed replacing an existing file.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source,
                                                      options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }
}

/// Becomes key on a click without activating Sniplet, so the app that was recorded stays in
/// front while the card's keys work: the same ones as a screenshot's.
private final class RecordingResultWindow: NSPanel {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "c" { onCopy?(); return true }
        if flags == .command, key == "s" { onSave?(); return true }
        if flags == [.command, .shift], key == "s" { onSaveAs?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if [36, 76].contains(event.keyCode), flags.isEmpty { onCopy?() }
        else if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 49, flags.isEmpty { onTogglePlayback?() }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct RecordingResultView: View {
    let video: RecordedVideo
    let model: RecordingResultModel
    let preview: RecordingPreviewView
    let onCopy: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onDiscard: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            RecordingPreviewHost(view: preview)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let saved = model.savedURL {
                savedBar(saved)
            } else {
                actionBar
            }
        }
        .padding(InlineToolbarMetrics.inset + 2)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onHover { model.isHovered = $0 }
    }

    /// The screenshot side bar's buttons, laid out flat: discard on the left, outputs on the right.
    private var actionBar: some View {
        HStack(spacing: InlineToolbarMetrics.spacing) {
            Button(action: onDiscard) { InlineToolbarIcon("xmark") }
                .help("丢弃这段录屏（Esc）")
                .accessibilityLabel("丢弃录屏")
            Text(details)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Spacer(minLength: 0)
            Button(action: onSave) { InlineToolbarIcon("square.and.arrow.down") }
                .help("存到选定的文件夹（⌘S，首次会让你选文件夹）；另存为按 ⇧⌘S 或右键")
                .accessibilityLabel("存储录屏")
                .contextMenu { Button("另存为…", action: onSaveAs) }
            Button(action: onCopy) {
                InlineToolbarIcon("checkmark")
                    .opacity(model.isBusy ? 0 : 1)
                    .overlay { if model.isBusy { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(InlineToolbarButtonStyle(isProminent: true))
            .help("拷贝视频并关闭（Return 或 ⌘C），可以直接粘贴到聊天窗口或访达")
            .accessibilityLabel("拷贝并完成")
        }
        .buttonStyle(InlineToolbarButtonStyle())
        .disabled(model.isBusy)
    }

    private func savedBar(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("已存到「\(url.deletingLastPathComponent().lastPathComponent)」").font(.callout.weight(.medium))
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("在访达中显示", action: onReveal)
                .controlSize(.small)
        }
        .frame(height: InlineToolbarMetrics.button)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let duration = RecordedVideo.format(video.duration)
        guard let bytes = try? video.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return duration }
        return duration + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Hosts the card's own preview instance, which the card tears down before touching the file.
private struct RecordingPreviewHost: NSViewRepresentable {
    let view: RecordingPreviewView
    func makeNSView(context: Context) -> RecordingPreviewView { view }
    func updateNSView(_ view: RecordingPreviewView, context: Context) {}
}

/// The video itself: a click plays or pauses it, a drag carries the file out. It takes every
/// mouse event, so the player underneath never swallows the drag.
final class RecordingPreviewView: NSView, NSDraggingSource {
    var fileURL: URL
    var onDragAccepted: (() -> Void)?
    private let duration: TimeInterval
    private var player: AVPlayer?
    private let playerView = AVPlayerView()
    private let playBadge = NSImageView()
    private let progress = NSView()
    private var fraction: CGFloat = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var poster: NSImage?
    private var mouseDownLocation: NSPoint?

    init(url: URL, duration: TimeInterval) {
        fileURL = url
        self.duration = duration
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let player = AVPlayer(url: url)
        self.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        addSubview(playerView)
        playBadge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.45)])))
        addSubview(playBadge)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        addSubview(progress)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rewind() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.showProgress(time.seconds) }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("录屏预览，时长 \(RecordedVideo.format(duration))")
        setAccessibilityHelp("按下播放或暂停；按住拖动可以把视频拖到聊天窗口或访达。")
        toolTip = "单击播放或暂停（空格）；按住拖到聊天窗口、访达或上传区"
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            guard let image = try? await generator.image(at: .zero).image else { return }
            self?.poster = NSImage(cgImage: image, size: .zero)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Stops playback and drops the player, so nothing holds the file once the card closes.
    func tearDown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        playerView.player = nil
        player = nil
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        playBadge.isHidden = player.rate != 0
    }

    private func rewind() {
        player?.pause()
        player?.seek(to: .zero)
        playBadge.isHidden = false
        showProgress(0)
    }

    private func showProgress(_ seconds: Double) {
        fraction = duration > 0 && seconds.isFinite ? CGFloat(min(1, max(0, seconds / duration))) : 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        playerView.frame = bounds
        let badge = CGSize(width: 48, height: 48)
        playBadge.frame = CGRect(x: bounds.midX - badge.width / 2, y: bounds.midY - badge.height / 2,
                                 width: badge.width, height: badge.height)
        progress.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: 3)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        togglePlayback()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownLocation != nil { togglePlayback() }
        mouseDownLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - start.x, location.y - start.y) >= 4 else { return }
        mouseDownLocation = nil
        let image = poster ?? NSWorkspace.shared.icon(forFile: fileURL.path)
        let scale = min(1, 160 / max(1, image.size.width), 160 / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(CGRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                                     width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDragAccepted?() }
    }
}
