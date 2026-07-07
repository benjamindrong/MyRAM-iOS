import XCTest
@testable import MyRAM

final class ActiveEditorApplicationPolicyTests: XCTestCase {
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
}
