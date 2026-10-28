import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

struct WelcomeFlowTests {
    @Test func stepsWalkInOrderWithoutWrapping() {
        #expect(WelcomeStep.menuBar.previous == nil)
        #expect(WelcomeStep.menuBar.next == .permission)
        #expect(WelcomeStep.permission.next == .firstCapture)
        #expect(WelcomeStep.firstCapture.next == nil)
    }

    @Test func aRelaunchResumesItsStepExactlyOnce() throws {
        let suite = "Sniplet.Welcome.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WelcomeStep.takeResume(from: defaults) == nil)
        // menuBar is raw value 0, which a plain integer read could not tell from "absent".
        defaults.set(WelcomeStep.menuBar.rawValue, forKey: WelcomeStep.resumeKey)
        #expect(WelcomeStep.takeResume(from: defaults) == .menuBar)
        defaults.set(WelcomeStep.permission.rawValue, forKey: WelcomeStep.resumeKey)
        #expect(WelcomeStep.takeResume(from: defaults) == .permission)
        #expect(WelcomeStep.takeResume(from: defaults) == nil)
    }

    @Test func permissionPhaseOffersTheRightNextAction() {
        #expect(WelcomePermissionPhase(isAvailable: true, hasRequested: false) == .granted)
        #expect(WelcomePermissionPhase(isAvailable: true, hasRequested: true) == .granted)
        #expect(WelcomePermissionPhase(isAvailable: false, hasRequested: false) == .notRequested)
        #expect(WelcomePermissionPhase(isAvailable: false, hasRequested: true) == .pending)
    }

    @Test func relaunchArgumentsRoundTripAndRejectMalformedOnes() {
        #expect(RelaunchHandoff.previousInstance(in: ["Sniplet"] + RelaunchHandoff.arguments(waitingFor: 4321)) == 4321)
        #expect(RelaunchHandoff.previousInstance(in: ["Sniplet"]) == nil)
        #expect(RelaunchHandoff.previousInstance(in: ["Sniplet", RelaunchHandoff.waitArgument]) == nil)
        #expect(RelaunchHandoff.previousInstance(in: ["Sniplet", RelaunchHandoff.waitArgument, "abc"]) == nil)
        #expect(RelaunchHandoff.previousInstance(in: ["Sniplet", RelaunchHandoff.waitArgument, "0"]) == nil)
    }
}

struct EditorTipTests {
    @Test func tipsComeInOrderOnceEachAndSkipWhatWasDiscovered() {
        var ledger = EditorTipLedger()
        #expect(ledger.next == .output)
        ledger.shown.insert(.output)
        ledger.discovered.insert(.tools)
        #expect(ledger.next == .style)
        ledger.shown.formUnion([.style, .areaActions])
        ledger.discovered.insert(.repeatAndHistory)
        #expect(ledger.next == nil)
    }

    @Test func storePersistsProgressAndResetStartsOver() throws {
        let suite = "Sniplet.Tips.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tips = EditorTips(defaults: defaults)
        #expect(tips.next == .output)
        tips.markShown(.output)
        tips.discovered(.tools)
        let reloaded = EditorTips(defaults: defaults)
        #expect(reloaded.ledger == EditorTipLedger(shown: [.output], discovered: [.tools]))
        #expect(reloaded.next == .style)
        reloaded.isEnabled = false
        #expect(reloaded.next == nil)
        #expect(EditorTips(defaults: defaults).next == nil)
        reloaded.reset()
        #expect(reloaded.isEnabled)
        #expect(EditorTips(defaults: defaults).next == .output)
    }

    @Test func messagesNameOnlyBoundShortcuts() {
        let bound = EditorTip.repeatAndHistory.message(regionShortcut: "⇧⌘A", previousRegionShortcut: "⌃⌥⌘4")
        #expect(bound.hasPrefix("⌃⌥⌘4"))
        let unbound = EditorTip.repeatAndHistory.message(regionShortcut: nil, previousRegionShortcut: nil)
        #expect(unbound.contains("菜单栏「重复上次区域」"))
        #expect(EditorTip.areaActions.message(regionShortcut: "⇧⌘A", previousRegionShortcut: nil).contains("⇧⌘A"))
        #expect(!EditorTip.areaActions.message(regionShortcut: nil, previousRegionShortcut: nil).contains("再按"))
    }
}

