import AppKit

/// A click-through status pill below the menu bar: the delay countdown, or a brief
/// "saved" note. It never becomes key or activates Sniplet, so menus and popovers the
/// user opens in other apps stay open underneath it.
@MainActor final class StatusPillPanel {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?
    private static let height: CGFloat = 40

    func show(_ text: String) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        let width = min(520, max(148, ceil(label.intrinsicContentSize.width) + 40))
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(CGRect(x: visible.midX - width / 2, y: visible.maxY - Self.height - 12,
                                  width: width, height: Self.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    /// Shows `text`, then hides itself unless something newer replaced it.
    func flash(_ text: String, for duration: Duration = .seconds(2.5)) {
        show(text)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let size = CGSize(width: 148, height: Self.height)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above open menus, which is exactly what the user is waiting to capture.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.autoresizingMask = [.width, .height]
        background.layer?.masksToBounds = true
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor, constant: -24),
        ])
        panel.contentView = background
        panel.setAccessibilityLabel("Sniplet 状态")
        return panel
    }
}
