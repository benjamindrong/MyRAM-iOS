import AnchoredSequenceCore
import CryptoKit
import XCTest

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergencePlanningTests: XCTestCase {
    func testMYR179FailureFirstEveryNonSuccessRuntimeOutcomeIsFailClosedForAcknowledgement() {
        let batchID = UUID()
        let outcomes: [SyncConvergenceRuntimeOutcome] = [
            .alreadyDraining,
            .pending([.queueCleanup]),
            .blocked(.init(batchID: batchID, kind: .persistence)),
            .quarantined(.init(items: [])),
            .deferred(.init(incoming: [], localObligations: [], postCommit: []))
        ]

        for outcome in outcomes {
            XCTAssertNotEqual(
                SyncConvergenceRemoteBatchDispositionPolicy.disposition(
                    for: outcome,
                    batchID: batchID
                ),
                .acknowledgementPermitted
            )
        }
    }
    func testAnchoredBatchReachesAuthoritativeStatePlanning() throws {
        let batch = try makeAnchoredInsertBatchForTest()

        XCTAssertEqual(
            SyncConvergencePlanner().plan(
                input: SyncConvergencePlanningInput(incomingBatch: batch)
            ),
            .failedBeforeCommit(
                .staleAuthoritativeState(noteID: batch.changes[0].noteID)
            )
        )
    }

    func testMYR180AnchoredStructuralPlanningBypassesLegacyConflictRebasePath() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000180201")
        let deviceID = uuid("00000000-0000-0000-0000-000000180202")
        let initialBody = "AB"
        let initialState = try NoteSequenceStateBootstrapAdapter.makeInitialState(
            noteID: noteID,
            body: initialBody
        )
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 1,
            text: "x",
            modifiedAt: date(2),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: initialBody),
            operationID: SyncOperationID(deviceID: deviceID, localCounter: 180),
            state: initialState
        )
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000180203"),
            originDeviceID: deviceID,
            createdAt: date(1),
            batchSequence: 1,
            changes: [change]
        )
        let snapshot = NoteSequenceStateMutationSnapshot(
            noteID: noteID,
            body: initialBody,
            revision: 7,
            state: initialState
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: initialBody)],
            anchoredSequenceSnapshots: [snapshot],
            anchoredRecoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(
                records: [],
                health: .healthy
            )
        ))

        guard case .planned(let validatedInput) = outcome,
              case .anchoredStructural(let bodyPlan) = validatedInput.plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected anchored structural planning, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.expectedSnapshot, snapshot)
        XCTAssertEqual(bodyPlan.finalBody, "AxB")
        XCTAssertEqual(bodyPlan.finalState.visibleText, "AxB")
        XCTAssertEqual(
            validatedInput.plan.presentationPlan.noteRoutings[noteID],
            .structuralRefresh
        )
    }

    func testCanonicalDigestDeterministicallySupportsAnchoredBatchForFutureEnabledPlanning() throws {
        let batch = try makeAnchoredInsertBatchForTest()
        let first = try SyncConvergenceCanonicalBatchDigest.canonicalBytes(for: batch)
        let second = try SyncConvergenceCanonicalBatchDigest.canonicalBytes(for: batch)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(
            try SyncConvergenceCanonicalBatchDigest.digest(for: batch),
            try SyncConvergenceCanonicalBatchDigest.digest(for: batch)
        )
    }

    func testLifecycleDivergencePreservesLiveNoteWithoutBlockingPlan() {
        let noteID = uuid("00000000-0000-0000-0000-000000165101")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165102"), originDeviceID: uuid("00000000-0000-0000-0000-000000165103"), createdAt: date(1),
            changes: [.noteLifecycleChanged(.init(noteID: noteID, deletedAt: date(1), modifiedAt: date(1), baseTitleHash: SyncBatchContentHash.sha256Hex(for: "old"), baseBodyHash: SyncBatchContentHash.sha256Hex(for: "old")))]
        )
        let outcome = SyncConvergencePlanner().plan(input: .init(incomingBatch: batch, currentNotes: [projectedNote(noteID: noteID, title: "edited", body: "edited")]))
        guard case .planned(let input) = outcome,
              let effect = input.plan.affectedNotePlans.first?.lifecycleEffect else { return XCTFail("Expected non-blocking lifecycle plan, got \(outcome)") }
        XCTAssertEqual(effect.verdict, .preserveLiveNote)
        XCTAssertEqual(input.plan.presentationPlan.noteRoutings[noteID], SyncConvergencePresentationRouting.none)
    }

    func testLifecycleForMissingNoteIsConsumedWithoutBlockingPlan() {
        let noteID = uuid("00000000-0000-0000-0000-000000165111")
        let batch = SyncBatch(id: uuid("00000000-0000-0000-0000-000000165112"), originDeviceID: uuid("00000000-0000-0000-0000-000000165113"), createdAt: date(1), changes: [.noteLifecycleChanged(.init(noteID: noteID, deletedAt: date(1), modifiedAt: date(1), baseTitleHash: "a", baseBodyHash: "b"))])
        let outcome = SyncConvergencePlanner().plan(input: .init(incomingBatch: batch))
        guard case .planned(let input) = outcome else { return XCTFail("Expected missing lifecycle plan, got \(outcome)") }
        XCTAssertEqual(input.plan.affectedNotePlans.first?.lifecycleEffect?.verdict, .preserveLiveNote)
    }

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

        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected planned outcome, got \(outcome)")
        }
        let plan = validatedInput.plan
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

    func testHashlessAnchorlessBodyOperationDefersBeforeCurrentBodyReplay() {
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

        guard case .deferred(let reason) = outcome else {
            return XCTFail("Expected typed compatibility deferral, got \(outcome)")
        }
        XCTAssertEqual(
            reason,
            .anchorlessMatchingBaseEvidenceUnavailable(
                noteID: noteID,
                batchID: batch.id
            )
        )
    }

    func testAnchorlessCompatibilityDeferralSuppressesTransportAcknowledgement() {
        let noteID = UUID(uuidString: "17800000-0000-0000-0000-0000000000D1")!
        let batchID = UUID(uuidString: "17800000-0000-0000-0000-0000000000D2")!
        let deferred = SyncConvergenceDeferredWork(
            incoming: [SyncConvergenceDeferredItem(
                domain: .incoming,
                batchID: batchID,
                affectedNoteIDs: [noteID],
                reason: .planning(.anchorlessMatchingBaseEvidenceUnavailable(
                    noteID: noteID,
                    batchID: batchID
                ))
            )],
            localObligations: [],
            postCommit: []
        )

        XCTAssertEqual(
            SyncConvergenceRemoteBatchDispositionPolicy.disposition(
                for: .deferred(deferred),
                batchID: batchID
            ),
            .recoverableAnchorlessCompatibilityRejection
        )
    }

    func testAlreadyDrainingDefersTransportAcknowledgementWithoutClassifyingCompatibility() {
        XCTAssertEqual(
            SyncConvergenceRemoteBatchDispositionPolicy.disposition(
                for: .alreadyDraining,
                batchID: UUID()
            ),
            .acknowledgementDeferred
        )
    }

    func testCompletedMatchingCompatibilityBatchPermitsTransportAcknowledgement() {
        let batchID = UUID()
        XCTAssertEqual(
            SyncConvergenceRemoteBatchDispositionPolicy.disposition(
                for: .drained(appliedBatchIDs: [batchID]),
                batchID: batchID
            ),
            .acknowledgementPermitted
        )
    }

    func testDivergentUnreconstructableBaseSuppressesTransportAcknowledgement() {
        let noteID = UUID(uuidString: "17800000-0000-0000-0000-0000000000D3")!
        let batchID = UUID(uuidString: "17800000-0000-0000-0000-0000000000D4")!
        let deferred = SyncConvergenceDeferredWork(
            incoming: [SyncConvergenceDeferredItem(
                domain: .incoming,
                batchID: batchID,
                affectedNoteIDs: [noteID],
                reason: .planning(.unreconstructableBase(
                    noteID: noteID,
                    batchID: batchID,
                    baseContentHash: String(repeating: "a", count: 64)
                ))
            )],
            localObligations: [],
            postCommit: []
        )

        XCTAssertEqual(
            SyncConvergenceRemoteBatchDispositionPolicy.disposition(
                for: .deferred(deferred),
                batchID: batchID
            ),
            .recoverableAnchorlessCompatibilityRejection
        )
    }

    func testReconstructedConflictDroppingUnprovenTextReturnsUnprovenTextLoss() {
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

        guard case .failedBeforeCommit(let failure) = outcome else {
            return XCTFail("Expected unproven text loss failure, got \(outcome)")
        }
        XCTAssertEqual(failure, .unprovenTextLoss(noteID: noteID))
    }

    func testReconstructedConflictUsesDeleteEvidenceForWholeNoteRouting() {
        let noteID = uuid("00000000-0000-0000-0000-000000132206")
        let currentBody = "ACB"
        let incomingBase = "AB"
        let incomingBaseHash = SyncBatchContentHash.sha256Hex(for: incomingBase)
        let retainedDelete = retainedDelete(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132506"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132606"),
            operationIndex: 0,
            offset: 1,
            length: 1,
            expectedText: "C",
            modifiedAt: date(2),
            baseBody: currentBody,
            resultHash: incomingBaseHash
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132306"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132406"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(3),
                    baseContentHash: incomingBaseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: currentBody)],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: incomingBaseHash, body: incomingBase, generation: 1)
            ],
            retainedRemoteOperations: [retainedDelete]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected safe reconstructed conflict plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseBody, incomingBase)
        XCTAssertEqual(bodyPlan.finalBody, "AxB")
        XCTAssertEqual(plan.presentationPlan.noteRoutings[noteID], .wholeNoteFallback)
        XCTAssertEqual(bodyPlan.rewriteSafetyReceipt?.noteID, noteID)
        XCTAssertEqual(bodyPlan.rewriteSafetyReceipt?.priorBodyHash, SyncBatchContentHash.sha256Hex(for: currentBody))
        XCTAssertEqual(bodyPlan.rewriteSafetyReceipt?.candidateBodyHash, bodyPlan.finalBodyHash)
        XCTAssertFalse(bodyPlan.rewriteSafetyReceipt?.consumedDeleteIdentities.isEmpty ?? true)
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
            currentNotes: [projectedNote(noteID: noteID, body: "ABC")],
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
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

        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected planned title outcome, got \(outcome)")
        }
        let plan = validatedInput.plan
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
                    explicitDeleteProvenanceCount: 0,
                    explicitDeleteProvenanceBytes: 0,
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

        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected planned creation outcome, got \(outcome)")
        }
        let plan = validatedInput.plan
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

    func testProjectedNoteEffectV1GoldenVectorPreservesMainContract() throws {
        let bytes = try projectedNoteEffectBytes(kinds: ["body", "title", "creation"])

        XCTAssertEqual(bytes.count, 117)
        XCTAssertEqual(
            bytes.hexString,
            "000000000000001c696e636f72706f726174696f6e2d6e6f74652d6566666563742d763100000000000000000000000000132c1000000000000000000000000000132c1100000000000000030000000000000004626f647900000000000000086372656174696f6e00000000000000057469746c65"
        )
        XCTAssertEqual(
            sha256Hex(bytes),
            "e6048b2eec3825e2394d70009c8f1234df6bdb3508b48c897b7d6df5849e55b5"
        )
        XCTAssertEqual(
            String(data: bytes.dropFirst(8).prefix(28), encoding: .utf8),
            "incorporation-note-effect-v1"
        )
    }

    func testProjectedNoteEffectV1IsKindPermutationIndependent() throws {
        let canonical = try projectedNoteEffectBytes(kinds: ["body", "creation", "title"])

        for kinds in permutations(["body", "creation", "title"]) {
            let bytes = try projectedNoteEffectBytes(kinds: kinds)
            XCTAssertEqual(bytes, canonical)
            XCTAssertEqual(bytes.count, canonical.count)
            XCTAssertEqual(sha256Hex(bytes), sha256Hex(canonical))
        }
    }

    func testProjectedNoteEffectV1MultiEffectPermutationIndependence() throws {
        let cases = [
            ["body", "title"],
            ["creation", "body"],
            ["creation", "title"],
            ["creation", "body", "title"]
        ]

        for kinds in cases {
            let canonical = try projectedNoteEffectBytes(kinds: kinds.sorted())
            for permutation in permutations(kinds) {
                XCTAssertEqual(try projectedNoteEffectBytes(kinds: permutation), canonical)
            }
        }
    }

    func testProjectedNoteEffectKindMembershipRejectsInvalidSets() {
        XCTAssertFalse(SyncConvergenceNoteEffectKindMembership.validate(["body", "title"], expected: ["body", "title", "creation"]))
        XCTAssertFalse(SyncConvergenceNoteEffectKindMembership.validate(["body", "title", "creation"], expected: ["body", "title"]))
        XCTAssertFalse(SyncConvergenceNoteEffectKindMembership.validate(["body", "body"], expected: ["body"]))
        XCTAssertFalse(SyncConvergenceNoteEffectKindMembership.validate(["body", "unsupported"], expected: ["body"]))
        XCTAssertTrue(SyncConvergenceNoteEffectKindMembership.validate(["title", "body"], expected: ["body", "title"]))
    }

    func testCommittedResultV1GoldenVectorMatrix() throws {
        let fixtures = committedResultGoldenFixtures()

        for fixture in fixtures {
            let bytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
                batchID: committedResultBatchID,
                results: fixture.results
            )
            XCTAssertEqual(bytes.count, fixture.byteCount, fixture.name)
            XCTAssertEqual(bytes.hexString, fixture.hex, fixture.name)
            XCTAssertEqual(sha256Hex(bytes), fixture.digest, fixture.name)
        }
    }

    func testCommittedResultV1ReconciliationReservedVariantIsPinned() throws {
        let fixture = committedResultGoldenFixtures().first { $0.name == "reconciliation" }!
        let bytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: fixture.results
        )

        XCTAssertEqual(bytes.dropFirst(28).prefix(4).hexString, "00000004")
        XCTAssertEqual(bytes.count, 296)
        XCTAssertEqual(bytes.hexString, fixture.hex)
        XCTAssertEqual(sha256Hex(bytes), fixture.digest)
    }

    func testCommittedResultV1OrderingAndChangeSensitivity() throws {
        let fixtures = committedResultGoldenFixtures()
        let multiple = fixtures.first { $0.name == "multiple" }!
        let reorderedBytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: multiple.results.reversed()
        )
        XCTAssertEqual(reorderedBytes.hexString, multiple.hex)
        XCTAssertEqual(sha256Hex(reorderedBytes), multiple.digest)

        let body = fixtures.first { $0.name == "body" }!
        let changed = fixtures.first { $0.name == "changed" }!
        let bodyBytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: body.results
        )
        let changedBytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: changed.results
        )
        XCTAssertNotEqual(changedBytes, bodyBytes)
        XCTAssertNotEqual(sha256Hex(changedBytes), sha256Hex(bodyBytes))
    }

    func testCommittedResultV1ReconciliationHashFieldOrderIsSignificant() throws {
        let identity = committedResultIdentity(kind: "reconciliation", operationIndex: 3, modifiedAt: date(5))
        let firstBytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: [.reconciliation(
                noteID: committedResultNoteID,
                identity: identity,
                finalBodyHash: String(repeating: "a", count: 64),
                replacementContentHash: String(repeating: "b", count: 64)
            )]
        )
        let secondBytes = try CanonicalCommittedResultDigestPayloadV1.canonicalBytes(
            batchID: committedResultBatchID,
            results: [.reconciliation(
                noteID: committedResultNoteID,
                identity: identity,
                finalBodyHash: String(repeating: "b", count: 64),
                replacementContentHash: String(repeating: "a", count: 64)
            )]
        )

        XCTAssertNotEqual(firstBytes, secondBytes)
        XCTAssertNotEqual(sha256Hex(firstBytes), sha256Hex(secondBytes))
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected grouped matching-base body plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody, "Ax")
        XCTAssertEqual(bodyPlan.operations.map(\.operationIdentity.operationIndex), [0, 1])
        XCTAssertEqual(plan.incorporationEvidence.resultEvidence.filter { $0.kind == .body && $0.noteID == noteID }.count, 1)
    }

    func testAllRetainedBodyOperationsRouteNone() {
        let noteID = uuid("00000000-0000-0000-0000-0000001322F0")
        let baseBody = "A"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-0000001323F0"),
            originDeviceID: uuid("00000000-0000-0000-0000-0000001324F0"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: baseBody)
                ))
            ]
        )
        let retained = retainedInsert(
            noteID: noteID,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: baseBody,
            resultBody: "AB"
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "AB")],
            retainedRemoteOperations: [retained]
        ))

        guard case .planned(let validatedInput) = outcome,
              case .matchingBaseIncremental(let bodyPlan) = validatedInput.plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected all-retained body plan, got \(outcome)")
        }
        XCTAssertEqual(validatedInput.plan.presentationPlan.noteRoutings[noteID], SyncConvergencePresentationRouting.none)
        XCTAssertTrue(bodyPlan.operations.isEmpty)
        XCTAssertEqual(bodyPlan.finalBodyHash, SyncBatchContentHash.sha256Hex(for: "AB"))
    }

    func testMixedRetainedAndExecutableBodyOperationsRouteIncrementalWithOnlyNewWork() {
        let noteID = uuid("00000000-0000-0000-0000-0000001322F1")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-0000001323F1"),
            originDeviceID: uuid("00000000-0000-0000-0000-0000001324F1"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                ))
            ]
        )
        let retained = retainedInsert(
            noteID: noteID,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: "A",
            resultBody: "AB"
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [projectedNote(noteID: noteID, body: "AB")],
            retainedRemoteOperations: [retained]
        ))

        guard case .planned(let validatedInput) = outcome,
              case .matchingBaseIncremental(let bodyPlan) = validatedInput.plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected mixed body plan, got \(outcome)")
        }
        XCTAssertEqual(validatedInput.plan.presentationPlan.noteRoutings[noteID], .incremental)
        XCTAssertEqual(bodyPlan.operations.map(\.operationIdentity.operationIndex), [1])
        XCTAssertEqual(bodyPlan.finalBody, "ABC")
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected retained concurrent candidates to merge, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody.filter { ["x", "y", "z"].contains($0) }.count, 3)
    }

    // Regression coverage for MYR-165: concurrent operations recorded relative to
    // the shared base must be rebased against each other during replay, not applied
    // with their raw offsets against an already-mutated body. Unlike the tests
    // above (non-overlapping single-character inserts, which pass either way),
    // this exercises an insert whose target position is only reachable by
    // accounting for an earlier-replayed foreign insert's length.
    func testConcurrentInsertsRebaseOffsetsInsteadOfCorruptingLaterText() {
        let noteID = uuid("00000000-0000-0000-0000-000000165201")
        let base = "Hello World"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000165202"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165203"),
            operationIndex: 0,
            offset: 0,
            text: "XXX",
            modifiedAt: date(2),
            baseBody: base,
            resultBody: "XXXHello World"
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165204"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165205"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: base.utf16.count,
                    text: "YYY",
                    modifiedAt: date(3),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "XXXHello World")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedLocalOperations: [retained]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected reconstructed concurrent plan, got \(outcome)")
        }
        // Without rebasing, the incoming insert's raw offset (11, the end of the
        // original 11-character base) lands in the middle of "World" once the
        // retained "XXX" has already shifted everything forward by three
        // characters, corrupting the text to "XXXHello WoYYYrld".
        XCTAssertEqual(bodyPlan.finalBody, "XXXHello WorldYYY")
    }

    // A delete that shifts text backward must also rebase a later concurrent
    // insert's offset, not just an insert shifting one forward. Without this, the
    // insert's raw offset overshoots into the now-shorter body and (after
    // boundary clamping) silently lands at the wrong position instead of where it
    // was actually meant to go. The delete is the incoming side here (rather than
    // retained/local) so the local "prior" body still contains the text the
    // incoming delete's evidence expects to find, satisfying
    // SyncConvergenceRewriteSafetyPolicy's own evidence check independent of the
    // offset-rebase logic under test.
    func testConcurrentDeleteRebasesLaterInsertOffsetBackward() {
        let noteID = uuid("00000000-0000-0000-0000-000000165211")
        let base = "Hello cruel World"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let retained = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000165212"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165213"),
            operationIndex: 0,
            offset: 12,
            text: "big ",
            modifiedAt: date(3),
            baseBody: base,
            resultBody: "Hello cruel big World"
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165214"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165215"),
            createdAt: date(1),
            changes: [
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: 5,
                    utf16Length: 6,
                    expectedText: " cruel",
                    modifiedAt: date(2),
                    baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "Hello cruel big World")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
            retainedLocalOperations: [retained]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected reconstructed concurrent plan, got \(outcome)")
        }
        // The delete (offset 5, length 6, canonically replayed first since its
        // modifiedAt is earlier) removes " cruel" from the base. Without rebasing,
        // the insert's raw offset (12, originally right before "World" in the
        // 17-character base) gets applied unmodified to the now-11-character
        // post-delete body, landing at "Hello Worldbig " instead of before "World".
        XCTAssertEqual(bodyPlan.finalBody, "Hello big World")
    }

    // The canonical replay order is symmetric by construction (it never depends on
    // which side calls an operation "local/retained" vs "incoming/remote"), but
    // that alone doesn't guarantee identical output unless offsets are rebased
    // consistently regardless of role. This runs the same pair of concurrent edits
    // from both devices' points of view and asserts they converge to the exact
    // same string — the property that was broken (peers converging to different
    // permutations of the same edits, or silently losing a character).
    func testConcurrentEditsConvergeToIdenticalBodyRegardlessOfWhichSideIsLocal() {
        let noteID = uuid("00000000-0000-0000-0000-000000165221")
        let base = "Hello World"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let deviceAID = uuid("00000000-0000-0000-0000-000000165222")
        let deviceBID = uuid("00000000-0000-0000-0000-000000165223")
        let batchAID = uuid("00000000-0000-0000-0000-000000165224")
        let batchBID = uuid("00000000-0000-0000-0000-000000165225")

        func finalBody(localDeviceIsA: Bool) -> String {
            let localOperation = retainedInsert(
                noteID: noteID,
                batchID: localDeviceIsA ? batchAID : batchBID,
                originDeviceID: localDeviceIsA ? deviceAID : deviceBID,
                operationIndex: 0,
                offset: localDeviceIsA ? 0 : base.utf16.count,
                text: localDeviceIsA ? "XXX" : "YYY",
                modifiedAt: localDeviceIsA ? date(2) : date(3),
                baseBody: base,
                resultBody: localDeviceIsA ? "XXXHello World" : "Hello WorldYYY"
            )
            let remoteChange: SyncBatchNoteBodyTextInsertedChange = localDeviceIsA
                ? SyncBatchNoteBodyTextInsertedChange(noteID: noteID, utf16Offset: base.utf16.count, text: "YYY", modifiedAt: date(3), baseContentHash: baseHash)
                : SyncBatchNoteBodyTextInsertedChange(noteID: noteID, utf16Offset: 0, text: "XXX", modifiedAt: date(2), baseContentHash: baseHash)
            let incoming = SyncBatch(
                id: localDeviceIsA ? batchBID : batchAID,
                originDeviceID: localDeviceIsA ? deviceBID : deviceAID,
                createdAt: date(1),
                changes: [.noteBodyTextInserted(remoteChange)]
            )

            let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
                incomingBatch: incoming,
                currentNotes: [projectedNote(noteID: noteID, body: localDeviceIsA ? "XXXHello World" : "Hello WorldYYY")],
                retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)],
                retainedLocalOperations: [localOperation]
            ))

            guard case .planned(let validatedInput) = outcome,
                  let plan = Optional(validatedInput.plan),
                  case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
                XCTFail("Expected reconstructed concurrent plan, got \(outcome)")
                return ""
            }
            return bodyPlan.finalBody
        }

        let resultWhenALocal = finalBody(localDeviceIsA: true)
        let resultWhenBLocal = finalBody(localDeviceIsA: false)

        XCTAssertEqual(resultWhenALocal, "XXXHello WorldYYY")
        XCTAssertEqual(resultWhenBLocal, resultWhenALocal)
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
            currentNotes: [projectedNote(noteID: noteID, body: "ABC")],
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

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
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

        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected compatibility no-op plan, got \(outcome)")
        }
        let plan = validatedInput.plan
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
                    explicitDeleteProvenanceCount: 0,
                    explicitDeleteProvenanceBytes: 0,
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

    func testEarlierMultiNoteEvidenceBatchBlocksItsOtherNotes() {
        let noteA = uuid("00000000-0000-0000-0000-000000132731")
        let noteB = uuid("00000000-0000-0000-0000-000000132732")
        let candidate = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132831"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132832"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteA, utf16Offset: 0, text: "c", modifiedAt: date(4), baseContentHash: nil
                ))
            ]
        )
        let evidence = SyncConvergenceQueuedBatch(
            batch: SyncBatch(
                id: uuid("00000000-0000-0000-0000-000000132833"),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132834"),
                createdAt: date(1),
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteA, utf16Offset: 0, text: "a", modifiedAt: date(2), baseContentHash: nil
                    )),
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteB, utf16Offset: 0, text: "b", modifiedAt: date(2), baseContentHash: nil
                    ))
                ]
            ),
            queuePosition: 0
        )
        let later = SyncConvergenceQueuedBatch(
            batch: SyncBatch(
                id: uuid("00000000-0000-0000-0000-000000132835"),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132836"),
                createdAt: date(1),
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteB, utf16Offset: 1, text: "z", modifiedAt: date(3), baseContentHash: nil
                    ))
                ]
            ),
            queuePosition: 1
        )

        let selection = SyncConvergenceEvidenceSelector().selectQueuedBatches(
            for: candidate,
            queuedBatches: [later, evidence]
        )

        // The earlier batch touches a note the candidate cannot cover, so it is
        // atomic-blocked rather than partially spliced as evidence.
        XCTAssertTrue(selection.eligibleEvidenceBatches.isEmpty)
        XCTAssertTrue(selection.blockedNoteIDs.contains(noteB))
        XCTAssertEqual(Set(selection.blockedBatches.map(\.batch.id)), [evidence.batch.id, later.batch.id])
        XCTAssertTrue(selection.eligibleDisjointBatches.isEmpty)
    }

    func testEarlierMultiNoteQueuedBatchIsNotPartiallyConsumedAsUnionEvidence() {
        let noteA = uuid("00000000-0000-0000-0000-000000132741")
        let noteB = uuid("00000000-0000-0000-0000-000000132742")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let multiNoteQueued = SyncConvergenceQueuedBatch(
            batch: SyncBatch(
                id: uuid("00000000-0000-0000-0000-000000132861"),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132862"),
                createdAt: date(1),
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteA, utf16Offset: 1, text: "y", modifiedAt: date(2), baseContentHash: baseHash
                    )),
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteB, utf16Offset: 0, text: "z", modifiedAt: date(2), baseContentHash: nil
                    ))
                ]
            ),
            queuePosition: 0
        )
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132863"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132864"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteA, utf16Offset: 1, text: "x", modifiedAt: date(3), baseContentHash: baseHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteA, body: "AxB")],
            retainedSnapshots: [SyncConvergenceRetainedSnapshot(noteID: noteA, contentHash: baseHash, body: base, generation: 1)],
            queuedBatches: [multiNoteQueued]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected planned reconstruction without spliced evidence, got \(outcome)")
        }
        let queuedBatchIDLowercase = multiNoteQueued.batch.id.uuidString.lowercased()
        XCTAssertFalse(plan.incorporationEvidence.operationIdentities.contains {
            $0.batchIDLowercase == queuedBatchIDLowercase
        })
        XCTAssertFalse(bodyPlan.finalBody.contains("y"))
        XCTAssertFalse(bodyPlan.finalBody.contains("z"))
    }

    func testCompetingValidNilBaseBranchesBacktrackToTargetPath() {
        let noteID = uuid("00000000-0000-0000-0000-000000132743")
        let snapshotBody = "A"
        let targetBody = "AB"
        let targetHash = SyncBatchContentHash.sha256Hex(for: targetBody)
        // Earlier canonical branch: individually valid (its declared result matches its
        // own replay from the snapshot) but not on the path to the requested target.
        let offTargetBranch = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132865"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132866"),
            operationIndex: 0,
            offset: 0,
            text: "Q",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: "QA"
        ).withoutBaseHash()
        let targetBranch = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132867"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132868"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(3),
            baseBody: snapshotBody,
            resultBody: targetBody
        ).withoutBaseHash()
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132869"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132870"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 2, text: "C", modifiedAt: date(4), baseContentHash: targetHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "ABC")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                    body: snapshotBody,
                    generation: 1
                )
            ],
            retainedRemoteOperations: [offTargetBranch, targetBranch]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected backtracking reconstruction to reach the target branch, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseHash, targetHash)
        XCTAssertFalse(bodyPlan.reconstructedBaseBody.contains("Q"))
    }

    func testExplicitCandidateQueuePositionLimitsEvidenceToEarlierBatches() {
        let noteID = uuid("00000000-0000-0000-0000-000000132733")
        let candidate = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132837"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132838"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "c", modifiedAt: date(4), baseContentHash: nil
                ))
            ]
        )
        func sameNoteQueued(_ suffix: String, position: Int) -> SyncConvergenceQueuedBatch {
            SyncConvergenceQueuedBatch(
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-00000013283\(suffix)"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132840"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: noteID, utf16Offset: 0, text: "q", modifiedAt: date(2), baseContentHash: nil
                        ))
                    ]
                ),
                queuePosition: position
            )
        }
        let earlier = sameNoteQueued("9", position: 0)
        let laterSuccessor = sameNoteQueued("A", position: 2)

        let selection = SyncConvergenceEvidenceSelector().selectQueuedBatches(
            for: candidate,
            queuedBatches: [earlier, laterSuccessor],
            candidateQueuePosition: 1
        )

        XCTAssertEqual(selection.candidateBatch.queuePosition, 1)
        XCTAssertEqual(selection.eligibleEvidenceBatches.map(\.batch.id), [earlier.batch.id])
        XCTAssertEqual(selection.blockedBatches.map(\.batch.id), [laterSuccessor.batch.id])
    }

    func testRetainedIdentityIdempotencyPreventsDoubleApplication() {
        let noteID = uuid("00000000-0000-0000-0000-000000132734")
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132841"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132842"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "x", modifiedAt: date(2), baseContentHash: nil
                ))
            ]
        )
        let alreadyRetained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: incoming.id,
            originDeviceID: incoming.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 0,
            utf16Length: nil,
            text: "x",
            expectedText: nil,
            baseContentHash: nil,
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "xAB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: incoming, change: incoming.changes[0], operationIndex: 0)
            )
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "xAB")],
            retainedRemoteOperations: [alreadyRetained]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected idempotent planned outcome, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.finalBody, "xAB")
        XCTAssertTrue(bodyPlan.operations.isEmpty)
        XCTAssertTrue(plan.historyPlan.retainedOperationAdditions.isEmpty)
        XCTAssertEqual(plan.incorporationEvidence.operationIdentities.count, 1)
    }

    func testRetainedIdentityContradictionFailsClosed() {
        let noteID = uuid("00000000-0000-0000-0000-000000132735")
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132843"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132844"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "x", modifiedAt: date(2), baseContentHash: nil
                ))
            ]
        )
        let contradictoryRetained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: incoming.id,
            originDeviceID: incoming.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 0,
            utf16Length: nil,
            text: "DIFFERENT",
            expectedText: nil,
            baseContentHash: nil,
            resultContentHash: nil,
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: incoming, change: incoming.changes[0], operationIndex: 0)
            )
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "AB")],
            retainedRemoteOperations: [contradictoryRetained]
        ))

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: noteID)))
    }

    func testUnrelatedNilBaseRetainedBranchDoesNotBlockValidReconstruction() {
        let noteID = uuid("00000000-0000-0000-0000-000000132736")
        let snapshotBody = "A"
        let targetBody = "AB"
        let targetHash = SyncBatchContentHash.sha256Hex(for: targetBody)
        let unrelatedBranch = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132845"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132846"),
            operationIndex: 0,
            offset: 0,
            text: "Q",
            modifiedAt: date(2),
            baseBody: "unrelated-base",
            resultBody: "ZZ"
        ).withoutBaseHash()
        let validStep = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132847"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132848"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(3),
            baseBody: snapshotBody,
            resultBody: targetBody
        ).withoutBaseHash()
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132849"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132850"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 2, text: "C", modifiedAt: date(4), baseContentHash: targetHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "ABC")],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                    body: snapshotBody,
                    generation: 1
                )
            ],
            retainedRemoteOperations: [unrelatedBranch, validStep]
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected unrelated nil-base branch to be skipped, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseHash, targetHash)
    }

    func testNilBaseRetainedOperationWithoutEvidenceIsNeverGuessedIntoChain() {
        let noteID = uuid("00000000-0000-0000-0000-000000132737")
        let snapshotBody = "A"
        let targetHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let unverifiable = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132851"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132852"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: "AB"
        ).withoutBaseHash().withoutResultHash()
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132853"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132854"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 2, text: "C", modifiedAt: date(3), baseContentHash: targetHash
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
            retainedRemoteOperations: [unverifiable]
        ))

        XCTAssertEqual(outcome, .deferred(.unreconstructableBase(
            noteID: noteID,
            batchID: incoming.id,
            baseContentHash: targetHash
        )))
    }

    func testUnencodablePlannedOperationAccountingFailsClosed() {
        let noteID = uuid("00000000-0000-0000-0000-000000132738")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132855"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132856"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "x", modifiedAt: date(2), baseContentHash: nil
                ))
            ]
        )
        let identity = OperationIdentityPayload(
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            operationKind: "insert",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
            )
        )
        let unencodable = SyncConvergencePlannedBodyOperation(
            noteID: noteID,
            kind: .insert,
            utf16Offset: -1,
            utf16Length: nil,
            text: "x",
            expectedText: nil,
            baseContentHash: nil,
            resultContentHash: "hash",
            operationIdentity: identity
        )

        XCTAssertThrowsError(try unencodable.canonicalEncodedByteCount())
    }

    func testValidatorRejectsMissingSourceOperationBlockedSuccessorRoutingAndHistoryMismatch() throws {
        let fixture = try validatorFixture()
        let validator = SyncConvergencePlanValidator()

        XCTAssertNil(validator.validate(
            fixture.plan,
            input: fixture.input,
            queueSelection: fixture.selection,
            projectedFullIncorporationEvidenceBytes: fixture.projectedBytes
        ))

        // Missing source operation: drop the title identity while its note stays represented.
        let droppedIdentities = fixture.plan.incorporationEvidence.operationIdentities.filter {
            $0.operationKind != "title"
        }
        let missingSource = rebuiltPlan(
            fixture.plan,
            incorporationEvidence: SyncConvergenceIncorporationPlan(
                operationIdentities: droppedIdentities,
                resultEvidence: fixture.plan.incorporationEvidence.resultEvidence
            )
        )
        XCTAssertEqual(
            validator.validate(
                missingSource,
                input: fixture.input,
                queueSelection: fixture.selection,
                projectedFullIncorporationEvidenceBytes: try projectedBytes(for: missingSource, input: fixture.input)
            ),
            .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        )

        // Blocked successor identity must never contribute evidence.
        let blockedBatch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132857"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132858"),
            createdAt: date(1),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: fixture.bodyNoteID, title: "Blocked", modifiedAt: date(9)
                ))
            ]
        )
        let blockedIdentity = OperationIdentityPayload(
            batchID: blockedBatch.id,
            originDeviceID: blockedBatch.originDeviceID,
            operationIndex: 0,
            operationKind: "title",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: blockedBatch, change: blockedBatch.changes[0], operationIndex: 0)
            )
        )
        let blockedSelection = SyncConvergenceQueueSelection(
            candidateBatch: fixture.selection.candidateBatch,
            eligibleEvidenceBatches: [],
            eligibleDisjointBatches: [],
            blockedBatches: [SyncConvergenceQueuedBatch(batch: blockedBatch, queuePosition: 5)],
            blockedNoteIDs: fixture.selection.blockedNoteIDs.union([fixture.bodyNoteID])
        )
        let withBlockedIdentity = rebuiltPlan(
            fixture.plan,
            incorporationEvidence: SyncConvergenceIncorporationPlan(
                operationIdentities: fixture.plan.incorporationEvidence.operationIdentities + [blockedIdentity],
                resultEvidence: fixture.plan.incorporationEvidence.resultEvidence
            )
        )
        XCTAssertEqual(
            validator.validate(
                withBlockedIdentity,
                input: fixture.input,
                queueSelection: blockedSelection,
                projectedFullIncorporationEvidenceBytes: try projectedBytes(for: withBlockedIdentity, input: fixture.input)
            ),
            .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        )

        // Presentation routing must agree with the body effect.
        let routingMismatch = rebuiltPlan(
            fixture.plan,
            presentationPlan: SyncConvergencePresentationPlan(
                noteRoutings: [fixture.bodyNoteID: .wholeNoteFallback]
            )
        )
        XCTAssertEqual(
            validator.validate(
                routingMismatch,
                input: fixture.input,
                queueSelection: fixture.selection,
                projectedFullIncorporationEvidenceBytes: fixture.projectedBytes
            ),
            .failedBeforeCommit(.invalidMergePlan(noteID: fixture.bodyNoteID))
        )

        // Incorporation result-evidence rows must equal their owning effects.
        let alteredRows = fixture.plan.incorporationEvidence.resultEvidence.map { row -> SyncConvergenceResultEvidence in
            guard row.kind == .body else { return row }
            return SyncConvergenceResultEvidence(
                batchID: row.batchID,
                noteID: row.noteID,
                kind: row.kind,
                preHash: row.preHash,
                postHash: "deadbeef",
                canonicalReplayKey: row.canonicalReplayKey
            )
        }
        let alteredEvidence = rebuiltPlan(
            fixture.plan,
            incorporationEvidence: SyncConvergenceIncorporationPlan(
                operationIdentities: fixture.plan.incorporationEvidence.operationIdentities,
                resultEvidence: alteredRows
            )
        )
        XCTAssertEqual(
            validator.validate(
                alteredEvidence,
                input: fixture.input,
                queueSelection: fixture.selection,
                projectedFullIncorporationEvidenceBytes: try projectedBytes(for: alteredEvidence, input: fixture.input)
            ),
            .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        )

        // History additions must match the body effects exactly.
        let historyMismatch = rebuiltPlan(
            fixture.plan,
            historyPlan: SyncConvergenceHistoryPlan(
                retainedOperationAdditions: [],
                snapshotAdditions: fixture.plan.historyPlan.snapshotAdditions,
                pressureNotes: fixture.plan.historyPlan.pressureNotes
            )
        )
        XCTAssertEqual(
            validator.validate(
                historyMismatch,
                input: fixture.input,
                queueSelection: fixture.selection,
                projectedFullIncorporationEvidenceBytes: fixture.projectedBytes
            ),
            .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        )
    }

    func testCanonicalPayloadDigestV1GoldenVectorMatrix() throws {
        // Expected constants generated by an independent re-implementation of the
        // V1 contract, cross-validated against the previously frozen 173-byte fixture.
        struct GoldenFixture {
            let name: String
            let batch: SyncBatch
            let byteCount: Int
            let canonicalHex: String
            let digest: String
        }
        let fixtures: [GoldenFixture] = [
            GoldenFixture(
                name: "emptyBatch",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132801"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132802"),
                    createdAt: date(1),
                    changes: []
                ),
                byteCount: 57,
                canonicalHex: "4d5952310000000100000000000000000000000000132801000000000000000000000000001328023ff0000000000000000000000000000000",
                digest: "f5e1ccd768c594fd6eea109001cdc140c9b638820f6337592021b2fc282a9a1a"
            ),
            GoldenFixture(
                name: "titleOnly",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132803"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132804"),
                    createdAt: date(1),
                    changes: [
                        .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132701"), title: "Title", modifiedAt: date(2)
                        ))
                    ]
                ),
                byteCount: 106,
                canonicalHex: "4d5952310000000100000000000000000000000000132803000000000000000000000000001328043ff00000000000000000000000000000010000000000000000000000020000000000000000000000000013270100000000000000055469746c654000000000000000",
                digest: "cf4e57b708b96c7e12bf59074126981f65e73d01b9edd06df12c0d3e0b45e7a3"
            ),
            GoldenFixture(
                name: "creationWithoutFolder",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132805"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132806"),
                    createdAt: date(1),
                    changes: [
                        .noteCreated(SyncBatchNoteCreatedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132702"),
                            title: "New",
                            body: "Body",
                            folderID: nil,
                            createdAt: date(2),
                            modifiedAt: date(3)
                        ))
                    ]
                ),
                byteCount: 125,
                canonicalHex: "4d5952310000000100000000000000000000000000132805000000000000000000000000001328063ff00000000000000000000000000000010000000000000000000000010000000000000000000000000013270200000000000000034e65770000000000000004426f64790040000000000000004008000000000000",
                digest: "fe0b720b310ba0aa0c64b3e8af5680f89252d23917ae63aa304c7334973f1ff3"
            ),
            GoldenFixture(
                name: "creationWithFolder",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132807"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132808"),
                    createdAt: date(1),
                    changes: [
                        .noteCreated(SyncBatchNoteCreatedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132702"),
                            title: "New",
                            body: "Body",
                            folderID: uuid("00000000-0000-0000-0000-000000132703"),
                            createdAt: date(2),
                            modifiedAt: date(3)
                        ))
                    ]
                ),
                byteCount: 141,
                canonicalHex: "4d5952310000000100000000000000000000000000132807000000000000000000000000001328083ff00000000000000000000000000000010000000000000000000000010000000000000000000000000013270200000000000000034e65770000000000000004426f6479010000000000000000000000000013270340000000000000004008000000000000",
                digest: "131014e2e4d11f20d284c9a7d749288b6827e7f7ed662e721aada10c992691ae"
            ),
            GoldenFixture(
                name: "legacyInsertNilBase",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132809"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132810"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132704"),
                            utf16Offset: 2,
                            text: "x",
                            modifiedAt: date(2),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 111,
                canonicalHex: "4d5952310000000100000000000000000000000000132809000000000000000000000000001328103ff0000000000000000000000000000001000000000000000000000003000000000000000000000000001327040000000000000002000000000000000178004000000000000000",
                digest: "2d4463ee6e6957024fa0bff84baa45ed717c191660218a32a67bcdeef2033ec7"
            ),
            GoldenFixture(
                name: "insertWithBaseHash",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132811"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132812"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132704"),
                            utf16Offset: 2,
                            text: "x",
                            modifiedAt: date(2),
                            baseContentHash: SyncBatchContentHash.sha256Hex(for: "BASE")
                        ))
                    ]
                ),
                byteCount: 183,
                canonicalHex: "4d5952310000000100000000000000000000000000132811000000000000000000000000001328123ff0000000000000000000000000000001000000000000000000000003000000000000000000000000001327040000000000000002000000000000000178010000000000000040636266333661393634626138633038393466636339656334393162346431646439346432323161376463383833303865396336623839323434356138353734624000000000000000",
                digest: "e8b82a2f263f67d00c23aec9e791f4bd2f7d48ed3a4e99c5959f67e110dd8817"
            ),
            GoldenFixture(
                name: "deleteExpectedTextAbsent",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132813"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132814"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132705"),
                            utf16Offset: 1,
                            utf16Length: 2,
                            expectedText: nil,
                            modifiedAt: date(2),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 111,
                canonicalHex: "4d5952310000000100000000000000000000000000132813000000000000000000000000001328143ff0000000000000000000000000000001000000000000000000000004000000000000000000000000001327050000000000000001000000000000000200004000000000000000",
                digest: "ef1ba79e1210e16893492c6a476c9842d8133ed4b37e7aca2c6e40e1cfb2469b"
            ),
            GoldenFixture(
                name: "deleteExpectedTextPresent",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132815"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132816"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132705"),
                            utf16Offset: 1,
                            utf16Length: 2,
                            expectedText: "ab",
                            modifiedAt: date(2),
                            baseContentHash: SyncBatchContentHash.sha256Hex(for: "BASE")
                        ))
                    ]
                ),
                byteCount: 193,
                canonicalHex: "4d5952310000000100000000000000000000000000132815000000000000000000000000001328163ff000000000000000000000000000000100000000000000000000000400000000000000000000000000132705000000000000000100000000000000020100000000000000026162010000000000000040636266333661393634626138633038393466636339656334393162346431646439346432323161376463383833303865396336623839323434356138353734624000000000000000",
                digest: "b374e81988355b2a53f47d27ae4b81004406eced7faeba69d89df27daabe8a7d"
            ),
            GoldenFixture(
                name: "reconciliationPayload",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132817"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132818"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyReconciled(SyncBatchNoteBodyReconciledChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132706"),
                            replacementBody: "Merged",
                            replacementContentHash: SyncBatchContentHash.sha256Hex(for: "Merged"),
                            modifiedAt: date(2)
                        ))
                    ]
                ),
                byteCount: 179,
                canonicalHex: "4d5952310000000100000000000000000000000000132817000000000000000000000000001328183ff00000000000000000000000000000010000000000000000000000050000000000000000000000000013270600000000000000064d65726765640000000000000040626430613036323032633434306139656538366635303136356161363638383632353964383963336432313965326566343761373539636465366133386330304000000000000000",
                digest: "8320bb97cba52c1bf389597d9dd0855dc7c6d6c0633f1517477622d6a40b6a32"
            ),
            GoldenFixture(
                name: "sequencedBatch",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132819"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132820"),
                    createdAt: date(1),
                    batchSequence: 7,
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132707"),
                            utf16Offset: 0,
                            text: "s",
                            modifiedAt: date(2),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 119,
                canonicalHex: "4d5952310000000100000000000000000000000000132819000000000000000000000000001328203ff00000000000000100000000000000070000000000000001000000000000000000000003000000000000000000000000001327070000000000000000000000000000000173004000000000000000",
                digest: "ed609684172cb0550a6691298bb09baf035e2fd24eeb7e1ec97baf961b099f86"
            ),
            GoldenFixture(
                name: "legacyOrderedBatch",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132819"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132820"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132707"),
                            utf16Offset: 0,
                            text: "s",
                            modifiedAt: date(2),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 111,
                canonicalHex: "4d5952310000000100000000000000000000000000132819000000000000000000000000001328203ff0000000000000000000000000000001000000000000000000000003000000000000000000000000001327070000000000000000000000000000000173004000000000000000",
                digest: "788fc13606a867a1ca30c916259dedca3f18db54421477432dd9eedfa862d36e"
            ),
            GoldenFixture(
                name: "multiNoteGlobalIndexes",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132821"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132822"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132708"),
                            utf16Offset: 0,
                            text: "a",
                            modifiedAt: date(2),
                            baseContentHash: nil
                        )),
                        .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132709"),
                            title: "Other",
                            modifiedAt: date(3)
                        )),
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132708"),
                            utf16Offset: 1,
                            text: "b",
                            modifiedAt: date(4),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 214,
                canonicalHex: "4d5952310000000100000000000000000000000000132821000000000000000000000000001328223ff00000000000000000000000000000030000000000000000000000030000000000000000000000000013270800000000000000000000000000000001610040000000000000000000000000000001000000020000000000000000000000000013270900000000000000054f746865724008000000000000000000000000000200000003000000000000000000000000001327080000000000000001000000000000000162004010000000000000",
                digest: "50bb3d2f27774597bde7f805c30fa35e4cc6b1a116a2062c528ff6ac6be70a37"
            ),
            GoldenFixture(
                name: "optionalNilBase",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132823"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132824"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132710"),
                            utf16Offset: 0,
                            text: "q",
                            modifiedAt: date(2),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 111,
                canonicalHex: "4d5952310000000100000000000000000000000000132823000000000000000000000000001328243ff0000000000000000000000000000001000000000000000000000003000000000000000000000000001327100000000000000000000000000000000171004000000000000000",
                digest: "2e3c607580ef87f6e323c7c7c87fc09f0e8f1b9e38da312af96e8b1dfd6dc174"
            ),
            GoldenFixture(
                name: "optionalEmptyStringBase",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132823"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132824"),
                    createdAt: date(1),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132710"),
                            utf16Offset: 0,
                            text: "q",
                            modifiedAt: date(2),
                            baseContentHash: ""
                        ))
                    ]
                ),
                byteCount: 119,
                canonicalHex: "4d5952310000000100000000000000000000000000132823000000000000000000000000001328243ff00000000000000000000000000000010000000000000000000000030000000000000000000000000013271000000000000000000000000000000001710100000000000000004000000000000000",
                digest: "3d242d531872214b659f441805903d47fc112e337acb12a0932e1c672d2cbc5d"
            ),
            GoldenFixture(
                name: "dateBitPattern",
                batch: SyncBatch(
                    id: uuid("00000000-0000-0000-0000-000000132825"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000132826"),
                    createdAt: date(0.5),
                    changes: [
                        .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                            noteID: uuid("00000000-0000-0000-0000-000000132711"),
                            utf16Offset: 0,
                            text: "d",
                            modifiedAt: date(-1.5),
                            baseContentHash: nil
                        ))
                    ]
                ),
                byteCount: 111,
                canonicalHex: "4d5952310000000100000000000000000000000000132825000000000000000000000000001328263fe000000000000000000000000000000100000000000000000000000300000000000000000000000000132711000000000000000000000000000000016400bff8000000000000",
                digest: "3608b6940070be428d8c750e908534b9d19ed8ae3d8bca814574a10b51fcb095"
            ),
            GoldenFixture(
                name: "uuidByteOrder",
                batch: SyncBatch(
                    id: uuid("01234567-89AB-CDEF-0123-456789ABCDEF"),
                    originDeviceID: uuid("FEDCBA98-7654-3210-FEDC-BA9876543210"),
                    createdAt: date(1),
                    changes: [
                        .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                            noteID: uuid("0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"),
                            title: "U",
                            modifiedAt: date(2)
                        ))
                    ]
                ),
                byteCount: 102,
                canonicalHex: "4d595231000000010123456789abcdef0123456789abcdeffedcba9876543210fedcba98765432103ff00000000000000000000000000000010000000000000000000000020f1e2d3c4b5a69788796a5b4c3d2e1f00000000000000001554000000000000000",
                digest: "6f2d670b825ad129c6dbb6cf1aaa3551775599e2900b476c80142b4e6104fa1d"
            )
        ]

        for fixture in fixtures {
            let bytes = try SyncConvergenceCanonicalBatchDigest.canonicalBytes(for: fixture.batch)
            XCTAssertEqual(bytes.count, fixture.byteCount, fixture.name)
            XCTAssertEqual(bytes.hexString, fixture.canonicalHex, fixture.name)
            XCTAssertEqual(
                try SyncConvergenceCanonicalBatchDigest.digest(for: fixture.batch),
                fixture.digest,
                fixture.name
            )
        }

        let byName = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.digest) })
        XCTAssertNotEqual(byName["optionalNilBase"], byName["optionalEmptyStringBase"])
        XCTAssertNotEqual(byName["sequencedBatch"], byName["legacyOrderedBatch"])
    }

    private struct ValidatorFixture {
        let plan: SyncConvergenceBatchPlan
        let input: SyncConvergencePlanningInput
        let selection: SyncConvergenceQueueSelection
        let projectedBytes: Int
        let bodyNoteID: UUID
    }

    private func validatorFixture() throws -> ValidatorFixture {
        let bodyNoteID = uuid("00000000-0000-0000-0000-000000132739")
        let titleNoteID = uuid("00000000-0000-0000-0000-000000132740")
        let body = "AB"
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132859"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132860"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: bodyNoteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: body)
                )),
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: titleNoteID,
                    title: "Renamed",
                    modifiedAt: date(3)
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [
                projectedNote(noteID: bodyNoteID, body: body),
                projectedNote(noteID: titleNoteID, body: "Other")
            ]
        )
        guard case .planned(let validatedInput) = SyncConvergencePlanner().plan(input: input) else {
            throw XCTSkip("validator fixture planning failed")
        }
        let plan = validatedInput.plan
        let selection = SyncConvergenceEvidenceSelector().selectQueuedBatches(
            for: incoming,
            queuedBatches: [],
            candidateQueuePosition: nil
        )
        return ValidatorFixture(
            plan: plan,
            input: input,
            selection: selection,
            projectedBytes: try projectedBytes(for: plan, input: input),
            bodyNoteID: bodyNoteID
        )
    }

    private func projectedBytes(for plan: SyncConvergenceBatchPlan, input: SyncConvergencePlanningInput) throws -> Int {
        try SyncConvergenceProjectedIncorporationEvidence(
            batch: input.incomingBatch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
    }

    private func rebuiltPlan(
        _ plan: SyncConvergenceBatchPlan,
        incorporationEvidence: SyncConvergenceIncorporationPlan? = nil,
        historyPlan: SyncConvergenceHistoryPlan? = nil,
        presentationPlan: SyncConvergencePresentationPlan? = nil
    ) -> SyncConvergenceBatchPlan {
        SyncConvergenceBatchPlan(
            batchID: plan.batchID,
            originDeviceID: plan.originDeviceID,
            canonicalPayloadDigest: plan.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: plan.canonicalPayloadDigestFormatVersion,
            affectedNotePlans: plan.affectedNotePlans,
            incorporationEvidence: incorporationEvidence ?? plan.incorporationEvidence,
            historyPlan: historyPlan ?? plan.historyPlan,
            cleanupPlan: plan.cleanupPlan,
            presentationPlan: presentationPlan ?? plan.presentationPlan
        )
    }

    func testReconstructionStressWithHundredsOfNilBaseCandidatesCompletesBounded() {
        let noteID = uuid("00000000-0000-0000-0000-000000132744")
        let snapshotBody = "A"
        // A five-step verified chain to the target, buried among 200 replay-valid
        // nil-base decoy branches that each verify only from the snapshot body.
        var chainBodies = [snapshotBody]
        for step in 1...5 {
            chainBodies.append(chainBodies[step - 1] + String(step))
        }
        let targetBody = chainBodies[5]
        let targetHash = SyncBatchContentHash.sha256Hex(for: targetBody)
        var retained: [SyncConvergenceRetainedOperation] = []
        for step in 1...5 {
            retained.append(retainedInsert(
                noteID: noteID,
                batchID: uuid(String(format: "00000000-0000-0000-0000-9000000%05d", step)),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132871"),
                operationIndex: 0,
                offset: chainBodies[step - 1].utf16.count,
                text: String(step),
                modifiedAt: date(TimeInterval(step + 10)),
                baseBody: chainBodies[step - 1],
                resultBody: chainBodies[step]
            ))
        }
        for decoy in 1...200 {
            retained.append(retainedInsert(
                noteID: noteID,
                batchID: uuid(String(format: "00000000-0000-0000-0000-8000000%05d", decoy)),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132872"),
                operationIndex: 0,
                offset: 0,
                text: "d\(decoy)-",
                modifiedAt: date(TimeInterval(decoy)),
                baseBody: snapshotBody,
                resultBody: "d\(decoy)-" + snapshotBody
            ).withoutBaseHash())
        }
        let incoming = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132873"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132874"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "X", modifiedAt: date(400), baseContentHash: targetHash
                ))
            ]
        )

        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [projectedNote(noteID: noteID, body: "X" + targetBody)],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                    body: snapshotBody,
                    generation: 1
                )
            ],
            retainedRemoteOperations: retained
        ))

        guard case .planned(let validatedInput) = outcome,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected bounded stress reconstruction to plan, got \(outcome)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseHash, targetHash)
    }

    func testCycleAndDuplicateResultOperationsDoNotReExploreBodies() {
        let noteID = uuid("00000000-0000-0000-0000-000000132745")
        let snapshotBody = "A"
        let insertResult = "AB"
        // Cycle: insert B then delete B returns to the snapshot body; a duplicate
        // second insert declares the identical result under a different identity.
        let insertOp = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132875"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132876"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(2),
            baseBody: snapshotBody,
            resultBody: insertResult
        ).withoutBaseHash()
        let duplicateInsert = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132877"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132878"),
            operationIndex: 0,
            offset: 1,
            text: "B",
            modifiedAt: date(3),
            baseBody: snapshotBody,
            resultBody: insertResult
        ).withoutBaseHash()
        let cycleDelete = retainedDelete(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132879"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132880"),
            operationIndex: 0,
            offset: 1,
            length: 1,
            expectedText: "B",
            modifiedAt: date(4),
            baseBody: insertResult,
            resultHash: SyncBatchContentHash.sha256Hex(for: snapshotBody)
        ).withoutBaseHash()
        let onwardTarget = "ABC"
        let onwardTargetHash = SyncBatchContentHash.sha256Hex(for: onwardTarget)
        let onward = retainedInsert(
            noteID: noteID,
            batchID: uuid("00000000-0000-0000-0000-000000132881"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132882"),
            operationIndex: 0,
            offset: 2,
            text: "C",
            modifiedAt: date(5),
            baseBody: insertResult,
            resultBody: onwardTarget
        )
        let snapshots = [
            SyncConvergenceRetainedSnapshot(
                noteID: noteID,
                contentHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
                body: snapshotBody,
                generation: 1
            )
        ]
        let operations = [insertOp, duplicateInsert, cycleDelete, onward]

        let reachable = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: SyncBatch(
                id: uuid("00000000-0000-0000-0000-000000132883"),
                originDeviceID: uuid("00000000-0000-0000-0000-000000132884"),
                createdAt: date(1),
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID, utf16Offset: 0, text: "X", modifiedAt: date(9), baseContentHash: onwardTargetHash
                    ))
                ]
            ),
            currentNotes: [projectedNote(noteID: noteID, body: "X" + onwardTarget)],
            retainedSnapshots: snapshots,
            retainedRemoteOperations: operations
        ))
        guard case .planned(let validatedInput) = reachable,
              let plan = Optional(validatedInput.plan),
              case .reconstructedConflict(let bodyPlan) = plan.affectedNotePlans[0].bodyEffect else {
            return XCTFail("Expected cycle-tolerant reconstruction to plan, got \(reachable)")
        }
        XCTAssertEqual(bodyPlan.reconstructedBaseHash, onwardTargetHash)

        // An unreachable target must terminate and defer, not loop through the cycle.
        let unreachableHash = SyncBatchContentHash.sha256Hex(for: "ZZ")
        let unreachableBatch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132885"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132886"),
            createdAt: date(1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID, utf16Offset: 0, text: "X", modifiedAt: date(9), baseContentHash: unreachableHash
                ))
            ]
        )
        let unreachable = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: unreachableBatch,
            currentNotes: [projectedNote(noteID: noteID, body: "diverged")],
            retainedSnapshots: snapshots,
            retainedRemoteOperations: operations
        ))
        XCTAssertEqual(unreachable, .deferred(.unreconstructableBase(
            noteID: noteID,
            batchID: unreachableBatch.id,
            baseContentHash: unreachableHash
        )))
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

