import XCTest
@testable import MyRAMMac

final class MacIncomingSyncApplicationPolicyTests: XCTestCase {
    func testZeroChangeAppliedBatchProducesNoOpPlan() {
        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: MacAppliedSyncBatch(batchID: UUID(), changes: []),
            selectedNoteID: UUID(),
            editorState: .ready
        )

        XCTAssertEqual(
            plan,
            MacIncomingSyncApplicationPlan(
                shouldRefreshNotesList: false,
                editorActions: [],
                reloadSelectedEditorReason: nil
            )
        )
    }

    func testNonSelectedBodyChangeRefreshesListOnly() {
        let selectedID = UUID()
        let insertion = AppliedEditorBodyInsertion(noteID: UUID(), utf16Offset: 1, text: "x", modifiedAt: Date())

        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: MacAppliedSyncBatch(batchID: UUID(), changes: [.bodyInserted(insertion)]),
            selectedNoteID: selectedID,
            editorState: .ready
        )

        XCTAssertTrue(plan.shouldRefreshNotesList)
        XCTAssertTrue(plan.editorActions.isEmpty)
        XCTAssertNil(plan.reloadSelectedEditorReason)
    }

    func testSelectedTitleOnlyChangeRefreshesListOnly() {
        let selectedID = UUID()
        let titleChange = MacAppliedTitleChanged(noteID: selectedID, title: "Remote", modifiedAt: Date())

        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: MacAppliedSyncBatch(batchID: UUID(), changes: [.titleChanged(titleChange)]),
            selectedNoteID: selectedID,
            editorState: .ready
        )

        XCTAssertTrue(plan.shouldRefreshNotesList)
        XCTAssertTrue(plan.editorActions.isEmpty)
        XCTAssertNil(plan.reloadSelectedEditorReason)
    }

    func testSelectedBodyChangesProduceOrderedEditorActions() {
        let selectedID = UUID()
        let insertion = AppliedEditorBodyInsertion(noteID: selectedID, utf16Offset: 1, text: "x", modifiedAt: Date())
        let deletion = AppliedEditorBodyDeletion(noteID: selectedID, range: NSRange(location: 2, length: 1), deletedText: "y", modifiedAt: Date())

        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: MacAppliedSyncBatch(batchID: UUID(), changes: [.bodyInserted(insertion), .bodyDeleted(deletion)]),
            selectedNoteID: selectedID,
            editorState: .ready
        )

        XCTAssertTrue(plan.shouldRefreshNotesList)
        XCTAssertEqual(plan.editorActions, [.applyBodyInsertion(insertion), .applyBodyDeletion(deletion)])
        XCTAssertNil(plan.reloadSelectedEditorReason)
    }

    func testUnsafeSelectedEditorRequestsFallback() {
        let selectedID = UUID()
        let insertion = AppliedEditorBodyInsertion(noteID: selectedID, utf16Offset: 1, text: "x", modifiedAt: Date())

        let plan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: MacAppliedSyncBatch(batchID: UUID(), changes: [.bodyInserted(insertion)]),
            selectedNoteID: selectedID,
            editorState: .unsafeForIncrementalApply
        )

        XCTAssertTrue(plan.shouldRefreshNotesList)
        XCTAssertTrue(plan.editorActions.isEmpty)
        XCTAssertEqual(plan.reloadSelectedEditorReason, .unsafeIncrementalApply)
    }

    func testMacSelectedEditorPathOnlyPlansIncrementalActionsOrUnsafeIncrementalReload() {
        let selectedID = UUID()
        let insertion = AppliedEditorBodyInsertion(noteID: selectedID, utf16Offset: 1, text: "x", modifiedAt: Date())
        let deletion = AppliedEditorBodyDeletion(
            noteID: selectedID,
            range: NSRange(location: 2, length: 1),
            deletedText: "y",
            modifiedAt: Date()
        )
        let batch = MacAppliedSyncBatch(batchID: UUID(), changes: [.bodyInserted(insertion), .bodyDeleted(deletion)])

        let readyPlan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: batch,
            selectedNoteID: selectedID,
            editorState: .ready
        )
        XCTAssertEqual(readyPlan.editorActions, [.applyBodyInsertion(insertion), .applyBodyDeletion(deletion)])
        XCTAssertNil(readyPlan.reloadSelectedEditorReason)

        let unsafePlan = MacIncomingSyncApplicationPolicy.plan(
            appliedBatch: batch,
            selectedNoteID: selectedID,
            editorState: .unsafeForIncrementalApply
        )
        XCTAssertTrue(unsafePlan.editorActions.isEmpty)
        XCTAssertEqual(unsafePlan.reloadSelectedEditorReason, .unsafeIncrementalApply)
    }
}
