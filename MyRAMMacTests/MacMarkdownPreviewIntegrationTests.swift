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

    func recordTextChanged() {
        onTextChangedCount += 1
    }
}

@MainActor
final class MacMarkdownPreviewHostState: ObservableObject {
    @Published var attributedText: NSAttributedString
    @Published var resignFocusToggleToken = 0
    @Published var mode: MarkdownEditorMode = .edit
    let syncBridge = MacEditorSyncBridge()
    let recorder = MacMarkdownPreviewTestRecorder()

    init(text: String) {
        attributedText = NSAttributedString(string: text)
    }

    func enterPreview() {
        resignFocusToggleToken &+= 1
        mode = .preview
    }

    func enterEdit() {
        mode = .edit
    }
}

private struct MacMarkdownPreviewHostedEditor: View {
    @ObservedObject var state: MacMarkdownPreviewHostState

    var body: some View {
        ZStack {
            MacTextViewRepresentable(
                attributedText: $state.attributedText,
                syncBridge: state.syncBridge,
                onTextChanged: { state.recorder.recordTextChanged() },
                resignFocusToggleToken: state.resignFocusToggleToken
            )
            .opacity(state.mode == .edit ? 1 : 0)
            .allowsHitTesting(state.mode == .edit)

            if state.mode == .preview {
                MarkdownPreviewView(source: state.attributedText.string)
            }
        }
        .frame(width: 400, height: 300)
    }
}

// MARK: - MacMarkdownPreviewIntegrationTests (§6 Sixth Remediation)
// Real AppKit host and production focus seam tests.

@MainActor
final class MacMarkdownPreviewIntegrationTests: XCTestCase {

    // MARK: - Real AppKit Host & Resignation Tests (§6)

    func testHostedRepresentableTokenResignsOwnedEditorWithoutPublishing() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        let originalIdentity = ObjectIdentifier(textView)

        XCTAssertTrue(host.window.makeFirstResponder(textView))
        XCTAssertTrue(host.window.firstResponder === textView)

        host.state.enterPreview()
        drainMainRunLoop()

        let installedTextView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertEqual(ObjectIdentifier(installedTextView), originalIdentity)
        XCTAssertFalse(host.window.firstResponder === textView)
        XCTAssertEqual(
            host.state.recorder.onTextChangedCount,
            0,
            "Focus-only updateNSView token handling MUST not invoke onTextChanged; production save scheduling is owned exclusively by that callback"
        )
    }

    func testHostedRepresentableTokenPreservesAnotherFirstResponder() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        let otherResponder = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        host.container.addSubview(otherResponder)

        XCTAssertTrue(host.window.makeFirstResponder(otherResponder))
        let otherFirstResponder = try XCTUnwrap(host.window.firstResponder)
        XCTAssertFalse(otherFirstResponder === textView)

        host.state.enterPreview()
        drainMainRunLoop()

        XCTAssertTrue(host.window.firstResponder === otherFirstResponder)
        XCTAssertTrue(host.state.syncBridge.textView === textView)
        XCTAssertEqual(host.state.recorder.onTextChangedCount, 0)
    }

    func testHostedRepresentableReturningToEditDoesNotForceFocus() throws {
        let host = makeHostedEditor(text: "Existing Note Content")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertTrue(host.window.makeFirstResponder(textView))

        host.state.enterPreview()
        drainMainRunLoop()
        XCTAssertFalse(host.window.firstResponder === textView)

        host.state.enterEdit()
        drainMainRunLoop()

        XCTAssertFalse(host.window.firstResponder === textView, "Returning to Edit MUST NOT force focus")
        XCTAssertTrue(host.state.syncBridge.textView === textView)
    }

    func testHostedRepresentableNativeUndoWorksAfterModeRoundTrip() throws {
        let host = makeHostedEditor(text: "")
        let textView = try XCTUnwrap(host.state.syncBridge.textView)
        XCTAssertTrue(host.window.makeFirstResponder(textView))

        textView.insertText("First edit", replacementRange: NSRange(location: 0, length: 0))
        drainMainRunLoop()
        XCTAssertEqual(textView.string, "First edit")
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        host.state.enterPreview()
        drainMainRunLoop()
        host.state.enterEdit()
        drainMainRunLoop()

        XCTAssertTrue(host.state.syncBridge.textView === textView)
        XCTAssertFalse(host.window.firstResponder === textView)
        textView.undoManager?.undo()
        drainMainRunLoop()

        XCTAssertEqual(textView.string, "", "Native Undo MUST restore text after the hosted production mode round trip")
    }

    func testTwoHostedRepresentablesMaintainIndependentModeAndTokenState() throws {
        let first = makeHostedEditor(text: "First")
        let second = makeHostedEditor(text: "Second")
        let firstTextView = try XCTUnwrap(first.state.syncBridge.textView)
        let secondTextView = try XCTUnwrap(second.state.syncBridge.textView)

        XCTAssertTrue(first.window.makeFirstResponder(firstTextView))
        XCTAssertTrue(second.window.makeFirstResponder(secondTextView))

        first.state.enterPreview()
        drainMainRunLoop()

        XCTAssertEqual(first.state.mode, .preview)
        XCTAssertEqual(first.state.resignFocusToggleToken, 1)
        XCTAssertFalse(first.window.firstResponder === firstTextView)
        XCTAssertEqual(second.state.mode, .edit)
        XCTAssertEqual(second.state.resignFocusToggleToken, 0)
        XCTAssertTrue(second.window.firstResponder === secondTextView)
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

    private func makeHostedEditor(
        text: String
    ) -> (state: MacMarkdownPreviewHostState, window: NSWindow, container: NSView) {
        let state = MacMarkdownPreviewHostState(text: text)
        let hostingView = NSHostingView(rootView: MacMarkdownPreviewHostedEditor(state: state))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        drainMainRunLoop()

        XCTAssertNotNil(state.syncBridge.textView, "The production representable MUST install an NSTextView")
        return (state, window, container)
    }

    private func drainMainRunLoop() {
        let expectation = expectation(description: "RunLoop drain")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}
