import AppKit
import Observation
import Sparkle

/// Sparkle updates from the signed appcast on the website. Sniplet lives in the menu bar,
/// so scheduled updates found mid-work appear as a menu item ("gentle reminder") instead of
/// a window; only updates found near launch, or asked for, open Sparkle's window directly.
@MainActor @Observable final class SoftwareUpdater: NSObject {
    /// Set while a found update waits in the menu; cleared when its session ends.
    private(set) var pendingVersion: String?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// The unit-test host never starts the updater, so tests stay offline.
    func start() {
        guard controller == nil, !AppRuntime.isUnitTesting else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = canCheck }
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Sparkle asks on the second launch; Settings can change it at any time.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }
}

extension SoftwareUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            // An agent app's windows otherwise open behind whatever the user is working in.
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
