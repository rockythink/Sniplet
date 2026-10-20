import CoreGraphics
import Testing
@testable import Sniplet

nonisolated struct OCRReadingOrderTests {
    @Test func ordersTopToBottomThenLeftToRight() {
        let fragments = [
            fragment("下行右", x: 80, y: 50),
            fragment("上行右", x: 80, y: 11),
            fragment("下行左", x: 10, y: 50),
            fragment("上行左", x: 10, y: 10)
        ]
        #expect(OCRReadingOrder.text(from: fragments) == "上行左 上行右\n下行左 下行右")
    }

    @Test func halfHeightOverlapIsInclusiveAndAnchorDoesNotGrow() {
        let fragments = [
            fragment("third", x: 60, y: 21, height: 20),
            fragment("second", x: 30, y: 10, height: 20),
            fragment("first", x: 0, y: 0, height: 20)
        ]
        // second overlaps first by exactly 50%. third overlaps second, but must
        // compare with first, not the row's expanded union or latest member.
        #expect(OCRReadingOrder.text(from: fragments) == "first second\nthird")
    }

    @Test func choosesLargestOverlapRatioAmongMatchingRows() {
        let fragments = [
            fragment("candidate", x: 20, y: 85, height: 20),
            fragment("second-row", x: 0, y: 80, height: 100),
            fragment("first-row", x: 40, y: 0, height: 100)
        ]
        // candidate overlaps the first anchor by 75%, the second by 100%.
        #expect(OCRReadingOrder.text(from: fragments) == "first-row\nsecond-row candidate")
    }

    @Test func equalOverlapChoosesFirstCreatedRow() {
        let fragments = [
            fragment("candidate", x: 20, y: 80, height: 10),
            fragment("second-row", x: 0, y: 80, height: 100),
            fragment("first-row", x: 40, y: 0, height: 100)
        ]
        // The two anchors do not match each other. The short candidate is
        // completely inside both: equal ratios must choose the earlier row.
        #expect(OCRReadingOrder.text(from: fragments) == "candidate first-row\nsecond-row")
    }

    @Test func usesShorterHeightRatherThanUnionForMixedHeights() {
        let fragments = [
            fragment("small", x: 0, y: 40, height: 10),
            fragment("tall", x: 30, y: 0, height: 100),
            fragment("next", x: 0, y: 110, height: 10)
        ]
        #expect(OCRReadingOrder.text(from: fragments) == "small tall\nnext")
    }

    @Test func equalXUsesTopEdgeThenDeterministicGeometryAndTextTies() {
        let fragments = [
            fragment("later", x: 10, y: 5, height: 20),
            fragment("B", x: 10, y: 0, height: 20),
            fragment("A", x: 10, y: 0, height: 20)
        ]
        let expected = "A B later"
        #expect(OCRReadingOrder.text(from: fragments) == expected)
        #expect(OCRReadingOrder.text(from: Array(fragments.reversed())) == expected)
    }

    @Test func equalTopEdgeUsesXBeforeCreatingRows() {
        let fragments = [
            fragment("right", x: 80, y: 10),
            fragment("left", x: 10, y: 10)
        ]
        #expect(OCRReadingOrder.lines(from: fragments).map { $0.map(\.text) } == [["left", "right"]])
    }

    @Test func emptyObservationsProduceSuccessfulEmptyText() {
        #expect(OCRReadingOrder.lines(from: []).isEmpty)
        #expect(OCRReadingOrder.text(from: []).isEmpty)
    }

    private func fragment(_ text: String, x: CGFloat, y: CGFloat,
                          width: CGFloat = 10, height: CGFloat = 10) -> OCRTextFragment {
        // Binary fractions keep the exact 50% threshold and tie fixtures exact.
        OCRTextFragment(text: text, boundingBox: CGRect(x: x / 256, y: y / 256,
                                                       width: width / 256, height: height / 256))
    }
}
