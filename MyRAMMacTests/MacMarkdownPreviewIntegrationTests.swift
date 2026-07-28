import Foundation
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Selection policy (production AppKit path)

    func testInitialModeIsEdit() {
        let mode = MarkdownEditorMode.edit
        XCTAssertEqual(mode, .edit)
    }

    func testSameNoteReloadPreservesPreviewModeUsingProductionPolicy() {
        let sameID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )
        XCTAssertEqual(mode, .preview, "Production selection policy MUST preserve Preview mode on same-note reloads")
    }

    func testDifferentNoteSelectionResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let newID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: newID
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note changes")
    }

    func testSyncDrivenRemovalResetsToEditModeUsingProductionPolicy() {
        let oldID = UUID()
        let mode = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: oldID,
            newID: nil
        )
        XCTAssertEqual(mode, .edit, "Production selection policy MUST reset to Edit mode when selected note is removed")
    }

    // MARK: - Interaction state policy

    func testInteractionStateIsEditInteractiveInEditMode() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .edit,
            committedMode: .edit,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .editInteractive)
        XCTAssertFalse(state.isPreviewOrPending)
    }

    func testInteractionStateIsPendingWhenFocusRequestIsOutstanding() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .edit,
            hasPendingFocusRequest: true
        )
        XCTAssertEqual(state, .previewTransitionPending)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    func testInteractionStateIsVisiblePreviewWhenCommitted() {
        let state = MarkdownPreviewInteractionPolicy.state(
            requestedMode: .preview,
            committedMode: .preview,
            hasPendingFocusRequest: false
        )
        XCTAssertEqual(state, .previewVisible)
        XCTAssertTrue(state.isPreviewOrPending)
    }

    // MARK: - Resignation policy (AppKit focus behavior)

    func testResignationWithNoTextChangeMeansAcknowledgeWithoutPublication() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Note text",
            nativePlainText: "Note text"
        )
        XCTAssertEqual(disposition, .acknowledgeWithoutPublication,
            "AppKit Preview resignation with no text change MUST NOT schedule save or trigger onTextChanged")
    }

    func testResignationWithIMEMutationPublishesFinalizedEditThenAcknowledges() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Draft",
            nativePlainText: "Draft + finalized"
        )
        XCTAssertEqual(disposition, .publishFinalizedUserEditThenAcknowledge,
            "AppKit Preview resignation with IME-finalized text MUST publish exactly once before acknowledging")
    }

    func testOrdinaryFocusLossProducesOrdinaryEndEditing() {
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: false,
            boundPlainText: "any",
            nativePlainText: "any"
        )
        XCTAssertEqual(disposition, .ordinaryEndEditing,
            "Non-Preview focus loss MUST follow ordinary end-editing path")
    }

    // MARK: - Search isolation during Preview (AppKit)

    func testSearchSuppressedInPendingPreviewState() {
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewTransitionPending,
                isSearchActiveInState: true
            ),
            "Search MUST be suppressed while AppKit Preview transition is pending"
        )
    }

    func testSearchSuppressedInVisiblePreviewState() {
        XCTAssertFalse(
            MarkdownPreviewSearchInteractionPolicy.isSearchPresented(
                state: .previewVisible,
                isSearchActiveInState: true
            ),
            "Search MUST be suppressed while AppKit Preview is visible"
        )
    }

    func testSearchBodyHighlightNilInAnyPreviewState() {
        let highlight = MarkdownPreviewSearchInteractionPolicy.bodyHighlightRange(
            state: .previewVisible,
            highlightRange: NSRange(location: 0, length: 5)
        )
        XCTAssertNil(highlight,
            "Body search highlight MUST be nil when AppKit Preview is visible — must not scroll hidden editor")
    }
}
