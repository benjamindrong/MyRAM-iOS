import XCTest
@testable import MyRAM

final class EditorSelectionMapperTests: XCTestCase {
    func testInsertionAtCollapsedCaretAdvancesCaret() {
        let mapped = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 5, length: 0),
            insertionOffset: 5,
            insertedUTF16Length: 2,
            resultingTextLength: 12
        )

        XCTAssertEqual(mapped, NSRange(location: 7, length: 0))
    }

    func testInsertionInsideSelectionExpandsEnd() {
        let mapped = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 2, length: 5),
            insertionOffset: 4,
            insertedUTF16Length: 3,
            resultingTextLength: 13
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 8))
    }

    func testDeletionContainingCaretCollapsesToDeletionStart() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 4, length: 0),
            deletedRange: NSRange(location: 2, length: 4),
            resultingTextLength: 6
        )

        XCTAssertEqual(mapped, NSRange(location: 2, length: 0))
    }

    func testOrderedBatchWithEmojiUsesUTF16Lengths() {
        let emojiLength = ("😀" as NSString).length
        let afterInsertion = EditorSelectionMapper.selectionAfterInsertion(
            current: NSRange(location: 4, length: 0),
            insertionOffset: 1,
            insertedUTF16Length: emojiLength,
            resultingTextLength: 8
        )
        let afterDeletion = EditorSelectionMapper.selectionAfterDeletion(
            current: afterInsertion,
            deletedRange: NSRange(location: 2, length: 1),
            resultingTextLength: 7
        )

        XCTAssertEqual(afterInsertion, NSRange(location: 6, length: 0))
        XCTAssertEqual(afterDeletion, NSRange(location: 5, length: 0))
    }

    func testMappingClampsPastDocumentEnd() {
        let mapped = EditorSelectionMapper.selectionAfterDeletion(
            current: NSRange(location: 8, length: 6),
            deletedRange: NSRange(location: 1, length: 2),
            resultingTextLength: 5
        )

        XCTAssertEqual(mapped, NSRange(location: 5, length: 0))
    }
}
