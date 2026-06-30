import XCTest
@testable import MyRAMMac

final class MacSidebarCollapsePolicyTests: XCTestCase {
    func testExpandedCollapsesWhenWidthDropsBelowThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .expanded,
            availableWidth: 400,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .autoCollapsed)
    }

    func testExpandedStaysExpandedAboveThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .expanded,
            availableWidth: 600,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .expanded)
    }

    func testAutoCollapsedExpandsWhenWidthGrowsPastThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .autoCollapsed,
            availableWidth: 600,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .expanded)
    }

    func testAutoCollapsedStaysCollapsedBelowThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .autoCollapsed,
            availableWidth: 400,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .autoCollapsed)
    }

    func testManuallyCollapsedNeverAutoExpandsWhenWidthGrows() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .manuallyCollapsed,
            availableWidth: 800,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .manuallyCollapsed)
    }

    func testManualVisibilityChangeToHiddenMarksManuallyCollapsed() {
        XCTAssertEqual(
            MacSidebarCollapsePolicy.stateAfterManualVisibilityChange(isSidebarVisible: false),
            .manuallyCollapsed
        )
    }

    func testManualVisibilityChangeToVisibleMarksExpanded() {
        XCTAssertEqual(
            MacSidebarCollapsePolicy.stateAfterManualVisibilityChange(isSidebarVisible: true),
            .expanded
        )
    }

    func testWindowFrameExpandingSidebarToLeftPreservesRightEdge() {
        let frame = MacSidebarCollapsePolicy.windowFrameExpandingSidebarToLeft(
            currentFrame: CGRect(x: 500, y: 100, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            sidebarWidth: 260
        )

        XCTAssertEqual(frame.minX, 240)
        XCTAssertEqual(frame.width, 860)
        XCTAssertEqual(frame.maxX, 1100)
        XCTAssertEqual(frame.height, 400)
    }

    func testWindowFrameExpandingSidebarToLeftClampsToVisibleFrame() {
        let frame = MacSidebarCollapsePolicy.windowFrameExpandingSidebarToLeft(
            currentFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            sidebarWidth: 260
        )

        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, 700)
        XCTAssertEqual(frame.maxX, 700)
    }
}
