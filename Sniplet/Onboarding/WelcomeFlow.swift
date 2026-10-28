import Foundation

/// The welcome window's three steps, in order.
nonisolated enum WelcomeStep: Int, CaseIterable, Sendable {
    case menuBar, permission, firstCapture

    var next: Self? { Self(rawValue: rawValue + 1) }
    var previous: Self? { Self(rawValue: rawValue - 1) }

    /// Set just before Sniplet relaunches itself from the permission step, so the new
    /// instance reopens the welcome window there instead of treating it as already seen.
    static let resumeKey = "welcome.resumeStep"

    static func takeResume(from defaults: UserDefaults) -> Self? {
        guard defaults.object(forKey: resumeKey) != nil else { return nil }
        defer { defaults.removeObject(forKey: resumeKey) }
        return Self(rawValue: defaults.integer(forKey: resumeKey))
    }
}

/// What the permission step offers. macOS often applies a new Screen Recording grant
/// only after the app relaunches, so a request that has not taken effect yet offers both
/// System Settings and a relaunch rather than guessing which one is needed.
nonisolated enum WelcomePermissionPhase: Equatable, Sendable {
    case granted, notRequested, pending

    init(isAvailable: Bool, hasRequested: Bool) {
        self = isAvailable ? .granted : hasRequested ? .pending : .notRequested
    }
}

/// A relaunched instance waits for the old one to quit before registering shortcuts,
/// which the old instance would otherwise still hold.
nonisolated enum RelaunchHandoff {
    static let waitArgument = "--sniplet-wait-for-pid"

    static func arguments(waitingFor pid: pid_t) -> [String] { [waitArgument, String(pid)] }

    static func previousInstance(in arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: waitArgument), arguments.indices.contains(index + 1),
              let pid = pid_t(arguments[index + 1]), pid > 0 else { return nil }
        return pid
    }
}
