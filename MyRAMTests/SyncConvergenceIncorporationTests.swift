import XCTest
import SwiftData
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergenceIncorporationTests: XCTestCase {
    func testStaleAuthoritativeStateMapsToDedicatedDrainFailure() {
        let batchID = uuid("00000000-0000-0000-0000-000000132c01")
        let failure = SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: nil)

        XCTAssertEqual(SyncConvergenceDrainFailureMapping.failureKind(for: failure), .staleAuthoritativeState)
        XCTAssertEqual(
            SyncBatchDrainFailureClassifier.userMessage(
                for: SyncBatchDrainFailure(batchID: batchID, kind: .staleAuthoritativeState)
            ),
            "The note changed before the sync update could be committed. Sync will re-evaluate the latest version."
        )
        XCTAssertEqual(SyncConvergenceDrainFailureMapping.failureKind(for: .invalidMergePlan(noteID: nil)), .invalidMergePlan)
        XCTAssertEqual(
            SyncConvergenceDrainFailureMapping.failureKind(for: .inconsistentIncorporationState(noteID: nil)),
            .inconsistentIncorporationState
        )
        XCTAssertEqual(SyncConvergenceDrainFailureMapping.failureKind(for: .corruptHistory(noteID: nil)), .corruptHistory)
    }

    func testValidatedInputPreservesCompleteSourceBatch() throws {
        let fixture = try makeFixture(batchSequence: 42)

        let input = fixture.validatedInput

        XCTAssertEqual(input.sourceBatchID, fixture.batch.id)
        XCTAssertEqual(input.sourceOriginDeviceID, fixture.batch.originDeviceID)
        XCTAssertEqual(input.sourceCreatedAt, fixture.batch.createdAt)
        XCTAssertEqual(input.sourceBatchSequence, 42)
        XCTAssertEqual(input.sourceSchemaVersion, 1)
        XCTAssertEqual(input.projectedFullIncorporationEvidenceBytes, fixture.projectedBytes)
        XCTAssertEqual(input.sourceBatch, fixture.batch)
        XCTAssertEqual(input.sourceBatch.changes, fixture.batch.changes)
    }

    func testExecutorPersistsPlannedEffectsRootChildrenAndPendingWork() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .incorporated(let result) = outcome else {
            return XCTFail("Expected incorporated, got \(outcome)")
        }

        XCTAssertEqual(transaction.notes[fixture.noteID]?.body, "AB")
        XCTAssertEqual(transaction.notes[fixture.noteID]?.title, fixture.initialNote.title)
        XCTAssertEqual(result.batchID, fixture.batch.id)
        XCTAssertEqual(result.affectedNoteIDs, [fixture.noteID])
        XCTAssertEqual(result.cleanupPlan.batchIDs, [fixture.batch.id])
        XCTAssertFalse(result.presentationPlan.noteRoutings.isEmpty)
        XCTAssertEqual(transaction.roots[fixture.batch.id]?.batchSequence, fixture.batch.batchSequence)
        XCTAssertEqual(transaction.children[fixture.batch.id]?.operationIdentities.count, 1)
        XCTAssertEqual(transaction.children[fixture.batch.id]?.noteEffects.count, 1)
        XCTAssertEqual(
            transaction.children[fixture.batch.id]?.noteEffects.first?.postBodyHash,
            SyncBatchContentHash.sha256Hex(for: "AB")
        )
        XCTAssertEqual(transaction.children[fixture.batch.id]?.resultEvidence.count, 1)
        XCTAssertEqual(transaction.retainedOperations.count, 1)
        XCTAssertFalse(transaction.saveCalled == false)

        let affectedPayload = String(data: transaction.roots[fixture.batch.id]!.affectedNotesPayloadData, encoding: .utf8)
        XCTAssertEqual(affectedPayload, #"{"n":["\#(fixture.noteID.uuidString.lowercased())"],"v":1}"#)
        let postCommit = try SyncConvergenceStableEncoding.decode(
            SyncConvergencePostCommitState.self,
            from: transaction.roots[fixture.batch.id]!.postCommitStatePayloadData
        )
        XCTAssertTrue(postCommit.queueCleanupPending)
        XCTAssertTrue(postCommit.presentationRefreshPending)
    }

    func testExecutorRejectsStaleBodyBeforeMutation() throws {
        let fixture = try makeFixture()
        let staleNote = SyncConvergenceMutableNoteRecord(
            noteID: fixture.noteID,
            folderID: nil,
            title: "Title",
            body: "changed",
            createdAt: fixture.initialNote.createdAt,
            modifiedAt: fixture.initialNote.modifiedAt
        )
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.noteID: staleNote])

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.staleAuthoritativeState(noteID: fixture.noteID)))
        XCTAssertEqual(transaction.notes[fixture.noteID]?.body, "changed")
        XCTAssertFalse(transaction.rollbackCalled)
        XCTAssertFalse(transaction.saveCalled)
    }

    func testExecutorRollsBackAfterStagedFailure() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.failAfterUpdateNote = true

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedAndRolledBack(.swiftDataSave))
        XCTAssertEqual(transaction.notes[fixture.noteID], fixture.initialNote)
        XCTAssertTrue(transaction.rollbackCalled)
        XCTAssertFalse(transaction.saveCalled)
        XCTAssertNil(transaction.roots[fixture.batch.id])
    }

    func testSwiftDataTransactionPersistsIncorporationEvidence() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let note = Note(title: fixture.initialNote.title, content: fixture.initialNote.body)
        note.id = fixture.initialNote.noteID
        note.createdAt = fixture.initialNote.createdAt
        note.modifiedAt = fixture.initialNote.modifiedAt
        context.insert(note)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
            committedAt: fixture.committedAt
        )

        guard case .incorporated = outcome else {
            return XCTFail("Expected SwiftData incorporation, got \(outcome)")
        }
        let persistedNote = try context.fetch(FetchDescriptor<Note>()).first
        XCTAssertEqual(persistedNote?.content, "AB")
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedSyncBatch>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>()).count, 1)
    }

    func testAlreadyIncorporatedUsesValidatedPlansGatedByPersistedPendingFlags() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation")
        }

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .alreadyIncorporated(let pendingResult) = duplicate else {
            return XCTFail("Expected already incorporated, got \(duplicate)")
        }
        XCTAssertEqual(pendingResult.cleanupPlan.batchIDs, [fixture.batch.id])
        XCTAssertEqual(pendingResult.presentationPlan, fixture.plan.presentationPlan)

        transaction.updatePostCommitState(
            batchID: fixture.batch.id,
            payloadData: try SyncConvergenceStableEncoding.encode(
            SyncConvergencePostCommitState.none
            )
        )
        let completedDuplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .alreadyIncorporated(let completedResult) = completedDuplicate else {
            return XCTFail("Expected completed already incorporated, got \(completedDuplicate)")
        }
        XCTAssertTrue(completedResult.cleanupPlan.batchIDs.isEmpty)
        XCTAssertTrue(completedResult.presentationPlan.noteRoutings.isEmpty)
    }

    func testDuplicateRootAcceptsRetryWithDifferentCommittedAtWithoutMutation() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let originalCommittedAt = fixture.committedAt
        let retryCommittedAt = date(99)
        XCTAssertNotEqual(originalCommittedAt, retryCommittedAt)

        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: originalCommittedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation, got \(first)")
        }
        let preRetryState = transaction.snapshotState()
        let preRetryCounts = transaction.mutationCounts

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: retryCommittedAt
        )

        guard case .alreadyIncorporated = duplicate else {
            return XCTFail("Expected retry to be idempotent, got \(duplicate)")
        }
        XCTAssertEqual(transaction.snapshotState(), preRetryState)
        XCTAssertEqual(transaction.mutationCounts, preRetryCounts)
        XCTAssertEqual(transaction.rollbackCount, 0)
    }

    func testDuplicateValidationAcceptsReorderedNoteEffectKindsWithoutMutation() throws {
        let fixture = try makeTitleAndBodyFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.titleWinners[fixture.noteID] = try XCTUnwrap(fixture.priorWinner)
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation, got \(first)")
        }
        transaction.children[fixture.batch.id] = transaction.children[fixture.batch.id]?.withResultEvidenceReversed()
        let preRetryCounts = transaction.mutationCounts

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .alreadyIncorporated = duplicate else {
            return XCTFail("Expected reordered duplicate to pass, got \(duplicate)")
        }
        XCTAssertEqual(transaction.mutationCounts, preRetryCounts)
    }

    func testDuplicateValidationRejectsInvalidPersistedNoteEffectMembershipsBeforeMutation() throws {
        let fixture = try makeTitleAndBodyFixture()
        let baseTransaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        baseTransaction.titleWinners[fixture.noteID] = try XCTUnwrap(fixture.priorWinner)
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: baseTransaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first,
              let validChildren = baseTransaction.children[fixture.batch.id] else {
            return XCTFail("Expected committed fixture")
        }

        let extraCreation = SyncConvergenceResultEvidenceRecord(evidence: SyncConvergenceResultEvidence(
            batchID: fixture.batch.id,
            noteID: fixture.noteID,
            kind: .creation,
            preHash: nil,
            postHash: nil,
            canonicalReplayKey: nil
        ))
        let cases: [(String, [SyncConvergenceResultEvidenceRecord])] = [
            ("missing expected kind", Array(validChildren.resultEvidence.dropFirst())),
            ("extra kind", validChildren.resultEvidence + [extraCreation]),
            ("duplicate kind", validChildren.resultEvidence + [validChildren.resultEvidence[0]])
        ]

        for testCase in cases {
            let transaction = InMemoryConvergenceTransaction(notes: baseTransaction.notes)
            transaction.titleWinners = baseTransaction.titleWinners
            transaction.roots = baseTransaction.roots
            transaction.children[fixture.batch.id] = validChildren.withResultEvidence(testCase.1)

            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: fixture.validatedInput,
                transaction: transaction,
                committedAt: fixture.committedAt
            )

            XCTAssertEqual(
                outcome,
                .failedBeforeCommit(.inconsistentIncorporationState(noteID: nil)),
                testCase.0
            )
            assertNoPreflightMutation(transaction, testCase.0)
        }
    }

    func testTombstoneOnlyDuplicateUsesDedicatedProjection() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.tombstones[fixture.batch.id] = try tombstoneProjection(matching: fixture)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .alreadyIncorporated(let result) = outcome else {
            return XCTFail("Expected tombstone duplicate, got \(outcome)")
        }
        XCTAssertEqual(result.batchID, fixture.batch.id)
        XCTAssertEqual(transaction.notes[fixture.noteID], fixture.initialNote)
        XCTAssertFalse(transaction.saveCalled)
    }

    func testMatchingRootAndTombstoneDuplicateComparesCommittedOrdering() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation, got \(first)")
        }
        transaction.tombstones[fixture.batch.id] = try tombstoneProjection(matching: fixture)

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .alreadyIncorporated = duplicate else {
            return XCTFail("Expected matching dual duplicate, got \(duplicate)")
        }
    }

    func testContradictoryRootAndTombstoneOrderingFailsDuplicatePreflight() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation, got \(first)")
        }
        transaction.tombstones[fixture.batch.id] = try tombstoneProjection(
            matching: fixture,
            committedAtOrderingPayloadData: CommittedAtOrderingPayload(
                batchID: fixture.batch.id,
                committedAt: date(99)
            ).encodedEvidenceData()
        )

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(duplicate, .failedBeforeCommit(.inconsistentIncorporationState(noteID: nil)))
    }

    func testInvalidTombstoneEvidenceFailsClosed() throws {
        let fixture = try makeFixture()
        let unsupported = try tombstoneProjection(matching: fixture, tombstoneFormatVersion: 2)
        let malformed = try tombstoneProjection(matching: fixture, committedAtOrderingPayloadData: Data([0xde, 0xad]))

        for tombstone in [unsupported, malformed] {
            let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
            transaction.tombstones[fixture.batch.id] = tombstone

            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: fixture.validatedInput,
                transaction: transaction,
                committedAt: fixture.committedAt
            )

            XCTAssertEqual(outcome, .failedBeforeCommit(.corruptHistory(noteID: nil)))
        }
    }

    func testRetainedOperationSourceControlsIdempotency() throws {
        let fixture = try makeFixture()
        let retained = try XCTUnwrap(fixture.plan.historyPlan.retainedOperationAdditions.first).testRetainedOperationRecord
        let identity = SyncConvergenceRetainedOperationIdentity(
            batchID: retained.batchID,
            operationIndex: retained.operationIndex
        )

        let remoteTransaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        remoteTransaction.retainedOperations[identity] = SyncConvergenceRetainedOperationProjection(
            operation: retained,
            source: .remote
        )
        let remoteOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: remoteTransaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = remoteOutcome else {
            return XCTFail("Expected remote retained idempotency, got \(remoteOutcome)")
        }
        XCTAssertEqual(remoteTransaction.retainedOperationInsertCount, 0)

        let localTransaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        localTransaction.retainedOperations[identity] = SyncConvergenceRetainedOperationProjection(
            operation: retained,
            source: .local
        )
        let localOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: localTransaction,
            committedAt: fixture.committedAt
        )
        XCTAssertEqual(localOutcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
    }

    func testRetainedHistoryCallCountsFilterExistingRowsAndFailBeforeMutation() throws {
        let fixture = try makeTwoOperationFixture()
        let retained = fixture.plan.historyPlan.retainedOperationAdditions.map(\.testRetainedOperationRecord)
        XCTAssertEqual(retained.count, 2)
        let firstIdentity = SyncConvergenceRetainedOperationIdentity(
            batchID: retained[0].batchID,
            operationIndex: retained[0].operationIndex
        )

        let mixedTransaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        mixedTransaction.retainedOperations[firstIdentity] = SyncConvergenceRetainedOperationProjection(
            operation: retained[0],
            source: .remote
        )
        let mixedOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: mixedTransaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = mixedOutcome else {
            return XCTFail("Expected mixed history incorporation, got \(mixedOutcome)")
        }
        XCTAssertEqual(mixedTransaction.retainedOperationInsertCount, 1)

        var contradictory = retained[0]
        contradictory = SyncConvergenceRetainedOperationRecord(
            noteID: contradictory.noteID,
            batchID: contradictory.batchID,
            originDeviceID: contradictory.originDeviceID,
            operationIndex: contradictory.operationIndex,
            operationKind: contradictory.operationKind,
            utf16Offset: contradictory.utf16Offset,
            utf16Length: contradictory.utf16Length,
            text: "contradiction",
            expectedText: contradictory.expectedText,
            baseContentHash: contradictory.baseContentHash,
            resultContentHash: contradictory.resultContentHash,
            canonicalReplayKey: contradictory.canonicalReplayKey,
            modifiedAt: contradictory.modifiedAt
        )
        let contradictoryTransaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        contradictoryTransaction.retainedOperations[firstIdentity] = SyncConvergenceRetainedOperationProjection(
            operation: contradictory,
            source: .remote
        )
        let contradictoryOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: contradictoryTransaction,
            committedAt: fixture.committedAt
        )
        XCTAssertEqual(contradictoryOutcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
        assertNoPreflightMutation(contradictoryTransaction, "contradictory retained operation")
    }

    func testSwiftDataRetainedOperationSourceIsRemote() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let note = Note(title: fixture.initialNote.title, content: fixture.initialNote.body)
        note.id = fixture.initialNote.noteID
        note.createdAt = fixture.initialNote.createdAt
        note.modifiedAt = fixture.initialNote.modifiedAt
        context.insert(note)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
            committedAt: fixture.committedAt
        )

        guard case .incorporated = outcome else {
            return XCTFail("Expected SwiftData incorporation, got \(outcome)")
        }
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<RetainedBodyOperation>()).first)
        XCTAssertEqual(retained.sourceRaw, "remote")
        let projection = try XCTUnwrap(
            try SwiftDataSyncConvergencePersistenceTransaction(context: context).loadRetainedOperation(
                identity: SyncConvergenceRetainedOperationIdentity(
                    batchID: retained.batchID,
                    operationIndex: retained.operationIndex
                )
            )
        )
        XCTAssertEqual(projection.source, .remote)
    }

    func testSwiftDataTombstoneProjectionRoundTripPreservesAuthoritativeFields() throws {
        let fixture = try makeFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let orderingPayload = try CommittedAtOrderingPayload(
            batchID: fixture.batch.id,
            committedAt: fixture.committedAt
        ).encodedEvidenceData()
        let committedResultDigest = try CanonicalCommittedResultDigestPayloadV1.digest(
            plan: fixture.plan,
            sourceBatch: fixture.batch
        )
        context.insert(try IncorporatedBatchTombstone.makeValidated(
            batchID: fixture.batch.id,
            originDeviceID: fixture.batch.originDeviceID,
            canonicalPayloadDigest: fixture.plan.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: fixture.plan.canonicalPayloadDigestFormatVersion,
            schemaVersion: fixture.validatedInput.sourceSchemaVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: CanonicalCommittedResultDigestPayloadV1.formatVersion,
            committedAtOrderingPayloadData: orderingPayload,
            tombstoneFormatVersion: IncorporatedBatchTombstone.supportedTombstoneFormatVersion
        ))

        let projection = try XCTUnwrap(
            try SwiftDataSyncConvergencePersistenceTransaction(context: context).loadTombstone(batchID: fixture.batch.id)
        )

        XCTAssertEqual(projection.batchID, fixture.batch.id)
        XCTAssertEqual(projection.originDeviceID, fixture.batch.originDeviceID)
        XCTAssertEqual(projection.schemaVersion, fixture.validatedInput.sourceSchemaVersion)
        XCTAssertEqual(projection.canonicalPayloadDigest, fixture.plan.canonicalPayloadDigest)
        XCTAssertEqual(projection.canonicalPayloadDigestFormatVersion, fixture.plan.canonicalPayloadDigestFormatVersion)
        XCTAssertEqual(projection.committedResultDigest, committedResultDigest)
        XCTAssertEqual(projection.committedResultDigestFormatVersion, CanonicalCommittedResultDigestPayloadV1.formatVersion)
        XCTAssertEqual(projection.committedAtOrderingPayloadData, orderingPayload)
        XCTAssertEqual(projection.tombstoneFormatVersion, IncorporatedBatchTombstone.supportedTombstoneFormatVersion)
    }

    func testSwiftDataUnsupportedRetainedOperationSourceFailsAsCorruptHistory() throws {
        let fixture = try makeFixture()
        let retained = try XCTUnwrap(fixture.plan.historyPlan.retainedOperationAdditions.first).testRetainedOperationRecord
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(RetainedBodyOperation(
            noteID: retained.noteID,
            batchID: retained.batchID,
            originDeviceID: retained.originDeviceID,
            operationIndex: retained.operationIndex,
            operationKindRaw: retained.operationKind.rawValue,
            utf16Offset: retained.utf16Offset,
            utf16Length: retained.utf16Length,
            text: retained.text,
            expectedText: retained.expectedText,
            baseContentHash: retained.baseContentHash,
            resultContentHash: retained.resultContentHash,
            modifiedAt: retained.modifiedAt,
            canonicalReplayKeyPayloadData: try retained.canonicalReplayKey.encodedEvidenceData(),
            sourceRaw: "authoritative-convergence-incorporation"
        ))

        XCTAssertThrowsError(
            try SwiftDataSyncConvergencePersistenceTransaction(context: context).loadRetainedOperation(
                identity: SyncConvergenceRetainedOperationIdentity(
                    batchID: retained.batchID,
                    operationIndex: retained.operationIndex
                )
            )
        ) { error in
            XCTAssertEqual(error as? SyncConvergenceTransactionFailure, .corruptHistory(noteID: retained.noteID))
        }
    }

    func testTitleApplyPreflightRejectsContradictoryAuthoritativeStateBeforeMutation() throws {
        let fixture = try makeTitleApplyFixture()
        let correctWinner = try XCTUnwrap(fixture.plan.affectedNotePlans[0].titleEffect?.priorWinningKey)
        let resultingWinner = try XCTUnwrap(fixture.plan.affectedNotePlans[0].titleEffect?.resultingWinningKey)
        let cases: [(String, String, CanonicalReplayKeyPayload?, SyncConvergenceTransactionFailure)] = [
            ("resulting title with prior winner", "Incoming", correctWinner, .staleAuthoritativeState(noteID: fixture.noteID)),
            ("prior title with resulting winner", "Prior", resultingWinner, .staleAuthoritativeState(noteID: fixture.noteID)),
            ("wrong title with correct winner", "Wrong", correctWinner, .staleAuthoritativeState(noteID: fixture.noteID)),
            ("correct title with wrong winner", "Prior", resultingWinner, .staleAuthoritativeState(noteID: fixture.noteID)),
            ("apply against already-applied state", "Incoming", resultingWinner, .staleAuthoritativeState(noteID: fixture.noteID))
        ]

        for testCase in cases {
            let transaction = InMemoryConvergenceTransaction(notes: [
                fixture.noteID: SyncConvergenceMutableNoteRecord(
                    noteID: fixture.noteID,
                    folderID: nil,
                    title: testCase.1,
                    body: "Body",
                    createdAt: date(1),
                    modifiedAt: date(2)
                )
            ])
            if let winnerKey = testCase.2 {
                transaction.titleWinners[fixture.noteID] = titleWinnerProjection(
                    noteID: fixture.noteID,
                    title: testCase.1,
                    key: winnerKey,
                    identity: fixture.priorWinner.operationIdentity
                )
            }

            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: fixture.validatedInput,
                transaction: transaction,
                committedAt: fixture.committedAt
            )

            XCTAssertEqual(outcome, .failedBeforeCommit(testCase.3), testCase.0)
            assertNoPreflightMutation(transaction, testCase.0)
        }
    }

    func testTitleIgnoreOlderPreflightRejectsPriorStateBeforeMutation() throws {
        let fixture = try makeTitleIgnoreOlderFixture()
        let effect = try XCTUnwrap(fixture.plan.affectedNotePlans[0].titleEffect)
        let transaction = InMemoryConvergenceTransaction(notes: [
            fixture.noteID: SyncConvergenceMutableNoteRecord(
                noteID: fixture.noteID,
                folderID: nil,
                title: effect.priorTitle,
                body: "Body",
                createdAt: date(1),
                modifiedAt: date(2)
            )
        ])
        transaction.titleWinners[fixture.noteID] = fixture.priorWinner

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.staleAuthoritativeState(noteID: fixture.noteID)))
        assertNoPreflightMutation(transaction, "ignoreOlder prior state")
    }

    func testTitleIdempotentPreflightRejectsContradictoryOperationIdentityBeforeMutation() throws {
        let fixture = try makeTitleIdempotentFixture()
        let effect = try XCTUnwrap(fixture.plan.affectedNotePlans[0].titleEffect)
        var contradictoryIdentity = effect.candidateOperationIdentity
        contradictoryIdentity = OperationIdentityPayload(
            batchID: uuid("00000000-0000-0000-0000-000000132e88"),
            originDeviceID: contradictoryIdentity.canonicalReplayKey.originDeviceID,
            operationIndex: contradictoryIdentity.operationIndex,
            operationKind: contradictoryIdentity.operationKind,
            canonicalReplayKey: contradictoryIdentity.canonicalReplayKey
        )
        let transaction = InMemoryConvergenceTransaction(notes: [
            fixture.noteID: SyncConvergenceMutableNoteRecord(
                noteID: fixture.noteID,
                folderID: nil,
                title: effect.resultingTitle,
                body: "Body",
                createdAt: date(1),
                modifiedAt: date(2)
            )
        ])
        transaction.titleWinners[fixture.noteID] = titleWinnerProjection(
            noteID: fixture.noteID,
            title: effect.resultingTitle,
            key: effect.candidateCanonicalKey,
            identity: contradictoryIdentity
        )

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
        assertNoPreflightMutation(transaction, "idempotent contradictory identity")
    }

    func testExistingSnapshotHistoryRowsAreNotRewritten() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let snapshot = try XCTUnwrap(fixture.plan.historyPlan.snapshotAdditions.first).testSnapshotRecord(
            createdAt: fixture.committedAt
        )
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.snapshots[snapshot.testKey] = SyncConvergenceSnapshotProjection(snapshot: snapshot)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .incorporated = outcome else {
            return XCTFail("Expected incorporation with existing snapshot, got \(outcome)")
        }
        XCTAssertEqual(transaction.snapshotInsertCount, 0)
        XCTAssertEqual(transaction.snapshots[snapshot.testKey]?.snapshot, snapshot)
    }

    func testMixedExistingAndNewSnapshotHistoryRowsOnlyInsertMissingRows() throws {
        let first = try makeReconstructedSnapshotFixture(
            noteID: uuid("00000000-0000-0000-0000-000000133101"),
            batchID: uuid("00000000-0000-0000-0000-000000133102"),
            originID: uuid("00000000-0000-0000-0000-000000133103")
        )
        let second = try makeReconstructedSnapshotFixture(
            noteID: uuid("00000000-0000-0000-0000-000000133201"),
            batchID: uuid("00000000-0000-0000-0000-000000133202"),
            originID: uuid("00000000-0000-0000-0000-000000133203")
        )
        let fixture = try makeCombinedFixture(first, second)
        let snapshots = fixture.plan.historyPlan.snapshotAdditions.map {
            $0.testSnapshotRecord(createdAt: fixture.committedAt)
        }
        XCTAssertEqual(snapshots.count, 2)
        let preExisting = snapshots[0]
        let missing = snapshots[1]
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.notes[second.initialNote.noteID] = second.initialNote
        transaction.snapshots[preExisting.testKey] = SyncConvergenceSnapshotProjection(snapshot: preExisting)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        guard case .incorporated = outcome else {
            return XCTFail("Expected mixed snapshot incorporation, got \(outcome)")
        }
        XCTAssertEqual(transaction.snapshotInsertCount, 1)
        XCTAssertEqual(transaction.snapshots[preExisting.testKey]?.snapshot, preExisting)
        XCTAssertEqual(transaction.snapshots[missing.testKey]?.snapshot, missing)
    }

    func testContradictorySnapshotHistoryFailsBeforeMutation() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let snapshot = try XCTUnwrap(fixture.plan.historyPlan.snapshotAdditions.first).testSnapshotRecord(
            createdAt: fixture.committedAt
        )
        let contradictory = SyncConvergenceSnapshotRecord(
            noteID: snapshot.noteID,
            contentHash: snapshot.contentHash,
            body: "different",
            generation: snapshot.generation,
            createdAt: snapshot.createdAt
        )
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.snapshots[snapshot.testKey] = SyncConvergenceSnapshotProjection(snapshot: contradictory)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
        assertNoPreflightMutation(transaction, "contradictory snapshot")
    }

    func testBackwardSnapshotGenerationFailsBeforeMutation() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let planned = try XCTUnwrap(fixture.plan.historyPlan.snapshotAdditions.first).testSnapshotRecord(
            createdAt: fixture.committedAt
        )
        let newer = SyncConvergenceSnapshotRecord(
            noteID: planned.noteID,
            contentHash: SyncBatchContentHash.sha256Hex(for: "newer"),
            body: "newer",
            generation: planned.generation + 1,
            createdAt: date(99)
        )
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        transaction.snapshots[newer.testKey] = SyncConvergenceSnapshotProjection(snapshot: newer)

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
        assertNoPreflightMutation(transaction, "backward snapshot")
    }

    func testExecutorRollsBackEveryStagedFailurePoint() throws {
        let creation = try makeCreationFixture()
        let cases: [(IncorporationFailurePoint, Fixture, [UUID: SyncConvergenceMutableNoteRecord]?, Int)] = [
            (.noteCreation, creation, [:], 0),
            (.noteUpdate, try makeFixture(), nil, 0),
            (.titleWinner, try makeTitleAndBodyFixture(), nil, 0),
            (.retainedOperation, try makeFixture(), nil, 0),
            (.snapshot, try makeReconstructedSnapshotFixture(), nil, 0),
            (.operationIdentity, try makeFixture(), nil, 0),
            (.noteEffect, try makeFixture(), nil, 0),
            (.resultEvidence, try makeFixture(), nil, 0),
            (.incorporatedRoot, try makeFixture(), nil, 0),
            (.save, try makeFixture(), nil, 1)
        ]

        for (failurePoint, fixture, seededNotes, expectedSaveCount) in cases {
            let transaction = InMemoryConvergenceTransaction(
                notes: seededNotes ?? [fixture.initialNote.noteID: fixture.initialNote]
            )
            if let priorWinner = fixture.priorWinner {
                transaction.titleWinners[fixture.noteID] = priorWinner
            }
            transaction.failurePoint = failurePoint
            let captured = transaction.snapshotState()

            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: fixture.validatedInput,
                transaction: transaction,
                committedAt: fixture.committedAt
            )

            XCTAssertEqual(outcome, .failedAndRolledBack(.swiftDataSave), "\(failurePoint)")
            assertRolledBack(transaction, equals: captured, expectedSaveCount: expectedSaveCount, "\(failurePoint)")
        }
    }

    func testSwiftDataFreshContextReloadAndDifferentTimestampDuplicate() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context1 = ModelContext(container)
        let note = Note(title: fixture.initialNote.title, content: fixture.initialNote.body)
        note.id = fixture.initialNote.noteID
        note.createdAt = fixture.initialNote.createdAt
        note.modifiedAt = fixture.initialNote.modifiedAt
        context1.insert(note)

        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context1),
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected SwiftData incorporation, got \(first)")
        }

        let context2 = ModelContext(container)
        let persistedNote = try XCTUnwrap(fetchOne(Note.self, in: context2))
        XCTAssertEqual(persistedNote.id, fixture.noteID)
        XCTAssertEqual(persistedNote.title, fixture.initialNote.title)
        XCTAssertEqual(persistedNote.content, "AxB")
        XCTAssertEqual(persistedNote.createdAt, fixture.initialNote.createdAt)
        XCTAssertEqual(persistedNote.modifiedAt, date(4))

        let root = try XCTUnwrap(fetchOne(IncorporatedSyncBatch.self, in: context2))
        XCTAssertEqual(root.batchID, fixture.batch.id)
        XCTAssertEqual(root.originDeviceID, fixture.batch.originDeviceID)
        XCTAssertEqual(root.committedAt, fixture.committedAt)
        XCTAssertEqual(root.canonicalPayloadDigest, fixture.plan.canonicalPayloadDigest)
        XCTAssertEqual(root.canonicalPayloadDigestFormatVersion, fixture.plan.canonicalPayloadDigestFormatVersion)
        XCTAssertEqual(root.committedResultDigestFormatVersion, CanonicalCommittedResultDigestPayloadV1.formatVersion)
        XCTAssertEqual(
            root.committedResultDigest,
            try CanonicalCommittedResultDigestPayloadV1.digest(plan: fixture.plan, sourceBatch: fixture.batch)
        )
        let rootProjection = try XCTUnwrap(
            try SwiftDataSyncConvergencePersistenceTransaction(context: context2)
                .loadIncorporatedBatch(batchID: fixture.batch.id)
        )
        XCTAssertEqual(
            rootProjection.committedAtOrderingPayloadData,
            try CommittedAtOrderingPayload(batchID: fixture.batch.id, committedAt: fixture.committedAt).encodedEvidenceData()
        )
        XCTAssertEqual(
            root.affectedNotesPayloadData,
            Data(#"{"n":["\#(fixture.noteID.uuidString.lowercased())"],"v":1}"#.utf8)
        )

        let operationIdentities = try context2.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>())
        let noteEffects = try context2.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>())
        let resultEvidence = try context2.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>())
        XCTAssertEqual(operationIdentities.count, 1)
        XCTAssertEqual(noteEffects.count, 1)
        XCTAssertEqual(resultEvidence.count, 1)
        XCTAssertEqual(root.authoritativeChildCount, 3)

        let retained = try XCTUnwrap(fetchOne(RetainedBodyOperation.self, in: context2))
        XCTAssertEqual(retained.sourceRaw, "remote")
        XCTAssertEqual(retained.text, "x")
        let snapshot = try XCTUnwrap(fetchOne(NoteContentSnapshot.self, in: context2))
        XCTAssertEqual(snapshot.noteID, fixture.noteID)
        XCTAssertEqual(snapshot.body, "AxB")
        XCTAssertEqual(snapshot.generation, 2)

        let retryCommittedAt = date(99)
        XCTAssertNotEqual(retryCommittedAt, fixture.committedAt)
        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context2),
            committedAt: retryCommittedAt
        )

        guard case .alreadyIncorporated(let result) = duplicate else {
            return XCTFail("Expected fresh-context duplicate, got \(duplicate)")
        }
        XCTAssertEqual(result.cleanupPlan.batchIDs, [fixture.batch.id])
        XCTAssertEqual(result.presentationPlan, fixture.plan.presentationPlan)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<IncorporatedSyncBatch>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<RetainedBodyOperation>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<NoteContentSnapshot>()).count, 1)
        XCTAssertEqual(try XCTUnwrap(fetchOne(Note.self, in: context2)).content, "AxB")
    }

    func testMissingNoteTitleCompatibilityNoopRequiresNoWinner() throws {
        let fixture = try makeMissingTitleFixture()
        let cleanTransaction = InMemoryConvergenceTransaction(notes: [:])

        let cleanOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: cleanTransaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = cleanOutcome else {
            return XCTFail("Expected missing-note compatibility no-op to incorporate, got \(cleanOutcome)")
        }
        XCTAssertEqual(cleanTransaction.noteInsertCount, 0)
        XCTAssertEqual(cleanTransaction.titleWinnerWriteCount, 0)

        let orphanedWinnerTransaction = InMemoryConvergenceTransaction(notes: [:])
        orphanedWinnerTransaction.titleWinners[fixture.noteID] = fixture.orphanedWinner
        let orphanedOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: orphanedWinnerTransaction,
            committedAt: fixture.committedAt
        )
        XCTAssertEqual(orphanedOutcome, .failedBeforeCommit(.inconsistentIncorporationState(noteID: fixture.noteID)))
        assertNoPreflightMutation(orphanedWinnerTransaction, "orphaned winner")
    }

    private struct Fixture {
        let noteID: UUID
        let batch: SyncBatch
        let plan: SyncConvergenceBatchPlan
        let projectedBytes: Int
        let validatedInput: ValidatedSyncConvergenceIncorporationInput
        let initialNote: SyncConvergenceMutableNoteRecord
        let committedAt: Date
        let priorWinner: SyncConvergenceTitleWinnerProjection?
    }

    private struct TitleFixture {
        let noteID: UUID
        let validatedInput: ValidatedSyncConvergenceIncorporationInput
        let plan: SyncConvergenceBatchPlan
        let committedAt: Date
        let priorWinner: SyncConvergenceTitleWinnerProjection
        let orphanedWinner: SyncConvergenceTitleWinnerProjection
    }

    private func makeFixture(batchSequence: UInt64? = 7) throws -> Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132c10")
        let origin = uuid("00000000-0000-0000-0000-000000132c11")
        let batchID = uuid("00000000-0000-0000-0000-000000132c12")
        let initialCreatedAt = date(1)
        let initialModifiedAt = date(2)
        let batchCreatedAt = date(3)
        let operationModifiedAt = date(4)
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "A",
            createdAt: initialCreatedAt,
            modifiedAt: initialModifiedAt
        )
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: batchCreatedAt,
            batchSequence: batchSequence,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: operationModifiedAt,
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [
                SyncConvergenceProjectedNote(
                    noteID: noteID,
                    folderID: nil,
                    title: "Title",
                    body: "A",
                    createdAt: initialCreatedAt,
                    modifiedAt: initialModifiedAt
                )
            ]
        )
        guard case .planned(let validatedInput) = SyncConvergencePlanner().plan(input: input) else {
            throw XCTSkip("Fixture planning failed")
        }
        let plan = validatedInput.plan
        let projectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: batch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
        return Fixture(
            noteID: noteID,
            batch: batch,
            plan: plan,
            projectedBytes: projectedBytes,
            validatedInput: validatedInput,
            initialNote: initialNote,
            committedAt: date(5),
            priorWinner: nil
        )
    }

    private func makeTitleAndBodyFixture() throws -> Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132d50")
        let origin = uuid("00000000-0000-0000-0000-000000132d51")
        let batchID = uuid("00000000-0000-0000-0000-000000132d52")
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Prior",
            body: "A",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let priorBatch = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132d53"),
            noteID: noteID,
            title: "Prior",
            modifiedAt: date(3)
        )
        let priorWinner = titleWinnerProjection(noteID: noteID, title: "Prior", batch: priorBatch)
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: date(4),
            batchSequence: 9,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(5),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                )),
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: "Incoming",
                    modifiedAt: date(6)
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Prior",
                body: "A",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            persistedTitleWinners: [priorWinner]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let plan = validatedInput.plan
        let projectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: batch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
        return Fixture(
            noteID: noteID,
            batch: batch,
            plan: plan,
            projectedBytes: projectedBytes,
            validatedInput: validatedInput,
            initialNote: initialNote,
            committedAt: date(7),
            priorWinner: priorWinner
        )
    }

    private func makeTwoOperationFixture() throws -> Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132f01")
        let origin = uuid("00000000-0000-0000-0000-000000132f02")
        let batchID = uuid("00000000-0000-0000-0000-000000132f03")
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "A",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let firstHash = SyncBatchContentHash.sha256Hex(for: "A")
        let secondHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: date(3),
            batchSequence: 8,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: firstHash
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(5),
                    baseContentHash: secondHash
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [
                SyncConvergenceProjectedNote(
                    noteID: noteID,
                    folderID: nil,
                    title: "Title",
                    body: "A",
                    createdAt: date(1),
                    modifiedAt: date(2)
                )
            ]
        )
        guard case .planned(let validatedInput) = SyncConvergencePlanner().plan(input: input) else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let plan = validatedInput.plan
        let projectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: batch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
        return Fixture(
            noteID: noteID,
            batch: batch,
            plan: plan,
            projectedBytes: projectedBytes,
            validatedInput: validatedInput,
            initialNote: initialNote,
            committedAt: date(6),
            priorWinner: nil
        )
    }

    private func makeReconstructedSnapshotFixture(
        noteID: UUID = uuid("00000000-0000-0000-0000-000000133001"),
        batchID: UUID = uuid("00000000-0000-0000-0000-000000133002"),
        originID: UUID = uuid("00000000-0000-0000-0000-000000133003")
    ) throws -> Fixture {
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "ACB",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originID,
            createdAt: date(3),
            batchSequence: 10,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(4),
                    baseContentHash: baseHash
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Title",
                body: "ACB",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)
            ]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return try makeFixture(from: batch, validatedInput: validatedInput, initialNote: initialNote, committedAt: date(5))
    }

    private func makeCreationFixture() throws -> Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000133301")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000133302"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000133303"),
            createdAt: date(3),
            batchSequence: 11,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: "Body",
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                ))
            ]
        )
        guard case .planned(let validatedInput) = SyncConvergencePlanner().plan(
            input: SyncConvergencePlanningInput(incomingBatch: batch)
        ) else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "",
            body: "",
            createdAt: date(1),
            modifiedAt: date(1)
        )
        return try makeFixture(from: batch, validatedInput: validatedInput, initialNote: initialNote, committedAt: date(5))
    }

    private func makeCombinedFixture(_ first: Fixture, _ second: Fixture) throws -> Fixture {
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000133401"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000133402"),
            createdAt: date(3),
            batchSequence: 12,
            changes: first.batch.changes + second.batch.changes
        )
        guard case .planned(let validatedInput) = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [
                SyncConvergenceProjectedNote(
                    noteID: first.noteID,
                    folderID: nil,
                    title: first.initialNote.title,
                    body: first.initialNote.body,
                    createdAt: first.initialNote.createdAt,
                    modifiedAt: first.initialNote.modifiedAt
                ),
                SyncConvergenceProjectedNote(
                    noteID: second.noteID,
                    folderID: nil,
                    title: second.initialNote.title,
                    body: second.initialNote.body,
                    createdAt: second.initialNote.createdAt,
                    modifiedAt: second.initialNote.modifiedAt
                )
            ],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: first.noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                    body: "AB",
                    generation: 1
                ),
                SyncConvergenceRetainedSnapshot(
                    noteID: second.noteID,
                    contentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                    body: "AB",
                    generation: 1
                )
            ]
        )) else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return try makeFixture(from: batch, validatedInput: validatedInput, initialNote: first.initialNote, committedAt: date(5))
    }

    private func makeFixture(
        from batch: SyncBatch,
        validatedInput: ValidatedSyncConvergenceIncorporationInput,
        initialNote: SyncConvergenceMutableNoteRecord,
        committedAt: Date
    ) throws -> Fixture {
        let plan = validatedInput.plan
        let projectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: batch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
        return Fixture(
            noteID: initialNote.noteID,
            batch: batch,
            plan: plan,
            projectedBytes: projectedBytes,
            validatedInput: validatedInput,
            initialNote: initialNote,
            committedAt: committedAt,
            priorWinner: nil
        )
    }

    private func tombstoneProjection(
        matching fixture: Fixture,
        committedAtOrderingPayloadData: Data? = nil,
        tombstoneFormatVersion: Int = IncorporatedBatchTombstone.supportedTombstoneFormatVersion
    ) throws -> SyncConvergenceIncorporatedTombstoneProjection {
        let committedResultDigest = try CanonicalCommittedResultDigestPayloadV1.digest(
            plan: fixture.plan,
            sourceBatch: fixture.batch
        )
        return SyncConvergenceIncorporatedTombstoneProjection(
            batchID: fixture.batch.id,
            originDeviceID: fixture.batch.originDeviceID,
            canonicalPayloadDigest: fixture.plan.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: fixture.plan.canonicalPayloadDigestFormatVersion,
            schemaVersion: fixture.validatedInput.sourceSchemaVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: CanonicalCommittedResultDigestPayloadV1.formatVersion,
            committedAtOrderingPayloadData: try committedAtOrderingPayloadData ?? CommittedAtOrderingPayload(
                batchID: fixture.batch.id,
                committedAt: fixture.committedAt
            ).encodedEvidenceData(),
            tombstoneFormatVersion: tombstoneFormatVersion
        )
    }

    private func makeTitleApplyFixture() throws -> TitleFixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132e01")
        let priorBatch = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e10"),
            noteID: noteID,
            title: "Prior",
            modifiedAt: date(2)
        )
        let incoming = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e11"),
            noteID: noteID,
            title: "Incoming",
            modifiedAt: date(4)
        )
        let priorWinner = titleWinnerProjection(noteID: noteID, title: "Prior", batch: priorBatch)
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Prior",
                body: "Body",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            persistedTitleWinners: [priorWinner]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return TitleFixture(
            noteID: noteID,
            validatedInput: validatedInput,
            plan: validatedInput.plan,
            committedAt: date(5),
            priorWinner: priorWinner,
            orphanedWinner: priorWinner
        )
    }

    private func makeTitleIgnoreOlderFixture() throws -> TitleFixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132e03")
        let older = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e14"),
            noteID: noteID,
            title: "Older",
            modifiedAt: date(2)
        )
        let newer = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e15"),
            noteID: noteID,
            title: "Newer",
            modifiedAt: date(4)
        )
        let newerWinner = titleWinnerProjection(noteID: noteID, title: "Newer", batch: newer)
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: older,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Older",
                body: "Body",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            persistedTitleWinners: [newerWinner]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return TitleFixture(
            noteID: noteID,
            validatedInput: validatedInput,
            plan: validatedInput.plan,
            committedAt: date(5),
            priorWinner: newerWinner,
            orphanedWinner: newerWinner
        )
    }

    private func makeTitleIdempotentFixture() throws -> TitleFixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132e04")
        let incoming = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e16"),
            noteID: noteID,
            title: "Winner",
            modifiedAt: date(4)
        )
        let winner = titleWinnerProjection(noteID: noteID, title: "Winner", batch: incoming)
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Winner",
                body: "Body",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            persistedTitleWinners: [winner]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return TitleFixture(
            noteID: noteID,
            validatedInput: validatedInput,
            plan: validatedInput.plan,
            committedAt: date(5),
            priorWinner: winner,
            orphanedWinner: winner
        )
    }

    private func makeMissingTitleFixture() throws -> TitleFixture {
        let noteID = uuid("00000000-0000-0000-0000-000000132e02")
        let incoming = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e12"),
            noteID: noteID,
            title: "Incoming",
            modifiedAt: date(4)
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: incoming))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let orphanBatch = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000132e13"),
            noteID: noteID,
            title: "Orphan",
            modifiedAt: date(3)
        )
        let orphan = titleWinnerProjection(noteID: noteID, title: "Orphan", batch: orphanBatch)
        return TitleFixture(
            noteID: noteID,
            validatedInput: validatedInput,
            plan: validatedInput.plan,
            committedAt: date(5),
            priorWinner: orphan,
            orphanedWinner: orphan
        )
    }

