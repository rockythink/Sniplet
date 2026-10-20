import AppKit
import CoreGraphics
import Testing
@testable import Sniplet

struct CaptureSelectionResizeGeometryTests {
    private let bounds = CGRect(x: -100, y: -100, width: 400, height: 300)
    private let selection = CGRect(x: -40, y: -30, width: 200, height: 120)

    @Test(arguments: CaptureSelectionResizeHandle.allCases)
    func everyHandleUsesUnflippedAppKitCoordinates(_ handle: CaptureSelectionResizeHandle) {
        let point = CaptureSelectionResizeGeometry.point(for: handle, in: selection)
        #expect(CaptureSelectionResizeGeometry.hit(at: point, selection: selection,
                                                  clippingRect: bounds, bounds: bounds) == handle)
    }

    @Test func topMeansHigherAppKitY() {
        #expect(CaptureSelectionResizeGeometry.point(for: .topLeft, in: selection)
                == CGPoint(x: -40, y: 90))
        #expect(CaptureSelectionResizeGeometry.point(for: .bottomRight, in: selection)
                == CGPoint(x: 160, y: -30))
    }

    @Test func cornersBeatBothAdjacentEdgeBands() {
        let point = CGPoint(x: selection.minX + 7, y: selection.maxY - 7)
        #expect(CaptureSelectionResizeGeometry.hit(at: point, selection: selection,
                                                  clippingRect: bounds, bounds: bounds) == .topLeft)
    }

    @Test func edgeBandWorksInsideAndOutsideWithoutTakingTheInterior() {
        for x in [selection.minX - 8, selection.minX + 8] {
            #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: x, y: selection.midY),
                                                      selection: selection,
                                                      clippingRect: bounds, bounds: bounds) == .left)
        }
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: selection.minX + 9, y: selection.midY),
                                                  selection: selection,
                                                  clippingRect: bounds, bounds: bounds) == nil)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: selection.midX, y: selection.midY),
                                                  selection: selection,
                                                  clippingRect: bounds, bounds: bounds) == nil)
    }

    @Test func fullSourceCropCanShrinkFromAllEightTargets() {
        let full = CGRect(x: 0, y: 0, width: 300, height: 200)
        let targets: [(CGPoint, CaptureSelectionResizeHandle)] = [
            (CGPoint(x: 7, y: 193), .topLeft),
            (CGPoint(x: 150, y: 193), .top),
            (CGPoint(x: 293, y: 193), .topRight),
            (CGPoint(x: 293, y: 100), .right),
            (CGPoint(x: 293, y: 7), .bottomRight),
            (CGPoint(x: 150, y: 7), .bottom),
            (CGPoint(x: 7, y: 7), .bottomLeft),
            (CGPoint(x: 7, y: 100), .left)
        ]
        for (point, handle) in targets {
            #expect(CaptureSelectionResizeGeometry.hit(at: point, selection: full,
                                                      clippingRect: full, bounds: full) == handle)
        }
    }

    @Test func tinyOverlappingTargetsChooseNearestThenStableTieOrder() {
        let tiny = CGRect(x: 0, y: 0, width: 4, height: 4)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: 2, y: 2), selection: tiny,
                                                  clippingRect: bounds, bounds: bounds) == .topLeft)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: 3, y: 1), selection: tiny,
                                                  clippingRect: bounds, bounds: bounds) == .bottomRight)
        let thin = CGRect(x: 0, y: 0, width: 4, height: 100)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: 2, y: 50), selection: thin,
                                                  clippingRect: bounds, bounds: bounds) == .right)
    }

    @Test func clippingAndRootBoundsRestrictHitsWithoutCreatingFalseEdges() {
        let clip = CGRect(x: -20, y: -10, width: 100, height: 100)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: -40, y: 0), selection: selection,
                                                  clippingRect: clip, bounds: bounds) == nil)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: clip.minX, y: 20), selection: selection,
                                                  clippingRect: clip, bounds: bounds) == nil)
        let root = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: -40, y: 20), selection: selection,
                                                  clippingRect: bounds, bounds: root) == nil)
    }

    @Test func emptyAndNonfiniteSelectionsDoNotInterceptInput() {
        for invalid in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)] {
            #expect(CaptureSelectionResizeGeometry.hit(at: .zero, selection: invalid,
                                                      clippingRect: bounds, bounds: bounds) == nil)
        }
    }

    @Test(arguments: CaptureSelectionResizeHandle.allCases)
    func fullScreenControlsStayReachableOutsideMenuBarAndDock(_ handle: CaptureSelectionResizeHandle) throws {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 200)
        let usable = CGRect(x: 20, y: 30, width: 260, height: 140)
        let point = try #require(CaptureSelectionResizeGeometry.controlPoint(for: handle, selection: screen,
            clippingRect: screen, bounds: screen, interactionBounds: usable))
        #expect(usable.contains(point))
        #expect(CaptureSelectionResizeGeometry.hit(at: point, selection: screen,
            clippingRect: screen, bounds: screen, interactionBounds: usable) == handle)
    }

    @Test func safeControlsDoNotInventEdgesForAnOffscreenSource() {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 200)
        let oversized = CGRect(x: -100, y: -100, width: 500, height: 400)
        #expect(CaptureSelectionResizeGeometry.controlPoint(for: .topLeft, selection: oversized,
            clippingRect: screen, bounds: screen, interactionBounds: screen) == nil)
        #expect(CaptureSelectionResizeGeometry.hit(at: CGPoint(x: 150, y: 199), selection: oversized,
            clippingRect: screen, bounds: screen, interactionBounds: screen) == nil)
    }
    @Test(arguments: [CGFloat(0.25), 2])
    func zoomedVisibleBorderMapsPointerIntoFrozenSource(zoom: CGFloat) throws {
        let sourceSize = CGSize(width: 300, height: 200)
        let displayed = CGRect(x: -40, y: -30, width: sourceSize.width * zoom, height: sourceSize.height * zoom)
        let viewport = CGRect(x: -100, y: -100, width: 1000, height: 1000)
        let edge = CaptureSelectionResizeGeometry.point(for: .right, in: displayed)
        #expect(CaptureSelectionResizeGeometry.hit(at: edge, selection: displayed,
            clippingRect: viewport, bounds: viewport) == .right)
        let mapping = try #require(CaptureSelectionResizeMapping(handle: .right, selection: displayed,
            sourceSize: sourceSize, clippingRect: viewport, bounds: viewport, interactionBounds: nil))
        let start = CGPoint(x: -1200, y: 200)
        #expect(mapping.displacement(from: start,
            to: CGPoint(x: start.x + 10 * zoom, y: start.y - 5 * zoom)) == CGSize(width: 10, height: -5))
    }

    @Test func visibleEdgeCanResizeWhenItsMidpointIsOffscreen() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = CGRect(x: 1200, y: 100, width: 800, height: 300)
        let point = CGPoint(x: 1300, y: window.maxY)
        #expect(CaptureSelectionResizeGeometry.controlPoint(for: .top, selection: window,
            clippingRect: viewport, bounds: viewport, interactionBounds: viewport) == nil)
        #expect(CaptureSelectionResizeGeometry.hit(at: point, selection: window,
            clippingRect: viewport, bounds: viewport, interactionBounds: viewport) == .top)
        let mapping = try #require(CaptureSelectionResizeMapping(handle: .top, selection: window,
            sourceSize: window.size, clippingRect: viewport, bounds: viewport, interactionBounds: viewport))
        #expect(mapping.displacement(from: point, to: CGPoint(x: point.x, y: point.y - 12))
                == CGSize(width: 0, height: -12))
    }

    @Test func insetHandleCompensationUsesTheSameFrozenZoomMapping() throws {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 200)
        let usable = CGRect(x: 20, y: 30, width: 260, height: 140)
        let mapping = try #require(CaptureSelectionResizeMapping(handle: .right, selection: screen,
            sourceSize: CGSize(width: 1200, height: 800),
            clippingRect: screen, bounds: screen, interactionBounds: usable))
        let start = CGPoint(x: -923.5, y: 500)
        #expect(mapping.displacement(from: start, to: CGPoint(x: start.x - 6, y: start.y))
                == CGSize(width: -118, height: 0))
    }

    @MainActor @Test(arguments: [25, 200])
    func resizingKeepsTheOppositeDisplayedEdgeFixedAtExistingZoom(percent: Int) throws {
        let source = try SessionTestSupport.capture()
        let frame = CGRect(x: 96, y: 100, width: 32, height: 24)
        let region = try #require(CaptureRegionSelection(source: source, screenFrame: frame,
            pixelRect: CGRect(x: 4, y: 4, width: 16, height: 12)))
        let editor = AnnotationEditor(capture: try region.croppedCapture(), regionSelection: region)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let scroll = AnnotationScrollView(editor: editor)
        root.addSubview(scroll)
        defer { scroll.canvas.detach() }
        scroll.frame = region.screenRect
        scroll.synchronizePresentation()
        scroll.apply(.percent(percent))
        let before = scroll.canvas.convert(editor.document.imageBounds, to: root)
        let mapping = try #require(CaptureSelectionResizeMapping(handle: .right, selection: before,
            sourceSize: region.screenRect.size, clippingRect: root.bounds, bounds: root.bounds,
            interactionBounds: nil))
        scroll.preserveSelectionPresentation()
        #expect(editor.beginSelectionAdjustment(resizing: .right))
        let displacement = CGFloat(percent) / 100 * 4
        try editor.updateSelectionAdjustment(by: mapping.displacement(from: .zero, to: CGPoint(x: displacement, y: 0)))
        scroll.frame = root.bounds
        scroll.synchronizePresentation()
        scroll.positionImageOrigin(CGPoint(x: before.minX, y: before.maxY), in: root)
        root.layoutSubtreeIfNeeded()
        let after = scroll.canvas.convert(editor.document.imageBounds, to: root)
        #expect(abs(after.minX - before.minX) < 0.0001)
        #expect(abs(after.maxY - before.maxY) < 0.0001)
        #expect(abs(after.maxX - before.maxX - displacement) < 0.0001)
        #expect(abs(scroll.magnification - CGFloat(percent) / 100) < 0.0001)
        editor.endSelectionAdjustment()
    }
}
