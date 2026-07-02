import XCTest
@testable import MyRAMMac

final class MacEditorSelectionMapperTests: XCTestCase {
    func testInsertionBeforeCaretShiftsForward() {
        let mapped = MacEditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 5, length: 0),
            insertionOffset: 2,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 8, length: 0))
    }

    func testInsertionAfterCaretLeavesSelectionUnchanged() {
        let mapped = MacEditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 5, length: 0),
            insertionOffset: 8,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 0))
    }

    func testInsertionInsideSelectionExpandsSelection() {
        let mapped = MacEditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 2, length: 5),
            insertionOffset: 4,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 8))
    }

    func testDeletionBeforeCaretShiftsBackward() {
        let mapped = MacEditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 8, length: 0),
            deletedRange: NSRange(location: 2, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 0))
    }

    func testDeletionAfterCaretLeavesSelectionUnchanged() {
        let mapped = MacEditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 2, length: 0),
            deletedRange: NSRange(location: 5, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 0))
    }

    func testDeletionOverlappingCaretClampsToDeletionStart() {
        let mapped = MacEditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 4, length: 0),
            deletedRange: NSRange(location: 2, length: 4),
            resultingTextLength: 6
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 0))
    }

    func testDeletionOverlappingSelectionClampsValidly() {
        let mapped = MacEditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 2, length: 6),
            deletedRange: NSRange(location: 4, length: 3),
            resultingTextLength: 7
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 3))
    }
}