private func projectedNoteEffectBytes(kinds: [String]) throws -> Data {
    var encoder = CanonicalPayloadDigestFormatV1()
    try encoder.appendProjectedNoteEffect(
        batchID: uuid("00000000-0000-0000-0000-000000132c10"),
        noteID: uuid("00000000-0000-0000-0000-000000132c11"),
        kinds: kinds
    )
    return encoder.data
}

private let committedResultBatchID = uuid("00000000-0000-0000-0000-000000132d01")
private let committedResultOriginID = uuid("00000000-0000-0000-0000-000000132d02")
private let committedResultNoteID = uuid("00000000-0000-0000-0000-000000132d11")
private let committedResultSecondNoteID = uuid("00000000-0000-0000-0000-000000132d12")
private let committedResultFolderID = uuid("00000000-0000-0000-0000-000000132d20")

private struct CommittedResultGoldenFixture {
    let name: String
    let results: [CanonicalCommittedResultV1]
    let byteCount: Int
    let hex: String
    let digest: String
}

private func committedResultGoldenFixtures() -> [CommittedResultGoldenFixture] {
    let preHash = String(repeating: "a", count: 64)
    let bodyHash = String(repeating: "b", count: 64)
    let creationHash = String(repeating: "c", count: 64)
    let reconciliationFinalBodyHash = String(repeating: "d", count: 64)
    let reconciliationReplacementContentHash = String(repeating: "f", count: 64)
    let changedHash = String(repeating: "e", count: 64)
    let insert = committedResultIdentity(kind: "insert", operationIndex: 0, modifiedAt: date(2))
    let title = committedResultIdentity(kind: "title", operationIndex: 1, modifiedAt: date(3))
    let creation = committedResultIdentity(kind: "creation", operationIndex: 2, modifiedAt: date(4))
    let reconciliation = committedResultIdentity(kind: "reconciliation", operationIndex: 3, modifiedAt: date(5))

    return [
        CommittedResultGoldenFixture(
            name: "body",
            results: [.body(noteID: committedResultNoteID, preHash: preHash, finalBodyHash: bodyHash, identities: [insert])],
            byteCount: 305,
            hex: "0000000100000000000000000000000000132d0100000000000000010000000100000000000000000000000000132d110100000000000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000000406262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626200000000000000010000000200000000000000000000000000132d0100000000000000000000000000132d020000000000000000400000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000000",
            digest: "23d4a3f4416d0ee2e62264f1508cc49797ad354269e4b48b39a5f77479858594"
        ),
        CommittedResultGoldenFixture(
            name: "title",
            results: [.title(noteID: committedResultNoteID, identity: title, key: title.canonicalReplayKey, finalTitle: "Winner")],
            byteCount: 226,
            hex: "0000000100000000000000000000000000132d0100000000000000010000000200000000000000000000000000132d110000000100000000000000000000000000132d0100000000000000000000000000132d020000000000000001400800000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000001400800000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000001000000000000000657696e6e6572",
            digest: "69c7bb23b0222259172dd01238649e2c76295861db2cbabccfbe30488854bb93"
        ),
        CommittedResultGoldenFixture(
            name: "creation",
            results: [.creation(noteID: committedResultNoteID, folderID: committedResultFolderID, finalBodyHash: creationHash, titleIdentity: creation, titleKey: creation.canonicalReplayKey, creationIdentity: creation)],
            byteCount: 405,
            hex: "0000000100000000000000000000000000132d0100000000000000010000000300000000000000000000000000132d110100000000000000000000000000132d200000000000000040636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363630000000500000000000000000000000000132d0100000000000000000000000000132d020000000000000002401000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000002401000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d0100000000000000020000000500000000000000000000000000132d0100000000000000000000000000132d020000000000000002401000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000002",
            digest: "c5a5d0b0076be37c47d1ce7a7bb257736077dc874cdf32c49dce2790c1e22182"
        ),
        CommittedResultGoldenFixture(
            name: "reconciliation",
            results: [.reconciliation(
                noteID: committedResultNoteID,
                identity: reconciliation,
                finalBodyHash: reconciliationFinalBodyHash,
                replacementContentHash: reconciliationReplacementContentHash
            )],
            byteCount: 296,
            hex: "0000000100000000000000000000000000132d0100000000000000010000000400000000000000000000000000132d110000000400000000000000000000000000132d0100000000000000000000000000132d020000000000000003401400000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000003000000000000004064646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464000000000000004066666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666",
            digest: "07760645e816f34f04060e19da9738d18a2e1b5e2020e7c6ce76569b4d803df8"
        ),
        CommittedResultGoldenFixture(
            name: "mixed",
            results: [
                .title(noteID: committedResultSecondNoteID, identity: title, key: title.canonicalReplayKey, finalTitle: "Winner"),
                .body(noteID: committedResultNoteID, preHash: preHash, finalBodyHash: bodyHash, identities: [insert]),
                .reconciliation(
                    noteID: committedResultNoteID,
                    identity: reconciliation,
                    finalBodyHash: reconciliationFinalBodyHash,
                    replacementContentHash: reconciliationReplacementContentHash
                )
            ],
            byteCount: 771,
            hex: "0000000100000000000000000000000000132d0100000000000000030000000100000000000000000000000000132d110100000000000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000000406262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626200000000000000010000000200000000000000000000000000132d0100000000000000000000000000132d020000000000000000400000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d0100000000000000000000000400000000000000000000000000132d110000000400000000000000000000000000132d0100000000000000000000000000132d020000000000000003401400000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d0100000000000000030000000000000040646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464646464640000000000000040666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666660000000200000000000000000000000000132d120000000100000000000000000000000000132d0100000000000000000000000000132d020000000000000001400800000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000001400800000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000001000000000000000657696e6e6572",
            digest: "bce38a27fcc2447bcd2425ee45912480a3163f14e9aa9f514341bbcd343a87f2"
        ),
        CommittedResultGoldenFixture(
            name: "multiple",
            results: [
                .body(noteID: committedResultSecondNoteID, preHash: preHash, finalBodyHash: changedHash, identities: [insert]),
                .body(noteID: committedResultNoteID, preHash: preHash, finalBodyHash: bodyHash, identities: [insert])
            ],
            byteCount: 582,
            hex: "0000000100000000000000000000000000132d0100000000000000020000000100000000000000000000000000132d110100000000000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000000406262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626262626200000000000000010000000200000000000000000000000000132d0100000000000000000000000000132d020000000000000000400000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d0100000000000000000000000100000000000000000000000000132d120100000000000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000000406565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656500000000000000010000000200000000000000000000000000132d0100000000000000000000000000132d020000000000000000400000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000000",
            digest: "b57d31db3351c0941da4d8adcd15264647110e9ebcf0cc065ea2d9af31f9e66b"
        ),
        CommittedResultGoldenFixture(
            name: "changed",
            results: [.body(noteID: committedResultNoteID, preHash: preHash, finalBodyHash: changedHash, identities: [insert])],
            byteCount: 305,
            hex: "0000000100000000000000000000000000132d0100000000000000010000000100000000000000000000000000132d110100000000000000406161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000000406565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656565656500000000000000010000000200000000000000000000000000132d0100000000000000000000000000132d020000000000000000400000000000000000000000000000000000000000132d02000000013ff000000000000000000000000000000000000000132d010000000000000000",
            digest: "867ddda64066c2161ed565ad1e9f3cb7caba334a5f660a993beaa0fc564bea51"
        )
    ]
}

