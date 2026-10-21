import Foundation
import Testing
@testable import Sniplet

struct LaunchGuidanceTests {
    @Test func newUsersSeeTheIntroductionOnlyAndUpgradersSeeNotesOnce() throws {
        let suite = "Sniplet.Launch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LaunchGuidance.next(in: defaults) == .introduction)
        LaunchGuidance.markShown(in: defaults)
        #expect(LaunchGuidance.next(in: defaults) == .none)

        // An install from before the notes existed: introduced, no notes revision stored.
        defaults.removeObject(forKey: LaunchGuidance.notesKey)
        #expect(LaunchGuidance.next(in: defaults) == .whatsNew)
        LaunchGuidance.markShown(in: defaults)
        #expect(LaunchGuidance.next(in: defaults) == .none)
    }

    @Test func aLaterNotesRevisionShowsAgain() {
        #expect(LaunchGuidance.next(hasShownIntroduction: true,
                                    seenNotesRevision: LaunchGuidance.notesRevision - 1) == .whatsNew)
        #expect(LaunchGuidance.next(hasShownIntroduction: true,
                                    seenNotesRevision: LaunchGuidance.notesRevision) == .none)
        #expect(LaunchGuidance.next(hasShownIntroduction: false,
                                    seenNotesRevision: LaunchGuidance.notesRevision) == .introduction)
    }
}
