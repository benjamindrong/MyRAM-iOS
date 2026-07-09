import XCTest
@testable import MyRAM

final class ActiveEditorApplicationPolicyTests: XCTestCase {
    func testWholeNoteFallbackGateAllowsAuthoritativeReloadWhenPreHashMatches() {
        let body = "current editor body"
        let decision = ActiveEditorWholeNoteFallbackGate.decision(
            reason: .authoritativeConvergencePresentation,
            expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: body),
            currentContent: body
        )

        XCTAssertEqual(decision, .allowReload)
    }

    func testWholeNoteFallbackGateReturnsStillPendingWhenPreHashMismatches() {
        let decision = ActiveEditorWholeNoteFallbackGate.decision(
            reason: .authoritativeConvergencePresentation,
            expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "expected prior body"),
            currentContent: "edited after convergence planned"
        )

        XCTAssertEqual(decision, .stillPending)
    }

    func testWholeNoteFallbackGateAllowsAuthoritativeReloadWithoutExpectedPreHash() {
        let decision = ActiveEditorWholeNoteFallbackGate.decision(
            reason: .authoritativeConvergencePresentation,
            expectedPreBodyHash: nil,
            currentContent: "current editor body"
        )

        XCTAssertEqual(decision, .allowReload)
    }

    func testWholeNoteFallbackGateDoesNotBlockNonAuthoritativeReloadReasons() {
        let decision = ActiveEditorWholeNoteFallbackGate.decision(
            reason: .preApplyBodyMismatch,
            expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "different body"),
            currentContent: "current editor body"
        )

        XCTAssertEqual(decision, .allowReload)
    }

    func testIdleEditorAppliesIncrementally() {
        XCTAssertEqual(
            ActiveEditorApplicationPolicy.decision(
                editorBufferOwner: .idle,
                hasPendingNoteCommit: false,
                hasActivePinnedTextEdit: false,
                hasMarkedText: false,
                isApplyingUndo: false,
                editorAvailable: true,
                selectedNoteMatches: true
            ),
            .applyIncrementally
        )
    }

    func testPendingLocalCommitDefers() {
        XCTAssertEqual(decision(hasPendingNoteCommit: true), .`defer`(.pendingLocalCommit))
    }

    func testActivePinnedTextEditDefers() {
        XCTAssertEqual(decision(hasActivePinnedTextEdit: true), .`defer`(.activePinnedTextEdit))
    }

    func testRestoringHistoryDefers() {
        XCTAssertEqual(decision(editorBufferOwner: .restoringHistory), .`defer`(.restoringHistory))
    }

    func testLocalBufferOwnershipDefers() {
        XCTAssertEqual(decision(editorBufferOwner: .localEditing), .`defer`(.editorBufferOwnedByLocalMutation))
        XCTAssertEqual(decision(editorBufferOwner: .applyingRemoteSync), .`defer`(.editorBufferOwnedByLocalMutation))
        XCTAssertEqual(decision(editorBufferOwner: .resolvingConflict), .`defer`(.editorBufferOwnedByLocalMutation))
    }

    func testMarkedTextCompositionDefers() {
        XCTAssertEqual(decision(hasMarkedText: true), .`defer`(.markedTextComposition))
    }

    func testMissingEditorReloads() {
        XCTAssertEqual(decision(editorAvailable: false), .reload(.editorUnavailable))
    }

    func testInactiveSelectedNoteIsIgnoredWithoutReload() {
        XCTAssertEqual(decision(selectedNoteMatches: false), .ignore(.targetNoteIsNotActive))
    }

    func testUnsafeStateDefersBeforeEditorUnavailableReload() {
        XCTAssertEqual(decision(hasPendingNoteCommit: true, editorAvailable: false), .`defer`(.pendingLocalCommit))
        XCTAssertEqual(decision(hasActivePinnedTextEdit: true, editorAvailable: false), .`defer`(.activePinnedTextEdit))
        XCTAssertEqual(decision(hasMarkedText: true, editorAvailable: false), .`defer`(.markedTextComposition))
        XCTAssertEqual(decision(isApplyingUndo: true, editorAvailable: false), .`defer`(.restoringHistory))
        XCTAssertEqual(decision(editorAvailable: false), .reload(.editorUnavailable))
        XCTAssertEqual(
            decision(hasPendingNoteCommit: true, editorAvailable: false, selectedNoteMatches: false),
            .ignore(.targetNoteIsNotActive)
        )
    }

    func testStatePolicyAppliesInSafeIdleState() {
        XCTAssertEqual(stateDecision(), .apply)
    }

    func testStatePolicyIgnoresSelectedNoteMismatch() {
        XCTAssertEqual(
            stateDecision(selectedNoteMatches: false),
            .ignore(.targetNoteIsNotActive)
        )
    }

    func testStatePolicyDefersPendingLocalCommit() {
        XCTAssertEqual(
            stateDecision(hasPendingNoteCommit: true),
            .deferUntilReintegration(.pendingLocalCommit)
        )
    }

    func testStatePolicyDefersActivePinnedTextEdit() {
        XCTAssertEqual(
            stateDecision(hasActivePinnedTextEdit: true),
            .deferUntilReintegration(.activePinnedTextEdit)
        )
    }

    func testStatePolicyDefersMarkedTextComposition() {
        XCTAssertEqual(
            stateDecision(hasMarkedText: true),
            .deferUntilReintegration(.markedTextComposition)
        )
    }

    func testStatePolicyDefersApplyingUndo() {
        XCTAssertEqual(
            stateDecision(isApplyingUndo: true),
            .deferUntilReintegration(.restoringHistory)
        )
    }

    func testStatePolicyDefersRestoringHistoryOwner() {
        XCTAssertEqual(
            stateDecision(editorBufferOwner: .restoringHistory),
            .deferUntilReintegration(.restoringHistory)
        )
    }

    func testStatePolicyDefersUnsafeOwners() {
        XCTAssertEqual(
            stateDecision(editorBufferOwner: .localEditing),
            .deferUntilReintegration(.editorBufferOwnedByLocalMutation)
        )
        XCTAssertEqual(
            stateDecision(editorBufferOwner: .applyingRemoteSync),
            .deferUntilReintegration(.editorBufferOwnedByLocalMutation)
        )
        XCTAssertEqual(
            stateDecision(editorBufferOwner: .resolvingConflict),
            .deferUntilReintegration(.editorBufferOwnedByLocalMutation)
        )
    }

    private func decision(
        editorBufferOwner: EditorBufferOwner = .idle,
        hasPendingNoteCommit: Bool = false,
        hasActivePinnedTextEdit: Bool = false,
        hasMarkedText: Bool = false,
        isApplyingUndo: Bool = false,
        editorAvailable: Bool = true,
        selectedNoteMatches: Bool = true
    ) -> ActiveEditorApplicationDecision {
        ActiveEditorApplicationPolicy.decision(
            editorBufferOwner: editorBufferOwner,
            hasPendingNoteCommit: hasPendingNoteCommit,
            hasActivePinnedTextEdit: hasActivePinnedTextEdit,
            hasMarkedText: hasMarkedText,
            isApplyingUndo: isApplyingUndo,
            editorAvailable: editorAvailable,
            selectedNoteMatches: selectedNoteMatches
        )
    }

    private func stateDecision(
        editorBufferOwner: EditorBufferOwner = .idle,
        hasPendingNoteCommit: Bool = false,
        hasActivePinnedTextEdit: Bool = false,
        hasMarkedText: Bool = false,
        isApplyingUndo: Bool = false,
        selectedNoteMatches: Bool = true
    ) -> ActiveEditorStateApplicationDecision {
        ActiveEditorApplicationPolicy.stateDecision(
            editorBufferOwner: editorBufferOwner,
            hasPendingNoteCommit: hasPendingNoteCommit,
            hasActivePinnedTextEdit: hasActivePinnedTextEdit,
            hasMarkedText: hasMarkedText,
            isApplyingUndo: isApplyingUndo,
            selectedNoteMatches: selectedNoteMatches
        )
    }
}
