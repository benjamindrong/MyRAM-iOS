import XCTest

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergencePlanningTests: XCTestCase {
    func testPlanningSuccessReturnsPlannedOutcome() {
        let noteID = uuid("00000000-0000-0000-0000-000000132201")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132301"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132401"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "AB")]
        ))

        guard case .planned(let plan) = outcome else {
            return XCTFail("Expected planned outcome, got \(outcome)")
        }
        XCTAssertEqual(plan.batchID, batch.id)
        XCTAssertEqual(plan.affectedNotePlans.count, 1)
        guard case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected matching-base body effect")
        }
        XCTAssertEqual(bodyPlan.finalBody, "AxB")
    }

    func testIdenticalPreviouslyIncorporatedBatchReturnsCleanupPlan() {
        let noteID = uuid("00000000-0000-0000-0000-000000132200")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")
        let digest = SyncConvergenceCanonicalBatchDigest.digest(for: batch)
        let cleanup = SyncConvergenceCleanupPlan(
            batchIDs: [batch.id],
            retryQueueCleanup: true,
            retryLegacyCleanup: false,
            retryPresentationRefresh: true
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, title: "Local")],
            incorporatedBatches: [
                SyncConvergenceIncorporatedBatchProjection(
                    batchID: batch.id,
                    noteID: noteID,
                    canonicalPayloadDigest: digest,
                    canonicalPayloadDigestFormatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion,
                    cleanupPlan: cleanup
                )
            ]
        ))

        XCTAssertEqual(outcome, SyncConvergencePlanningOutcome.alreadyIncorporated(cleanup))
    }

    func testUnsupportedStoredDigestFormatFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-000000132200")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, title: "Local")],
            incorporatedTombstones: [
                SyncConvergenceIncorporatedBatchProjection(
                    batchID: batch.id,
                    noteID: noteID,
                    canonicalPayloadDigest: String(repeating: "a", count: 64),
                    canonicalPayloadDigestFormatVersion: 99,
                    cleanupPlan: SyncConvergenceCleanupPlan(
                        batchIDs: [batch.id],
                        retryQueueCleanup: false,
                        retryLegacyCleanup: false,
                        retryPresentationRefresh: false
                    )
                )
            ]
        ))

        XCTAssertEqual(
            outcome,
            SyncConvergencePlanningOutcome.failedBeforeCommit(.unsupportedDigestFormat(
                noteID: noteID,
                batchID: batch.id,
                formatVersion: 99
            ))
        )
    }

    func testContradictoryDuplicateBatchIdentityFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-000000132200")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, title: "Local")],
            incorporatedBatches: [
                SyncConvergenceIncorporatedBatchProjection(
                    batchID: batch.id,
                    noteID: noteID,
                    canonicalPayloadDigest: String(repeating: "b", count: 64),
                    canonicalPayloadDigestFormatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion,
                    cleanupPlan: SyncConvergenceCleanupPlan(
                        batchIDs: [batch.id],
                        retryQueueCleanup: false,
                        retryLegacyCleanup: false,
                        retryPresentationRefresh: false
                    )
                )
            ]
        ))

        XCTAssertEqual(
            outcome,
            SyncConvergencePlanningOutcome.failedBeforeCommit(.inconsistentIncorporationState(noteID: noteID))
        )
    }

    func testContradictoryFullRecordAndTombstoneFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-000000132210")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")
        let digest = SyncConvergenceCanonicalBatchDigest.digest(for: batch)
        let cleanup = SyncConvergenceCleanupPlan(
            batchIDs: [batch.id],
            retryQueueCleanup: false,
            retryLegacyCleanup: false,
            retryPresentationRefresh: false
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, title: "Local")],
            incorporatedBatches: [
                SyncConvergenceIncorporatedBatchProjection(
                    batchID: batch.id,
                    noteID: noteID,
                    canonicalPayloadDigest: digest,
                    canonicalPayloadDigestFormatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion,
                    cleanupPlan: cleanup
                )
            ],
            incorporatedTombstones: [
                SyncConvergenceIncorporatedBatchProjection(
                    batchID: batch.id,
                    noteID: noteID,
                    canonicalPayloadDigest: String(repeating: "c", count: 64),
                    canonicalPayloadDigestFormatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion,
                    cleanupPlan: cleanup
                )
            ]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: noteID)))
    }

    func testUnsupportedReconciliationDefersBatch() {
        let noteID = uuid("00000000-0000-0000-0000-000000132202")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132302"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132402"),
            createdAt: date(1),
            changes: [
                .noteBodyReconciled(SyncBatchNoteBodyReconciledChange(
                    noteID: noteID,
                    replacementBody: "winner",
                    replacementContentHash: SyncBatchContentHash.sha256Hex(for: "winner"),
                    modifiedAt: date(2)
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID)]
        ))

        XCTAssertEqual(outcome, .deferred(.unsupportedReconciliation(noteID: noteID, batchID: batch.id)))
    }

    func testMissingHistoricalBaseDefersAsUnreconstructableBase() {
        let noteID = uuid("00000000-0000-0000-0000-000000132203")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132303"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132403"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: "missing"
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "current")]
        ))

        XCTAssertEqual(
            outcome,
            .deferred(.unreconstructableBase(noteID: noteID, batchID: batch.id, baseContentHash: "missing"))
        )
    }

    func testLegacyPositionalEffectPreservesExpectedTextNoop() {
        let noteID = uuid("00000000-0000-0000-0000-000000132204")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132304"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132404"),
            createdAt: date(1),
            changes: [
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    utf16Length: 1,
                    expectedText: "z",
                    modifiedAt: date(2)
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "abc")]
        ))

        guard case .planned(let plan) = outcome,
              case .legacyPositional(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected legacy positional plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody, "abc")
    }

    func testReconstructedConflictUsesHistoricalBaseAndWholeNoteRouting() {
        let noteID = uuid("00000000-0000-0000-0000-000000132205")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132305"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132405"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "ACB")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)
            ]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected reconstructed conflict plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseBody, base)
        XCTAssertEqual(bodyPlan.finalBody, "AxB")
        XCTAssertEqual(plan.presentationPlan.noteRoutings[noteID], .wholeNoteFallback)
    }

    func testReconstructionFromRetainedOperationDoesNotReplayConsumedHistoryTwice() {
        let noteID = uuid("00000000-0000-0000-0000-00000013220C")
        let snapshotBody = "A"
        let reconstructedBaseBody = "AB"
        let reconstructedBaseHash = SyncBatchContentHash.sha256Hex(for: reconstructedBaseBody)
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013230C"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013240C"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(4),
                    baseContentHash: reconstructedBaseHash
                ))
            ]
        )
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013250C"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013260C"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: reconstructedBaseBody
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AZ")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                    body: snapshotBody,
                    generation: 1
                )
            ],
            retainedRemoteOperations: [retained]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected retained-operation reconstruction, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseBody, reconstructedBaseBody)
        XCTAssertEqual(bodyPlan.finalBody, "ABC")
        XCTAssertEqual(bodyPlan.orderedOperationIdentities.map(\.operationIndex), [0])
    }

    func testCorruptRetainedOperationResultFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-00000013220D")
        let snapshotBody = "A"
        let reconstructedBaseBody = "AB"
        let reconstructedBaseHash = SyncBatchContentHash.sha256Hex(for: reconstructedBaseBody)
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013230D"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013240D"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(4),
                    baseContentHash: reconstructedBaseHash
                ))
            ]
        )
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013250D"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013260D"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: "wrong"
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AZ")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                    body: snapshotBody,
                    generation: 1
                )
            ],
            retainedRemoteOperations: [retained]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.corruptHistory(noteID: noteID)))
    }

    func testTitleHigherCanonicalKeyWinsAndLowerKeyIsIgnored() {
        let noteID = uuid("00000000-0000-0000-0000-000000132206")
        let older = makeTitleBatch(noteID: noteID, title: "Older", modifiedAt: date(2))
        let newer = makeTitleBatch(noteID: noteID, title: "Newer", modifiedAt: date(3))
        let olderIdentity = OperationIdentityPayload(
            batchID: older.id,
            originDeviceID: older.originDeviceID,
            operationIndex: 0,
            operationKind: "title",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: older, change: older.changes[0], operationIndex: 0)
            )
        )
        let winner = SyncConvergenceTitleWinnerProjection(
            noteID: noteID,
            title: "Newer",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: newer, change: newer.changes[0], operationIndex: 0)
            ),
            operationIdentity: OperationIdentityPayload(
                batchID: newer.id,
                originDeviceID: newer.originDeviceID,
                operationIndex: 0,
                operationKind: "title",
                canonicalReplayKey: CanonicalReplayKeyPayload(
                    replayKey: SyncBatchReplayKey(batch: newer, change: newer.changes[0], operationIndex: 0)
                )
            )
        )

        _ = olderIdentity
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: older,
            currentNotes: [projectedNote(noteID: noteID, title: "Newer")],
            persistedTitleWinners: [winner]
        ))

        guard case .planned(let plan) = outcome else {
            return XCTFail("Expected planned title outcome, got \(outcome)")
        }
        XCTAssertEqual(plan.affectedNotePlans[0].titleEffect?.verdict, .ignoreOlder)
        XCTAssertEqual(plan.affectedNotePlans[0].titleEffect?.resultingTitle, "Newer")
    }

    func testContradictoryTitleWinnerAuthorityFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-00000013220E")
        let incoming = makeTitleBatch(noteID: noteID, title: "Incoming", modifiedAt: date(4))
        let firstWinnerBatch = makeTitleBatch(noteID: noteID, title: "First", modifiedAt: date(2))
        let secondWinnerBatch = makeTitleBatch(noteID: noteID, title: "Second", modifiedAt: date(3))

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, title: "First")],
            persistedTitleWinners: [
                titleWinner(noteID: noteID, title: "First", batch: firstWinnerBatch),
                titleWinner(noteID: noteID, title: "Second", batch: secondWinnerBatch)
            ]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: noteID)))
    }

    func testContradictoryOperationIdentityFailsBeforeCommit() {
        let noteID = uuid("00000000-0000-0000-0000-00000013220F")
        let baseBody = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: baseBody)
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013230F"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013240F"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: baseHash
                ))
            ]
        )
        let retained = retainedInsert(
            noteID: noteID,
            batchID: incoming.id,
            originDeviceID: incoming.originDeviceID,
            operationIndex: 0,
            offset: 1,
            text: "y",
            modifiedAt: date(2),
            baseBody: baseBody,
            resultBody: "AyB"
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AzzB")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: baseBody, generation: 1)
            ],
            retainedRemoteOperations: [retained]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: noteID)))
    }

    func testHistoryHardOverflowDefersBeforePlan() {
        let noteID = uuid("00000000-0000-0000-0000-000000132207")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132307"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132407"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "AB")],
            historyStates: [
                SyncConvergenceHistoryAccountingProjection(
                    noteID: noteID,
                    snapshotCount: 13,
                    retainedOperationCount: 0,
                    snapshotBytes: 0,
                    retainedOperationBytes: 0,
                    fullIncorporationEvidenceBytes: 0,
                    diagnosticEvidenceBytes: 0,
                    cleanupEvidenceBytes: 0,
                    completedReconciliationEpisodeCount: 0,
                    activeReconciliationEpisodeCount: 0,
                    reconciliationEvidenceBytes: 0
                )
            ]
        ))

        XCTAssertEqual(outcome, .deferred(.historyPressure(noteID: noteID, blockingBatchID: nil)))
    }

    func testDisjointNoteSelectionIsIndependentOfQueueEnumerationOrder() {
        let blocked = uuid("00000000-0000-0000-0000-000000132208")
        let first = queuedBatch(position: 2, noteID: uuid("00000000-0000-0000-0000-000000132209"))
        let second = queuedBatch(position: 1, noteID: uuid("00000000-0000-0000-0000-00000013220A"))
        let blockedBatch = queuedBatch(position: 0, noteID: blocked)

        let selector = SyncConvergenceEvidenceSelector()
        let selectedA = selector.selectEligibleQueuedBatches([first, blockedBatch, second], blockedNoteIDs: [blocked])
        let selectedB = selector.selectEligibleQueuedBatches([second, first, blockedBatch], blockedNoteIDs: [blocked])

        XCTAssertEqual(selectedA, selectedB)
        XCTAssertEqual(selectedA.map(\.queuePosition), [1, 2])
    }

    func testCreationPlanningDoesNotRequireExistingProjectedNote() {
        let noteID = uuid("00000000-0000-0000-0000-00000013220B")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013230B"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013240B"),
            createdAt: date(1),
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: "Body",
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 4,
                    text: "!",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Body")
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))

        guard case .planned(let plan) = outcome else {
            return XCTFail("Expected planned creation outcome, got \(outcome)")
        }
        XCTAssertEqual(plan.affectedNotePlans[0].creationEffect?.verdict, .create)
        guard case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected same-batch body change to use projected created note")
        }
        XCTAssertEqual(bodyPlan.finalBody, "Body!")
    }

    private func makeTitleBatch(
        noteID: UUID = uuid("00000000-0000-0000-0000-000000132200"),
        title: String,
        modifiedAt: Date = date(2)
    ) -> SyncBatch {
        SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132300"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132400"),
            createdAt: date(1),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: title,
                    modifiedAt: modifiedAt
                ))
            ]
        )
    }

    private func queuedBatch(position: Int, noteID: UUID) -> SyncConvergenceQueuedBatch {
        SyncConvergenceQueuedBatch(
            batch: makeTitleBatch(noteID: noteID, title: "Queued \(position)", modifiedAt: date(TimeInterval(position + 10))),
            queuePosition: position
        )
    }

    private func retainedInsert(
        noteID: UUID,
        batchID: UUID,
        originDeviceID: UUID,
        operationIndex: Int,
        offset: Int,
        text: String,
        modifiedAt: Date,
        baseBody: String,
        resultBody: String
    ) -> SyncConvergenceRetainedOperation {
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: offset,
                    text: text,
                    modifiedAt: modifiedAt,
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: baseBody)
                ))
            ]
        )
        return SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: operationIndex,
            operationKind: .insert,
            utf16Offset: offset,
            utf16Length: nil,
            text: text,
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: baseBody),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: resultBody),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: operationIndex)
            )
        )
    }

    private func titleWinner(
        noteID: UUID,
        title: String,
        batch: SyncBatch
    ) -> SyncConvergenceTitleWinnerProjection {
        let replayKey = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
        )
        return SyncConvergenceTitleWinnerProjection(
            noteID: noteID,
            title: title,
            canonicalReplayKey: replayKey,
            operationIdentity: OperationIdentityPayload(
                batchID: batch.id,
                originDeviceID: batch.originDeviceID,
                operationIndex: 0,
                operationKind: "title",
                canonicalReplayKey: replayKey
            )
        )
    }
}

private func projectedNote(
    noteID: UUID,
    title: String = "Local",
    body: String = "Body"
) -> SyncConvergenceProjectedNote {
    SyncConvergenceProjectedNote(
        noteID: noteID,
        folderID: nil,
        title: title,
        body: body,
        createdAt: date(0),
        modifiedAt: date(0)
    )
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}

private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}
