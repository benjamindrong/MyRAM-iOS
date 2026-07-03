import XCTest
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

    func testValidatedInputPreservesSourceMetadataAndRejectsMismatches() throws {
        let fixture = try makeFixture(batchSequence: 42)

        let input = try fixture.validatedInput.get()

        XCTAssertEqual(input.sourceBatchID, fixture.batch.id)
        XCTAssertEqual(input.sourceOriginDeviceID, fixture.batch.originDeviceID)
        XCTAssertEqual(input.sourceCreatedAt, fixture.batch.createdAt)
        XCTAssertEqual(input.sourceBatchSequence, 42)
        XCTAssertEqual(input.sourceSchemaVersion, 1)
        XCTAssertEqual(input.projectedFullIncorporationEvidenceBytes, fixture.projectedBytes)

        let mismatchedBatch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132cff"),
            originDeviceID: fixture.batch.originDeviceID,
            createdAt: fixture.batch.createdAt,
            batchSequence: fixture.batch.batchSequence,
            changes: fixture.batch.changes
        )
        XCTAssertEqual(
            ValidatedSyncConvergenceIncorporationInput.make(
                plan: fixture.plan,
                sourceBatch: mismatchedBatch,
                sourceSchemaVersion: 1,
                projectedFullIncorporationEvidenceBytes: fixture.projectedBytes
            ),
            .failure(.invalidMergePlan(noteID: nil))
        )
        XCTAssertEqual(
            ValidatedSyncConvergenceIncorporationInput.make(
                plan: fixture.plan,
                sourceBatch: fixture.batch,
                sourceSchemaVersion: 1,
                projectedFullIncorporationEvidenceBytes: fixture.projectedBytes + 1
            ),
            .failure(.invalidMergePlan(noteID: nil))
        )
    }

    func testExecutorPersistsPlannedEffectsRootChildrenAndPendingWork() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: try fixture.validatedInput.get(),
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
        XCTAssertEqual(transaction.children[fixture.batch.id]?.noteEffects.first?.kinds, ["body"])
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
            input: try fixture.validatedInput.get(),
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
            input: try fixture.validatedInput.get(),
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedAndRolledBack(.swiftDataSave))
        XCTAssertEqual(transaction.notes[fixture.noteID], fixture.initialNote)
        XCTAssertTrue(transaction.rollbackCalled)
        XCTAssertFalse(transaction.saveCalled)
        XCTAssertNil(transaction.roots[fixture.batch.id])
    }

    func testAlreadyIncorporatedUsesValidatedPlansGatedByPersistedPendingFlags() throws {
        let fixture = try makeFixture()
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.initialNote.noteID: fixture.initialNote])
        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: try fixture.validatedInput.get(),
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected first incorporation")
        }

        let duplicate = SyncConvergenceIncorporationExecutor().incorporate(
            input: try fixture.validatedInput.get(),
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
            input: try fixture.validatedInput.get(),
            transaction: transaction,
            committedAt: fixture.committedAt
        )
        guard case .alreadyIncorporated(let completedResult) = completedDuplicate else {
            return XCTFail("Expected completed already incorporated, got \(completedDuplicate)")
        }
        XCTAssertTrue(completedResult.cleanupPlan.batchIDs.isEmpty)
        XCTAssertTrue(completedResult.presentationPlan.noteRoutings.isEmpty)
    }

    private struct Fixture {
        let noteID: UUID
        let batch: SyncBatch
        let plan: SyncConvergenceBatchPlan
        let projectedBytes: Int
        let validatedInput: Result<ValidatedSyncConvergenceIncorporationInput, SyncConvergenceTransactionFailure>
        let initialNote: SyncConvergenceMutableNoteRecord
        let committedAt: Date
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
        guard case .planned(let plan) = SyncConvergencePlanner().plan(input: input) else {
            throw XCTSkip("Fixture planning failed")
        }
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
            validatedInput: ValidatedSyncConvergenceIncorporationInput.make(
                plan: plan,
                sourceBatch: batch,
                sourceSchemaVersion: 1,
                projectedFullIncorporationEvidenceBytes: projectedBytes
            ),
            initialNote: initialNote,
            committedAt: date(5)
        )
    }
}

