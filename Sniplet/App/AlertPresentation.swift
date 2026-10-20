import AppKit

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
