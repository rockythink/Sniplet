import CoreGraphics
import Testing
@testable import Sniplet

struct PinnedImageLayoutTests {
    private let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func smallCaptureKeepsItsNaturalSizeInsteadOfAFixedWindow() {
        let size = PinnedImageLayout.fittedSize(CGSize(width: 120, height: 48), in: visible.size)
        #expect(size == CGSize(width: 120, height: 48))
    }

    @Test func oversizedCaptureScalesDownKeepingAspectRatio() {
        let size = PinnedImageLayout.fittedSize(CGSize(width: 2880, height: 900), in: CGSize(width: 1440, height: 860))
        #expect(size == CGSize(width: 1440, height: 450))
    }

    @Test func anchoredPinKeepsTheCaptureTopLeftCorner() {
        let anchor = CGRect(x: 300, y: 500, width: 200, height: 100)
        let frame = PinnedImageLayout.anchoredFrame(size: anchor.size, anchor: anchor, visible: visible)
        #expect(frame == anchor)
    }

    @Test func anchoredPinStaysOnScreen() {
        let anchor = CGRect(x: 1400, y: 10, width: 200, height: 100)
        let frame = PinnedImageLayout.anchoredFrame(size: anchor.size, anchor: anchor, visible: visible)
        #expect(visible.contains(frame))
        #expect(frame.size == anchor.size)
    }

    @Test func historyPinsCascadeInsteadOfStackingExactly() {
        let size = CGSize(width: 300, height: 200)
        let frames = (0..<3).map { PinnedImageLayout.cascadedFrame(size: size, index: $0, visible: visible) }
        #expect(Set(frames.map(\.origin.x)).count == 3)
        #expect(frames[1].minX - frames[0].minX == PinnedImageLayout.cascadeStep)
        #expect(frames[0].maxY - frames[1].maxY == PinnedImageLayout.cascadeStep)
        #expect(frames.allSatisfy { visible.contains($0) })
    }

    @Test func zoomIsBoundedByRangeAndScreen() {
        let natural = CGSize(width: 400, height: 200)
        #expect(PinnedImageLayout.clampedZoom(1.25, natural: natural, visible: visible.size) == 1.25)
        #expect(PinnedImageLayout.clampedZoom(10, natural: natural, visible: visible.size) == 3.6)
        #expect(PinnedImageLayout.clampedZoom(0.01, natural: natural, visible: visible.size) == 0.1)
        // A tiny capture never shrinks below a grabbable size.
        let tiny = CGSize(width: 40, height: 20)
        #expect(PinnedImageLayout.clampedZoom(0.1, natural: tiny, visible: visible.size) == 0.8)
    }

    @Test func zoomResizesAroundTheCenter() {
        let frame = CGRect(x: 400, y: 300, width: 200, height: 100)
        let zoomed = PinnedImageLayout.zoomedFrame(frame, natural: frame.size, zoom: 2, visible: visible)
        #expect(zoomed.size == CGSize(width: 400, height: 200))
        #expect(zoomed.midX == frame.midX)
        #expect(zoomed.midY == frame.midY)
    }
}
