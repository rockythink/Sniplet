import AppKit
import Testing
@testable import Sniplet

@MainActor struct InlineCaptureLifecycleTests {
    @Test func closingUnpresentedHostReleasesItsRootIdempotently() throws {
        let host = InlineCaptureHost(screenFrame: CGRect(x: -1200, y: 200, width: 1200, height: 800), displayID: 7)
        weak let root = host.rootView
        #expect(host.panel == nil)
        #expect(!host.hasPresented)
        host.close()
        host.close()
        #expect(host.isClosed)
        #expect(host.panel == nil)
        #expect(host.rootView == nil)
        #expect(root == nil)
    }


    @Test func relocatingUnpresentedHostReleasesObsoleteBackdrop() throws {
        let image = try SessionTestSupport.capture().image
        let host = InlineCaptureHost(screenFrame: CGRect(x: -1200, y: 0, width: 1200, height: 800), displayID: 7, snapshot: image)
        defer { host.close() }
        #expect(host.rootView?.hasSnapshot == true)
        let replacement = CGRect(x: 0, y: 40, width: 800, height: 600)
        host.relocate(to: replacement, displayID: 8)
        #expect(host.rootView?.hasSnapshot == false)
        #expect(host.screenFrame == replacement)
        #expect(host.displayID == 8)
        #expect(host.panel == nil)
    }

    @Test func transferSurvivesOverlayCleanupAndClosesOtherScreens() throws {
        let hosts = InlineCaptureHostSet()
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let selected = InlineCaptureHost(screenFrame: frame, displayID: 7)
        let other = InlineCaptureHost(screenFrame: frame.offsetBy(dx: -100, dy: 0), displayID: 8)
        hosts.insert(selected, for: 7)
        hosts.insert(other, for: 8)
        hosts.retainOnly(7)
        #expect(other.isClosed)
        #expect(!selected.isClosed)
        let adopted = try #require(hosts.take(7))
        hosts.close()
        #expect(!adopted.isClosed)
        #expect(hosts.take(7) == nil)
        adopted.close()
        #expect(adopted.isClosed)
    }

    @Test func cancellationBeforeTransferClosesSelectedHost() {
        let hosts = InlineCaptureHostSet()
        let selected = InlineCaptureHost(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 80), displayID: 7)
        hosts.insert(selected, for: 7)
        hosts.retainOnly(7)
        hosts.close()
        #expect(selected.isClosed)
        #expect(hosts.take(7) == nil)
    }

    @Test func emptyScreenSelectionReturnsWithoutCreatingWindow() async {
        let overlay = SelectionOverlayController()
        let region = await overlay.selectRegion(screens: [], candidates: [])
        let window = await overlay.selectWindow(screens: [], candidates: [])
        #expect(region == nil)
        #expect(window == nil)
        #expect(overlay.takeSelectedHost() == nil)
    }
}

struct CaptureSelectionGestureTests {
    private let window = WindowCandidate(id: 4, bounds: CGRect(x: 10, y: 10, width: 200, height: 100))

    @Test func windowClickWaitsForMouseUpAndToleratesSmallJitter() {
        var gesture = CaptureSelectionGesture(start: CGPoint(x: 50, y: 50), window: window)
        gesture.move(to: CGPoint(x: 53.9, y: 49))
        #expect(gesture.pendingWindow?.id == window.id)
        #expect(!gesture.didDrag)
    }

    @Test func draggingPermanentlyChangesWindowClickToRegion() {
        var gesture = CaptureSelectionGesture(start: CGPoint(x: 50, y: 50), window: window)
        gesture.move(to: CGPoint(x: 54, y: 50))
        gesture.move(to: CGPoint(x: 50, y: 50))
        #expect(gesture.pendingWindow == nil)
        #expect(gesture.didDrag)
    }

    @Test func desktopDragCreatesRegionWithoutInventingAWindow() {
        var gesture = CaptureSelectionGesture(start: .zero, window: nil)
        gesture.move(to: CGPoint(x: 0, y: 4))
        #expect(gesture.pendingWindow == nil)
        #expect(gesture.didDrag)
    }
}

struct CaptureFootprintTests {
    @Test func sourceFootprintUsesActualOutwardRoundedPixelsOnNegativeScreen() throws {
        let screen = CGRect(x: -1000, y: 200, width: 1000, height: 800)
        let selection = CGRect(x: -900.2, y: 300.1, width: 100.3, height: 80.4)
        let footprint = try #require(CaptureFootprint.regionRect(selection, screenFrame: screen,
                                                                 imageSize: CGSize(width: 2000, height: 1600)))
        #expect(footprint == CGRect(x: -900.5, y: 300, width: 101, height: 80.5))
    }

    @Test func negativeDecorationPaddingDoesNotShiftOriginalContent() {
        let source = CGRect(x: -1700, y: 80, width: 200, height: 100)
        let pixels = CGRect(x: -40, y: -20, width: 480, height: 260)
        let frame = CaptureFootprint.presentationRect(pixels, imageSize: CGSize(width: 400, height: 200), sourceRect: source)
        #expect(frame == CGRect(x: -1720, y: 60, width: 240, height: 130))
        #expect(frame.minX-pixels.minX*0.5 == source.minX)
        #expect(frame.maxY+pixels.minY*0.5 == source.maxY)
    }

    @Test func zeroAreaSelectionAndInvalidPixelDimensionsHaveNoFootprint() {
        let screen = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureFootprint.regionRect(.zero, screenFrame: screen, imageSize: CGSize(width: 200, height: 200)) == nil)
        #expect(CaptureFootprint.regionRect(screen, screenFrame: screen, imageSize: CGSize(width: CGFloat.infinity, height: 200)) == nil)
    }
}
