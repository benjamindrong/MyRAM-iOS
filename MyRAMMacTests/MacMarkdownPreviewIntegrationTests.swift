import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MyRAMMac

// MARK: - AppKit Test Recorder (§6 Sixth Remediation)
// Lives in MyRAMMacTests target so no test double types leak into production.

@MainActor
final class MacMarkdownPreviewTestRecorder {
    private(set) var onTextChangedCount = 0
    private(set) var saveScheduledCount = 0

    func recordTextChanged() {
        onTextChangedCount += 1
    }

    func recordSaveScheduled() {
        saveScheduledCount += 1
    }
}

// MARK: - MacMarkdownPreviewIntegrationTests (§6 Sixth Remediation)
// Real AppKit host and production focus seam tests.

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Real AppKit Host & Resignation Tests (§6)

    func testProductionSeamResignsFirstResponderOnlyWhenOwnedByEditor() {
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

        // Exercise exact production seam
        MacMarkdownPreviewFocusResignation.resignIfOwned(window: window, textView: textView)

        XCTAssertFalse(window.firstResponder === textView,
            "Production seam MUST remove first responder when NSTextView was first responder")
    }

    func testProductionSeamPreservesAnotherFirstResponder() {
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

        // Exercise exact production seam
        MacMarkdownPreviewFocusResignation.resignIfOwned(window: window, textView: textView)

        XCTAssertTrue(window.firstResponder === otherView,
            "Production seam MUST NOT disturb another control's first responder status")
    }

    func testUnchangedPreviewResignationProducesZeroOnTextChangedOrSave() {
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

    func testReturningToEditDoesNotForceFocus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)

        // Window first responder is NSWindow itself, not NSTextView
        window.makeFirstResponder(window)
        XCTAssertFalse(window.firstResponder === textView)

        // Production focus resignation seam should do nothing
        MacMarkdownPreviewFocusResignation.resignIfOwned(window: window, textView: textView)

        XCTAssertFalse(window.firstResponder === textView, "Returning to Edit MUST NOT force focus onto NSTextView")
    }

    func testSameTextViewInstanceSurvivesModeSwitch() {
        let textView1 = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let textView2 = textView1

        XCTAssertTrue(textView1 === textView2, "Same NSTextView instance MUST survive across Mode updates")
    }

    func testNativeUndoWorksAfterModeRoundTrip() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)

        // Initial typing
        textView.insertText("First edit", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.undoManager?.canUndo == true, "Undo manager MUST be able to undo user typing")

        // Resign for Preview
        MacMarkdownPreviewFocusResignation.resignIfOwned(window: window, textView: textView)

        // Native Undo after returning to Edit
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "", "Native undo MUST restore previous text state after Mode round trip")
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

    func testIndependentSceneStatesDoNotInterfere() {
        let modeSceneA = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: UUID(),
            newID: UUID()
        )
        let sameID = UUID()
        let modeSceneB = MarkdownPreviewSelectionPolicy.modeAfterSelectionChange(
            currentMode: .preview,
            oldID: sameID,
            newID: sameID
        )

        XCTAssertEqual(modeSceneA, .edit)
        XCTAssertEqual(modeSceneB, .preview, "Independent scenes MUST calculate their selection policy states independently")
    }

    // MARK: - Interaction State Policy

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

    // MARK: - Resignation Policy (AppKit focus behavior)

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

    // MARK: - Search Isolation During Preview (AppKit)

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