struct EditorTipPlacementTests {
    private let safe = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 420, height: 52)

    @Test func tipSitsOnTheToolbarSideAwayFromTheCapture() throws {
        let capture = CGRect(x: 300, y: 300, width: 600, height: 400)
        let side = CGRect(x: 908, y: 400, width: 44, height: 300)
        let barBelow = CGRect(x: 300, y: 248, width: 560, height: 44)
        let below = try #require(EditorTipPlacement.frame(size: size, primary: barBelow, side: side, capture: capture, in: safe))
        #expect(below.maxY == barBelow.minY - EditorTipPlacement.gap)
        #expect(!below.intersects(capture))
        let barAbove = CGRect(x: 300, y: 708, width: 560, height: 44)
        let above = try #require(EditorTipPlacement.frame(size: size, primary: barAbove, side: side, capture: capture, in: safe))
        #expect(above.minY == barAbove.maxY + EditorTipPlacement.gap)
        #expect(!above.intersects(capture))
    }

    @Test func noRoomOutsideTheCaptureHidesTheTipRatherThanCoveringIt() {
        // Bar below the capture at the bottom edge: below is off screen, above covers the image.
        let capture = CGRect(x: 300, y: 60, width: 600, height: 700)
        let bar = CGRect(x: 300, y: 8, width: 560, height: 44)
        #expect(EditorTipPlacement.frame(size: size, primary: bar, side: .zero, capture: capture, in: safe) == nil)
    }

    @Test func fullScreenToolbarsInsideTheCaptureCarryTheTipWithThem() throws {
        let capture = safe
        let bar = CGRect(x: 400, y: 24, width: 560, height: 44)
        let side = CGRect(x: 1380, y: 300, width: 44, height: 300)
        let frame = try #require(EditorTipPlacement.frame(size: size, primary: bar, side: side, capture: capture, in: safe))
        #expect(safe.contains(frame))
        #expect(!frame.intersects(side))
        #expect(!frame.intersects(bar))
    }

    @Test func tipStaysOnScreenAndNarrowsOnSmallDisplays() throws {
        let small = CGRect(x: 0, y: 0, width: 360, height: 500)
        let bar = CGRect(x: 200, y: 300, width: 150, height: 44)
        let frame = try #require(EditorTipPlacement.frame(size: size, primary: bar, side: .zero,
                                                          capture: CGRect(x: 0, y: 352, width: 360, height: 148), in: small))
        #expect(small.contains(frame))
        #expect(frame.width == small.width - 2 * EditorTipPlacement.gap)
    }
}

struct GuideContentTests {
    private let bound = GuideContent(captureShortcuts: [.region: "⇧⌘A", .window: "⌃⌥⌘5", .fullScreen: "⌃⌥⌘3",
                                                         .previousRegion: "⌃⌥⌘4"])

    @Test func everySectionHasContent() {
        for section in GuideSection.allCases {
            #expect(!bound.blocks(for: section).isEmpty, "\(section) is empty")
        }
    }

    @Test func textFollowsTheBoundRegionShortcut() {
        let custom = GuideContent(captureShortcuts: [.region: "⌃⇧X"])
        guard case let .list(steps) = custom.blocks(for: .start)[1] else { Issue.record("start has no steps"); return }
        #expect(steps[0].contains("⌃⇧X"))
        let unbound = GuideContent(captureShortcuts: [:])
        #expect(unbound.globalShortcuts.allSatisfy { $0.keys == "未设置" })
        #expect(unbound.globalShortcuts.count == GlobalHotKeyManager.modes.count)
    }

    @Test func toolShortcutsCoverEveryToolWithDistinctKeys() {
        let keys = GuideContent.toolShortcuts.map(\.keys)
        #expect(keys.count == AnnotationTool.allCases.count)
        #expect(Set(keys).count == keys.count)
        for tool in AnnotationTool.allCases {
            #expect(GuideContent.toolShortcuts.contains(GuideShortcut(keys: String(tool.shortcutKey).uppercased(),
                                                                      meaning: tool.label)))
        }
    }
}
