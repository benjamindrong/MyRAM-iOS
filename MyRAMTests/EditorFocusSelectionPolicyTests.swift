import XCTest
@testable import MyRAM

final class EditorFocusSelectionPolicyTests: XCTestCase {
    func testFocusRestoreUsesValidSessionFallbackWhenCurrentRangeIsNotFound() {
        let sessionRange = NSRange(location: 4, length: 0)

        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: NSNotFound, length: 0),
            focusAcquisitionRange: nil,
            sessionRange: sessionRange,
            textLength: 12
        )

        XCTAssertEqual(decision, .restoreSessionFallback(sessionRange))
    }

    func testFocusRestoreRejectsInvalidSessionFallback() {
        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: NSNotFound, length: 0),
            focusAcquisitionRange: nil,
            sessionRange: NSRange(location: 20, length: 1),
            textLength: 12
        )

        XCTAssertEqual(decision, .acceptCurrent)
    }

    func testFocusRestoreUsesFocusAcquisitionForTransientEndOfDocumentSelection() {
        let focusRange = NSRange(location: 3, length: 0)

        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: 12, length: 0),
            focusAcquisitionRange: focusRange,
            sessionRange: nil,
            textLength: 12
        )

        XCTAssertEqual(decision, .restoreFocusAcquisition(focusRange))
    }

    func testFocusRestoreRejectsInvalidFocusAcquisitionRange() {
        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: 12, length: 0),
            focusAcquisitionRange: NSRange(location: 14, length: 0),
            sessionRange: nil,
            textLength: 12
        )

        XCTAssertEqual(decision, .acceptCurrent)
    }

    func testFocusRestoreAcceptsNewerValidCurrentSelection() {
        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: 8, length: 0),
            focusAcquisitionRange: NSRange(location: 3, length: 0),
            sessionRange: NSRange(location: 2, length: 0),
            textLength: 12
        )

        XCTAssertEqual(decision, .acceptCurrent)
    }

    func testFocusRestoreAcceptsFirstOpenState() {
        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: 0, length: 0),
            focusAcquisitionRange: nil,
            sessionRange: nil,
            textLength: 12
        )

        XCTAssertEqual(decision, .acceptCurrent)
    }

    func testFocusRestoreAcceptsTextEndCaretWithoutFocusAcquisitionFallback() {
        let decision = EditorFocusSelectionPolicy.focusRestoreDecision(
            currentRange: NSRange(location: 12, length: 0),
            focusAcquisitionRange: nil,
            sessionRange: nil,
            textLength: 12
        )

        XCTAssertEqual(decision, .acceptCurrent)
    }

    func testCachedSelectionUsesPositiveLengthCachedRangeWhileUnfocused() {
        let cachedRange = NSRange(location: 2, length: 4)

        let range = EditorFocusSelectionPolicy.cachedSelectionRange(
            currentRange: NSRange(location: 0, length: 0),
            isFirstResponder: false,
            cachedRange: cachedRange,
            textLength: 12
        )

        XCTAssertEqual(range, cachedRange)
    }

    func testCachedSelectionRejectsInvalidCachedRange() {
        let range = EditorFocusSelectionPolicy.cachedSelectionRange(
            currentRange: NSRange(location: 0, length: 0),
            isFirstResponder: false,
            cachedRange: NSRange(location: 11, length: 4),
            textLength: 12
        )

        XCTAssertNil(range)
    }

    func testCachedSelectionUsesFocusedCollapsedCurrentRange() {
        let currentRange = NSRange(location: 12, length: 0)

        let range = EditorFocusSelectionPolicy.cachedSelectionRange(
            currentRange: currentRange,
            isFirstResponder: true,
            cachedRange: NSRange(location: 2, length: 4),
            textLength: 12
        )

        XCTAssertEqual(range, currentRange)
    }

    func testShouldCacheSelectionPreservesExistingPredicate() {
        XCTAssertTrue(EditorFocusSelectionPolicy.shouldCacheSelection(
            range: NSRange(location: 0, length: 1),
            isFirstResponder: false
        ))
        XCTAssertTrue(EditorFocusSelectionPolicy.shouldCacheSelection(
            range: NSRange(location: 0, length: 0),
            isFirstResponder: true
        ))
        XCTAssertFalse(EditorFocusSelectionPolicy.shouldCacheSelection(
            range: NSRange(location: 0, length: 0),
            isFirstResponder: false
        ))
    }
}
