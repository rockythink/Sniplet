import AppKit
import SwiftUI

extension NSWindow {
    /// Sniplet activates itself to capture. A window left on another Space would make that
    /// activation switch there, away from what the user is capturing; it comes along instead,
    /// including onto another app's full-screen Space.
    func followActiveSpace() {
        collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
    }
}

/// Reaches the window of a SwiftUI scene, which offers no collection behavior of its own.
struct FollowsActiveSpace: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.followActiveSpace()
        }
    }
}

extension NSAlert {
    /// Menu-bar apps may be activated while another app owns a full-screen
    /// Space. Keep the modal reachable there without switching the user's Space.
    @discardableResult
    func runForSniplet() -> NSApplication.ModalResponse {
        NSApp.unhideWithoutActivation()
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        layout()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }
}
