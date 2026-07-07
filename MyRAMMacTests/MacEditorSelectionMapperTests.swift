import XCTest
@testable import MyRAMMac

final class EditorSelectionMapperTests: XCTestCase {
    func testInsertionBeforeCaretShiftsForward() {
        let mapped = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 5, length: 0),
            insertionOffset: 2,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 8, length: 0))
    }

    func testInsertionAfterCaretLeavesSelectionUnchanged() {
        let mapped = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 5, length: 0),
            insertionOffset: 8,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 0))
    }

    func testInsertionInsideSelectionExpandsSelection() {
        let mapped = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 2, length: 5),
            insertionOffset: 4,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 8))
    }

    func testDeletionBeforeCaretShiftsBackward() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 8, length: 0),
            deletedRange: NSRange(location: 2, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 0))
    }

    func testDeletionAfterCaretLeavesSelectionUnchanged() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 2, length: 0),
            deletedRange: NSRange(location: 5, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 0))
    }

    func testDeletionOverlappingCaretClampsToDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 4, length: 0),
            deletedRange: NSRange(location: 2, length: 4),
            resultingTextLength: 6
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 0))
    }

    func testDeletionOverlappingSelectionClampsValidly() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 2, length: 6),
            deletedRange: NSRange(location: 4, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 3))
    }

    func testDeletionOverlapFromBeforeKeepsDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 5, length: 4),
            deletedRange: NSRange(location: 3, length: 4),
            resultingTextLength: 6
        )

        XCTAssertEqual(mapped, NSRange(location: 3, length: 2))
    }

    func testDeletionStraddlingSelectionStartKeepsDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 5, length: 4),
            deletedRange: NSRange(location: 4, length: 2),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 4, length: 3))
    }

    func testLongDeletionFromZeroKeepsDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 5, length: 4),
            deletedRange: NSRange(location: 0, length: 6),
            resultingTextLength: 3
        )

        XCTAssertEqual(mapped, NSRange(location: 0, length: 3))
    }

    func testDeletionInsideSelectionTailShrinksSelection() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 5, length: 4),
            deletedRange: NSRange(location: 7, length: 2),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 2))
    }

    func testDeletionContainingSelectionCollapsesToDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 4, length: 2),
            deletedRange: NSRange(location: 3, length: 4),
            resultingTextLength: 3
        )

        XCTAssertEqual(mapped, NSRange(location: 3, length: 0))
    }
}
