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

    func testZoomInCreatesAdditionalWrappedLinesWithoutChangingStorage() throws {
        let fixture = makeFixture(width: 360)
        let scrollView = fixture.scrollView
        let textView = fixture.textView
        let originalDocument = NSAttributedString(attributedString: textView.attributedString())

        MacNoteViewZoom.apply(1.0, to: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        let actualSizeLineCount = lineFragmentCount(in: textView)
        let actualSizeUsedHeight = usedLayoutHeight(in: textView)
        XCTAssertGreaterThan(actualSizeLineCount, 1)
        XCTAssertEqual(
            textView.frame.width,
            scrollView.contentSize.width,
            accuracy: 1.0
        )

        MacNoteViewZoom.apply(2.0, to: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        let zoomedLineCount = lineFragmentCount(in: textView)
        let zoomedUsedHeight = usedLayoutHeight(in: textView)

        XCTAssertEqual(scrollView.magnification, 2.0, accuracy: 0.0001)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertGreaterThan(
            zoomedLineCount,
            actualSizeLineCount,
            "Zoom In must create additional TextKit line fragments"
        )
        XCTAssertGreaterThan(
            zoomedUsedHeight,
            actualSizeUsedHeight,
            "Zoom In must increase laid-out document height through reflow"
        )
        XCTAssertEqual(
            textView.frame.width,
            scrollView.contentSize.width / 2.0,
            accuracy: 1.0
        )
        XCTAssertLessThanOrEqual(
            textView.frame.width * scrollView.magnification,
            scrollView.contentSize.width + 1.0
        )
        XCTAssertTrue(textView.attributedString().isEqual(to: originalDocument))

        MacNoteViewZoom.apply(1.0, to: scrollView)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.magnification, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lineFragmentCount(in: textView), actualSizeLineCount)
        XCTAssertEqual(usedLayoutHeight(in: textView), actualSizeUsedHeight, accuracy: 1.0)
        XCTAssertEqual(textView.frame.width, scrollView.contentSize.width, accuracy: 1.0)
        XCTAssertTrue(textView.attributedString().isEqual(to: originalDocument))
    }

    func testViewportResizeReappliesCurrentReflowWidth() {
        let fixture = makeFixture(width: 320)
        let scrollView = fixture.scrollView
        let textView = fixture.textView

        MacNoteViewZoom.apply(2.0, to: scrollView)
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            textView.frame.width,
            scrollView.contentSize.width / 2.0,
            accuracy: 1.0
        )

        scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.magnification, 2.0, accuracy: 0.0001)
        XCTAssertEqual(
            textView.frame.width,
            scrollView.contentSize.width / 2.0,
            accuracy: 1.0
        )
        XCTAssertLessThanOrEqual(
            textView.frame.width * scrollView.magnification,
            scrollView.contentSize.width + 1.0
        )
    }

    private func makeFixture(width: CGFloat) -> (
        scrollView: MacNoteReflowingScrollView,
        textView: NSTextView
    ) {
        let scrollView = MacNoteReflowingScrollView(
            frame: NSRect(x: 0, y: 0, width: width, height: 240)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 240)
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true

        let source = String(
            repeating: "A readable note sentence should remain inside the window and wrap naturally. ",
            count: 24
        )
        let document = NSAttributedString(
            string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 20)]
        )
        textView.textStorage?.setAttributedString(document)
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, textView)
    }

    private func lineFragmentCount(in textView: NSTextView) -> Int {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Expected TextKit layout objects")
            return 0
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var count = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, _, _, _, _ in
            count += 1
        }
        return count
    }

    private func usedLayoutHeight(in textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Expected TextKit layout objects")
            return 0
        }
        layoutManager.ensureLayout(for: textContainer)
        return layoutManager.usedRect(for: textContainer).height
    }
}
