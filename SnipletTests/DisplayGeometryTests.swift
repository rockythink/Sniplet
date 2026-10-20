import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

struct DisplayGeometryTests {
    @Test func negativeOriginRetinaUsesLocalTopLeft() {
        let frame = CGRect(x: -1200, y: 300, width: 1200, height: 900)
        let rect = CGRect(x: -1190, y: 1100, width: 100, height: 80)
        #expect(DisplayGeometry.pixelRect(for: rect, screenFrame: frame, imageWidth: 2400, imageHeight: 1800)
                == CGRect(x: 20, y: 40, width: 200, height: 160))
    }

    @Test func aboveMainScreenAtOneTimesScale() {
        let frame = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let rect = CGRect(x: 100, y: 1980, width: 100, height: 80)
        #expect(DisplayGeometry.pixelRect(for: rect, screenFrame: frame, imageWidth: 1920, imageHeight: 1080)
                == CGRect(x: 100, y: 100, width: 100, height: 80))
    }

    @Test func eachAxisUsesActualPixelRatioAndRoundsOutward() {
        let frame = CGRect(x: -100, y: -50, width: 100, height: 100)
        let rect = CGRect(x: -99.75, y: 39.75, width: 10, height: 10)
        #expect(DisplayGeometry.pixelRect(for: rect, screenFrame: frame, imageWidth: 200, imageHeight: 150)
                == CGRect(x: 0, y: 0, width: 21, height: 16))
    }

    @Test func clipsToImageEdgesWithoutAddingPixels() {
        let frame = CGRect(x: -500, y: -400, width: 500, height: 400)
        #expect(DisplayGeometry.pixelRect(for: CGRect(x: -501, y: -401, width: 502, height: 402),
                                         screenFrame: frame, imageWidth: 1000, imageHeight: 800)
                == CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    @Test func reverseDragAndCrossScreenClamping() {
        let frame = CGRect(x: -1000, y: 200, width: 1000, height: 800)
        #expect(DisplayGeometry.selection(from: CGPoint(x: -100, y: 900), to: CGPoint(x: -200, y: 820), in: frame)
                == CGRect(x: -200, y: 820, width: 100, height: 80))
        #expect(DisplayGeometry.selection(from: CGPoint(x: -100, y: 900), to: CGPoint(x: 100, y: 1100), in: frame)
                == CGRect(x: -100, y: 900, width: 100, height: 100))
    }

    @Test func emptyOutsideAndInvalidSelectionsProduceNoPixels() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        for rect in [CGRect(x: 2, y: 3, width: 0, height: 10), CGRect(x: 2, y: 3, width: 10, height: 0),
                     CGRect(x: 101, y: 101, width: 10, height: 10), CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            #expect(DisplayGeometry.pixelRect(for: rect, screenFrame: frame, imageWidth: 200, imageHeight: 200) == nil)
        }
        #expect(DisplayGeometry.pixelRect(for: frame, screenFrame: frame, imageWidth: 0, imageHeight: 200) == nil)
    }

    @Test func quartzMappingAndInverseRectangleOnNegativeDisplays() {
        let frame = CGRect(x: -1440, y: 400, width: 1440, height: 900)
        let quartz = CGRect(x: -1440, y: -220, width: 1440, height: 900)
        #expect(DisplayGeometry.quartzPoint(CGPoint(x: -1400, y: 1280), screenFrame: frame, displayBounds: quartz)
                == CGPoint(x: -1400, y: -200))
        #expect(DisplayGeometry.appKitRect(CGRect(x: -1400, y: -200, width: 100, height: 80), screenFrame: frame, displayBounds: quartz)
                == CGRect(x: -1400, y: 1200, width: 100, height: 80))
    }

    @Test func crossingWindowHighlightUsesOneGlobalConversionAndClipsEachOverlay() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let window = DisplayGeometry.appKitRect(CGRect(x: -100, y: 220, width: 200, height: 80),
                                               screenFrame: left,
                                               displayBounds: CGRect(x: -1440, y: 180, width: 1440, height: 900))
        #expect(DisplayGeometry.overlayRect(for: window, in: left)
                == CGRect(x: 1340, y: 780, width: 100, height: 80))
        #expect(DisplayGeometry.overlayRect(for: window, in: main)
                == CGRect(x: 0, y: 780, width: 100, height: 80))
        #expect(DisplayGeometry.overlayRect(for: window, in: above) == nil)
    }

    @Test func windowHitPreservesFrontToBackOrder() {
        let front = WindowCandidate(id: 2, bounds: CGRect(x: -100, y: -50, width: 200, height: 100))
        let back = WindowCandidate(id: 1, bounds: CGRect(x: -200, y: -100, width: 400, height: 200))
        #expect(WindowSelectionService.hit(at: .zero, candidates: [front, back])?.id == 2)
        #expect(WindowSelectionService.hit(at: CGPoint(x: 150, y: 0), candidates: [front, back])?.id == 1)
        #expect(WindowSelectionService.hit(at: CGPoint(x: 300, y: 0), candidates: [front, back]) == nil)
    }
}
