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

    func testIdenticalPreviouslyIncorporatedBatchReturnsCleanupPlan() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132200")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")
        let digest = try SyncConvergenceCanonicalBatchDigest.digest(for: batch)
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

    func testContradictoryFullRecordAndTombstoneFailsBeforeCommit() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132210")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")
        let digest = try SyncConvergenceCanonicalBatchDigest.digest(for: batch)
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

    func testCanonicalPayloadDigestV1IsStableAndOrderSensitive() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132211")
        let first = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132311"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132411"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: date(2),
                    baseContentHash: nil
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(3),
                    baseContentHash: ""
                ))
            ]
        )
        let reordered = SyncBatch(
            id: first.id,
            originDeviceID: first.originDeviceID,
            createdAt: first.createdAt,
            changes: Array(first.changes.reversed())
        )

        let bytes = try SyncConvergenceCanonicalBatchDigest.canonicalBytes(for: first)
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertEqual(bytes.count, 173)
        XCTAssertEqual(
            bytes.hexString,
            "4d5952310000000100000000000000000000000000132311000000000000000000000000001324113ff00000000000000000000000000000020000000000000000000000030000000000000000000000000013221100000000000000000000000000000001410040000000000000000000000000000001000000030000000000000000000000000013221100000000000000010000000000000001420100000000000000004008000000000000"
        )
        XCTAssertEqual(
            try SyncConvergenceCanonicalBatchDigest.digest(for: first),
            "f3bae6ee01c99de711aa9bfea7dcbb78ec337011716630c6bd52a6086479ba05"
        )
        XCTAssertEqual(try SyncConvergenceCanonicalBatchDigest.digest(for: first), try SyncConvergenceCanonicalBatchDigest.digest(for: first))
        XCTAssertNotEqual(try SyncConvergenceCanonicalBatchDigest.digest(for: first), try SyncConvergenceCanonicalBatchDigest.digest(for: reordered))
    }

    func testTwoBodyOperationsInOneBatchProduceOneCompleteEffectAndOneBodyEvidence() {
        let noteID = uuid("00000000-0000-0000-0000-000000132212")
        let firstBase = "AB"
        let afterInsert = "AxB"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132312"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132412"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: firstBase)
                )),
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    utf16Length: 1,
                    expectedText: "B",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: afterInsert)
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: firstBase)]
        ))

        guard case .planned(let plan) = outcome,
              case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected grouped matching-base body plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody, "Ax")
        XCTAssertEqual(bodyPlan.operations.map(\.operationIdentity.operationIndex), [0, 1])
        XCTAssertEqual(plan.incorporationEvidence.resultEvidence.filter { $0.kind == .body && $0.noteID == noteID }.count, 1)
    }

    func testConcurrentSameBaseOperationsConvergeInsteadOfCorruptingHistory() {
        let noteID = uuid("00000000-0000-0000-0000-000000132213")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132513"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132613"),
            operationIndex: 0,
            offset: 1,
            text: "y",
            modifiedAt: date(2),
            baseBody: base,
            resultBody: "AyB"
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132313"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132413"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(3),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AyB")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedLocalOperations: [retained]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected reconstructed concurrent plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody.filter { $0 == "x" }.count, 1)
        XCTAssertEqual(bodyPlan.finalBody.filter { $0 == "y" }.count, 1)
    }

    func testQueuedSameNoteEvidenceParticipatesInConflictUnion() {
        let noteID = uuid("00000000-0000-0000-0000-00000013222A")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let queued = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013252A"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013262A"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "y",
                    modifiedAt: date(2),
                    baseContentHash: baseHash
                ))
            ]
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013232A"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013242A"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(3),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AyB")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            queuedBatches: [SyncConvergenceQueuedBatch(batch: queued, queuePosition: 0)]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected queued same-note evidence in reconstructed union, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody.filter { $0 == "x" }.count, 1)
        XCTAssertEqual(bodyPlan.finalBody.filter { $0 == "y" }.count, 1)
    }

    func testLaterQueuedSameNoteSuccessorIsBlockedFromEvidenceSelection() {
        let noteID = uuid("00000000-0000-0000-0000-00000013222D")
        let candidate = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013232D"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013242D"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: nil
                ))
            ]
        )
        let earlier = SyncConvergenceQueuedBatch(batch: candidate, queuePosition: 1)
        let successor = SyncConvergenceQueuedBatch(
            batch: SyncBatch(
                id: uuid("00000000-0000-0000-0000-00000013252E"),
                originDeviceID: uuid("00000000-0000-0000-0000-00000013262E"),
                createdAt: date(1),
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "y",
                        modifiedAt: date(3),
                        baseContentHash: nil
                    ))
                ]
            ),
            queuePosition: 2
        )

        let selection = SyncConvergenceEvidenceSelector().selectQueuedBatches(
            for: candidate,
            queuedBatches: [successor, earlier]
        )

        XCTAssertTrue(selection.eligibleEvidenceBatches.isEmpty)
        XCTAssertEqual(selection.blockedBatches.map(\.batch.id), [successor.batch.id])
        XCTAssertEqual(selection.blockedNoteIDs, [noteID])
    }

    func testSameBatchChainedOperationsSurviveReconstructedConflict() {
        let noteID = uuid("00000000-0000-0000-0000-00000013222E")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let senderAfterFirst = "AxB"
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013252F"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013262F"),
            operationIndex: 0,
            offset: 1,
            text: "y",
            modifiedAt: date(2),
            baseBody: base,
            resultBody: "AyB"
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013232E"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013242E"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(3),
                    baseContentHash: baseHash
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "q",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: senderAfterFirst)
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AyB")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedLocalOperations: [retained]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected chained same-batch operations to plan in one union, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody.filter { ["x", "y", "q"].contains($0) }.count, 3)
        XCTAssertEqual(plan.incorporationEvidence.resultEvidence.filter { $0.kind == .body && $0.noteID == noteID }.count, 1)
    }

    func testTwoRetainedConcurrentCandidatesDoNotCorruptMergedReplay() {
        let noteID = uuid("00000000-0000-0000-0000-00000013222B")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let firstRetained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013252B"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013262B"),
            operationIndex: 0,
            offset: 1,
            text: "x",
            modifiedAt: date(2),
            baseBody: base,
            resultBody: "AxB"
        )
        let secondRetained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013252C"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013262C"),
            operationIndex: 0,
            offset: 1,
            text: "y",
            modifiedAt: date(3),
            baseBody: base,
            resultBody: "AyB"
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013232B"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013242B"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "z",
                    modifiedAt: date(4),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AxyB")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedLocalOperations: [firstRetained, secondRetained]
        ))

        guard case .planned(let plan) = outcome,
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected retained concurrent candidates to merge, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody.filter { ["x", "y", "z"].contains($0) }.count, 3)
    }

    func testNilBaseRetainedOperationWithResultHashReconstructsChain() {
        let noteID = uuid("00000000-0000-0000-0000-00000013222C")
        let snapshotBody = "A"
        let targetBody = "AB"
        let targetHash = SyncBatchContentHash.sha256Hex(for: targetBody)
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-00000013252D"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013262D"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: targetBody
        ).withoutBaseHash()
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-00000013232C"),
            originDeviceID: uuid("00000000-0000-0000-0000-00000013242C"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(3),
                    baseContentHash: targetHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AX")],
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
            return XCTFail("Expected nil-base retained reconstruction, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseHash, targetHash)
    }

    func testMalformedRetainedReplayKeyFailsAsCorruptHistoryWithoutFallbackOrdering() {
        let noteID = uuid("00000000-0000-0000-0000-000000132214")
        let base = "A"
        let target = "AB"
        let retained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132514"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132614"),
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "B",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: base),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: target),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                version: CanonicalReplayKeyPayload.supportedVersion,
                modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: date(2)),
                originDeviceIDLowercase: uuid("00000000-0000-0000-0000-000000132614").uuidString.lowercased(),
                batchOrderKind: .legacy,
                legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: date(1)),
                sequence: nil,
                batchIDLowercase: uuid("00000000-0000-0000-0000-000000132514").uuidString.lowercased(),
                operationIndex: -1
            )
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132314"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132414"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: target)
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AX")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: SyncBatchContentHash.sha256Hex(for: base), body: base, generation: 1)],
            retainedRemoteOperations: [retained]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.corruptHistory(noteID: noteID)))
    }

    func testRetainedChainInvalidRangeFailsAsCorruptHistory() {
        let noteID = uuid("00000000-0000-0000-0000-000000132215")
        let base = "A"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let targetHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let retained = retainedDelete(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132515"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132615"),
            operationIndex: 0,
            offset: 20,
            length: 1,
            expectedText: nil,
            modifiedAt: date(2),
            baseBody: base,
            resultHash: targetHash
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132315"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132415"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(3),
                    baseContentHash: targetHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AX")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedRemoteOperations: [retained]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.corruptHistory(noteID: noteID)))
    }

    func testUnknownTitleAndLegacyBodyProduceCompatibilityNoops() {
        let titleNote = uuid("00000000-0000-0000-0000-000000132216")
        let bodyNote = uuid("00000000-0000-0000-0000-000000132217")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132316"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132416"),
            createdAt: date(1),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(noteID: titleNote, title: "Ignored", modifiedAt: date(2))),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(noteID: bodyNote, utf16Offset: 0, text: "Ignored", modifiedAt: date(3)))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))

        guard case .planned(let plan) = outcome else {
            return XCTFail("Expected compatibility no-op plan, got \(outcome)")
        }
        XCTAssertEqual(plan.affectedNotePlans.count, 2)
        let titleEffect = plan.affectedNotePlans.first { $0.noteID == titleNote }?.titleEffect
        XCTAssertEqual(titleEffect?.verdict, .compatibilityNoopMissingNote)
        XCTAssertNil(titleEffect?.resultingWinningKey)
        guard case .compatibilityNoopMissingNote(let bodyPlan) = plan.affectedNotePlans.first(where: { $0.noteID == bodyNote })?.bodyEffect else {
            return XCTFail("Expected unknown legacy body no-op")
        }
        XCTAssertEqual(bodyPlan.operationIdentities.count, 1)
        XCTAssertTrue(plan.historyPlan.retainedOperationAdditions.isEmpty)
        XCTAssertTrue(plan.historyPlan.snapshotAdditions.isEmpty)
    }

    func testUnknownHashedBodyDefersWithRealDeclaredHash() {
        let noteID = uuid("00000000-0000-0000-0000-000000132218")
        let declared = SyncBatchContentHash.sha256Hex(for: "RemoteBase")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132318"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132418"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "x",
                    modifiedAt: date(2),
                    baseContentHash: declared
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))

        XCTAssertEqual(outcome, .deferred(.unreconstructableBase(noteID: noteID, batchID: batch.id, baseContentHash: declared)))
    }

    func testSoftHistoryPressureDefersNewEvidenceGrowth() {
        let noteID = uuid("00000000-0000-0000-0000-000000132219")
        let batch = makeTitleBatch(noteID: noteID, title: "Remote")

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, title: "Local")],
            historyStates: [
                SyncConvergenceHistoryAccountingProjection(
                    noteID: noteID,
                    snapshotCount: 9,
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

    private func retainedDelete(
        noteID: UUID,
        batchID: UUID,
        originDeviceID: UUID,
        operationIndex: Int,
        offset: Int,
        length: Int,
        expectedText: String?,
        modifiedAt: Date,
        baseBody: String,
        resultHash: String
    ) -> SyncConvergenceRetainedOperation {
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: date(1),
            changes: [
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: offset,
                    utf16Length: length,
                    expectedText: expectedText,
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
            operationKind: .delete,
            utf16Offset: offset,
            utf16Length: length,
            text: nil,
            expectedText: expectedText,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: baseBody),
            resultContentHash: resultHash,
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

private extension SyncConvergenceRetainedOperation {
    func withoutBaseHash() -> SyncConvergenceRetainedOperation {
        SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: operationIndex,
            operationKind: operationKind,
            utf16Offset: utf16Offset,
            utf16Length: utf16Length,
            text: text,
            expectedText: expectedText,
            baseContentHash: nil,
            resultContentHash: resultContentHash,
            canonicalReplayKey: canonicalReplayKey
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
