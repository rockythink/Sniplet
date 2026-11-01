import AppKit
import SwiftUI

/// Where the guide sits relative to System Settings' window: outside it when the screen
/// has room, so it never covers the permission list it points at.
nonisolated enum ScreenRecordingGuidePlacement {
    enum Edge: Equatable, Sendable { case below, above, inside }

    static let gap: CGFloat = 8

    /// `CGWindowListCopyWindowInfo` bounds are top-left based on the primary display.
    static func appKitRect(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    static func frame(size: CGSize, beside window: CGRect, in visible: CGRect) -> (frame: CGRect, edge: Edge) {
        let x = min(max(window.midX - size.width / 2, visible.minX + gap), visible.maxX - size.width - gap)
        if window.minY - gap - size.height >= visible.minY {
            return (CGRect(x: x, y: window.minY - gap - size.height, width: size.width, height: size.height), .below)
        }
        if window.maxY + gap + size.height <= visible.maxY {
            return (CGRect(x: x, y: window.maxY + gap, width: size.width, height: size.height), .above)
        }
        // A window filling the screen: overlap its bottom edge, still on screen.
        let y = max(window.minY, visible.minY) + 2 * gap
        return (CGRect(x: x, y: y, width: size.width, height: size.height), .inside)
    }
}

@MainActor @Observable final class ScreenRecordingGuideModel {
    var edge = ScreenRecordingGuidePlacement.Edge.below
    var isGranted = false
}

/// A small panel attached to System Settings while it shows the Screen Recording list:
/// Sniplet's icon can be dragged straight into the list, so nobody has to find the app
/// with the + button. It never activates Sniplet, follows the Settings window, hides while
/// another app is in front, and closes itself once access is granted or Settings quits.
@MainActor final class ScreenRecordingGuidePanel {
    private static let settingsBundleID = "com.apple.systempreferences"
    private let model = ScreenRecordingGuideModel()
    private let onGranted: () -> Void
    private let onRelaunch: () -> Void
    private var panel: NSPanel?
    private var tracking: Task<Void, Never>?

    init(onGranted: @escaping () -> Void, onRelaunch: @escaping () -> Void) {
        self.onGranted = onGranted
        self.onRelaunch = onRelaunch
    }

    func show() {
        model.isGranted = false
        if panel == nil { panel = makePanel() }
        tracking?.cancel()
        tracking = Task { [weak self] in await self?.track() }
    }

    func close() {
        tracking?.cancel()
        tracking = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Window positions and the grant are polled only while the guide is open; neither
    /// needs an entitlement, and window titles (which would) are never read.
    private func track() async {
        let start = ContinuousClock.now
        var hasSeenSettings = false
        var tick = 0
        while !Task.isCancelled {
            if tick % 4 == 0, !model.isGranted, CGPreflightScreenCaptureAccess() {
                model.isGranted = true
                onGranted()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    self?.close()
                }
            }
            tick += 1
            let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first
            if let settings, let window = Self.mainWindowFrame(of: settings.processIdentifier) {
                hasSeenSettings = true
                place(beside: window, visible: Self.isFrontmostRelevant(settings))
            } else {
                panel?.orderOut(nil)
                // Settings quit, or never opened (the deep link can fail): nothing to point at.
                if settings == nil, hasSeenSettings || ContinuousClock.now - start > .seconds(15) {
                    close()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func place(beside window: CGRect, visible: Bool) {
        guard let panel else { return }
        guard visible else { panel.orderOut(nil); return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: window.midX, y: window.midY)) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame, let content = panel.contentView else { return }
        let placement = ScreenRecordingGuidePlacement.frame(size: content.fittingSize, beside: window, in: area)
        if model.edge != placement.edge { model.edge = placement.edge }
        if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shown over Settings (and Sniplet's own welcome window), never over unrelated apps.
    private static func isFrontmostRelevant(_ settings: NSRunningApplication) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == settings.processIdentifier
            || front.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// The largest normal-level on-screen window of System Settings, in AppKit coordinates.
    private static func mainWindowFrame(of pid: pid_t) -> CGRect? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let bounds = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  rect.width > 200, rect.height > 200 else { return nil }
            return rect
        }
        guard let largest = bounds.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return ScreenRecordingGuidePlacement.appKitRect(fromWindowBounds: largest,
                                                        primaryScreenHeight: primary.frame.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ScreenRecordingGuideView(
            model: model,
            relaunch: { [weak self] in self?.onRelaunch() },
            close: { [weak self] in self?.close() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.setAccessibilityLabel("Sniplet 屏幕录制授权提示")
        return panel
    }
}

private struct ScreenRecordingGuideView: View {
    let model: ScreenRecordingGuideModel
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if model.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("已允许屏幕录制").font(.headline)
                    Text("现在可以截图了。").foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else {
                VStack(spacing: 4) {
                    AppBundleDragHandle()
                        .frame(width: 56, height: 56)
                    Text("拖动")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text("列表里已经有 Sniplet 的话，直接打开它旁边的开关。系统提示「退出并重新打开」时点它就行。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("打开了还是截不了？重新打开 Sniplet", action: relaunch)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
            .accessibilityLabel("关闭提示")
        }
        .padding(14)
        .frame(width: 440)
    }

    private var title: String {
        switch model.edge {
        case .below: "把 Sniplet 图标拖进上方的列表"
        case .above: "把 Sniplet 图标拖进下方的列表"
        case .inside: "把 Sniplet 图标拖进系统设置的列表"
        }
    }
}

/// Sniplet's own icon as a drag source carrying the app bundle's file URL, which the
/// privacy lists in System Settings accept like an app dropped from Finder.
private struct AppBundleDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragView { AppBundleDragView() }
    func updateNSView(_ view: AppBundleDragView, context: Context) {}
}

final class AppBundleDragView: NSView, NSDraggingSource {
    private let icon = NSApp.applicationIconImage ?? NSImage()
    private var mouseDownLocation: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Sniplet 图标")
        setAccessibilityHelp("拖到系统设置的屏幕录制列表里，即可添加 Sniplet。")
        toolTip = "把这个图标拖进系统设置的列表"
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - start.x, location.y - start.y) >= 3 else { return }
        mouseDownLocation = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownLocation = nil }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
