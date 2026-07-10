import XCTest
@testable import MyRAM

@MainActor
final class ActiveEditorSyncUpdateHandlerTests: XCTestCase {
    func testImmediateDispatcherAcknowledgementCases() {
        let noteID = UUID()
        let matchingHash = SyncBatchContentHash.sha256Hex(for: "Body")
        let batch = AppliedEditorMutationBatch(
            noteID: noteID,
            mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 4, text: "!", modifiedAt: Date()))],
            authoritativeBody: "Body!"
        )
        let emptyBatch = AppliedEditorMutationBatch(noteID: noteID, mutations: [], authoritativeBody: "Body")
        let cases: [(String, ActiveEditorSyncUpdate, HandlerSpy.Configuration, SyncConvergencePostCommitAdapterResult, Int, Int)] = [
            (
                "apply applied no metadata",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .apply(batch)),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied)),
                .verifiedComplete,
                1,
                0
            ),
            (
                "apply no mutations no metadata",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .apply(emptyBatch)),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)),
                .verifiedComplete,
                1,
                0
            ),
            (
                "bridge reload gate passes",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .apply(batch)),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.editorUnavailable))),
                .verifiedComplete,
                1,
                1
            ),
            (
                "bridge reload gate blocks",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    disposition: .apply(batch),
                    expectedPreBodyHash: String(repeating: "0", count: 64)
                ),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.authoritativeConvergencePresentation))),
                .stillPending,
                1,
                0
            ),
            (
                "apply metadata without title",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    metadata: ActiveEditorMetadataUpdate(title: nil),
                    disposition: .apply(batch)
                ),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied)),
                .verifiedComplete,
                1,
                0
            ),
            (
                "apply metadata immediate title",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    metadata: ActiveEditorMetadataUpdate(title: "Body"),
                    disposition: .apply(batch)
                ),
                .init(applyResult: EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied), title: "Body"),
                .verifiedComplete,
                1,
                0
            ),
            (
                "metadata nil",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .metadataOnly),
                .init(),
                .verifiedComplete,
                1,
                0
            ),
            (
                "metadata immediate title",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    metadata: ActiveEditorMetadataUpdate(title: "Body"),
                    disposition: .metadataOnly
                ),
                .init(title: "Body"),
                .verifiedComplete,
                1,
                0
            ),
            (
                "reload gate passes",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    disposition: .reload(.authoritativeConvergencePresentation),
                    expectedPreBodyHash: matchingHash
                ),
                .init(),
                .verifiedComplete,
                1,
                1
            ),
            (
                "reload gate blocks",
                ActiveEditorSyncUpdate(
                    noteID: noteID,
                    disposition: .reload(.authoritativeConvergencePresentation),
                    expectedPreBodyHash: String(repeating: "0", count: 64)
                ),
                .init(),
                .stillPending,
                1,
                0
            ),
            (
                "deferred",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .deferred(.pendingLocalCommit)),
                .init(),
                .stillPending,
                1,
                0
            ),
            (
                "ignored",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .ignored(.targetNoteIsNotActive)),
                .init(),
                .verifiedComplete,
                1,
                0
            ),
            (
                "unsafe state",
                ActiveEditorSyncUpdate(noteID: noteID, metadata: ActiveEditorMetadataUpdate(title: "Remote"), disposition: .metadataOnly),
                .init(stateDecision: .deferUntilReintegration(.editorBufferOwnedByLocalMutation)),
                .stillPending,
                1,
                0
            ),
            (
                "pending local commit",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .reload(.editorUnavailable)),
                .init(stateDecision: .deferUntilReintegration(.pendingLocalCommit)),
                .stillPending,
                1,
                0
            ),
            (
                "marked text",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .reload(.editorUnavailable)),
                .init(stateDecision: .deferUntilReintegration(.markedTextComposition)),
                .stillPending,
                1,
                0
            ),
            (
                "active pinned text edit",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .reload(.editorUnavailable)),
                .init(stateDecision: .deferUntilReintegration(.activePinnedTextEdit)),
                .stillPending,
                1,
                0
            ),
            (
                "undo restore state",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .reload(.editorUnavailable)),
                .init(stateDecision: .deferUntilReintegration(.restoringHistory)),
                .stillPending,
                1,
                0
            ),
            (
                "policy editor unavailable",
                ActiveEditorSyncUpdate(noteID: noteID, disposition: .apply(batch)),
                .init(batchDecision: .reload(.editorUnavailable)),
                .verifiedComplete,
                1,
                1
            )
        ]

        for testCase in cases {
            let spy = HandlerSpy(configuration: testCase.2)
            spy.handler.handle(testCase.1)

            XCTAssertEqual(spy.acknowledgements.map(\.result), [testCase.3], testCase.0)
            let expectedApplyCount: Int
            if case .apply = testCase.1.disposition, testCase.2.batchDecision == .applyIncrementally {
                expectedApplyCount = 1
            } else {
                expectedApplyCount = 0
            }
            XCTAssertEqual(spy.applyBatchCount, expectedApplyCount, testCase.0)
            XCTAssertEqual(spy.reloadReasons.count, testCase.5, testCase.0)
            XCTAssertEqual(spy.acknowledgements.count, testCase.4, testCase.0)
        }
    }

    func testDeferredTitleDispatchRecordsPendingMarkerWithoutImmediateAcknowledgement() {
        let noteID = UUID()
        let update = ActiveEditorSyncUpdate(
            noteID: noteID,
            metadata: ActiveEditorMetadataUpdate(title: "Remote"),
            disposition: .metadataOnly
        )
        let spy = HandlerSpy(configuration: .init(title: "Local"))

        spy.handler.handle(update)

        XCTAssertTrue(spy.acknowledgements.isEmpty)
        XCTAssertEqual(
            spy.pendingTitlePublication,
            PendingRemoteTitlePublication(updateID: update.id, noteID: noteID, expectedTitle: "Remote")
        )
        XCTAssertEqual(spy.title, "Remote")
    }

    func testApplyWithDeferredTitleDispatchRecordsPendingMarkerWithoutImmediateAcknowledgement() {
        let noteID = UUID()
        let update = ActiveEditorSyncUpdate(
            noteID: noteID,
            metadata: ActiveEditorMetadataUpdate(title: "Remote"),
            disposition: .apply(
                AppliedEditorMutationBatch(
                    noteID: noteID,
                    mutations: [.bodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 4, text: "!", modifiedAt: Date()))],
                    authoritativeBody: "Body!"
                )
            )
        )
        let spy = HandlerSpy(
            configuration: .init(
                applyResult: EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied),
                title: "Local"
            )
        )

        spy.handler.handle(update)

        XCTAssertTrue(spy.acknowledgements.isEmpty)
        XCTAssertEqual(
            spy.pendingTitlePublication,
            PendingRemoteTitlePublication(updateID: update.id, noteID: noteID, expectedTitle: "Remote")
        )
        XCTAssertEqual(spy.title, "Remote")
        XCTAssertEqual(spy.applyBatchCount, 1)
    }

    func testDeferredTitleConsumptionAcknowledgesMatchingObservedTitle() {
        let spy = HandlerSpy(configuration: .init())
        let marker = PendingRemoteTitlePublication(updateID: UUID(), noteID: spy.noteID, expectedTitle: "Remote")
        spy.pendingTitlePublication = marker

        XCTAssertTrue(spy.handler.consumeMatchingRemoteTitlePublication("Remote"))

        XCTAssertNil(spy.pendingTitlePublication)
        XCTAssertEqual(spy.acknowledgements.map(\.result), [.verifiedComplete])
        XCTAssertEqual(spy.alignedTitles, ["Remote"])
    }

    func testDeferredTitleConsumptionAcknowledgesMismatchedObservedTitleAsPending() {
        let spy = HandlerSpy(configuration: .init())
        spy.pendingTitlePublication = PendingRemoteTitlePublication(updateID: UUID(), noteID: spy.noteID, expectedTitle: "Remote")

        XCTAssertFalse(spy.handler.consumeMatchingRemoteTitlePublication("Local"))

        XCTAssertNil(spy.pendingTitlePublication)
        XCTAssertEqual(spy.acknowledgements.map(\.result), [.stillPending])
    }

    func testTitleObservationWithoutPendingMarkerContinuesNormalEditorHandling() {
        let spy = HandlerSpy(configuration: .init())

        XCTAssertFalse(spy.handler.consumeMatchingRemoteTitlePublication("Remote"))

        XCTAssertTrue(spy.acknowledgements.isEmpty)
    }

    @MainActor
    private final class HandlerSpy {
        struct Configuration {
            var stateDecision: ActiveEditorStateApplicationDecision = .apply
            var batchDecision: ActiveEditorApplicationDecision = .applyIncrementally
            var applyResult = EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
            var content = "Body"
            var title = "Local"
        }

        let noteID = UUID()
        var configuration: Configuration
        var title: String
        var pendingTitlePublication: PendingRemoteTitlePublication?
        var acknowledgements: [(updateID: UUID, result: SyncConvergencePostCommitAdapterResult)] = []
        var reloadReasons: [ActiveEditorReloadReason] = []
        var applyBatchCount = 0
        var alignedTitles: [String] = []
        var handler: ActiveEditorSyncUpdateHandler {
            ActiveEditorSyncUpdateHandler(
                environment: ActiveEditorSyncUpdateHandler.Environment(
                    stateDecision: { [unowned self] _ in configuration.stateDecision },
                    batchDecision: { [unowned self] _ in configuration.batchDecision },
                    beginRemoteBatchApply: {},
                    clearRemoteBatchApplyIfNeeded: {},
                    finishFailedRemoteBatchApply: {},
                    applyBatch: { [unowned self] _ in
                        applyBatchCount += 1
                        return configuration.applyResult
                    },
                    currentContent: { [unowned self] in configuration.content },
                    currentTitle: { [unowned self] in title },
                    performReload: { [unowned self] reason in reloadReasons.append(reason) },
                    applySuccessfulBatchSnapshot: {},
                    publishTitle: { [unowned self] remoteTitle in
                        title = remoteTitle
                        return false
                    },
                    recordPendingTitlePublication: { [unowned self] marker in pendingTitlePublication = marker },
                    clearPendingTitlePublication: { [unowned self] in pendingTitlePublication = nil },
                    pendingTitlePublication: { [unowned self] in pendingTitlePublication },
                    isCurrentNote: { [unowned self] noteID in noteID == self.noteID },
                    alignPublishedTitle: { [unowned self] remoteTitle in alignedTitles.append(remoteTitle) },
                    refreshUndoState: {},
                    acknowledge: { [unowned self] update, result in acknowledgements.append((update.id, result)) }
                )
            )
        }

        init(configuration: Configuration) {
            self.configuration = configuration
            self.title = configuration.title
        }
    }
}
