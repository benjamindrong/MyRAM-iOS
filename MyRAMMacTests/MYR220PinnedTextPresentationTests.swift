import Foundation
import XCTest
@testable import MyRAMMac

final class MYR220PinnedTextPresentationTests: XCTestCase {
    func testZeroPinsPreservesDerivedBodyWithTwoLineBudget() {
        let note = Note(title: "Zero", content: "ignored")
        let plan = MacNoteListRowPlanFactory.make(note: note, bodyPreview: "derived body")

        XCTAssertTrue(plan.pinnedTextPreviews.isEmpty)
        XCTAssertEqual(plan.bodyPreview, "derived body")
        XCTAssertTrue(plan.bodyIsEligible)
        XCTAssertEqual(plan.bodyLineLimit, 2)
        XCTAssertNil(plan.visibleCountText)
        XCTAssertNil(plan.countAccessibilityIdentifier)
    }

    func testOnePinUsesOnePinLineAndOneBodyLineWithoutCount() {
        let note = Note(title: "One", content: "ignored")
        note.pinnedThoughts = [PinnedThought(text: "  First pin  ", order: 0, note: note)]
        note.isPinned = true

        let plan = MacNoteListRowPlanFactory.make(note: note, bodyPreview: "Mac-derived body")

        XCTAssertEqual(plan.pinnedTextPreviews, ["First pin"])
        XCTAssertEqual(plan.firstPinnedTextLineLimit, 1)
        XCTAssertEqual(plan.bodyPreview, "Mac-derived body")
        XCTAssertEqual(plan.bodyLineLimit, 1)
        XCTAssertNil(plan.visibleCountText)
        XCTAssertNil(plan.countAccessibilityIdentifier)
        XCTAssertEqual(plan.totalPinnedTextCount, 1)
    }

    func testTwoPinsShowSeparateOrderedPreviewsAndExactCount() {
        let note = Note(title: "Two", content: "ignored")
        let later = PinnedThought(text: "Second", order: 2, note: note)
        later.createdAt = Date(timeIntervalSinceReferenceDate: 20)
        let earlier = PinnedThought(text: "First", order: 1, note: note)
        earlier.createdAt = Date(timeIntervalSinceReferenceDate: 30)
        note.pinnedThoughts = [later, earlier]

        let plan = MacNoteListRowPlanFactory.make(note: note, bodyPreview: "body")

        XCTAssertEqual(plan.pinnedTextPreviews, ["First", "Second"])
        XCTAssertFalse(plan.bodyIsEligible)
        XCTAssertNil(plan.bodyPreview)
        XCTAssertEqual(plan.visibleCountText, "2 pinned texts")
        XCTAssertEqual(plan.accessibilityCountText, "2 pinned texts")
        XCTAssertEqual(plan.countAccessibilityIdentifier, "myram.noteRow.pinnedTextCount")
        XCTAssertTrue(plan.countOccupiesAuxiliarySlot)
    }

    func testMoreThanTwoPinsFilterWhitespaceUseOrderThenCreatedAtAndReserveCountSlot() {
        let note = Note(title: "Many", content: "ignored")
        note.isPinned = true
        let tieLater = PinnedThought(text: "Third", order: 2, note: note)
        tieLater.createdAt = Date(timeIntervalSinceReferenceDate: 30)
        let empty = PinnedThought(text: " \n ", order: 0, note: note)
        let first = PinnedThought(text: "  First long pinned text that must remain a one-line tail-truncation candidate  ", order: 1, note: note)
        let tieEarlier = PinnedThought(text: "Second", order: 2, note: note)
        tieEarlier.createdAt = Date(timeIntervalSinceReferenceDate: 20)
        let fourth = PinnedThought(text: "Fourth", order: 3, note: note)
        note.pinnedThoughts = [tieLater, empty, fourth, first, tieEarlier]

        let plan = MacNoteListRowPlanFactory.make(note: note, bodyPreview: "body")

        XCTAssertEqual(plan.pinnedTextPreviews, ["First long pinned text that must remain a one-line tail-truncation candidate", "Second"])
        XCTAssertEqual(plan.firstPinnedTextLineLimit, 1)
        XCTAssertEqual(plan.secondPinnedTextLineLimit, 1)
        XCTAssertEqual(plan.totalPinnedTextCount, 4)
        XCTAssertEqual(plan.remainingPinnedTextCount, 2)
        XCTAssertEqual(plan.visibleCountText, "4 pinned texts · +2 more")
        XCTAssertEqual(plan.accessibilityCountText, "4 pinned texts, 2 more not shown")
        XCTAssertEqual(plan.countAccessibilityIdentifier, "myram.noteRow.pinnedTextCount")
        XCTAssertTrue(plan.countOccupiesAuxiliarySlot)
        XCTAssertFalse(plan.bodyIsEligible)
    }
}
