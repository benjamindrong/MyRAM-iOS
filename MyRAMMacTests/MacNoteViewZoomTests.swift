import AppKit
import SwiftUI
import XCTest
@testable import MyRAMMac

@MainActor
final class MacNoteViewZoomTests: XCTestCase {
    func testPolicyConstantsAndActualSize() {
        XCTAssertEqual(MacNoteViewZoom.actualSize, 1.0)
        XCTAssertEqual(MacNoteViewZoom.minimum, 0.5)
        XCTAssertEqual(MacNoteViewZoom.maximum, 3.0)
        XCTAssertEqual(MacNoteViewZoom.step, 0.1)
        XCTAssertTrue(MacNoteViewZoom.isActualSize(1.0))
        XCTAssertFalse(MacNoteViewZoom.isActualSize(1.1))
    }

    func testZoomStepsNormalizeWithoutBoundaryDrift() {
        var value = MacNoteViewZoom.actualSize
        value = MacNoteViewZoom.zoomedIn(from: value)
        XCTAssertEqual(value, 1.1, accuracy: 0.0001)
        value = MacNoteViewZoom.zoomedOut(from: value)
        XCTAssertEqual(value, 1.0, accuracy: 0.0001)

        for _ in 0..<100 {
            value = MacNoteViewZoom.zoomedIn(from: value)
        }
        XCTAssertEqual(value, 3.0, accuracy: 0.0001)
        XCTAssertFalse(MacNoteViewZoom.canZoomIn(value))

        for _ in 0..<100 {
            value = MacNoteViewZoom.zoomedOut(from: value)
        }
        XCTAssertEqual(value, 0.5, accuracy: 0.0001)
        XCTAssertFalse(MacNoteViewZoom.canZoomOut(value))
    }

    func testNormalizationRoundsBeforeClamping() {
        XCTAssertEqual(MacNoteViewZoom.normalized(1.049), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MacNoteViewZoom.normalized(1.051), 1.1, accuracy: 0.0001)
        XCTAssertEqual(MacNoteViewZoom.normalized(9), 3.0, accuracy: 0.0001)
        XCTAssertEqual(MacNoteViewZoom.normalized(-9), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MacNoteViewZoom.normalized(.infinity), 1.0, accuracy: 0.0001)
    }

    func testBoundaryAvailability() {
        XCTAssertTrue(MacNoteViewZoom.canZoomIn(0.5))
        XCTAssertFalse(MacNoteViewZoom.canZoomIn(3.0))
        XCTAssertTrue(MacNoteViewZoom.canZoomOut(3.0))
        XCTAssertFalse(MacNoteViewZoom.canZoomOut(0.5))
    }

    func testIndependentBindingsDoNotShareState() {
        var first = MacNoteViewZoom.actualSize
        var second = MacNoteViewZoom.actualSize
        let firstBinding = Binding(get: { first }, set: { first = $0 })
        let secondBinding = Binding(get: { second }, set: { second = $0 })

        firstBinding.wrappedValue = MacNoteViewZoom.zoomedIn(from: firstBinding.wrappedValue)

        XCTAssertEqual(first, 1.1, accuracy: 0.0001)
        XCTAssertEqual(secondBinding.wrappedValue, 1.0, accuracy: 0.0001)
    }

    func testAppKitApplicatorReflowsTextInsideViewportWithoutChangingDocument() {
        let scrollView = MacNoteReflowingScrollView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200)
        )
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = String(repeating: "Document content that must wrap inside the viewport. ", count: 20)
        let originalString = textView.string
        scrollView.documentView = textView

        MacNoteViewZoom.apply(2.0, to: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.magnification, 2.0, accuracy: 0.0001)
        XCTAssertEqual(scrollView.minMagnification, 0.5, accuracy: 0.0001)
        XCTAssertEqual(scrollView.maxMagnification, 3.0, accuracy: 0.0001)
        XCTAssertFalse(scrollView.allowsMagnification)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(textView.string, originalString)
        XCTAssertEqual(
            textView.frame.width,
            scrollView.documentVisibleRect.width,
            accuracy: 1.0
        )
        XCTAssertLessThanOrEqual(
            textView.frame.width * scrollView.magnification,
            scrollView.contentSize.width + 1.0
        )
    }
}
