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
}