private func committedResultIdentity(kind: String, operationIndex: Int, modifiedAt: Date) -> OperationIdentityPayload {
    let change: SyncBatchChange
    switch kind {
    case "title":
        change = .noteTitleChanged(SyncBatchNoteTitleChangedChange(
            noteID: committedResultNoteID,
            title: "Winner",
            modifiedAt: modifiedAt
        ))
    case "creation":
        change = .noteCreated(SyncBatchNoteCreatedChange(
            noteID: committedResultNoteID,
            title: "Created",
            body: "Body",
            folderID: committedResultFolderID,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt
        ))
    case "reconciliation":
        change = .noteBodyReconciled(SyncBatchNoteBodyReconciledChange(
            noteID: committedResultNoteID,
            replacementBody: "Resolved",
            replacementContentHash: String(repeating: "d", count: 64),
            modifiedAt: modifiedAt
        ))
    default:
        change = .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: committedResultNoteID,
            utf16Offset: 0,
            text: "B",
            modifiedAt: modifiedAt,
            baseContentHash: String(repeating: "a", count: 64)
        ))
    }
    let batch = SyncBatch(
        id: committedResultBatchID,
        originDeviceID: committedResultOriginID,
        createdAt: date(1),
        changes: [change]
    )
    let replayKey = CanonicalReplayKeyPayload(
        replayKey: SyncBatchReplayKey(batch: batch, change: change, operationIndex: operationIndex)
    )
    return OperationIdentityPayload(
        batchID: committedResultBatchID,
        originDeviceID: committedResultOriginID,
        operationIndex: operationIndex,
        operationKind: kind,
        canonicalReplayKey: replayKey
    )
}

private func permutations(_ values: [String]) -> [[String]] {
    guard let first = values.first else { return [[]] }
    return permutations(Array(values.dropFirst())).flatMap { permutation in
        (0...permutation.count).map { index in
            var next = permutation
            next.insert(first, at: index)
            return next
        }
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    func withoutResultHash() -> SyncConvergenceRetainedOperation {
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
            baseContentHash: baseContentHash,
            resultContentHash: nil,
            canonicalReplayKey: canonicalReplayKey
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
