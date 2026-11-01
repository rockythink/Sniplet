import CoreGraphics
import Testing
@testable import Sniplet

struct ScreenRecordingGuidePlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 440, height: 110)

    @Test func windowBoundsFlipFromTopLeftToAppKit() {
        let bounds = CGRect(x: 846, y: 135, width: 754, height: 625)
        let rect = ScreenRecordingGuidePlacement.appKitRect(fromWindowBounds: bounds, primaryScreenHeight: 900)
        #expect(rect == CGRect(x: 846, y: 140, width: 754, height: 625))
    }

    @Test func sitsCentredBelowTheWindowWhenThereIsRoom() {
        let window = CGRect(x: 400, y: 300, width: 754, height: 500)
        let placement = ScreenRecordingGuidePlacement.frame(size: size, beside: window, in: visible)
        #expect(placement.edge == .below)
        #expect(placement.frame.maxY == window.minY - ScreenRecordingGuidePlacement.gap)
        #expect(placement.frame.midX == window.midX)
    }

    @Test func movesAboveThenInsideAsTheScreenRunsOut() {
        let low = CGRect(x: 400, y: 20, width: 754, height: 500)
        let above = ScreenRecordingGuidePlacement.frame(size: size, beside: low, in: visible)
        #expect(above.edge == .above)
        #expect(above.frame.minY == low.maxY + ScreenRecordingGuidePlacement.gap)
        let tall = CGRect(x: 400, y: 0, width: 754, height: 875)
        let inside = ScreenRecordingGuidePlacement.frame(size: size, beside: tall, in: visible)
        #expect(inside.edge == .inside)
        #expect(visible.contains(inside.frame))
    }

    @Test func staysOnScreenBesideAWindowAtTheEdge() {
        let window = CGRect(x: 1200, y: 400, width: 600, height: 400)
        let placement = ScreenRecordingGuidePlacement.frame(size: size, beside: window, in: visible)
        #expect(placement.frame.maxX <= visible.maxX)
        #expect(placement.frame.minX >= visible.minX)
    }
}
