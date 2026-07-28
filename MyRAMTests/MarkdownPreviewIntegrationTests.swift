import Foundation
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Selection Policy Tests

    func testModeAfterSelectionChangeDifferentIDResetsToEdit() {
        let oldID = UUID()
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Selecting a different note MUST reset mode to Edit")
    }

    func testModeAfterSelectionChangeSameIDPreservesPreview() {
        let sameID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )
        XCTAssertEqual(mode, .preview, "Same-note selection MUST preserve current Preview mode")
    }

    // MARK: - Interaction State Policy Tests

    func testInteractionStatePendingPreviewTransition() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .edit,
            hasPendingFocusRequest: true
        )
        XCTAssertEqual(state, .previewTransitionPending)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    func testInteractionStateVisiblePreview() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .preview,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .previewVisible)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    func testInteractionStateEditInteractive() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .edit,
            committedMode: .edit,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .editInteractive)
        XCTAssertFalse(state.isPreviewOrPending)
    }

    // MARK: - Resignation Policy Tests

    func testResignationPolicyUnchangedTextAcknowledgeWithoutPublication() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Hello World",
            nativePlainText: "Hello World"
        )
        XCTAssertEqual(disposition, .acknowledgeWithoutPublication,
                       "Unchanged Preview resignation MUST acknowledge without publishing edit")
    }

    func testResignationPolicyChangedTextPublishesFinalizedEdit() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Hello",
            nativePlainText: "Hello World (IME Finalized)"
        )
        XCTAssertEqual(disposition, .publishFinalizedUserEditThenAcknowledge,
                       "IME-changed text during resignation MUST publish finalized edit exactly once")
    }

    func testResignationPolicyOrdinaryEndEditing() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: false,
            boundPlainText: "Hello",
            nativePlainText: "Hello"
        )
        XCTAssertEqual(disposition, .ordinaryEndEditing,
                       "Ordinary focus loss MUST proceed with standard end-editing publication")
    }

    // MARK: - Command Consumption Policy Tests

    func testCommandConsumptionPolicyEditExecutes() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .editInteractive)
        XCTAssertEqual(disposition, .execute)
    }

    func testCommandConsumptionPolicyPendingPreviewConsumesWithoutExecution() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewTransitionPending)
        XCTAssertEqual(disposition, .consumeWithoutExecution)
    }

    func testCommandConsumptionPolicyVisiblePreviewConsumesWithoutExecution() {
        let disposition = MarkdownPreviewCommandConsumptionPolicy.disposition(forState: .previewVisible)
        XCTAssertEqual(disposition, .consumeWithoutExecution)
    }

    // MARK: - Search Interaction Policy Tests

    func testSearchInteractionPolicyHidesInPreview() {
        let isPresented = MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
            state: .previewVisible,
            isSearchActiveInState: true
        )
        XCTAssertFalse(isPresented, "Search controls MUST be hidden while in Preview mode")
    }

    func testSearchInteractionPolicyHidesInPendingPreview() {
        let isPresented = MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
            state: .previewTransitionPending,
            isSearchActiveInState: true
        )
        XCTAssertFalse(isPresented, "Search controls MUST be hidden while Preview is pending")
    }

    func testSearchInteractionPolicyRemovesHighlightInPreview() {
        let highlight = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .previewVisible,
            highlightRange: NSRange(location: 0, length: 5)
        )
        XCTAssertNil(highlight, "Body search highlight MUST be nil while in Preview mode")
    }

}
