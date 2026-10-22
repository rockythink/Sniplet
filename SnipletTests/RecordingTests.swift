import CoreGraphics
import Foundation
import Testing
@testable import Sniplet

struct RecordingGeometryTests {
    @Test func sourceRectIsDisplayLocalWithATopLeftOrigin() {
        // A secondary display to the left of and above the primary one.
        let screen = CGRect(x: -1440, y: 300, width: 1440, height: 900)
        let rect = CGRect(x: -1340, y: 1000, width: 400, height: 150)
        #expect(RecordingGeometry.sourceRect(for: rect, screenFrame: screen)
                == CGRect(x: 100, y: 50, width: 400, height: 150))
        // Anything outside the display is clipped away.
        let spilling = CGRect(x: -100, y: 250, width: 300, height: 200)
        #expect(RecordingGeometry.sourceRect(for: spilling, screenFrame: screen)
                == CGRect(x: 1340, y: 750, width: 100, height: 150))
    }

    @Test func outputSizeIsEvenAndKeepsRetinaPixels() throws {
        let size = try #require(RecordingGeometry.outputSize(points: CGSize(width: 301.5, height: 99.7), scale: 2))
        #expect(size.width == 602 && size.height == 198)
        #expect(RecordingGeometry.outputSize(points: CGSize(width: 0.5, height: 40), scale: 2) == nil)
    }

    @Test func largeAreasAreScaledDownToAnEncodableSize() throws {
        let size = try #require(RecordingGeometry.outputSize(points: CGSize(width: 2560, height: 1440), scale: 2))
        #expect(CGFloat(size.width * size.height) <= RecordingGeometry.maxPixels)
        #expect(CGFloat(max(size.width, size.height)) <= RecordingGeometry.maxSide)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
        // The aspect ratio survives the shrink to within a pixel of rounding.
        #expect(abs(Double(size.width) / Double(size.height) - 16.0 / 9.0) < 0.01)
    }

    @Test func durationsReadAsMinutesAndSeconds() {
        #expect(RecordedVideo.format(0) == "0:00")
        #expect(RecordedVideo.format(9.6) == "0:10")
        #expect(RecordedVideo.format(754) == "12:34")
        #expect(ExportFilename.mp4(createdAt: Date(timeIntervalSince1970: 0)).hasSuffix(".mp4"))
    }
}

struct RecordingStopButtonPlacementTests {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 110, height: 36)

    @Test func sitsAboveTheTopRightCornerWhenThereIsRoom() {
        let area = CGRect(x: 200, y: 200, width: 600, height: 400)
        #expect(RecordingGeometry.stopButtonFrame(size: size, area: area, visible: visible)
                == CGRect(x: 690, y: 606, width: 110, height: 36))
    }

    @Test func dropsBelowWhenTheAreaTouchesTheTop() {
        let area = CGRect(x: 200, y: 400, width: 600, height: 470)
        let frame = RecordingGeometry.stopButtonFrame(size: size, area: area, visible: visible)
        #expect(frame.maxY == area.minY - 6)
    }

    @Test func staysInsideTheCornerForAFullScreenAreaAndNeverLeavesTheScreen() {
        let frame = RecordingGeometry.stopButtonFrame(size: size, area: visible, visible: visible)
        #expect(visible.contains(frame))
        #expect(frame.maxX == visible.maxX - 6 && frame.maxY == visible.maxY - 6)
        let offLeft = RecordingGeometry.stopButtonFrame(size: size, area: CGRect(x: 0, y: 100, width: 40, height: 40), visible: visible)
        #expect(offLeft.minX >= visible.minX)
    }
}

struct CountdownLayoutTests {
    @Test func theNumberSitsInsideOnlyWhenTheAreaHasRoomForIt() {
        #expect(CountdownLayout.showsNumberInside(CGRect(x: 0, y: 0, width: 400, height: 240)))
        #expect(CountdownLayout.showsNumberInside(CGRect(x: 0, y: 0, width: 120, height: 80)))
        #expect(!CountdownLayout.showsNumberInside(CGRect(x: 0, y: 0, width: 300, height: 40)))
        #expect(!CountdownLayout.showsNumberInside(CGRect(x: 0, y: 0, width: 90, height: 300)))
    }
}
