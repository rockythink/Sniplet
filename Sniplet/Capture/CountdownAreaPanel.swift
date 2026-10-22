import AppKit
import SwiftUI

/// Click-through panels that mark an area on screen while the user keeps working in other
/// apps. They never become key or activate Sniplet, and every capture excludes them.
@MainActor enum AreaPanels {
    static func make(frame: CGRect, level: NSWindow.Level = .statusBar) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        return panel
    }

    /// An outline drawn just outside `rect`, so it never covers the area's own edge pixels.
    static func outline(around rect: CGRect, color: NSColor, dashPattern: [CGFloat] = []) -> NSPanel {
        let inset: CGFloat = 3
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        let panel = make(frame: frame)
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let shape = CAShapeLayer()
        shape.frame = view.bounds
        shape.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = 2
        if !dashPattern.isEmpty { shape.lineDashPattern = dashPattern.map { NSNumber(value: Double($0) * 2) } }
        view.layer?.addSublayer(shape)
        panel.contentView = view
        return panel
    }
}

nonisolated enum CountdownLayout {
    /// Smaller areas show the number in the corner pill instead of covering their content.
    static let minimumInsideSize = CGSize(width: 120, height: 80)

    static func showsNumberInside(_ area: CGRect) -> Bool {
        area.width >= minimumInsideSize.width && area.height >= minimumInsideSize.height
    }
}

@MainActor @Observable final class CountdownModel {
    var secondsLeft = 0
}

/// The selection stays on screen as an outline with the countdown in its middle; only the
/// small cancel button takes clicks, so everything underneath stays usable until capture.
@MainActor final class CountdownAreaPanel {
    private var panels: [NSPanel] = []
    private let model = CountdownModel()

    func show(around area: CGRect, appearance: CaptureSelectionAppearance, secondsLeft: Int,
              onCancel: @escaping () -> Void) {
        close()
        model.secondsLeft = secondsLeft
        let color = appearance.normalized.color
        let outline = AreaPanels.outline(around: area,
                                         color: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1),
                                         dashPattern: appearance.lineStyle.dashPattern)
        panels.append(outline)
        let inside = CountdownLayout.showsNumberInside(area)
        if inside {
            let number = NSHostingView(rootView: CountdownNumber(model: model))
            let size = number.fittingSize
            let badge = AreaPanels.make(frame: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                                      width: size.width, height: size.height))
            badge.ignoresMouseEvents = true
            badge.contentView = number
            panels.append(badge)
        }
        let control = NSHostingView(rootView: CountdownCancelControl(model: model, showsNumber: !inside, onCancel: onCancel))
        let visible = NSScreen.screens.first(where: { $0.frame.intersects(area) })?.visibleFrame ?? area
        let controlPanel = AreaPanels.make(frame: RecordingGeometry.stopButtonFrame(size: control.fittingSize,
                                                                                  area: area, visible: visible))
        controlPanel.contentView = control
        panels.append(controlPanel)
        for panel in panels { panel.orderFrontRegardless() }
    }

    func update(secondsLeft: Int) { model.secondsLeft = secondsLeft }

    func close() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}

private struct CountdownNumber: View {
    let model: CountdownModel

    var body: some View {
        Text("\(model.secondsLeft)")
            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .background(.black.opacity(0.45), in: Circle())
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.secondsLeft)
            .accessibilityLabel("\(model.secondsLeft) 秒后截图")
    }
}

private struct CountdownCancelControl: View {
    let model: CountdownModel
    let showsNumber: Bool
    let onCancel: () -> Void

    var body: some View {
        Button(action: onCancel) {
            HStack(spacing: 6) {
                if showsNumber {
                    Text("\(model.secondsLeft) 秒").monospacedDigit()
                }
                Image(systemName: "xmark")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, showsNumber ? 12 : 9)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .padding(4)
        .fixedSize()
        .help("取消延迟截图（也可以再按 ⇧⌘A）")
        .accessibilityLabel("取消延迟截图")
    }
}