private enum TestFixtureError: Error {
        case unexpectedPlanningOutcome
    }
}

private enum IncorporationFailurePoint: CaseIterable {
    case noteCreation
    case noteUpdate
    case titleWinner
    case retainedOperation
    case snapshot
    case operationIdentity
    case noteEffect
    case resultEvidence
    case incorporatedRoot
    case save
}

private final class InMemoryConvergenceTransaction: SyncConvergencePersistenceTransaction {
    var notes: [UUID: SyncConvergenceMutableNoteRecord]
    var titleWinners: [UUID: SyncConvergenceTitleWinnerProjection] = [:]
    var roots: [UUID: SyncConvergenceIncorporatedRootProjection] = [:]
    var tombstones: [UUID: SyncConvergenceIncorporatedTombstoneProjection] = [:]
    var children: [UUID: SyncConvergenceIncorporatedChildrenProjection] = [:]
    var retainedOperations: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationProjection] = [:]
    var snapshots: [String: SyncConvergenceSnapshotProjection] = [:]
    var saveCalled = false
    var rollbackCalled = false
    var noteInsertCount = 0
    var noteUpdateCount = 0
    var titleWinnerWriteCount = 0
    var retainedOperationInsertCount = 0
    var snapshotInsertCount = 0
    var operationIdentityInsertCount = 0
    var noteEffectInsertCount = 0
    var resultEvidenceInsertCount = 0
    var rootInsertCount = 0
    var saveCount = 0
    var rollbackCount = 0
    var failAfterUpdateNote = false
    var failurePoint: IncorporationFailurePoint?

    private var rollbackSnapshot: TransactionState?

    init(notes: [UUID: SyncConvergenceMutableNoteRecord]) {
        self.notes = notes
    }

    func loadNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? { notes[id] }

    func insertNote(_ record: SyncConvergenceNewNoteRecord) throws {
        stageRollback()
        noteInsertCount += 1
        notes[record.noteID] = SyncConvergenceMutableNoteRecord(
            noteID: record.noteID,
            folderID: record.folderID,
            title: record.title,
            body: record.body,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt
        )
        try throwIfConfigured(.noteCreation)
    }

    func updateNote(_ record: SyncConvergenceUpdatedNoteRecord) throws {
        stageRollback()
        noteUpdateCount += 1
        let existing = notes[record.noteID]
        notes[record.noteID] = SyncConvergenceMutableNoteRecord(
            noteID: record.noteID,
            folderID: existing?.folderID,
            title: record.title,
            body: record.body,
            createdAt: existing?.createdAt ?? record.modifiedAt,
            modifiedAt: record.modifiedAt
        )
        if failAfterUpdateNote {
            throw SyncConvergenceTransactionFailure.swiftDataSave
        }
        try throwIfConfigured(.noteUpdate)
    }

    func loadTitleWinner(noteID: UUID) throws -> SyncConvergenceTitleWinnerProjection? { titleWinners[noteID] }

    func insertOrUpdateTitleWinner(_ record: SyncConvergenceTitleWinnerRecord) throws {
        stageRollback()
        titleWinnerWriteCount += 1
        titleWinners[record.noteID] = SyncConvergenceTitleWinnerProjection(
            noteID: record.noteID,
            title: record.title,
            canonicalReplayKey: record.canonicalReplayKey,
            operationIdentity: record.operationIdentity
        )
        try throwIfConfigured(.titleWinner)
    }

    func loadIncorporatedBatch(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection? { roots[batchID] }
    func loadIncorporatedBatchChildren(batchID: UUID) throws -> SyncConvergenceIncorporatedChildrenProjection {
        children[batchID] ?? .empty
    }
    func loadTombstone(batchID: UUID) throws -> SyncConvergenceIncorporatedTombstoneProjection? { tombstones[batchID] }

    func insertIncorporatedBatch(_ record: SyncConvergenceIncorporatedBatchRecord) throws {
        stageRollback()
        rootInsertCount += 1
        roots[record.batchID] = SyncConvergenceIncorporatedRootProjection(
            batchID: record.batchID,
            originDeviceID: record.originDeviceID,
            createdAt: record.createdAt,
            batchSequence: record.batchSequence,
            schemaVersion: record.schemaVersion,
            committedAt: record.committedAt,
            canonicalPayloadDigest: record.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: record.canonicalPayloadDigestFormatVersion,
            committedResultDigest: record.committedResultDigest,
            committedResultDigestFormatVersion: record.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: try CommittedAtOrderingPayload(
                batchID: record.batchID,
                committedAt: record.committedAt
            ).encodedEvidenceData(),
            affectedNotesPayloadData: record.affectedNotesPayloadData,
            authoritativeChildCount: record.authoritativeChildCount,
            authoritativeChildBytes: record.authoritativeChildBytes,
            authoritativeChildrenDigest: record.authoritativeChildrenDigest,
            postCommitStatePayloadData: record.postCommitStatePayloadData
        )
        try throwIfConfigured(.incorporatedRoot)
    }

    func insertOperationIdentity(_ record: SyncConvergenceOperationIdentityRecord) throws {
        stageRollback()
        operationIdentityInsertCount += 1
        let projection = children[record.batchID] ?? .empty
        children[record.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities + [record],
            noteEffects: projection.noteEffects,
            resultEvidence: projection.resultEvidence
        )
        try throwIfConfigured(.operationIdentity)
    }

    func insertNoteEffect(_ record: SyncConvergenceNoteEffectRecord) throws {
        stageRollback()
        noteEffectInsertCount += 1
        let projection = children[record.batchID] ?? .empty
        children[record.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities,
            noteEffects: projection.noteEffects + [record],
            resultEvidence: projection.resultEvidence
        )
        try throwIfConfigured(.noteEffect)
    }

    func insertResultEvidence(_ record: SyncConvergenceResultEvidenceRecord) throws {
        stageRollback()
        resultEvidenceInsertCount += 1
        let projection = children[record.evidence.batchID] ?? .empty
        children[record.evidence.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities,
            noteEffects: projection.noteEffects,
            resultEvidence: projection.resultEvidence + [record]
        )
        try throwIfConfigured(.resultEvidence)
    }

    func loadRetainedOperation(
        identity: SyncConvergenceRetainedOperationIdentity
    ) throws -> SyncConvergenceRetainedOperationProjection? {
        retainedOperations[identity]
    }

    func insertRetainedOperation(_ record: SyncConvergenceRetainedOperationRecord) throws {
        stageRollback()
        retainedOperationInsertCount += 1
        retainedOperations[SyncConvergenceRetainedOperationIdentity(
            batchID: record.batchID,
            operationIndex: record.operationIndex
        )] = SyncConvergenceRetainedOperationProjection(operation: record, source: .remote)
        try throwIfConfigured(.retainedOperation)
    }

    func loadSnapshot(noteID: UUID, generation: Int) throws -> SyncConvergenceSnapshotProjection? {
        snapshots["\(noteID.uuidString.lowercased())|\(generation)"]
    }

    func loadHighestSnapshotGeneration(noteID: UUID) throws -> Int? {
        let prefix = "\(noteID.uuidString.lowercased())|"
        return snapshots.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return Int(key.dropFirst(prefix.count))
        }.max()
    }

    func insertSnapshot(_ record: SyncConvergenceSnapshotRecord) throws {
        stageRollback()
        snapshotInsertCount += 1
        snapshots["\(record.noteID.uuidString.lowercased())|\(record.generation)"] = SyncConvergenceSnapshotProjection(
            snapshot: record
        )
        try throwIfConfigured(.snapshot)
    }

    func save() throws {
        saveCalled = true
        saveCount += 1
        try throwIfConfigured(.save)
        rollbackSnapshot = nil
    }

    func rollback() {
        rollbackCalled = true
        rollbackCount += 1
        guard let rollbackSnapshot else { return }
        notes = rollbackSnapshot.notes
        titleWinners = rollbackSnapshot.titleWinners
        roots = rollbackSnapshot.roots
        tombstones = rollbackSnapshot.tombstones
        children = rollbackSnapshot.children
        retainedOperations = rollbackSnapshot.retainedOperations
        snapshots = rollbackSnapshot.snapshots
        self.rollbackSnapshot = nil
    }

    func updatePostCommitState(batchID: UUID, payloadData: Data) {
        guard let root = roots[batchID] else { return }
        roots[batchID] = SyncConvergenceIncorporatedRootProjection(
            batchID: root.batchID,
            originDeviceID: root.originDeviceID,
            createdAt: root.createdAt,
            batchSequence: root.batchSequence,
            schemaVersion: root.schemaVersion,
            committedAt: root.committedAt,
            canonicalPayloadDigest: root.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: root.canonicalPayloadDigestFormatVersion,
            committedResultDigest: root.committedResultDigest,
            committedResultDigestFormatVersion: root.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: root.committedAtOrderingPayloadData,
            affectedNotesPayloadData: root.affectedNotesPayloadData,
            authoritativeChildCount: root.authoritativeChildCount,
            authoritativeChildBytes: root.authoritativeChildBytes,
            authoritativeChildrenDigest: root.authoritativeChildrenDigest,
            postCommitStatePayloadData: payloadData
        )
    }

    var mutationCounts: MutationCounts {
        MutationCounts(
            noteInsertCount: noteInsertCount,
            noteUpdateCount: noteUpdateCount,
            titleWinnerWriteCount: titleWinnerWriteCount,
            retainedOperationInsertCount: retainedOperationInsertCount,
            snapshotInsertCount: snapshotInsertCount,
            operationIdentityInsertCount: operationIdentityInsertCount,
            noteEffectInsertCount: noteEffectInsertCount,
            resultEvidenceInsertCount: resultEvidenceInsertCount,
            rootInsertCount: rootInsertCount,
            saveCount: saveCount,
            rollbackCount: rollbackCount
        )
    }

    func snapshotState() -> TransactionState {
        TransactionState(
            notes: notes,
            titleWinners: titleWinners,
            roots: roots,
            tombstones: tombstones,
            children: children,
            retainedOperations: retainedOperations,
            snapshots: snapshots
        )
    }

    private func stageRollback() {
        guard rollbackSnapshot == nil else { return }
        rollbackSnapshot = snapshotState()
    }

    private func throwIfConfigured(_ point: IncorporationFailurePoint) throws {
        guard failurePoint == point else { return }
        throw SyncConvergenceTransactionFailure.swiftDataSave
    }
}