private final class InMemoryConvergenceTransaction: SyncConvergencePersistenceTransaction {
    var notes: [UUID: SyncConvergenceMutableNoteRecord]
    var titleWinners: [UUID: SyncConvergenceTitleWinnerProjection] = [:]
    var roots: [UUID: SyncConvergenceIncorporatedRootProjection] = [:]
    var tombstones: [UUID: SyncConvergenceIncorporatedRootProjection] = [:]
    var children: [UUID: SyncConvergenceIncorporatedChildrenProjection] = [:]
    var retainedOperations: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationProjection] = [:]
    var snapshots: [String: SyncConvergenceSnapshotProjection] = [:]
    var saveCalled = false
    var rollbackCalled = false
    var failAfterUpdateNote = false

    private var rollbackSnapshot: Snapshot?

    init(notes: [UUID: SyncConvergenceMutableNoteRecord]) {
        self.notes = notes
    }

    func loadNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? { notes[id] }

    func insertNote(_ record: SyncConvergenceNewNoteRecord) throws {
        stageRollback()
        notes[record.noteID] = SyncConvergenceMutableNoteRecord(
            noteID: record.noteID,
            folderID: record.folderID,
            title: record.title,
            body: record.body,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt
        )
    }

    func updateNote(_ record: SyncConvergenceUpdatedNoteRecord) throws {
        stageRollback()
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
    }

    func loadTitleWinner(noteID: UUID) throws -> SyncConvergenceTitleWinnerProjection? { titleWinners[noteID] }

    func insertOrUpdateTitleWinner(_ record: SyncConvergenceTitleWinnerRecord) throws {
        stageRollback()
        titleWinners[record.noteID] = SyncConvergenceTitleWinnerProjection(
            noteID: record.noteID,
            title: record.title,
            canonicalReplayKey: record.canonicalReplayKey,
            operationIdentity: record.operationIdentity
        )
    }

    func loadIncorporatedBatch(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection? { roots[batchID] }
    func loadIncorporatedBatchChildren(batchID: UUID) throws -> SyncConvergenceIncorporatedChildrenProjection {
        children[batchID] ?? .empty
    }
    func loadTombstone(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection? { tombstones[batchID] }

    func insertIncorporatedBatch(_ record: SyncConvergenceIncorporatedBatchRecord) throws {
        stageRollback()
        roots[record.batchID] = SyncConvergenceIncorporatedRootProjection(
            batchID: record.batchID,
            originDeviceID: record.originDeviceID,
            createdAt: record.createdAt,
            batchSequence: record.batchSequence,
            schemaVersion: record.schemaVersion,
            canonicalPayloadDigest: record.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: record.canonicalPayloadDigestFormatVersion,
            committedResultDigest: record.committedResultDigest,
            committedResultDigestFormatVersion: record.committedResultDigestFormatVersion,
            affectedNotesPayloadData: record.affectedNotesPayloadData,
            authoritativeChildCount: record.authoritativeChildCount,
            authoritativeChildBytes: record.authoritativeChildBytes,
            authoritativeChildrenDigest: record.authoritativeChildrenDigest,
            postCommitStatePayloadData: record.postCommitStatePayloadData
        )
    }

    func insertOperationIdentity(_ record: SyncConvergenceOperationIdentityRecord) throws {
        stageRollback()
        let projection = children[record.batchID] ?? .empty
        children[record.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities + [record],
            noteEffects: projection.noteEffects,
            resultEvidence: projection.resultEvidence
        )
    }

    func insertNoteEffect(_ record: SyncConvergenceNoteEffectRecord) throws {
        stageRollback()
        let projection = children[record.batchID] ?? .empty
        children[record.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities,
            noteEffects: projection.noteEffects + [record],
            resultEvidence: projection.resultEvidence
        )
    }

    func insertResultEvidence(_ record: SyncConvergenceResultEvidenceRecord) throws {
        stageRollback()
        let projection = children[record.evidence.batchID] ?? .empty
        children[record.evidence.batchID] = SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: projection.operationIdentities,
            noteEffects: projection.noteEffects,
            resultEvidence: projection.resultEvidence + [record]
        )
    }

    func loadRetainedOperation(
        identity: SyncConvergenceRetainedOperationIdentity
    ) throws -> SyncConvergenceRetainedOperationProjection? {
        retainedOperations[identity]
    }

    func insertRetainedOperation(_ record: SyncConvergenceRetainedOperationRecord) throws {
        stageRollback()
        retainedOperations[SyncConvergenceRetainedOperationIdentity(
            batchID: record.batchID,
            operationIndex: record.operationIndex
        )] = SyncConvergenceRetainedOperationProjection(operation: record)
    }

    func loadSnapshot(noteID: UUID, generation: Int) throws -> SyncConvergenceSnapshotProjection? {
        snapshots["\(noteID.uuidString.lowercased())|\(generation)"]
    }

    func insertSnapshot(_ record: SyncConvergenceSnapshotRecord) throws {
        stageRollback()
        snapshots["\(record.noteID.uuidString.lowercased())|\(record.generation)"] = SyncConvergenceSnapshotProjection(
            snapshot: record
        )
    }

    func save() throws {
        saveCalled = true
        rollbackSnapshot = nil
    }

    func rollback() {
        rollbackCalled = true
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
            canonicalPayloadDigest: root.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: root.canonicalPayloadDigestFormatVersion,
            committedResultDigest: root.committedResultDigest,
            committedResultDigestFormatVersion: root.committedResultDigestFormatVersion,
            affectedNotesPayloadData: root.affectedNotesPayloadData,
            authoritativeChildCount: root.authoritativeChildCount,
            authoritativeChildBytes: root.authoritativeChildBytes,
            authoritativeChildrenDigest: root.authoritativeChildrenDigest,
            postCommitStatePayloadData: payloadData
        )
    }

    private func stageRollback() {
        guard rollbackSnapshot == nil else { return }
        rollbackSnapshot = Snapshot(
            notes: notes,
            titleWinners: titleWinners,
            roots: roots,
            tombstones: tombstones,
            children: children,
            retainedOperations: retainedOperations,
            snapshots: snapshots
        )
    }

    private struct Snapshot {
        let notes: [UUID: SyncConvergenceMutableNoteRecord]
        let titleWinners: [UUID: SyncConvergenceTitleWinnerProjection]
        let roots: [UUID: SyncConvergenceIncorporatedRootProjection]
        let tombstones: [UUID: SyncConvergenceIncorporatedRootProjection]
        let children: [UUID: SyncConvergenceIncorporatedChildrenProjection]
        let retainedOperations: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationProjection]
        let snapshots: [String: SyncConvergenceSnapshotProjection]
    }
}

private func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}

private func date(_ value: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: value)
}
