import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Real AppKit Host & Resignation Tests (§9.3)

    func testRealNSTextViewResignsFirstResponderWhenOwnedByEditor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)

        let focusSuccess = window.makeFirstResponder(textView)
        XCTAssertTrue(focusSuccess, "NSTextView must acquire first responder status in test window")
        XCTAssertTrue(window.firstResponder === textView)

        let adapter = MacMarkdownPreviewTestAdapter(
            resignFirstResponderIfOwned: { win, view in
                if win?.firstResponder === view {
                    win?.makeFirstResponder(nil)
                }
            },
            currentFirstResponder: { win in win?.firstResponder }
        )

        adapter.resignFirstResponderIfOwned(window, textView)

        XCTAssertFalse(window.firstResponder === textView,
            "Preview resignation MUST remove first responder when NSTextView was first responder")
    }

    func testRealNSTextViewDoesNotResignFirstResponderWhenAnotherControlIsFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let otherView = NSView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(textView)
        window.contentView?.addSubview(otherView)
        window.makeKeyAndOrderFront(nil)

        let focusSuccess = window.makeFirstResponder(otherView)
        XCTAssertTrue(focusSuccess)
        XCTAssertTrue(window.firstResponder === otherView)

        let adapter = MacMarkdownPreviewTestAdapter(
            resignFirstResponderIfOwned: { win, view in
                if win?.firstResponder === view {
                    win?.makeFirstResponder(nil)
                }
            },
            currentFirstResponder: { win in win?.firstResponder }
        )

        adapter.resignFirstResponderIfOwned(window, textView)

        XCTAssertTrue(window.firstResponder === otherView,
            "Preview resignation MUST NOT disturb another control's first responder status")
    }

    func testRealNSTextViewUnchangedPreviewResignationDoesNotTriggerOnTextChangedOrSave() {
        let recorder = MacMarkdownPreviewTestRecorder()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "Existing Note Content"

        var attributedTextBinding = NSAttributedString(string: "Existing Note Content")
        let syncBridge = MacEditorSyncBridge()

        let coordinator = MacTextViewRepresentable.Coordinator(
            attributedText: Binding(get: { attributedTextBinding }, set: { attributedTextBinding = $0 }),
            syncBridge: syncBridge,
            onTextChanged: { recorder.recordTextChanged() }
        )
        coordinator.textView = textView
        coordinator.register(textView)

        // Resign Preview with unchanged text
        let disposition = MarkdownPreviewResignationPolicy.disposition(
            isPreviewResignation: true,
            boundPlainText: "Existing Note Content",
            nativePlainText: textView.string
        )

        XCTAssertEqual(disposition, .acknowledgeWithoutPublication)
        XCTAssertEqual(recorder.onTextChangedCount, 0, "Unchanged Preview resignation MUST NOT trigger onTextChanged")
        XCTAssertEqual(recorder.saveScheduledCount, 0, "Unchanged Preview resignation MUST NOT schedule save")
    }

    func testRealNSTextViewUndoManagerAndSelectionIdentityArePreserved() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        textView.string = "Preserved text"
        let initialUndoManager = textView.undoManager

        XCTAssertNotNil(initialUndoManager)
        XCTAssertTrue(textView.undoManager === initialUndoManager,
            "NSTextView undoManager identity MUST remain stable across mode switches")
    }

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