private struct TransactionState: Equatable {
    let notes: [UUID: SyncConvergenceMutableNoteRecord]
    let titleWinners: [UUID: SyncConvergenceTitleWinnerProjection]
    let roots: [UUID: SyncConvergenceIncorporatedRootProjection]
    let tombstones: [UUID: SyncConvergenceIncorporatedTombstoneProjection]
    let children: [UUID: SyncConvergenceIncorporatedChildrenProjection]
    let retainedOperations: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationProjection]
    let snapshots: [String: SyncConvergenceSnapshotProjection]
}

private struct MutationCounts: Equatable {
    let noteInsertCount: Int
    let noteUpdateCount: Int
    let titleWinnerWriteCount: Int
    let retainedOperationInsertCount: Int
    let snapshotInsertCount: Int
    let operationIdentityInsertCount: Int
    let noteEffectInsertCount: Int
    let resultEvidenceInsertCount: Int
    let rootInsertCount: Int
    let saveCount: Int
    let rollbackCount: Int
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}

private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}

private func titleBatch(id: UUID, noteID: UUID, title: String, modifiedAt: Date) -> SyncBatch {
    SyncBatch(
        id: id,
        originDeviceID: uuid("00000000-0000-0000-0000-000000132e99"),
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

private func titleWinnerProjection(
    noteID: UUID,
    title: String,
    batch: SyncBatch
) -> SyncConvergenceTitleWinnerProjection {
    let replayKey = CanonicalReplayKeyPayload(
        replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
    )
    return titleWinnerProjection(
        noteID: noteID,
        title: title,
        key: replayKey,
        identity: OperationIdentityPayload(
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            operationKind: "title",
            canonicalReplayKey: replayKey
        )
    )
}

private func titleWinnerProjection(
    noteID: UUID,
    title: String,
    key: CanonicalReplayKeyPayload,
    identity: OperationIdentityPayload
) -> SyncConvergenceTitleWinnerProjection {
    SyncConvergenceTitleWinnerProjection(
        noteID: noteID,
        title: title,
        canonicalReplayKey: key,
        operationIdentity: identity
    )
}

private func assertNoPreflightMutation(
    _ transaction: InMemoryConvergenceTransaction,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(transaction.noteInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.noteUpdateCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.titleWinnerWriteCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.retainedOperationInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.snapshotInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.operationIdentityInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.noteEffectInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.resultEvidenceInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.rootInsertCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.saveCount, 0, message, file: file, line: line)
    XCTAssertEqual(transaction.rollbackCount, 0, message, file: file, line: line)
}

private func assertRolledBack(
    _ transaction: InMemoryConvergenceTransaction,
    equals captured: TransactionState,
    expectedSaveCount: Int,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(transaction.snapshotState(), captured, message, file: file, line: line)
    XCTAssertEqual(transaction.rollbackCount, 1, message, file: file, line: line)
    XCTAssertEqual(transaction.saveCount, expectedSaveCount, message, file: file, line: line)
}

private func fetchOne<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> T? {
    try context.fetch(FetchDescriptor<T>()).first
}

private extension SyncConvergencePlannedBodyOperation {
    var testRetainedOperationRecord: SyncConvergenceRetainedOperationRecord {
        SyncConvergenceRetainedOperationRecord(
            noteID: noteID,
            batchID: UUID(uuidString: operationIdentity.batchIDLowercase) ?? operationIdentity.canonicalReplayKey.batchID,
            originDeviceID: UUID(uuidString: operationIdentity.originDeviceIDLowercase) ?? operationIdentity.canonicalReplayKey.originDeviceID,
            operationIndex: operationIdentity.operationIndex,
            operationKind: kind,
            utf16Offset: utf16Offset,
            utf16Length: utf16Length,
            text: text,
            expectedText: expectedText,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            canonicalReplayKey: operationIdentity.canonicalReplayKey,
            modifiedAt: operationIdentity.canonicalReplayKey.modifiedAt
        )
    }
}

private extension SyncConvergenceSnapshotAddition {
    func testSnapshotRecord(createdAt: Date) -> SyncConvergenceSnapshotRecord {
        SyncConvergenceSnapshotRecord(
            noteID: noteID,
            contentHash: contentHash,
            body: body,
            generation: generation,
            createdAt: createdAt
        )
    }
}

private extension SyncConvergenceSnapshotRecord {
    var testKey: String { "\(noteID.uuidString.lowercased())|\(generation)" }
}

private extension SyncConvergenceIncorporatedChildrenProjection {
    func withResultEvidence(_ resultEvidence: [SyncConvergenceResultEvidenceRecord]) -> Self {
        SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: operationIdentities,
            noteEffects: noteEffects,
            resultEvidence: resultEvidence
        )
    }

    func withResultEvidenceReversed() -> Self {
        withResultEvidence(resultEvidence.reversed())
    }
}

private extension CanonicalReplayKeyPayload {
    var batchID: UUID { UUID(uuidString: batchIDLowercase)! }
    var originDeviceID: UUID { UUID(uuidString: originDeviceIDLowercase)! }
}
