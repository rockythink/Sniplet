import CoreGraphics
import Testing
@testable import Sniplet

/// Core below/above and right/left expectations adapted from CapCap's focused placement
/// tests (MIT), commit 7dd035225eaa41e6da8a5156556a8c4dd7bd028b, with tiny/negative
/// bounds and collision regressions added for Sniplet's bounded native toolbar containers.
struct EditorToolbarPlacementTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let primary = CGSize(width: 720, height: 44)
    private let side = CGSize(width: 44, height: 300)

    @Test func primaryRightAlignsBelowSelection() {
        let selection = CGRect(x: 200, y: 300, width: 900, height: 500)
        let rect = EditorToolbarPlacement.primaryToolbarRect(referenceRect: selection, in: bounds,
                                                             size: primary, topSafeInset: 38)
        #expect(rect.maxX == selection.maxX)
        #expect(rect.maxY == selection.minY-8)
    }

    @Test func fullScreenSelectionReservesSafeTopInset() {
        let rect = EditorToolbarPlacement.primaryToolbarRect(referenceRect: bounds, in: bounds,
                                                             size: primary, topSafeInset: 38)
        #expect(rect.maxY == bounds.maxY-38-8)
        #expect(rect.maxX == bounds.maxX-8)
    }

    @Test func sideFlipsLeftAtRightEdge() {
        let selection = CGRect(x: 1200, y: 100, width: 310, height: 400)
        let rect = EditorToolbarPlacement.sideToolbarRect(referenceRect: selection, in: bounds, size: side)
        #expect(rect.maxX == selection.minX-8)
        #expect(rect.minY == selection.minY)
    }

    @Test func sideDefaultsRightAndKeepsBottomMargin() {
        let selection = CGRect(x: 200, y: 0, width: 900, height: 500)
        let rect = EditorToolbarPlacement.sideToolbarRect(referenceRect: selection, in: bounds, size: side)
        #expect(rect.minX == selection.maxX+8)
        #expect(rect.minY == bounds.minY+8)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 1512, height: 982),
        CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
        CGRect(x: -320, y: 480, width: 320, height: 80),
        CGRect(x: 100, y: -200, width: 64, height: 48),
        CGRect(x: -1, y: -1, width: 1, height: 1)
    ])
    func fullScreenAndTinyBoundsNeverCollide(_ screen: CGRect) {
        let frames = EditorToolbarPlacement.frames(referenceRect: screen, in: screen,
                                                   primarySize: primary, sideSize: side, topSafeInset: 38)
        #expect(screen.contains(frames.primary))
        #expect(screen.contains(frames.side))
        #expect(!frames.primary.intersects(frames.side))
        #expect(frames.primary.width > 0 && frames.primary.height > 0)
        #expect(frames.side.width > 0 && frames.side.height > 0)
    }

    @Test func tinySelectionKeepsFullControlsReachableWithoutBarCollision() {
        let selection = CGRect(x: 20, y: 20, width: 2, height: 3)
        let frames = EditorToolbarPlacement.frames(referenceRect: selection, in: bounds,
                                                   primarySize: primary, sideSize: side)
        #expect(frames.primary.size == primary)
        #expect(frames.side.size == side)
        #expect(bounds.contains(frames.primary) && bounds.contains(frames.side))
        #expect(!frames.primary.intersects(frames.side))
    }

    @Test func sideMovesOutOfPrimaryBand() {
        let primary = CGRect(x: 8, y: 8, width: 900, height: 44)
        let side = EditorToolbarPlacement.sideToolbarRect(referenceRect: CGRect(x: 400, y: 0, width: 100, height: 20),
                                                          in: bounds, size: self.side, avoiding: primary)
        #expect(!side.intersects(primary))
        #expect(side.minY == primary.maxY+8)
    }

    @Test func disconnectedDisplayRehomesWithoutChangingImageAspect() {
        let old = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let source = CGRect(x: -1900, y: 30, width: 1600, height: 900)
        let available = CGRect(x: 0, y: 40, width: 800, height: 600)
        let moved = EditorToolbarPlacement.relocatedSourceRect(source, from: old, to: available)
        #expect(available.contains(moved))
        #expect(moved.width/moved.height == source.width/source.height)
    }

    @Test func fullScreenCapturePlacesBothToolbarsInsideTheImage() {
        let frames = EditorToolbarPlacement.frames(
            referenceRect: bounds, in: bounds,
            primarySize: CGSize(width: 640, height: 44), sideSize: CGSize(width: 44, height: 300))
        #expect(bounds.contains(frames.primary))
        #expect(bounds.contains(frames.side))
        #expect(frames.primary.minY >= bounds.minY)
        #expect(frames.side.maxX <= bounds.maxX)
        #expect(frames.side.height == 300)
        #expect(!frames.primary.intersects(frames.side))
        // The side bar stacks directly above the primary bar on the same inside edge.
        #expect(frames.side.minY >= frames.primary.maxY)
        #expect(frames.side.maxX == frames.primary.maxX)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 1512, height: 957),      // menu bar only
        CGRect(x: 0, y: 70, width: 1512, height: 887),     // dock at bottom
        CGRect(x: 80, y: 0, width: 1432, height: 957),     // dock at left
        CGRect(x: 0, y: 0, width: 1432, height: 957)       // dock at right
    ])
    func fullScreenToolbarsStayInsideEveryVisibleSafeArea(_ visible: CGRect) {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = EditorToolbarPlacement.frames(
            referenceRect: screen, in: visible,
            primarySize: CGSize(width: 640, height: 44), sideSize: CGSize(width: 44, height: 300))
        #expect(visible.contains(frames.primary))
        #expect(visible.contains(frames.side))
        #expect(!frames.primary.intersects(frames.side))
    }

    @Test func normalRegionStillUsesOutsidePlacement() {
        let selection = CGRect(x: 200, y: 300, width: 500, height: 300)
        let frames = EditorToolbarPlacement.frames(referenceRect: selection, in: bounds,
                                                   primarySize: primary, sideSize: side)
        #expect(frames.primary.maxY <= selection.minY)
        #expect(frames.side.minX >= selection.maxX)
    }
}
