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

/// A small floating card in the screen corner: thumbnail (drag it out), save, copy, discard.
@MainActor final class RecordingResultPanel {
    let video: RecordedVideo
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    private var panel: NSPanel?
    private var saveTask: Task<Void, Never>?

    init(video: RecordedVideo) { self.video = video }

    /// Several unsaved recordings stack upwards from the bottom-right corner.
    func present(on screen: NSScreen, stackIndex: Int) {
        let size = CGSize(width: 360, height: 290)
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - size.width - 16,
                           y: min(visible.maxY - size.height, visible.minY + 16 + CGFloat(stackIndex) * (size.height + 12)),
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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
        panel.contentView = NSHostingView(rootView: RecordingResultView(
            video: video,
            onSave: { [weak self] in self?.save() },
            onCopy: { [weak self] in self?.copy() },
            onDiscard: { [weak self] in self?.close(discarding: true) }))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close(discarding: Bool) {
        saveTask?.cancel()
        // Releases the player, and with it the file, before the file is removed.
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
        if discarding { RecordingFiles.discard(video.url) }
        onClose?()
        onClose = nil
    }

    private func save() {
        guard saveTask == nil else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = video.url.lastPathComponent
        savePanel.title = "存储录屏"
        NSApp.activate(ignoringOtherApps: true)
        saveTask = Task { [weak self, video] in
            let response = await withCheckedContinuation { continuation in
                savePanel.begin { continuation.resume(returning: $0) }
            }
            guard let self else { return }
            defer { self.saveTask = nil }
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                try await Self.write(video.url, to: destination)
                self.close(discarding: true)
            } catch {
                self.onError?("存储失败，录屏仍保留在 Sniplet 中：" + error.localizedDescription)
            }
        }
    }

    /// The file itself goes on the pasteboard, so Finder and chat apps paste a video attachment.
    private func copy() {
        do { try ClipboardService().copyFile(video.url) }
        catch { onError?(error.localizedDescription) }
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

private struct RecordingResultView: View {
    let video: RecordedVideo
    let onSave: () -> Void
    let onCopy: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordingPlayerView(url: video.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("录屏预览，时长 \(RecordedVideo.format(video.duration))")
            HStack(spacing: 8) {
                Button("存储…", action: onSave).keyboardShortcut(.defaultAction)
                Button("拷贝", action: onCopy)
                // The player takes clicks for playback, so dragging out has its own handle.
                Label("拖出", systemImage: "hand.draw")
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .onDrag { NSItemProvider(contentsOf: video.url) ?? NSItemProvider() }
                    .help("按住拖动视频到 Finder、聊天窗口或上传区")
                Spacer()
                Button(role: .destructive, action: onDiscard) {
                    Image(systemName: "trash")
                }
                .help("丢弃这段录屏")
                .accessibilityLabel("丢弃")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Native inline controls: play/pause, scrubbing and time, starting paused on the first frame.
private struct RecordingPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
