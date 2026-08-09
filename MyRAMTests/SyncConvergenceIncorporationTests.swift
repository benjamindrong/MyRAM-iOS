import XCTest
import SwiftData
import CryptoKit
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergenceIncorporationTests: XCTestCase {
    func testDivergedLifecycleDeleteIncorporatesWithoutChangingDeletedAt() {
        let noteID = uuid("00000000-0000-0000-0000-000000165201")
        let initial = SyncConvergenceMutableNoteRecord(
            noteID: noteID, folderID: nil, title: "Local edit", body: "Local body", createdAt: date(1), modifiedAt: date(2)
        )
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165202"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165203"),
            createdAt: date(3),
            changes: [.noteLifecycleChanged(.init(
                noteID: noteID,
                deletedAt: date(3),
                modifiedAt: date(3),
                title: "Remote title",
                body: "Remote body",
                baseTitleHash: SyncBatchContentHash.sha256Hex(for: "Remote title"),
                baseBodyHash: SyncBatchContentHash.sha256Hex(for: "Remote body")
            ))]
        )
        let outcome = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: batch,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: initial.title, body: initial.body, createdAt: initial.createdAt, modifiedAt: initial.modifiedAt)]
        ))
        guard case .planned(let input) = outcome else {
            return XCTFail("Expected non-blocking lifecycle plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initial])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: input, transaction: transaction, committedAt: date(4)
        )

        guard case .incorporated = incorporation else {
            return XCTFail("Expected divergence to be incorporated, got \(incorporation)")
        }
        XCTAssertNil(transaction.notes[noteID]?.deletedAt)
        XCTAssertEqual(transaction.notes[noteID]?.title, "Local edit")
        XCTAssertEqual(transaction.notes[noteID]?.body, "Local body")
    }

    func testDivergedLifecycleDeleteAlongsideApplyingTitleChangeDoesNotDeleteNote() {
        let noteID = uuid("00000000-0000-0000-0000-000000165301")
        let initial = SyncConvergenceMutableNoteRecord(
            noteID: noteID, folderID: nil, title: "Original Title", body: "Local unsynced body edit", createdAt: date(1), modifiedAt: date(2)
        )
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165302"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165303"),
            createdAt: date(3),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: "Renamed",
                    modifiedAt: date(3)
                )),
                .noteLifecycleChanged(.init(
                    noteID: noteID,
                    deletedAt: date(3),
                    modifiedAt: date(3),
                    title: "Renamed",
                    body: "Remote body",
                    baseTitleHash: SyncBatchContentHash.sha256Hex(for: "Renamed"),
                    baseBodyHash: SyncBatchContentHash.sha256Hex(for: "Remote body")
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: batch,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: initial.title, body: initial.body, createdAt: initial.createdAt, modifiedAt: initial.modifiedAt)]
        ))
        guard case .planned(let input) = outcome else {
            return XCTFail("Expected non-blocking compound plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initial])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: input, transaction: transaction, committedAt: date(4)
        )

        guard case .incorporated = incorporation else {
            return XCTFail("Expected compound plan to be incorporated, got \(incorporation)")
        }
        // The title change applies on its own merits; the diverged lifecycle change must not
        // ride along on the compound plan's hasMutableNoteEffect and delete the note anyway.
        XCTAssertNil(transaction.notes[noteID]?.deletedAt)
        XCTAssertEqual(transaction.notes[noteID]?.title, "Renamed")
        XCTAssertEqual(transaction.notes[noteID]?.body, "Local unsynced body edit")
    }

    func testDivergedLifecycleDeleteAlongsideApplyingBodyEditDoesNotClobberIncrementalRouting() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000165311")
        let initial = SyncConvergenceMutableNoteRecord(
            noteID: noteID, folderID: nil, title: "Original Title", body: "Local body", createdAt: date(1), modifiedAt: date(2)
        )
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165312"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165313"),
            createdAt: date(3),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Local body".utf16.count,
                    text: " more",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Local body")
                )),
                .noteLifecycleChanged(.init(
                    noteID: noteID,
                    deletedAt: date(3),
                    modifiedAt: date(3),
                    title: "Some other title",
                    body: "Some other body",
                    baseTitleHash: SyncBatchContentHash.sha256Hex(for: "Some other title"),
                    baseBodyHash: SyncBatchContentHash.sha256Hex(for: "Some other body")
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: batch,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: initial.title, body: initial.body, createdAt: initial.createdAt, modifiedAt: initial.modifiedAt)]
        ))
        guard case .planned(let input) = outcome else {
            return XCTFail("Expected non-blocking compound plan, got \(outcome)")
        }
        // The bug this covers: the lifecycle branch used to unconditionally overwrite
        // routing, clobbering the body effect's .incremental need down to .none, which
        // then failed plan validation (invalidMergePlan) and permanently blocked the
        // runtime for every subsequent incoming batch.
        XCTAssertEqual(input.plan.presentationPlan.noteRoutings[noteID], .incremental)

        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initial])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: input, transaction: transaction, committedAt: date(4)
        )

        guard case .incorporated = incorporation else {
            return XCTFail("Expected compound plan to be incorporated, got \(incorporation)")
        }
        XCTAssertNil(transaction.notes[noteID]?.deletedAt)
        XCTAssertEqual(transaction.notes[noteID]?.body, "Local body more")
        XCTAssertEqual(transaction.notes[noteID]?.title, "Original Title")
    }

    func testApplyingLifecycleDeleteAlongsideApplyingBodyEditRoutesToNoteRemoved() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000165321")
        let initial = SyncConvergenceMutableNoteRecord(
            noteID: noteID, folderID: nil, title: "Original Title", body: "Local body", createdAt: date(1), modifiedAt: date(2)
        )
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165322"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165323"),
            createdAt: date(3),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Local body".utf16.count,
                    text: " more",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Local body")
                )),
                .noteLifecycleChanged(.init(
                    noteID: noteID,
                    deletedAt: date(3),
                    modifiedAt: date(3),
                    title: "Original Title",
                    body: "Local body more",
                    // Matches the note's state *after* the body edit in this same batch applies,
                    // so this is a non-conflicting delete: it should win presentation routing.
                    baseTitleHash: SyncBatchContentHash.sha256Hex(for: "Original Title"),
                    baseBodyHash: SyncBatchContentHash.sha256Hex(for: "Local body more")
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: batch,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: initial.title, body: initial.body, createdAt: initial.createdAt, modifiedAt: initial.modifiedAt)]
        ))
        guard case .planned(let input) = outcome else {
            return XCTFail("Expected non-blocking compound plan, got \(outcome)")
        }
        // A delete that actually applies must win over the body effect's own .incremental want —
        // the note is being deleted, so the editor must close rather than receive more content.
        XCTAssertEqual(input.plan.presentationPlan.noteRoutings[noteID], .noteRemoved)

        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initial])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: input, transaction: transaction, committedAt: date(4)
        )

        guard case .incorporated = incorporation else {
            return XCTFail("Expected compound plan to be incorporated, got \(incorporation)")
        }
        XCTAssertEqual(transaction.notes[noteID]?.deletedAt, date(3))
        XCTAssertEqual(transaction.notes[noteID]?.body, "Local body more")
        XCTAssertEqual(transaction.notes[noteID]?.title, "Original Title")
    }

    func testLifecycleDeleteAndRestorePersistThroughConvergence() {
        let noteID = uuid("00000000-0000-0000-0000-000000165001")
        let title = "Title"
        let body = "Body"
        let initial = SyncConvergenceMutableNoteRecord(
            noteID: noteID, folderID: nil, title: title, body: body, createdAt: date(1), modifiedAt: date(1)
        )
        let delete = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165002"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165003"),
            createdAt: date(2),
            changes: [.noteLifecycleChanged(.init(
                noteID: noteID, deletedAt: date(2), modifiedAt: date(2),
                baseTitleHash: SyncBatchContentHash.sha256Hex(for: title),
                baseBodyHash: SyncBatchContentHash.sha256Hex(for: body)
            ))]
        )
        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initial])
        let deleteOutcome = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: delete,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: title, body: body, createdAt: date(1), modifiedAt: date(1))]
        ))
        guard case .planned(let deleteInput) = deleteOutcome else {
            return XCTFail("Expected delete lifecycle plan, got \(deleteOutcome)")
        }
        let deleteIncorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: deleteInput, transaction: transaction, committedAt: date(3)
        )
        guard case .incorporated = deleteIncorporation else {
            return XCTFail("Expected delete lifecycle incorporation, got \(deleteIncorporation)")
        }
        XCTAssertEqual(transaction.notes[noteID]?.deletedAt, date(2))

        let restore = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000165004"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000165003"),
            createdAt: date(4),
            changes: [.noteLifecycleChanged(.init(
                noteID: noteID, deletedAt: nil, modifiedAt: date(4),
                baseTitleHash: SyncBatchContentHash.sha256Hex(for: title),
                baseBodyHash: SyncBatchContentHash.sha256Hex(for: body)
            ))]
        )
        guard case .planned(let restoreInput) = SyncConvergencePlanner().plan(input: .init(
            incomingBatch: restore,
            currentNotes: [.init(noteID: noteID, folderID: nil, title: title, body: body, createdAt: date(1), modifiedAt: date(2))]
        )), case .incorporated = SyncConvergenceIncorporationExecutor().incorporate(
            input: restoreInput, transaction: transaction, committedAt: date(5)
        ) else { return XCTFail("Expected restore lifecycle incorporation") }
        XCTAssertNil(transaction.notes[noteID]?.deletedAt)
    }

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

    func testMYR158SwiftDataTransactionPersistsPostCommitIndexMatrix() throws {
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        let cases: [(String, SyncConvergencePostCommitState)] = [
            (
                "queue cleanup only",
                SyncConvergencePostCommitState(
                    queueCleanupPending: true,
                    legacyCleanupPending: false,
                    presentationRefreshPending: false
                )
            ),
            (
                "presentation refresh only",
                SyncConvergencePostCommitState(
                    queueCleanupPending: false,
                    legacyCleanupPending: false,
                    presentationRefreshPending: true
                )
            ),
            (
                "multiple pending domains",
                SyncConvergencePostCommitState(
                    queueCleanupPending: true,
                    legacyCleanupPending: true,
                    presentationRefreshPending: true
                )
            ),
            ("no post-commit work", .none)
        ]

        for (index, testCase) in cases.enumerated() {
            let batchID = uuid(String(format: "00000000-0000-0000-0000-%012d", 158200 + index))
            let record = try myr158IncorporatedRecord(
                batchID: batchID,
                index: 200 + index,
                state: testCase.1
            )

            try transaction.insertIncorporatedBatch(record)

            let root = try XCTUnwrap(try transaction.loadIncorporatedBatch(batchID: batchID), testCase.0)
            let persisted = try XCTUnwrap(try fetchIncorporatedBatch(batchID: batchID, in: context), testCase.0)
            let decodedState = try SyncConvergencePostCommitState.decodePayloadData(root.postCommitStatePayloadData)
            XCTAssertEqual(decodedState, testCase.1, testCase.0)
            XCTAssertEqual(persisted.hasPendingPostCommitWork, testCase.1.hasPendingWork, testCase.0)
            let workPayload = try XCTUnwrap(root.postCommitWorkPayloadData, testCase.0)
            let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(workPayload)
            try work.validateCurrentState(decodedState)
        }
    }

    func testMYR158SwiftDataTransactionRejectsMalformedPostCommitStateAsInvalidMergePlan() throws {
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: ModelContext(container))
        var record = try myr158IncorporatedRecord(
            batchID: uuid("00000000-0000-0000-0000-000000158299"),
            index: 299,
            state: SyncConvergencePostCommitState.none
        )
        record = SyncConvergenceIncorporatedBatchRecord(
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
            affectedNotesPayloadData: record.affectedNotesPayloadData,
            authoritativeChildCount: record.authoritativeChildCount,
            authoritativeChildBytes: record.authoritativeChildBytes,
            authoritativeChildrenDigest: record.authoritativeChildrenDigest,
            postCommitWorkPayloadData: record.postCommitWorkPayloadData,
            postCommitStatePayloadData: Data([0xde, 0xad, 0xbe, 0xef]),
            hasPendingPostCommitWork: false
        )

        XCTAssertThrowsError(try transaction.insertIncorporatedBatch(record)) { error in
            XCTAssertEqual(error as? SyncConvergenceTransactionFailure, .invalidMergePlan(noteID: nil))
        }
    }

    func testSwiftDataTransactionRejectsContradictoryPostCommitIndex() throws {
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: ModelContext(container))
        let batchID = uuid("00000000-0000-0000-0000-000000158101")
        let committedAt = date(158)
        let record = SyncConvergenceIncorporatedBatchRecord(
            batchID: batchID,
            originDeviceID: uuid("00000000-0000-0000-0000-000000158102"),
            createdAt: date(157),
            batchSequence: 158,
            schemaVersion: 1,
            committedAt: committedAt,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: try SyncConvergenceAffectedNotesPayloadV1(noteIDs: []).encodedData(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitWorkPayloadData: nil,
            postCommitStatePayloadData: try SyncConvergencePostCommitState.none.encodedPayloadData(),
            hasPendingPostCommitWork: true
        )

        XCTAssertThrowsError(try transaction.insertIncorporatedBatch(record)) { error in
            XCTAssertEqual(error as? SyncConvergenceTransactionFailure, .invalidMergePlan(noteID: nil))
        }
    }

    func testAllIdempotentRetainedBodyDeliveryPersistsWithoutPresentationWork() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132c70")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132c71"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132c72"),
            createdAt: date(3),
            batchSequence: 70,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                ))
            ]
        )
        let retained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "B",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
            )
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "AB",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Title",
                body: "AB",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            retainedRemoteOperations: [retained]
        )
        let outcome = SyncConvergencePlanner().plan(input: input)
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected all-idempotent plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [noteID: initialNote])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: date(5)
        )

        guard case .incorporated = incorporation,
              let root = transaction.roots[batch.id] else {
            return XCTFail("Expected all-idempotent incorporation, got \(incorporation)")
        }
        let state = try SyncConvergenceStableEncoding.decode(
            SyncConvergencePostCommitState.self,
            from: root.postCommitStatePayloadData
        )
        let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(root.postCommitWorkPayloadData!)
        XCTAssertTrue(state.presentationRefreshPending)
        XCTAssertFalse(state.legacyCleanupPending)
        let entry = try XCTUnwrap(work.presentationEntries.first)
        XCTAssertEqual(work.presentationEntries.map(\.noteID), [noteID])
        XCTAssertEqual(entry.routing, .none)
        XCTAssertTrue(entry.incrementalOperations.isEmpty)
        XCTAssertEqual(entry.committedPostBodyHash, String(repeating: "0", count: 64))
        XCTAssertEqual(work.derivedInitialState(), state)
        let reencodedWork = try work.encodedPayloadData()
        XCTAssertEqual(reencodedWork, root.postCommitWorkPayloadData)
        XCTAssertEqual(sha256Hex(reencodedWork), "4a6413d5e7022768128f4d04368b5d1a3b78cb023d9725d0844283646081f63f")
    }

    func testCreatePlusBodyUsesFinalBodyHashForPresentationWork() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132c80")
        let creationBody = "A"
        let finalBody = "AB"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132c81"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132c82"),
            createdAt: date(3),
            batchSequence: 80,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: creationBody,
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: creationBody)
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected create-plus-body plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [:])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: date(5)
        )

        guard case .incorporated = incorporation,
              let root = transaction.roots[batch.id] else {
            return XCTFail("Expected create-plus-body incorporation, got \(incorporation)")
        }
        let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(root.postCommitWorkPayloadData!)
        let entry = try XCTUnwrap(work.presentationEntries.first)
        let finalHash = SyncBatchContentHash.sha256Hex(for: finalBody)
        XCTAssertEqual(transaction.notes[noteID]?.body, finalBody)
        XCTAssertEqual(entry.committedPostBodyHash, finalHash)
        XCTAssertEqual(entry.incrementalOperations.last?.resultContentHash, finalHash)
        XCTAssertNotEqual(entry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: creationBody))
    }

    func testCreatePlusDeleteUsesFinalBodyHashForPresentationWork() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132c90")
        let creationBody = "ABC"
        let finalBody = "AC"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132c91"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132c92"),
            createdAt: date(3),
            batchSequence: 81,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: creationBody,
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    utf16Length: 1,
                    expectedText: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: creationBody)
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected create-plus-delete plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [:])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: date(5)
        )

        guard case .incorporated = incorporation,
              let root = transaction.roots[batch.id] else {
            return XCTFail("Expected create-plus-delete incorporation, got \(incorporation)")
        }
        let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(root.postCommitWorkPayloadData!)
        let entry = try XCTUnwrap(work.presentationEntries.first)
        let finalHash = SyncBatchContentHash.sha256Hex(for: finalBody)
        XCTAssertEqual(transaction.notes[noteID]?.body, finalBody)
        XCTAssertEqual(entry.committedPostBodyHash, finalHash)
        XCTAssertEqual(entry.incrementalOperations.last?.resultContentHash, finalHash)
        XCTAssertEqual(entry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: creationBody))
    }

    func testCreatePlusBodyRollsBackEntirelyOnStagedFailure() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132ca0")
        let creationBody = "A"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132ca1"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132ca2"),
            createdAt: date(3),
            batchSequence: 82,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: creationBody,
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: creationBody)
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(incomingBatch: batch))
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected create-plus-body plan, got \(outcome)")
        }

        let transaction = InMemoryConvergenceTransaction(notes: [:])
        transaction.failAfterUpdateNote = true

        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: date(5)
        )

        XCTAssertEqual(incorporation, .failedAndRolledBack(.swiftDataSave))
        XCTAssertNil(transaction.notes[noteID])
        XCTAssertNil(transaction.roots[batch.id])
        XCTAssertTrue(transaction.rollbackCalled)
        XCTAssertFalse(transaction.saveCalled)
        XCTAssertEqual(transaction.operationIdentityInsertCount, 0)
        XCTAssertEqual(transaction.noteEffectInsertCount, 0)
        XCTAssertEqual(transaction.resultEvidenceInsertCount, 0)
    }

    func testDeletedIdempotentCreationNoteFailsStaleAndIsNotRecreated() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132cb0")
        let origin = uuid("00000000-0000-0000-0000-000000132cb1")
        let batchID = uuid("00000000-0000-0000-0000-000000132cb2")
        let creationBody = "A"
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: date(3),
            batchSequence: 83,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: creationBody,
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: creationBody)
                ))
            ]
        )
        // The creation is already reflected in `currentNotes`, so the planner
        // classifies it `.idempotent`; the body operation still plans as a fresh
        // incremental effect building on the already-created content.
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Created",
                body: creationBody,
                createdAt: date(1),
                modifiedAt: date(2)
            )]
        ))
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected idempotent-creation-plus-body plan, got \(outcome)")
        }
        guard let notePlan = validatedInput.plan.affectedNotePlans.first(where: { $0.noteID == noteID }),
              notePlan.creationEffect?.verdict == .idempotent else {
            return XCTFail("Expected idempotent creation effect in plan")
        }

        // The note was deleted after planning but before incorporation.
        let transaction = InMemoryConvergenceTransaction(notes: [:])
        let incorporation = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: date(5)
        )

        XCTAssertEqual(incorporation, .failedBeforeCommit(.staleAuthoritativeState(noteID: noteID)))
        XCTAssertNil(transaction.notes[noteID])
        assertNoPreflightMutation(transaction, "deleted idempotent-creation note")
    }

    func testMalformedCreationBodyPreStateFailsBeforeCommit() throws {
        let noteID = uuid("00000000-0000-0000-0000-000000132cc0")
        let creationBody = "A"
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000132cc1"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000132cc2"),
            createdAt: date(3),
            batchSequence: 84,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: creationBody,
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: creationBody)
                ))
            ]
        )
        let planningInput = SyncConvergencePlanningInput(incomingBatch: batch)
        let outcome = SyncConvergencePlanner().plan(input: planningInput)
        guard case .planned(let validatedInput) = outcome else {
            return XCTFail("Expected create-plus-body plan, got \(outcome)")
        }
        let plan = validatedInput.plan
        guard let noteIndex = plan.affectedNotePlans.firstIndex(where: { $0.noteID == noteID }),
              case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[noteIndex].bodyEffect else {
            return XCTFail("Expected matching-base body effect")
        }

        // Disagree with the creation body while staying internally consistent
        // everywhere else (initialBodyHash still hashes initialBody, and the
        // result-evidence preHash is updated to match), so only the dedicated
        // creation/body agreement check can reject this — not any of the
        // pre-existing internal hash-consistency checks.
        let disagreeingInitialBody = "Z"
        let disagreeingInitialBodyHash = SyncBatchContentHash.sha256Hex(for: disagreeingInitialBody)
        let malformedResultEvidence = SyncConvergenceResultEvidence(
            batchID: bodyPlan.resultEvidence.batchID,
            noteID: bodyPlan.resultEvidence.noteID,
            kind: bodyPlan.resultEvidence.kind,
            preHash: disagreeingInitialBodyHash,
            postHash: bodyPlan.resultEvidence.postHash,
            canonicalReplayKey: bodyPlan.resultEvidence.canonicalReplayKey
        )
        let malformedBodyPlan = MatchingBaseBodyPlan(
            noteID: bodyPlan.noteID,
            initialBody: disagreeingInitialBody,
            initialBodyHash: disagreeingInitialBodyHash,
            operations: bodyPlan.operations,
            finalBody: bodyPlan.finalBody,
            finalBodyHash: bodyPlan.finalBodyHash,
            resultEvidence: malformedResultEvidence
        )
        var malformedNotePlans = plan.affectedNotePlans
        malformedNotePlans[noteIndex] = SyncConvergenceNotePlan(
            noteID: noteID,
            creationEffect: plan.affectedNotePlans[noteIndex].creationEffect,
            bodyEffect: .matchingBaseIncremental(malformedBodyPlan),
            titleEffect: plan.affectedNotePlans[noteIndex].titleEffect
        )
        let malformedResultEvidenceList = plan.incorporationEvidence.resultEvidence.map { evidence in
            evidence.kind == .body && evidence.noteID == noteID ? malformedResultEvidence : evidence
        }
        let malformedPlan = SyncConvergenceBatchPlan(
            batchID: plan.batchID,
            originDeviceID: plan.originDeviceID,
            canonicalPayloadDigest: plan.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: plan.canonicalPayloadDigestFormatVersion,
            affectedNotePlans: malformedNotePlans,
            incorporationEvidence: SyncConvergenceIncorporationPlan(
                operationIdentities: plan.incorporationEvidence.operationIdentities,
                resultEvidence: malformedResultEvidenceList
            ),
            historyPlan: plan.historyPlan,
            cleanupPlan: plan.cleanupPlan,
            presentationPlan: plan.presentationPlan
        )

        // Recomputed for the malformed (but internally re-consistent) evidence so the
        // trailing whole-plan byte-count recompute cannot be what rejects this plan —
        // only the dedicated creation/body agreement check should fire.
        let malformedProjectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: batch,
            affectedNoteIDs: Set(malformedPlan.affectedNotePlans.map(\.noteID)),
            operationIdentities: malformedPlan.incorporationEvidence.operationIdentities,
            resultEvidence: malformedPlan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()

        let queueSelection = SyncConvergenceEvidenceSelector().selectQueuedBatches(for: batch, queuedBatches: [])
        let result = SyncConvergencePlanValidator().validate(
            malformedPlan,
            input: planningInput,
            queueSelection: queueSelection,
            projectedFullIncorporationEvidenceBytes: malformedProjectedBytes
        )

        XCTAssertEqual(result, .failedBeforeCommit(.invalidMergePlan(noteID: noteID)))
    }

    func testSwappedOperationIdentityAcrossNotesFailsBeforeCommit() throws {
        let fixture = try makeTwoNoteSwappableFixture()
        let plan = fixture.validatedInput.plan
        let swappedPlan = fixture.swappedValidatedInput.plan
        let originalIdentityA = try operationIdentity(for: fixture.noteA, in: plan)
        let originalIdentityB = try operationIdentity(for: fixture.noteB, in: plan)
        let swappedIdentityA = try operationIdentity(for: fixture.noteA, in: swappedPlan)
        let swappedIdentityB = try operationIdentity(for: fixture.noteB, in: swappedPlan)

        XCTAssertNoThrow(try swappedIdentityA.validate())
        XCTAssertNoThrow(try swappedIdentityB.validate())
        XCTAssertEqual(swappedIdentityA.operationKind, swappedIdentityB.operationKind)
        XCTAssertEqual(swappedIdentityA, originalIdentityB)
        XCTAssertEqual(swappedIdentityB, originalIdentityA)
        XCTAssertEqual(
            try noteIDResolvingReplayKey(swappedIdentityA.canonicalReplayKey, in: plan),
            fixture.noteB
        )
        XCTAssertEqual(
            try noteIDResolvingReplayKey(swappedIdentityB.canonicalReplayKey, in: plan),
            fixture.noteA
        )
        XCTAssertNotEqual(try noteIDResolvingReplayKey(swappedIdentityA.canonicalReplayKey, in: plan), fixture.noteA)
        XCTAssertNotEqual(try noteIDResolvingReplayKey(swappedIdentityB.canonicalReplayKey, in: plan), fixture.noteB)

        let malformedOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.swappedValidatedInput,
            transaction: fixture.transaction,
            committedAt: fixture.committedAt
        )

        let expectedFailingNoteID = [fixture.noteA, fixture.noteB]
            .sorted { $0.uuidString < $1.uuidString }
            .first!
        XCTAssertEqual(malformedOutcome, .failedBeforeCommit(.invalidMergePlan(noteID: expectedFailingNoteID)))
        XCTAssertEqual(fixture.transaction.notes[fixture.noteA]?.body, "A")
        XCTAssertEqual(fixture.transaction.notes[fixture.noteB]?.body, "X")
        assertNoPreflightMutation(fixture.transaction, "swapped operation identity")
    }

    func testTwoNoteExactOwnershipIncorporatesSuccessfully() throws {
        let fixture = try makeTwoNoteSwappableFixture()

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: fixture.transaction,
            committedAt: fixture.committedAt
        )

        guard case .incorporated = outcome else {
            return XCTFail("Expected exact-ownership two-note incorporation, got \(outcome)")
        }
        XCTAssertEqual(fixture.transaction.notes[fixture.noteA]?.body, "AB")
        XCTAssertEqual(fixture.transaction.notes[fixture.noteB]?.body, "XY")
        let root = try XCTUnwrap(fixture.transaction.roots[fixture.batchID])
        let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(root.postCommitWorkPayloadData!)

        let persistedIdentities = fixture.transaction.children[fixture.batchID]?.operationIdentities ?? []
        XCTAssertEqual(persistedIdentities.count, 2)
        XCTAssertEqual(work.presentationEntries.count, 2)
        XCTAssertEqual(
            work.presentationEntries.map(\.noteID).sorted { $0.uuidString < $1.uuidString },
            [fixture.noteA, fixture.noteB].sorted { $0.uuidString < $1.uuidString }
        )

        for noteID in [fixture.noteA, fixture.noteB] {
            let plannedIdentity = try operationIdentity(for: noteID, in: fixture.validatedInput.plan)
            let persistedRowsForNote = persistedIdentities.filter { $0.noteID == noteID }
            XCTAssertEqual(persistedRowsForNote.count, 1)
            let persistedRow = try XCTUnwrap(persistedRowsForNote.first)

            let workEntriesForNote = work.presentationEntries.filter { $0.noteID == noteID }
            XCTAssertEqual(workEntriesForNote.count, 1)
            let workEntry = try XCTUnwrap(workEntriesForNote.first)

            XCTAssertEqual(workEntry.incrementalOperations.count, 1)
            let workOperation = try XCTUnwrap(workEntry.incrementalOperations.first)

            XCTAssertEqual(persistedRow.noteID, noteID)
            XCTAssertEqual(persistedRow.operationIdentity, plannedIdentity)
            XCTAssertEqual(workEntry.noteID, noteID)
            XCTAssertEqual(workOperation.operationIdentity, plannedIdentity)
            XCTAssertFalse(persistedIdentities.contains { $0.noteID != noteID && $0.operationIdentity == plannedIdentity })
            XCTAssertFalse(work.presentationEntries.contains { $0.noteID != noteID && $0.incrementalOperations.contains { $0.operationIdentity == plannedIdentity } })
        }
    }

    private func operationIdentity(
        for noteID: UUID,
        in plan: SyncConvergenceBatchPlan
    ) throws -> OperationIdentityPayload {
        let notePlan = try XCTUnwrap(plan.affectedNotePlans.first { $0.noteID == noteID })
        guard case .matchingBaseIncremental(let bodyPlan) = notePlan.bodyEffect,
              let identity = bodyPlan.operations.first?.operationIdentity else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return identity
    }

    private func noteIDResolvingReplayKey(
        _ replayKey: CanonicalReplayKeyPayload,
        in plan: SyncConvergenceBatchPlan
    ) throws -> UUID {
        let matches = plan.affectedNotePlans.compactMap { notePlan -> UUID? in
            guard case .matchingBaseIncremental(let bodyPlan) = notePlan.bodyEffect else {
                return nil
            }
            return bodyPlan.operations.contains { $0.operationIdentity.canonicalReplayKey == replayKey }
                ? notePlan.noteID
                : nil
        }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    // MARK: - MYR-134 Planner and Routed-Note Verification

    func testMYR134RealPlannerShapeMatrixPersistsExpectedRoutedWork() throws {
        let incremental = try makeTwoOperationFixture()
        let incrementalResult = try planIncorporateAndDecode(
            input: incremental.planningInputForCurrentNotes(),
            notes: [incremental.noteID: incremental.initialNote],
            committedAt: incremental.committedAt,
            expectedRoutings: [incremental.noteID: .incremental]
        )
        let incrementalEntry = try XCTUnwrap(incrementalResult.work.presentationEntries.first)
        XCTAssertEqual(incrementalResult.work.presentationEntries.map(\.noteID), [incremental.noteID])
        XCTAssertEqual(incrementalEntry.routing, .incremental)
        XCTAssertEqual(incrementalEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "A"))
        XCTAssertEqual(incrementalEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "ABC"))
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.noteID), [incremental.noteID, incremental.noteID])
        assertHashChain(incrementalEntry)

        let idempotent = try makeAllIdempotentBodyFixture()
        let idempotentResult = try planIncorporateAndDecode(
            input: idempotent.input,
            notes: [idempotent.noteID: idempotent.initialNote],
            committedAt: idempotent.committedAt,
            expectedRoutings: [idempotent.noteID: .none]
        )
        let idempotentEntry = try XCTUnwrap(idempotentResult.work.presentationEntries.first)
        XCTAssertEqual(idempotentEntry.routing, .none)
        XCTAssertTrue(idempotentResult.state.presentationRefreshPending)

        let mixedExecutable = try makeMixedIdempotentAndExecutableFixture()
        let mixedExecutableResult = try planIncorporateAndDecode(
            input: mixedExecutable.input,
            notes: [mixedExecutable.noteID: mixedExecutable.initialNote],
            committedAt: mixedExecutable.committedAt,
            expectedRoutings: [mixedExecutable.noteID: .incremental]
        )
        let executableEntry = try XCTUnwrap(mixedExecutableResult.work.presentationEntries.first)
        XCTAssertEqual(executableEntry.incrementalOperations.map(\.operationIndex), [1])
        XCTAssertEqual(executableEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "ABC"))

        let matchingBase = try makeMatchingBasePositionalFixture()
        let legacyResult = try planIncorporateAndDecode(
            input: matchingBase.input,
            notes: [matchingBase.noteID: matchingBase.initialNote],
            committedAt: matchingBase.committedAt,
            expectedRoutings: [matchingBase.noteID: .incremental]
        )
        let legacyEntry = try XCTUnwrap(legacyResult.work.presentationEntries.first)
        XCTAssertEqual(legacyEntry.routing, .incremental)
        XCTAssertEqual(legacyEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "abc"))
        XCTAssertEqual(legacyEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "bcd"))
        XCTAssertEqual(legacyEntry.incrementalOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(legacyEntry.incrementalOperations[0].baseContentHash, SyncBatchContentHash.sha256Hex(for: "abc"))
        XCTAssertEqual(legacyEntry.incrementalOperations[0].resultContentHash, SyncBatchContentHash.sha256Hex(for: "bc"))
        XCTAssertEqual(legacyEntry.incrementalOperations[1].baseContentHash, SyncBatchContentHash.sha256Hex(for: "bc"))
        XCTAssertEqual(legacyEntry.incrementalOperations[1].resultContentHash, SyncBatchContentHash.sha256Hex(for: "bcd"))
        assertHashChain(legacyEntry)

        let creationOnly = try makeCreationOnlyFixture(existing: false)
        let creationOnlyResult = try planIncorporateAndDecode(
            input: creationOnly.input,
            notes: [:],
            committedAt: creationOnly.committedAt,
            expectedRoutings: [creationOnly.noteID: .none]
        )
        let creationOnlyEntry = try XCTUnwrap(creationOnlyResult.work.presentationEntries.first)
        XCTAssertEqual(creationOnlyEntry.routing, .none)
        XCTAssertTrue(creationOnlyEntry.incrementalOperations.isEmpty)

        let creationIdempotent = try makeCreationOnlyFixture(existing: true)
        let creationIdempotentResult = try planIncorporateAndDecode(
            input: creationIdempotent.input,
            notes: [creationIdempotent.noteID: creationIdempotent.initialNote],
            committedAt: creationIdempotent.committedAt,
            expectedRoutings: [creationIdempotent.noteID: .none]
        )
        let creationIdempotentEntry = try XCTUnwrap(creationIdempotentResult.work.presentationEntries.first)
        XCTAssertEqual(creationIdempotentEntry.routing, .none)
        XCTAssertTrue(creationIdempotentEntry.incrementalOperations.isEmpty)

        let createPlusBody = try makeCreatePlusBodyFixture(existingCreation: false)
        let createPlusBodyResult = try planIncorporateAndDecode(
            input: createPlusBody.input,
            notes: [:],
            committedAt: createPlusBody.committedAt,
            expectedRoutings: [createPlusBody.noteID: .incremental]
        )
        let createPlusBodyEntry = try XCTUnwrap(createPlusBodyResult.work.presentationEntries.first)
        XCTAssertEqual(createPlusBodyEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "A"))
        XCTAssertEqual(createPlusBodyEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "AB"))

        let idempotentCreatePlusBody = try makeCreatePlusBodyFixture(existingCreation: true)
        let idempotentCreatePlusBodyResult = try planIncorporateAndDecode(
            input: idempotentCreatePlusBody.input,
            notes: [idempotentCreatePlusBody.noteID: idempotentCreatePlusBody.initialNote],
            committedAt: idempotentCreatePlusBody.committedAt,
            expectedRoutings: [idempotentCreatePlusBody.noteID: .incremental]
        )
        let idempotentCreatePlusBodyEntry = try XCTUnwrap(idempotentCreatePlusBodyResult.work.presentationEntries.first)
        XCTAssertEqual(idempotentCreatePlusBodyEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "A"))
        XCTAssertEqual(idempotentCreatePlusBodyEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "AB"))

        let titleOnly = try makeTitleOnlyApplyFixture()
        let titleOnlyResult = try planIncorporateAndDecode(
            input: titleOnly.input,
            notes: [titleOnly.noteID: titleOnly.initialNote],
            committedAt: titleOnly.committedAt,
            expectedRoutings: [titleOnly.noteID: .none]
        )
        let titleOnlyEntry = try XCTUnwrap(titleOnlyResult.work.presentationEntries.first)
        XCTAssertEqual(titleOnlyEntry.routing, .none)
        XCTAssertTrue(titleOnlyEntry.incrementalOperations.isEmpty)

        let reconstructed = try makeReconstructedSnapshotFixture()
        let reconstructedResult = try planIncorporateAndDecode(
            input: reconstructed.input,
            notes: [reconstructed.noteID: reconstructed.initialNote],
            committedAt: reconstructed.committedAt,
            expectedRoutings: [reconstructed.noteID: .wholeNoteFallback]
        )
        let fallbackEntry = try XCTUnwrap(reconstructedResult.work.presentationEntries.first)
        XCTAssertEqual(fallbackEntry.routing, .wholeNoteFallback)
        XCTAssertTrue(fallbackEntry.incrementalOperations.isEmpty)
        XCTAssertEqual(fallbackEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "AxB"))

        let missingBody = try makeCompatibilityMissingBodyFixture()
        let missingBodyResult = try planIncorporateAndDecode(
            input: missingBody.input,
            notes: [:],
            committedAt: missingBody.committedAt,
            expectedRoutings: [missingBody.noteID: .none]
        )
        let missingBodyEntry = try XCTUnwrap(missingBodyResult.work.presentationEntries.first)
        XCTAssertEqual(missingBodyEntry.routing, .none)
        XCTAssertTrue(missingBodyEntry.incrementalOperations.isEmpty)

        let missingTitle = try makeMissingTitleFixture()
        let missingTitleResult = try planIncorporateAndDecode(
            input: missingTitle.validatedInput.planningInputForSourceOnly(),
            notes: [:],
            committedAt: missingTitle.committedAt,
            expectedRoutings: [:]
        )
        XCTAssertTrue(missingTitleResult.work.presentationEntries.isEmpty)
    }

    func testMYR134MixedRoutingsPersistAllEntriesInDeterministicOrder() throws {
        let fixture = try makeMYR134MixedRoutingFixture()
        let result = try planIncorporateAndDecode(
            input: fixture.input,
            notes: fixture.initialNotes,
            committedAt: fixture.committedAt,
            expectedRoutings: [
                fixture.noneNote: .none,
                fixture.incrementalNote: .incremental,
                fixture.fallbackNote: .wholeNoteFallback
            ]
        )

        XCTAssertEqual(
            result.validatedInput.plan.affectedNotePlans.map(\.noteID),
            result.validatedInput.plan.affectedNotePlans.map(\.noteID).sortedByUUIDStringForTest()
        )
        XCTAssertEqual(
            result.work.presentationEntries.map(\.noteID),
            [fixture.noneNote, fixture.incrementalNote, fixture.fallbackNote].sortedByUUIDStringForTest()
        )
        XCTAssertTrue(result.state.presentationRefreshPending)

        let noneEntry = try XCTUnwrap(
            result.work.presentationEntries.first { $0.noteID == fixture.noneNote }
        )
        XCTAssertEqual(noneEntry.routing, .none)
        XCTAssertTrue(noneEntry.incrementalOperations.isEmpty)

        let incrementalEntry = try XCTUnwrap(
            result.work.presentationEntries.first { $0.noteID == fixture.incrementalNote }
        )
        XCTAssertEqual(incrementalEntry.routing, .incremental)
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIndex), [1, 3])
        XCTAssertEqual(
            incrementalEntry.incrementalOperations.map(\.operationIdentity.operationIndex),
            incrementalEntry.incrementalOperations.map(\.operationIndex)
        )
        assertHashChain(incrementalEntry)

        let fallbackEntry = try XCTUnwrap(
            result.work.presentationEntries.first { $0.noteID == fixture.fallbackNote }
        )
        XCTAssertEqual(fallbackEntry.routing, .wholeNoteFallback)
        XCTAssertTrue(fallbackEntry.incrementalOperations.isEmpty)
    }

    func testReconstructedConflictMissingRewriteReceiptFailsBeforeMutation() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let validated = fixture.validatedInput
        let malformedPlan = try validated.plan.replacingBodyEffect(for: fixture.noteID) { effect in
            guard case .reconstructedConflict(let bodyPlan) = effect else {
                throw TestFixtureError.unexpectedPlanningOutcome
            }
            return .reconstructedConflict(ReconstructedConflictBodyPlan(
                noteID: bodyPlan.noteID,
                reconstructedBaseBody: bodyPlan.reconstructedBaseBody,
                reconstructedBaseHash: bodyPlan.reconstructedBaseHash,
                projectedPreMergeCurrentBody: bodyPlan.projectedPreMergeCurrentBody,
                projectedPreMergeCurrentHash: bodyPlan.projectedPreMergeCurrentHash,
                orderedOperationIdentities: bodyPlan.orderedOperationIdentities,
                finalBody: bodyPlan.finalBody,
                finalBodyHash: bodyPlan.finalBodyHash,
                retainedOperationAdditions: bodyPlan.retainedOperationAdditions,
                mergedOperations: bodyPlan.mergedOperations,
                snapshotAdditions: bodyPlan.snapshotAdditions,
                resultEvidence: bodyPlan.resultEvidence,
                presentationRouting: bodyPlan.presentationRouting,
                rewriteSafetyReceipt: nil
            ))
        }
        let malformedInput = try validated.replacingPlanForTesting(malformedPlan)
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.noteID: fixture.initialNote])

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: malformedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.unprovenTextLoss(noteID: fixture.noteID)))
        XCTAssertEqual(transaction.notes[fixture.noteID], fixture.initialNote)
    }

    func testReconstructedConflictCrossNoteDeleteEvidenceFailsBeforeMutation() throws {
        let fixture = try makeReconstructedSnapshotFixture()
        let noteB = uuid("00000000-0000-0000-0000-0000001330b2")
        let wrongNoteDelete = retainedDelete(
            noteID: noteB,
            batchID: uuid("00000000-0000-0000-0000-0000001334b2"),
            originDeviceID: uuid("00000000-0000-0000-0000-0000001334b3"),
            operationIndex: 0,
            offset: 1,
            length: 1,
            expectedText: "C",
            modifiedAt: date(3),
            baseBody: "ACB",
            resultHash: SyncBatchContentHash.sha256Hex(for: "AB")
        )
        let wrongNoteOperation = SyncConvergencePlannedBodyOperation(
            noteID: noteB,
            kind: .delete,
            utf16Offset: wrongNoteDelete.utf16Offset,
            utf16Length: wrongNoteDelete.utf16Length,
            text: wrongNoteDelete.text,
            expectedText: wrongNoteDelete.expectedText,
            baseContentHash: wrongNoteDelete.baseContentHash,
            resultContentHash: try XCTUnwrap(wrongNoteDelete.resultContentHash),
            operationIdentity: OperationIdentityPayload(
                batchID: wrongNoteDelete.batchID,
                originDeviceID: wrongNoteDelete.originDeviceID,
                operationIndex: wrongNoteDelete.operationIndex,
                operationKind: wrongNoteDelete.operationKind.rawValue,
                canonicalReplayKey: wrongNoteDelete.canonicalReplayKey
            )
        )
        var malformedRetainedOperations: [SyncConvergencePlannedBodyOperation] = []
        let malformedBodyPlan = try fixture.validatedInput.plan.replacingBodyEffect(for: fixture.noteID) { effect in
            guard case .reconstructedConflict(let bodyPlan) = effect else {
                throw TestFixtureError.unexpectedPlanningOutcome
            }
            malformedRetainedOperations = bodyPlan.retainedOperationAdditions.map { operation in
                operation.kind == .delete ? wrongNoteOperation : operation
            }
            // The fixture's only delete is an already-retained remote operation, so
            // it's absent from retainedOperationAdditions (only genuinely-new
            // operations are persisted there) but present in mergedOperations, which
            // is what verifyBodyPrecondition now reads to reconstruct delete
            // evidence — the malformed substitution must target that list too.
            let malformedMergedOperations = bodyPlan.mergedOperations.map { operation in
                operation.kind == .delete ? wrongNoteOperation : operation
            }
            return .reconstructedConflict(ReconstructedConflictBodyPlan(
                noteID: bodyPlan.noteID,
                reconstructedBaseBody: bodyPlan.reconstructedBaseBody,
                reconstructedBaseHash: bodyPlan.reconstructedBaseHash,
                projectedPreMergeCurrentBody: bodyPlan.projectedPreMergeCurrentBody,
                projectedPreMergeCurrentHash: bodyPlan.projectedPreMergeCurrentHash,
                orderedOperationIdentities: bodyPlan.orderedOperationIdentities,
                finalBody: bodyPlan.finalBody,
                finalBodyHash: bodyPlan.finalBodyHash,
                retainedOperationAdditions: malformedRetainedOperations,
                mergedOperations: malformedMergedOperations,
                snapshotAdditions: bodyPlan.snapshotAdditions,
                resultEvidence: bodyPlan.resultEvidence,
                presentationRouting: bodyPlan.presentationRouting,
                rewriteSafetyReceipt: bodyPlan.rewriteSafetyReceipt
            ))
        }
        let malformedPlan = malformedBodyPlan.replacingHistoryRetainedOperations(malformedRetainedOperations)
        let malformedInput = try fixture.validatedInput.replacingPlanForTesting(malformedPlan)
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.noteID: fixture.initialNote])

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: malformedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(
            outcome,
            SyncConvergenceIncorporationOutcome.failedBeforeCommit(.unprovenTextLoss(noteID: fixture.noteID))
        )
        XCTAssertEqual(transaction.notes[fixture.noteID], fixture.initialNote)
    }

    func testMYR134RepeatedPlanningAndIncorporationProducesIdenticalWorkPayload() throws {
        let fixture = try makeMYR134MixedRoutingFixture()
        let first = try planIncorporateAndDecode(
            input: fixture.input,
            notes: fixture.initialNotes,
            committedAt: fixture.committedAt,
            expectedRoutings: [
                fixture.noneNote: .none,
                fixture.incrementalNote: .incremental,
                fixture.fallbackNote: .wholeNoteFallback
            ]
        )
        let second = try planIncorporateAndDecode(
            input: fixture.input,
            notes: fixture.initialNotes,
            committedAt: fixture.committedAt,
            expectedRoutings: [
                fixture.noneNote: .none,
                fixture.incrementalNote: .incremental,
                fixture.fallbackNote: .wholeNoteFallback
            ]
        )

        XCTAssertEqual(first.validatedInput.plan.affectedNotePlans, second.validatedInput.plan.affectedNotePlans)
        XCTAssertEqual(first.validatedInput.plan.presentationPlan, second.validatedInput.plan.presentationPlan)
        XCTAssertEqual(try first.work.encodedPayloadData(), try second.work.encodedPayloadData())
    }

    func testMYR134MalformedRoutedNoteConstructionFailsBeforeCommitWithoutMutation() throws {
        let mixed = try makeMYR134MixedRoutingFixture()
        let mixedValidated = try plannedInput(from: mixed.input)
        let incremental = try makeTwoOperationFixture()
        let incrementalValidated = try plannedInput(from: incremental.planningInputForCurrentNotes())
        let reconstructed = try makeReconstructedSnapshotFixture()
        let reconstructedValidated = reconstructed.validatedInput
        let titleOnly = try makeTitleOnlyApplyFixture()
        let titleOnlyValidated = try plannedInput(from: titleOnly.input)

        let cases: [MalformedPlanCase] = [
            MalformedPlanCase(
                name: "missing note plan with routing retained",
                base: mixedValidated,
                notes: mixed.initialNotes,
                committedAt: mixed.committedAt,
                expectedNoteID: mixed.incrementalNote,
                mutate: { plan in
                    plan.replacingNotePlans(plan.affectedNotePlans.filter { $0.noteID != mixed.incrementalNote })
                }
            ),
            MalformedPlanCase(
                name: "duplicate note plan inserted adjacent",
                base: mixedValidated,
                notes: mixed.initialNotes,
                committedAt: mixed.committedAt,
                expectedNoteID: mixed.incrementalNote,
                mutate: { plan in
                    var notePlans = plan.affectedNotePlans
                    let index = try XCTUnwrap(notePlans.firstIndex { $0.noteID == mixed.incrementalNote })
                    notePlans.insert(notePlans[index], at: index + 1)
                    return plan.replacingNotePlans(notePlans)
                }
            ),
            MalformedPlanCase(
                name: "incremental route with no executable operations",
                base: incrementalValidated,
                notes: [incremental.noteID: incremental.initialNote],
                committedAt: incremental.committedAt,
                expectedNoteID: incremental.noteID,
                mutate: { plan in
                    try plan.replacingBodyEffect(for: incremental.noteID) { bodyEffect in
                        guard case .matchingBaseIncremental(let bodyPlan) = bodyEffect else {
                            throw TestFixtureError.unexpectedPlanningOutcome
                        }
                        return .matchingBaseIncremental(MatchingBaseBodyPlan(
                            noteID: bodyPlan.noteID,
                            initialBody: bodyPlan.initialBody,
                            initialBodyHash: bodyPlan.initialBodyHash,
                            operations: [],
                            finalBody: bodyPlan.finalBody,
                            finalBodyHash: bodyPlan.finalBodyHash,
                            resultEvidence: bodyPlan.resultEvidence
                        ))
                    }.replacingHistoryRetainedOperations([])
                }
            ),
            MalformedPlanCase(
                name: "whole-note fallback route with incremental effect",
                base: incrementalValidated,
                notes: [incremental.noteID: incremental.initialNote],
                committedAt: incremental.committedAt,
                expectedNoteID: incremental.noteID,
                mutate: { plan in
                    plan.replacingRoutings([incremental.noteID: .wholeNoteFallback])
                }
            ),
            MalformedPlanCase(
                name: "incremental route for reconstructed conflict",
                base: reconstructedValidated,
                notes: [reconstructed.noteID: reconstructed.initialNote],
                committedAt: reconstructed.committedAt,
                expectedNoteID: reconstructed.noteID,
                mutate: { plan in
                    plan.replacingRoutings([reconstructed.noteID: .incremental])
                }
            ),
            MalformedPlanCase(
                name: "extraneous routing with no body effect",
                base: titleOnlyValidated,
                notes: [titleOnly.noteID: titleOnly.initialNote],
                committedAt: titleOnly.committedAt,
                expectedNoteID: titleOnly.noteID,
                mutate: { plan in
                    plan.replacingRoutings([titleOnly.noteID: .incremental])
                }
            )
        ]

        for testCase in cases {
            let malformedPlan = try testCase.mutate(testCase.base.plan)
            let malformedInput = try testCase.base.replacingPlanForTesting(malformedPlan)
            let transaction = InMemoryConvergenceTransaction(notes: testCase.notes)
            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: malformedInput,
                transaction: transaction,
                committedAt: testCase.committedAt
            )

            XCTAssertEqual(
                outcome,
                .failedBeforeCommit(.invalidMergePlan(noteID: testCase.expectedNoteID)),
                testCase.name
            )
            assertNoPreflightMutation(transaction, testCase.name)
        }

        let missingBaseHashPlan = try incrementalValidated.plan.replacingBodyEffect(for: incremental.noteID) { bodyEffect in
            guard case .matchingBaseIncremental(let bodyPlan) = bodyEffect,
                  let firstOperation = bodyPlan.operations.first else {
                throw TestFixtureError.unexpectedPlanningOutcome
            }
            let malformedOperation = SyncConvergencePlannedBodyOperation(
                noteID: firstOperation.noteID,
                kind: firstOperation.kind,
                utf16Offset: firstOperation.utf16Offset,
                utf16Length: firstOperation.utf16Length,
                text: firstOperation.text,
                expectedText: firstOperation.expectedText,
                baseContentHash: nil,
                resultContentHash: firstOperation.resultContentHash,
                operationIdentity: firstOperation.operationIdentity
            )
            var operations = bodyPlan.operations
            operations[0] = malformedOperation
            return .matchingBaseIncremental(MatchingBaseBodyPlan(
                noteID: bodyPlan.noteID,
                initialBody: bodyPlan.initialBody,
                initialBodyHash: bodyPlan.initialBodyHash,
                operations: operations,
                finalBody: bodyPlan.finalBody,
                finalBodyHash: bodyPlan.finalBodyHash,
                resultEvidence: bodyPlan.resultEvidence
            ))
        }.replacingHistoryRetainedOperations([])
        let missingBaseHashInput = try incrementalValidated.replacingPlanForTesting(missingBaseHashPlan)
        let missingBaseHashTransaction = InMemoryConvergenceTransaction(notes: [incremental.noteID: incremental.initialNote])
        let missingBaseHashOutcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: missingBaseHashInput,
            transaction: missingBaseHashTransaction,
            committedAt: incremental.committedAt
        )
        XCTAssertEqual(missingBaseHashOutcome, .failedBeforeCommit(.unexpected))
        assertNoPreflightMutation(missingBaseHashTransaction, "matching-base operation missing base hash")
    }

    func testMYR135ValidSourceIdentityPersistsAndBuildsExactWorkIdentity() throws {
        let fixture = try makeTwoOperationFixture()
        let result = try planIncorporateAndDecode(
            input: fixture.planningInputForCurrentNotes(),
            notes: [fixture.noteID: fixture.initialNote],
            committedAt: fixture.committedAt,
            expectedRoutings: [fixture.noteID: .incremental]
        )
        let plannedIdentities = result.validatedInput.plan.incorporationEvidence.operationIdentities
            .sorted { $0.operationIndex < $1.operationIndex }
        let entry = try XCTUnwrap(result.work.presentationEntries.first)
        let persistedIdentities = result.transaction.children[result.validatedInput.sourceBatchID]?.operationIdentities
            .sorted { $0.operationIndex < $1.operationIndex } ?? []

        XCTAssertEqual(plannedIdentities.count, fixture.batch.changes.count)
        XCTAssertEqual(entry.incrementalOperations.map(\.operationIdentity), plannedIdentities)
        XCTAssertEqual(persistedIdentities.map(\.operationIdentity), plannedIdentities)
        for (index, identity) in plannedIdentities.enumerated() {
            let sourceChange = fixture.batch.changes[index]
            XCTAssertEqual(identity.batchIDLowercase, fixture.batch.id.uuidString.lowercased())
            XCTAssertEqual(identity.originDeviceIDLowercase, fixture.batch.originDeviceID.uuidString.lowercased())
            XCTAssertEqual(identity.operationIndex, index)
            XCTAssertEqual(identity.operationKind, "insert")
            XCTAssertEqual(
                identity.canonicalReplayKey,
                CanonicalReplayKeyPayload(replayKey: SyncBatchReplayKey(batch: fixture.batch, change: sourceChange, operationIndex: index))
            )
            XCTAssertEqual(persistedIdentities[index].noteID, fixture.noteID)
        }
    }

    func testMYR135ReconstructedConflictAcceptsLegitimateNonSourceIdentities() throws {
        let reconstructed = try makeReconstructedSnapshotFixture()
        let priorBatch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000135101"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000135102"),
            createdAt: date(2),
            batchSequence: 135101,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: reconstructed.noteID,
                    utf16Offset: 1,
                    text: "C",
                    modifiedAt: date(3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                ))
            ]
        )
        let retainedPriorOperation = SyncConvergenceRetainedOperation(
            noteID: reconstructed.noteID,
            batchID: priorBatch.id,
            originDeviceID: priorBatch.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "C",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "ACB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: priorBatch, change: priorBatch.changes[0], operationIndex: 0)
            )
        )
        let result = try planIncorporateAndDecode(
            input: reconstructed.planningInputForCurrentNotes(
                retainedSnapshots: [
                    SyncConvergenceRetainedSnapshot(
                        noteID: reconstructed.noteID,
                        contentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                        body: "AB",
                        generation: 1
                    )
                ],
                retainedRemoteOperations: [retainedPriorOperation]
            ),
            notes: [reconstructed.noteID: reconstructed.initialNote],
            committedAt: reconstructed.committedAt,
            expectedRoutings: [reconstructed.noteID: .wholeNoteFallback]
        )
        let nonSourceIdentities = result.validatedInput.plan.incorporationEvidence.operationIdentities.filter {
            $0.batchIDLowercase != result.validatedInput.sourceBatchID.uuidString.lowercased()
        }

        XCTAssertFalse(nonSourceIdentities.isEmpty)
        XCTAssertEqual(result.work.presentationEntries.first?.routing, .wholeNoteFallback)
        XCTAssertTrue(result.work.presentationEntries.first?.incrementalOperations.isEmpty ?? false)
        XCTAssertTrue(
            result.transaction.children.values.flatMap(\.operationIdentities).contains {
                nonSourceIdentities.contains($0.operationIdentity)
            }
        )
    }

    func testMYR135ConstructionIdentityMatrixFailsBeforeCommitWithoutMutation() throws {
        let fixture = try makeTwoOperationFixture()
        let validated = try plannedInput(from: fixture.planningInputForCurrentNotes())
        let sourceIdentity = try XCTUnwrap(validated.plan.incorporationEvidence.operationIdentities.first)
        let differentUUID = uuid("00000000-0000-0000-0000-000000135999")

        struct Case {
            let name: String
            let expectedNoteID: UUID?
            let mutate: (ValidatedSyncConvergenceIncorporationInput, OperationIdentityPayload) throws -> SyncConvergenceBatchPlan
        }

        let cases: [Case] = [
            Case(name: "missing authoritative identity", expectedNoteID: fixture.noteID) { input, _ in
                input.plan.replacingOperationIdentitiesForTest([])
            },
            Case(name: "duplicate batch index identity", expectedNoteID: fixture.noteID) { input, identity in
                input.plan.replacingOperationIdentitiesForTest(input.plan.incorporationEvidence.operationIdentities + [identity])
            },
            Case(name: "wrong outer batch ID", expectedNoteID: nil) { input, identity in
                let mutated = identity.replacingForTest(
                    batchID: differentUUID,
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(batchID: differentUUID)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "wrong source origin", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(
                    originDeviceID: differentUUID,
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(originDeviceID: differentUUID)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "wrong source operation kind", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(operationKind: "delete")
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "out-of-range source operation index", expectedNoteID: nil) { input, identity in
                let outOfRangeIndex = input.sourceBatch.changes.count
                let mutated = identity.replacingForTest(
                    operationIndex: outOfRangeIndex,
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(operationIndex: outOfRangeIndex)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "uppercase outer source origin", expectedNoteID: nil) { input, identity in
                let mutated = try identity.replacingRawStringsForTest(
                    originDeviceIDLowercase: identity.originDeviceIDLowercase.uppercased()
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "replay key batch mismatch", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(batchID: differentUUID)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "replay key origin mismatch", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(originDeviceID: differentUUID)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "replay key operation index mismatch", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(operationIndex: input.sourceBatch.changes.count)
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            },
            Case(name: "noncanonical source replay key", expectedNoteID: fixture.noteID) { input, identity in
                let mutated = identity.replacingForTest(
                    canonicalReplayKey: identity.canonicalReplayKey.replacingForTest(sequence: .replace(135135))
                )
                return input.plan.replacingOperationIdentityForTest(identity, with: mutated)
            }
        ]

        for testCase in cases {
            let malformedPlan = try testCase.mutate(validated, sourceIdentity)
            let malformedInput = try validated.replacingPlanForTesting(malformedPlan)
            let transaction = InMemoryConvergenceTransaction(notes: [fixture.noteID: fixture.initialNote])
            let outcome = SyncConvergenceIncorporationExecutor().incorporate(
                input: malformedInput,
                transaction: transaction,
                committedAt: fixture.committedAt
            )

            XCTAssertEqual(
                outcome,
                .failedBeforeCommit(.invalidMergePlan(noteID: testCase.expectedNoteID)),
                testCase.name
            )
            assertNoPreflightMutation(transaction, testCase.name)
        }

        let negativeIndexIdentity = sourceIdentity.replacingForTest(
            operationIndex: -1,
            canonicalReplayKey: sourceIdentity.canonicalReplayKey.replacingForTest(operationIndex: -1)
        )
        try assertMalformedIdentityFailsDuringProjectedEvidenceRecompute(
            name: "negative outer operation index",
            validated: validated,
            fixture: fixture,
            replacement: negativeIndexIdentity
        )

        let malformedUUIDIdentity = try sourceIdentity.replacingRawStringsForTest(
            batchIDLowercase: "not-a-uuid"
        )
        try assertMalformedIdentityFailsDuringProjectedEvidenceRecompute(
            name: "malformed outer batch UUID string",
            validated: validated,
            fixture: fixture,
            replacement: malformedUUIDIdentity
        )
    }

    private func assertMalformedIdentityFailsDuringProjectedEvidenceRecompute(
        name: String,
        validated: ValidatedSyncConvergenceIncorporationInput,
        fixture: Fixture,
        replacement: OperationIdentityPayload
    ) throws {
        let malformedPlan = validated.plan.replacingOperationIdentityForTest(
            try XCTUnwrap(validated.plan.incorporationEvidence.operationIdentities.first),
            with: replacement
        )
        let malformedInput = validated.replacingPlanForTestingWithoutRecomputedEvidenceBytes(malformedPlan)
        let transaction = InMemoryConvergenceTransaction(notes: [fixture.noteID: fixture.initialNote])
        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: malformedInput,
            transaction: transaction,
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.unexpected), name)
        assertNoPreflightMutation(transaction, name)
    }

    private struct PlannedIncorporationResult {
        let validatedInput: ValidatedSyncConvergenceIncorporationInput
        let incorporationResult: SyncConvergenceIncorporationResult
        let state: SyncConvergencePostCommitState
        let work: SyncConvergencePostCommitWorkPayloadV1
        let transaction: InMemoryConvergenceTransaction
    }

    private struct MYR134Fixture {
        let noteID: UUID
        let input: SyncConvergencePlanningInput
        let initialNote: SyncConvergenceMutableNoteRecord
        let committedAt: Date
    }

    private struct MYR134MixedRoutingFixture {
        let noneNote: UUID
        let incrementalNote: UUID
        let fallbackNote: UUID
        let input: SyncConvergencePlanningInput
        let initialNotes: [UUID: SyncConvergenceMutableNoteRecord]
        let committedAt: Date
    }

    private struct MalformedPlanCase {
        let name: String
        let base: ValidatedSyncConvergenceIncorporationInput
        let notes: [UUID: SyncConvergenceMutableNoteRecord]
        let committedAt: Date
        let expectedNoteID: UUID?
        let mutate: (SyncConvergenceBatchPlan) throws -> SyncConvergenceBatchPlan
    }

    private func planIncorporateAndDecode(
        input: SyncConvergencePlanningInput,
        notes: [UUID: SyncConvergenceMutableNoteRecord],
        committedAt: Date,
        expectedRoutings: [UUID: SyncConvergencePresentationRouting],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlannedIncorporationResult {
        let validatedInput = try plannedInput(from: input, file: file, line: line)
        XCTAssertFalse(validatedInput.plan.cleanupPlan.retryLegacyCleanup, file: file, line: line)
        XCTAssertEqual(validatedInput.plan.presentationPlan.noteRoutings, expectedRoutings, file: file, line: line)

        let transaction = InMemoryConvergenceTransaction(notes: notes)
        for winner in input.persistedTitleWinners {
            transaction.titleWinners[winner.noteID] = winner
        }
        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: validatedInput,
            transaction: transaction,
            committedAt: committedAt
        )
        guard case .incorporated(let incorporationResult) = outcome else {
            XCTFail(
                "Expected incorporation for \(input.incomingBatch.id), got \(outcome)",
                file: file,
                line: line
            )
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let root = try XCTUnwrap(transaction.roots[validatedInput.sourceBatchID], file: file, line: line)
        let state = try SyncConvergenceStableEncoding.decode(
            SyncConvergencePostCommitState.self,
            from: root.postCommitStatePayloadData
        )
        let work = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(
            try XCTUnwrap(root.postCommitWorkPayloadData, file: file, line: line)
        )
        XCTAssertFalse(state.legacyCleanupPending, file: file, line: line)
        XCTAssertFalse(work.legacyCleanupRequired, file: file, line: line)
        XCTAssertEqual(work.derivedInitialState(), state, file: file, line: line)
        XCTAssertEqual(
            work.presentationEntries.map(\.noteID),
            expectedRoutings.map(\.key).sortedByUUIDStringForTest(),
            file: file,
            line: line
        )
        XCTAssertEqual(state.presentationRefreshPending, work.presentationEntries.isEmpty == false, file: file, line: line)

        return PlannedIncorporationResult(
            validatedInput: validatedInput,
            incorporationResult: incorporationResult,
            state: state,
            work: work,
            transaction: transaction
        )
    }

    private func plannedInput(
        from input: SyncConvergencePlanningInput,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ValidatedSyncConvergenceIncorporationInput {
        let outcome = SyncConvergencePlanner().plan(input: input)
        guard case .planned(let validatedInput) = outcome else {
            XCTFail("Expected planned outcome, got \(outcome)", file: file, line: line)
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return validatedInput
    }

    private func assertHashChain(
        _ entry: SyncConvergencePostCommitWorkPayloadV1.PresentationEntry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(entry.incrementalOperations.first?.baseContentHash, entry.expectedPreBodyHash, file: file, line: line)
        for (previous, current) in zip(entry.incrementalOperations, entry.incrementalOperations.dropFirst()) {
            XCTAssertEqual(current.baseContentHash, previous.resultContentHash, file: file, line: line)
        }
        XCTAssertEqual(entry.incrementalOperations.last?.resultContentHash, entry.committedPostBodyHash, file: file, line: line)
    }

    private func makeAllIdempotentBodyFixture() throws -> MYR134Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000134001")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000134002"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134003"),
            createdAt: date(3),
            batchSequence: 134001,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                ))
            ]
        )
        let retained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "B",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
            )
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "AB",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [initialNote.projectedForTest],
            retainedRemoteOperations: [retained]
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(5))
    }

    private func makeMixedIdempotentAndExecutableFixture() throws -> MYR134Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000134011")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000134012"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134013"),
            createdAt: date(3),
            batchSequence: 134011,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "C",
                    modifiedAt: date(5),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                ))
            ]
        )
        let retained = SyncConvergenceRetainedOperation(
            noteID: noteID,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 0,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "B",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[0], operationIndex: 0)
            )
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "AB",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [initialNote.projectedForTest],
            retainedRemoteOperations: [retained]
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(6))
    }

    private func makeMatchingBasePositionalFixture() throws -> MYR134Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000134021")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000134022"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134023"),
            createdAt: date(3),
            batchSequence: 134021,
            changes: [
                .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    utf16Length: 1,
                    expectedText: "a",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "abc")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 2,
                    text: "d",
                    modifiedAt: date(5),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "bc")
                ))
            ]
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: "abc",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(incomingBatch: batch, currentNotes: [initialNote.projectedForTest])
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(6))
    }

    private func makeCreationOnlyFixture(existing: Bool) throws -> MYR134Fixture {
        let noteID = uuid(existing ? "00000000-0000-0000-0000-000000134031" : "00000000-0000-0000-0000-000000134032")
        let batch = SyncBatch(
            id: uuid(existing ? "00000000-0000-0000-0000-000000134033" : "00000000-0000-0000-0000-000000134034"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134035"),
            createdAt: date(3),
            batchSequence: existing ? 134031 : 134032,
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
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Created",
            body: "Body",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: existing ? [initialNote.projectedForTest] : []
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(5))
    }

    private func makeCreatePlusBodyFixture(existingCreation: Bool) throws -> MYR134Fixture {
        let noteID = uuid(existingCreation ? "00000000-0000-0000-0000-000000134041" : "00000000-0000-0000-0000-000000134042")
        let batch = SyncBatch(
            id: uuid(existingCreation ? "00000000-0000-0000-0000-000000134043" : "00000000-0000-0000-0000-000000134044"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134045"),
            createdAt: date(3),
            batchSequence: existingCreation ? 134041 : 134042,
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Created",
                    body: "A",
                    folderID: nil,
                    createdAt: date(1),
                    modifiedAt: date(2)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                ))
            ]
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Created",
            body: "A",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: existingCreation ? [initialNote.projectedForTest] : []
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(5))
    }

    private func makeTitleOnlyApplyFixture() throws -> MYR134Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000134051")
        let priorBatch = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000134052"),
            noteID: noteID,
            title: "Prior",
            modifiedAt: date(2)
        )
        let incoming = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000134053"),
            noteID: noteID,
            title: "Incoming",
            modifiedAt: date(4)
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Prior",
            body: "Body",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: incoming,
            currentNotes: [initialNote.projectedForTest],
            persistedTitleWinners: [titleWinnerProjection(noteID: noteID, title: "Prior", batch: priorBatch)]
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: initialNote, committedAt: date(5))
    }

    private func makeCompatibilityMissingBodyFixture() throws -> MYR134Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000134061")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000134062"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134063"),
            createdAt: date(3),
            batchSequence: 134061,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "Ignored",
                    modifiedAt: date(4)
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(incomingBatch: batch)
        let placeholder = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "",
            body: "",
            createdAt: date(1),
            modifiedAt: date(1)
        )
        return MYR134Fixture(noteID: noteID, input: input, initialNote: placeholder, committedAt: date(5))
    }

    private func makeMYR134MixedRoutingFixture() throws -> MYR134MixedRoutingFixture {
        let noneNote = uuid("00000000-0000-0000-0000-000000134101")
        let incrementalNote = uuid("00000000-0000-0000-0000-000000134102")
        let fallbackNote = uuid("00000000-0000-0000-0000-000000134103")
        let batch = SyncBatch(
            id: uuid("00000000-0000-0000-0000-000000134104"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134105"),
            createdAt: date(3),
            batchSequence: 134101,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: fallbackNote,
                    utf16Offset: 1,
                    text: "q",
                    modifiedAt: date(6),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: incrementalNote,
                    utf16Offset: 1,
                    text: "Y",
                    modifiedAt: date(5),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "X")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noneNote,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: incrementalNote,
                    utf16Offset: 2,
                    text: "Z",
                    modifiedAt: date(7),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "XY")
                ))
            ]
        )
        let noneRetained = SyncConvergenceRetainedOperation(
            noteID: noneNote,
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: 2,
            operationKind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "B",
            expectedText: nil,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            canonicalReplayKey: CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: batch.changes[2], operationIndex: 2)
            )
        )
        let fallbackRetainedDelete = retainedDelete(
            noteID: fallbackNote,
            batchID: uuid("00000000-0000-0000-0000-000000134106"),
            originDeviceID: uuid("00000000-0000-0000-0000-000000134107"),
            operationIndex: 0,
            offset: 1,
            length: 1,
            expectedText: "C",
            modifiedAt: date(5),
            baseBody: "ACB",
            resultHash: SyncBatchContentHash.sha256Hex(for: "AB")
        )
        let notes = [
            noneNote: SyncConvergenceMutableNoteRecord(
                noteID: noneNote,
                folderID: nil,
                title: "None",
                body: "AB",
                createdAt: date(1),
                modifiedAt: date(2)
            ),
            incrementalNote: SyncConvergenceMutableNoteRecord(
                noteID: incrementalNote,
                folderID: nil,
                title: "Incremental",
                body: "X",
                createdAt: date(1),
                modifiedAt: date(2)
            ),
            fallbackNote: SyncConvergenceMutableNoteRecord(
                noteID: fallbackNote,
                folderID: nil,
                title: "Fallback",
                body: "ACB",
                createdAt: date(1),
                modifiedAt: date(2)
            )
        ]
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: notes.values.map(\.projectedForTest),
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(
                    noteID: fallbackNote,
                    contentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                    body: "AB",
                    generation: 1
                )
            ],
            retainedRemoteOperations: [noneRetained, fallbackRetainedDelete]
        )
        return MYR134MixedRoutingFixture(
            noneNote: noneNote,
            incrementalNote: incrementalNote,
            fallbackNote: fallbackNote,
            input: input,
            initialNotes: notes,
            committedAt: date(8)
        )
    }

    private struct TwoNoteSwappableFixture {
        let noteA: UUID
        let noteB: UUID
        let batchID: UUID
        let committedAt: Date
        let validatedInput: ValidatedSyncConvergenceIncorporationInput
        let swappedValidatedInput: ValidatedSyncConvergenceIncorporationInput
        let transaction: InMemoryConvergenceTransaction
    }

    /// Builds a two-note batch that plans cleanly, then constructs a malformed
    /// sibling plan with the two notes' same-kind body operation identities
    /// swapped while leaving the global incorporation identity set intact —
    /// the exact shape a poison-pill plan would need to pass every prior check.
    private func makeTwoNoteSwappableFixture() throws -> TwoNoteSwappableFixture {
        let noteA = uuid("00000000-0000-0000-0000-000000132e01")
        let noteB = uuid("00000000-0000-0000-0000-000000132e02")
        let origin = uuid("00000000-0000-0000-0000-000000132e03")
        let batchID = uuid("00000000-0000-0000-0000-000000132e04")
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: date(3),
            batchSequence: 90,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteA,
                    utf16Offset: 1,
                    text: "B",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteB,
                    utf16Offset: 1,
                    text: "Y",
                    modifiedAt: date(4),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "X")
                ))
            ]
        )
        let outcome = SyncConvergencePlanner().plan(input: SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [
                SyncConvergenceProjectedNote(
                    noteID: noteA, folderID: nil, title: "Title A", body: "A",
                    createdAt: date(1), modifiedAt: date(2)
                ),
                SyncConvergenceProjectedNote(
                    noteID: noteB, folderID: nil, title: "Title B", body: "X",
                    createdAt: date(1), modifiedAt: date(2)
                )
            ]
        ))
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        let plan = validatedInput.plan

        func matchingBasePlan(for noteID: UUID) throws -> (index: Int, plan: MatchingBaseBodyPlan) {
            guard let index = plan.affectedNotePlans.firstIndex(where: { $0.noteID == noteID }),
                  case .matchingBaseIncremental(let bodyPlan) = plan.affectedNotePlans[index].bodyEffect,
                  bodyPlan.operations.count == 1 else {
                throw TestFixtureError.unexpectedPlanningOutcome
            }
            return (index, bodyPlan)
        }

        let (indexA, bodyPlanA) = try matchingBasePlan(for: noteA)
        let (indexB, bodyPlanB) = try matchingBasePlan(for: noteB)
        let originalOperationA = bodyPlanA.operations[0]
        let originalOperationB = bodyPlanB.operations[0]

        let swappedOperationA = SyncConvergencePlannedBodyOperation(
            noteID: originalOperationA.noteID,
            kind: originalOperationA.kind,
            utf16Offset: originalOperationA.utf16Offset,
            utf16Length: originalOperationA.utf16Length,
            text: originalOperationA.text,
            expectedText: originalOperationA.expectedText,
            baseContentHash: originalOperationA.baseContentHash,
            resultContentHash: originalOperationA.resultContentHash,
            operationIdentity: originalOperationB.operationIdentity
        )
        let swappedOperationB = SyncConvergencePlannedBodyOperation(
            noteID: originalOperationB.noteID,
            kind: originalOperationB.kind,
            utf16Offset: originalOperationB.utf16Offset,
            utf16Length: originalOperationB.utf16Length,
            text: originalOperationB.text,
            expectedText: originalOperationB.expectedText,
            baseContentHash: originalOperationB.baseContentHash,
            resultContentHash: originalOperationB.resultContentHash,
            operationIdentity: originalOperationA.operationIdentity
        )

        var swappedNotePlans = plan.affectedNotePlans
        swappedNotePlans[indexA] = SyncConvergenceNotePlan(
            noteID: noteA,
            creationEffect: plan.affectedNotePlans[indexA].creationEffect,
            bodyEffect: .matchingBaseIncremental(MatchingBaseBodyPlan(
                noteID: bodyPlanA.noteID,
                initialBody: bodyPlanA.initialBody,
                initialBodyHash: bodyPlanA.initialBodyHash,
                operations: [swappedOperationA],
                finalBody: bodyPlanA.finalBody,
                finalBodyHash: bodyPlanA.finalBodyHash,
                resultEvidence: bodyPlanA.resultEvidence
            )),
            titleEffect: plan.affectedNotePlans[indexA].titleEffect
        )
        swappedNotePlans[indexB] = SyncConvergenceNotePlan(
            noteID: noteB,
            creationEffect: plan.affectedNotePlans[indexB].creationEffect,
            bodyEffect: .matchingBaseIncremental(MatchingBaseBodyPlan(
                noteID: bodyPlanB.noteID,
                initialBody: bodyPlanB.initialBody,
                initialBodyHash: bodyPlanB.initialBodyHash,
                operations: [swappedOperationB],
                finalBody: bodyPlanB.finalBody,
                finalBodyHash: bodyPlanB.finalBodyHash,
                resultEvidence: bodyPlanB.resultEvidence
            )),
            titleEffect: plan.affectedNotePlans[indexB].titleEffect
        )

        let swappedHistoryPlan = SyncConvergenceHistoryPlan(
            retainedOperationAdditions: [swappedOperationA, swappedOperationB],
            snapshotAdditions: plan.historyPlan.snapshotAdditions,
            pressureNotes: plan.historyPlan.pressureNotes
        )

        let swappedPlan = SyncConvergenceBatchPlan(
            batchID: plan.batchID,
            originDeviceID: plan.originDeviceID,
            canonicalPayloadDigest: plan.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: plan.canonicalPayloadDigestFormatVersion,
            affectedNotePlans: swappedNotePlans,
            incorporationEvidence: plan.incorporationEvidence,
            historyPlan: swappedHistoryPlan,
            cleanupPlan: plan.cleanupPlan,
            presentationPlan: plan.presentationPlan
        )
        let swappedValidatedInput = ValidatedSyncConvergenceIncorporationInput(
            validatedPlanToken: SyncConvergenceValidatedPlanToken.unvalidatedForTesting(),
            plan: swappedPlan,
            sourceBatch: validatedInput.sourceBatch,
            sourceSchemaVersion: validatedInput.sourceSchemaVersion,
            projectedFullIncorporationEvidenceBytes: validatedInput.projectedFullIncorporationEvidenceBytes
        )

        let transaction = InMemoryConvergenceTransaction(notes: [
            noteA: SyncConvergenceMutableNoteRecord(
                noteID: noteA, folderID: nil, title: "Title A", body: "A", createdAt: date(1), modifiedAt: date(2)
            ),
            noteB: SyncConvergenceMutableNoteRecord(
                noteID: noteB, folderID: nil, title: "Title B", body: "X", createdAt: date(1), modifiedAt: date(2)
            )
        ])

        return TwoNoteSwappableFixture(
            noteA: noteA,
            noteB: noteB,
            batchID: batchID,
            committedAt: date(5),
            validatedInput: validatedInput,
            swappedValidatedInput: swappedValidatedInput,
            transaction: transaction
        )
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

    func testDuplicateValidationRejectsUnsupportedPersistedResultKindBeforeMutation() throws {
        let fixture = try makeTitleAndBodyFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        seed(note: fixture.initialNote, in: context)
        try seedTitleWinner(try XCTUnwrap(fixture.priorWinner), updatedAt: date(6), in: context)

        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected SwiftData incorporation, got \(first)")
        }
        var stored = try captureSwiftDataState(in: context)
        let malformed = try XCTUnwrap(
            try context.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>())
                .first { $0.resultKindRaw == SyncConvergenceResultEvidence.Kind.body.rawValue }
        )
        malformed.resultKindRaw = "unsupported"
        malformed.resultEvidencePayloadData = try unsupportedKindPayload(from: malformed.resultEvidencePayloadData)
        try context.save()
        stored.resultEvidence = try captureSwiftDataState(in: context).resultEvidence

        let outcome = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
            committedAt: fixture.committedAt
        )

        XCTAssertEqual(outcome, .failedBeforeCommit(.unexpected))
        XCTAssertEqual(try captureSwiftDataState(in: context), stored)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteTitleWinner>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).count, 1)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<NoteContentSnapshot>()).count,
            fixture.plan.historyPlan.snapshotAdditions.count
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedSyncBatch>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>()).count, 2)
        XCTAssertFalse(context.hasChanges)
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
            originID: uuid("00000000-0000-0000-0000-000000133103"),
            retainedDeleteBatchID: uuid("00000000-0000-0000-0000-000000133104"),
            retainedDeleteOriginID: uuid("00000000-0000-0000-0000-000000133105")
        )
        let second = try makeReconstructedSnapshotFixture(
            noteID: uuid("00000000-0000-0000-0000-000000133201"),
            batchID: uuid("00000000-0000-0000-0000-000000133202"),
            originID: uuid("00000000-0000-0000-0000-000000133203"),
            retainedDeleteBatchID: uuid("00000000-0000-0000-0000-000000133204"),
            retainedDeleteOriginID: uuid("00000000-0000-0000-0000-000000133205")
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
        let fixture = try makeTitleAndBodyReconstructedSnapshotFixture()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context1 = ModelContext(container)
        seed(note: fixture.initialNote, in: context1)
        try seedTitleWinner(try XCTUnwrap(fixture.priorWinner), updatedAt: date(6), in: context1)

        let first = SyncConvergenceIncorporationExecutor().incorporate(
            input: fixture.validatedInput,
            transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context1),
            committedAt: fixture.committedAt
        )
        guard case .incorporated = first else {
            return XCTFail("Expected SwiftData incorporation, got \(first)")
        }

        let context2 = ModelContext(container)
        let expectedNotePlan = try XCTUnwrap(fixture.plan.affectedNotePlans.first { $0.noteID == fixture.noteID })
        let expectedTitle = try XCTUnwrap(expectedNotePlan.titleEffect)
        let expectedWinningKey = try XCTUnwrap(expectedTitle.resultingWinningKey)
        let expectedBody = try XCTUnwrap(expectedNotePlan.plannedFinalBodyForTest)
        let expectedModifiedAt = try XCTUnwrap(expectedNotePlan.plannedModifiedAtForTest)
        let persistedNote = try XCTUnwrap(fetchOne(Note.self, in: context2))
        XCTAssertEqual(persistedNote.id, fixture.noteID)
        XCTAssertNil(persistedNote.folder)
        XCTAssertEqual(persistedNote.title, expectedTitle.resultingTitle)
        XCTAssertEqual(persistedNote.content, expectedBody)
        XCTAssertEqual(persistedNote.createdAt, fixture.initialNote.createdAt)
        XCTAssertEqual(persistedNote.modifiedAt, expectedModifiedAt)

        let titleWinner = try XCTUnwrap(fetchOne(NoteTitleWinner.self, in: context2))
        XCTAssertEqual(titleWinner.noteID, fixture.noteID)
        XCTAssertEqual(titleWinner.title, expectedTitle.resultingTitle)
        XCTAssertEqual(titleWinner.canonicalReplayKeyPayloadData, try expectedWinningKey.encodedEvidenceData())
        XCTAssertEqual(titleWinner.operationIdentityPayloadData, try expectedTitle.candidateOperationIdentity.encodedPayloadData())
        XCTAssertEqual(
            try CanonicalReplayKeyPayload.decodeEvidenceData(titleWinner.canonicalReplayKeyPayloadData),
            expectedWinningKey
        )
        XCTAssertEqual(
            try OperationIdentityPayload.decodePayloadData(titleWinner.operationIdentityPayloadData),
            expectedTitle.candidateOperationIdentity
        )
        XCTAssertEqual(titleWinner.updatedAt, fixture.committedAt)

        let root = try XCTUnwrap(fetchOne(IncorporatedSyncBatch.self, in: context2))
        XCTAssertEqual(root.batchID, fixture.batch.id)
        XCTAssertEqual(root.originDeviceID, fixture.batch.originDeviceID)
        XCTAssertEqual(root.createdAt, fixture.batch.createdAt)
        XCTAssertEqual(root.batchSequence, fixture.batch.batchSequence)
        XCTAssertEqual(root.schemaVersion, fixture.validatedInput.sourceSchemaVersion)
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
        let committedAtOrdering = try CommittedAtOrderingPayload.decodeEvidenceData(rootProjection.committedAtOrderingPayloadData)
        XCTAssertEqual(committedAtOrdering.batchIDLowercase, fixture.batch.id.uuidString.lowercased())
        XCTAssertEqual(committedAtOrdering.committedAtBitPattern, SyncConvergenceDateBits.bitPattern(for: fixture.committedAt))
        let expectedAffectedNotesPayload = ExpectedAffectedNotesPayloadV1(
            version: 1,
            noteIDsLowercase: [
                fixture.noteID.uuidString.lowercased()
            ].sorted()
        )
        let expectedAffectedNotesPayloadData = try SyncConvergenceStableEncoding.encode(
            expectedAffectedNotesPayload
        )
        XCTAssertEqual(root.affectedNotesPayloadData, expectedAffectedNotesPayloadData)
        let affectedNotes = try decodedAffectedNotes(root.affectedNotesPayloadData)
        XCTAssertEqual(affectedNotes.version, expectedAffectedNotesPayload.version)
        XCTAssertEqual(affectedNotes.noteIDs, expectedAffectedNotesPayload.noteIDsLowercase)

        let expectedPostCommit = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: fixture.plan.cleanupPlan.retryLegacyCleanup,
            presentationRefreshPending: true
        )
        let expectedPostCommitPayloadData = try SyncConvergenceStableEncoding.encode(
            expectedPostCommit
        )
        XCTAssertEqual(root.postCommitStatePayloadData, expectedPostCommitPayloadData)
        XCTAssertEqual(
            try SyncConvergenceStableEncoding.decode(
                SyncConvergencePostCommitState.self,
                from: root.postCommitStatePayloadData
            ),
            expectedPostCommit
        )

        let operationIdentities = try context2.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>())
        let noteEffects = try context2.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>())
        let resultEvidence = try context2.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>())
        XCTAssertEqual(operationIdentities.count, fixture.plan.incorporationEvidence.operationIdentities.count)
        XCTAssertEqual(noteEffects.count, 1)
        XCTAssertEqual(resultEvidence.count, fixture.plan.incorporationEvidence.resultEvidence.count)

        try assertPersistedOperationIdentities(operationIdentities, fixture: fixture)
        try assertPersistedNoteEffects(noteEffects, fixture: fixture)
        try assertPersistedResultEvidence(resultEvidence, fixture: fixture)
        try assertAuthoritativeChildAccounting(
            root: root,
            operationIdentities: operationIdentities,
            noteEffects: noteEffects,
            resultEvidence: resultEvidence
        )

        try assertPersistedRetainedOperations(
            try context2.fetch(FetchDescriptor<RetainedBodyOperation>()),
            fixture: fixture
        )
        try assertPersistedSnapshots(
            try context2.fetch(FetchDescriptor<NoteContentSnapshot>()),
            fixture: fixture
        )

        let beforeDuplicate = try captureSwiftDataState(in: context2)
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
        XCTAssertEqual(try captureSwiftDataState(in: context2), beforeDuplicate)
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

    fileprivate struct Fixture {
        let noteID: UUID
        let batch: SyncBatch
        let input: SyncConvergencePlanningInput
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

    private func myr158IncorporatedRecord(
        batchID: UUID,
        index: Int,
        state: SyncConvergencePostCommitState
    ) throws -> SyncConvergenceIncorporatedBatchRecord {
        SyncConvergenceIncorporatedBatchRecord(
            batchID: batchID,
            originDeviceID: uuid("00000000-0000-0000-0000-000000158201"),
            createdAt: date(TimeInterval(158_000 + index)),
            batchSequence: UInt64(index),
            schemaVersion: 1,
            committedAt: date(TimeInterval(159_000 + index)),
            canonicalPayloadDigest: String(format: "%064d", index),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(format: "%064d", index + 1_000),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: try SyncConvergenceAffectedNotesPayloadV1(noteIDs: []).encodedData(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitWorkPayloadData: try SyncConvergencePostCommitWorkPayloadV1(
                queueCleanupBatchIDs: state.queueCleanupPending ? [batchID] : [],
                legacyCleanupRequired: state.legacyCleanupPending,
                presentationEntries: state.presentationRefreshPending ? [myr158PresentationEntry(noteID: uuid("00000000-0000-0000-0000-000000158202"))] : []
            ).encodedPayloadData(),
            postCommitStatePayloadData: try state.encodedPayloadData(),
            hasPendingPostCommitWork: state.hasPendingWork
        )
    }

    private func fetchIncorporatedBatch(batchID: UUID, in context: ModelContext) throws -> IncorporatedSyncBatch? {
        try context.fetch(FetchDescriptor<IncorporatedSyncBatch>(predicate: #Predicate { $0.batchID == batchID })).first
    }

    private func myr158PresentationEntry(noteID: UUID) -> SyncConvergencePostCommitWorkPayloadV1.PresentationEntry {
        let priorHash = SyncBatchContentHash.sha256Hex(for: "prior")
        let committedHash = SyncBatchContentHash.sha256Hex(for: "committed")
        return SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
            noteID: noteID,
            routing: .wholeNoteFallback,
            expectedPreBodyHash: priorHash,
            committedPostBodyHash: committedHash,
            incrementalOperations: [],
            rewriteSafetyReceipt: SyncConvergenceRewriteSafetyReceipt(
                noteID: noteID,
                priorBodyHash: priorHash,
                candidateBodyHash: committedHash,
                consumedDeleteIdentities: []
            )
        )
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
            input: input,
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
        let input = SyncConvergencePlanningInput(
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
        )
        let outcome = SyncConvergencePlanner().plan(input: input)
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
            input: input,
            plan: plan,
            projectedBytes: projectedBytes,
            validatedInput: validatedInput,
            initialNote: initialNote,
            committedAt: date(7),
            priorWinner: priorWinner
        )
    }

    private func makeTitleAndBodyReconstructedSnapshotFixture() throws -> Fixture {
        let noteID = uuid("00000000-0000-0000-0000-000000133101")
        let origin = uuid("00000000-0000-0000-0000-000000133102")
        let batchID = uuid("00000000-0000-0000-0000-000000133103")
        let base = "AB"
        let baseHash = SyncBatchContentHash.sha256Hex(for: base)
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Prior",
            body: "ACB",
            createdAt: date(1),
            modifiedAt: date(2)
        )
        let priorBatch = titleBatch(
            id: uuid("00000000-0000-0000-0000-000000133104"),
            noteID: noteID,
            title: "Prior",
            modifiedAt: date(3)
        )
        let priorWinner = titleWinnerProjection(noteID: noteID, title: "Prior", batch: priorBatch)
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: origin,
            createdAt: date(4),
            batchSequence: 13,
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: 1,
                    text: "x",
                    modifiedAt: date(5),
                    baseContentHash: baseHash
                )),
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: "Incoming",
                    modifiedAt: date(6)
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Prior",
                body: "ACB",
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: baseHash, body: base, generation: 1)
            ],
            retainedRemoteOperations: [
                retainedDelete(
                    noteID: noteID,
                    batchID: uuid("00000000-0000-0000-0000-000000133105"),
                    originDeviceID: uuid("00000000-0000-0000-0000-000000133106"),
                    operationIndex: 0,
                    offset: 1,
                    length: 1,
                    expectedText: "C",
                    modifiedAt: date(3),
                    baseBody: "ACB",
                    resultHash: baseHash
                )
            ],
            persistedTitleWinners: [priorWinner]
        )
        let outcome = SyncConvergencePlanner().plan(input: input)
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
            input: input,
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
            input: input,
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
        originID: UUID = uuid("00000000-0000-0000-0000-000000133003"),
        retainedDeleteBatchID: UUID = uuid("00000000-0000-0000-0000-000000133402"),
        retainedDeleteOriginID: UUID = uuid("00000000-0000-0000-0000-000000133403")
    ) throws -> Fixture {
        let currentBody = "ACB"
        let incomingBase = "AB"
        let incomingBaseHash = SyncBatchContentHash.sha256Hex(for: incomingBase)
        let retainedDelete = retainedDelete(
            noteID: noteID,
            batchID: retainedDeleteBatchID,
            originDeviceID: retainedDeleteOriginID,
            operationIndex: 0,
            offset: 1,
            length: 1,
            expectedText: "C",
            modifiedAt: date(3),
            baseBody: currentBody,
            resultHash: incomingBaseHash
        )
        let initialNote = SyncConvergenceMutableNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Title",
            body: currentBody,
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
                    baseContentHash: incomingBaseHash
                ))
            ]
        )
        let input = SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [SyncConvergenceProjectedNote(
                noteID: noteID,
                folderID: nil,
                title: "Title",
                body: currentBody,
                createdAt: date(1),
                modifiedAt: date(2)
            )],
            retainedSnapshots: [
                SyncConvergenceRetainedSnapshot(noteID: noteID, contentHash: incomingBaseHash, body: incomingBase, generation: 1)
            ],
            retainedRemoteOperations: [retainedDelete]
        )
        let outcome = SyncConvergencePlanner().plan(input: input)
        guard case .planned(let validatedInput) = outcome else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return try makeFixture(from: batch, input: input, validatedInput: validatedInput, initialNote: initialNote, committedAt: date(5))
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
            ],
            retainedRemoteOperations: first.input.retainedRemoteOperations + second.input.retainedRemoteOperations
        )) else {
            throw TestFixtureError.unexpectedPlanningOutcome
        }
        return try makeFixture(from: batch, validatedInput: validatedInput, initialNote: first.initialNote, committedAt: date(5))
    }

    private func makeFixture(
        from batch: SyncBatch,
        input: SyncConvergencePlanningInput? = nil,
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
            input: input ?? SyncConvergencePlanningInput(
                incomingBatch: batch,
                currentNotes: [initialNote.projectedForTest]
            ),
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

private extension SyncConvergenceIncorporationTests.Fixture {
    func planningInputForCurrentNotes(
        retainedSnapshots: [SyncConvergenceRetainedSnapshot] = [],
        retainedRemoteOperations: [SyncConvergenceRetainedOperation] = []
    ) -> SyncConvergencePlanningInput {
        SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: [initialNote.projectedForTest],
            retainedSnapshots: retainedSnapshots,
            retainedRemoteOperations: retainedRemoteOperations,
            persistedTitleWinners: priorWinner.map { [$0] } ?? []
        )
    }
}

private extension ValidatedSyncConvergenceIncorporationInput {
    func planningInputForSourceOnly() -> SyncConvergencePlanningInput {
        SyncConvergencePlanningInput(incomingBatch: sourceBatch)
    }

    func replacingPlanForTesting(_ plan: SyncConvergenceBatchPlan) throws -> ValidatedSyncConvergenceIncorporationInput {
        let projectedBytes = try SyncConvergenceProjectedIncorporationEvidence(
            batch: sourceBatch,
            affectedNoteIDs: Set(plan.affectedNotePlans.map(\.noteID)),
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount()
        return ValidatedSyncConvergenceIncorporationInput(
            validatedPlanToken: SyncConvergenceValidatedPlanToken.unvalidatedForTesting(),
            plan: plan,
            sourceBatch: sourceBatch,
            sourceSchemaVersion: sourceSchemaVersion,
            projectedFullIncorporationEvidenceBytes: projectedBytes
        )
    }

    func replacingPlanForTestingWithoutRecomputedEvidenceBytes(_ plan: SyncConvergenceBatchPlan) -> ValidatedSyncConvergenceIncorporationInput {
        ValidatedSyncConvergenceIncorporationInput(
            validatedPlanToken: SyncConvergenceValidatedPlanToken.unvalidatedForTesting(),
            plan: plan,
            sourceBatch: sourceBatch,
            sourceSchemaVersion: sourceSchemaVersion,
            projectedFullIncorporationEvidenceBytes: projectedFullIncorporationEvidenceBytes
        )
    }
}

private extension SyncConvergenceBatchPlan {
    func replacingOperationIdentitiesForTest(
        _ operationIdentities: [OperationIdentityPayload]
    ) -> SyncConvergenceBatchPlan {
        SyncConvergenceBatchPlan(
            batchID: batchID,
            originDeviceID: originDeviceID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            affectedNotePlans: affectedNotePlans,
            incorporationEvidence: SyncConvergenceIncorporationPlan(
                operationIdentities: operationIdentities,
                resultEvidence: incorporationEvidence.resultEvidence
            ),
            historyPlan: historyPlan,
            cleanupPlan: cleanupPlan,
            presentationPlan: presentationPlan
        )
    }

    func replacingOperationIdentityForTest(
        _ original: OperationIdentityPayload,
        with replacement: OperationIdentityPayload
    ) -> SyncConvergenceBatchPlan {
        replacingOperationIdentitiesForTest(incorporationEvidence.operationIdentities.map {
            $0 == original ? replacement : $0
        })
    }

    func replacingNotePlans(_ notePlans: [SyncConvergenceNotePlan]) -> SyncConvergenceBatchPlan {
        SyncConvergenceBatchPlan(
            batchID: batchID,
            originDeviceID: originDeviceID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            affectedNotePlans: notePlans,
            incorporationEvidence: incorporationEvidence,
            historyPlan: historyPlan,
            cleanupPlan: cleanupPlan,
            presentationPlan: presentationPlan
        )
    }

    func replacingRoutings(_ routings: [UUID: SyncConvergencePresentationRouting]) -> SyncConvergenceBatchPlan {
        SyncConvergenceBatchPlan(
            batchID: batchID,
            originDeviceID: originDeviceID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            affectedNotePlans: affectedNotePlans,
            incorporationEvidence: incorporationEvidence,
            historyPlan: historyPlan,
            cleanupPlan: cleanupPlan,
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: routings)
        )
    }

    func replacingHistoryRetainedOperations(
        _ operations: [SyncConvergencePlannedBodyOperation]
    ) -> SyncConvergenceBatchPlan {
        SyncConvergenceBatchPlan(
            batchID: batchID,
            originDeviceID: originDeviceID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            affectedNotePlans: affectedNotePlans,
            incorporationEvidence: incorporationEvidence,
            historyPlan: SyncConvergenceHistoryPlan(
                retainedOperationAdditions: operations,
                snapshotAdditions: historyPlan.snapshotAdditions,
                pressureNotes: historyPlan.pressureNotes
            ),
            cleanupPlan: cleanupPlan,
            presentationPlan: presentationPlan
        )
    }

    func replacingBodyEffect(
        for noteID: UUID,
        transform: (SyncConvergenceBodyEffect) throws -> SyncConvergenceBodyEffect
    ) throws -> SyncConvergenceBatchPlan {
        var notePlans = affectedNotePlans
        let index = try XCTUnwrap(notePlans.firstIndex { $0.noteID == noteID })
        let notePlan = notePlans[index]
        let bodyEffect = try XCTUnwrap(notePlan.bodyEffect)
        notePlans[index] = SyncConvergenceNotePlan(
            noteID: notePlan.noteID,
            creationEffect: notePlan.creationEffect,
            bodyEffect: try transform(bodyEffect),
            titleEffect: notePlan.titleEffect
        )
        return replacingNotePlans(notePlans)
    }
}

private extension SyncConvergenceMutableNoteRecord {
    var projectedForTest: SyncConvergenceProjectedNote {
        SyncConvergenceProjectedNote(
            noteID: noteID,
            folderID: folderID,
            title: title,
            body: body,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}

private extension Array where Element == UUID {
    func sortedByUUIDStringForTest() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}

private final class InMemoryConvergenceTransaction: SyncConvergencePersistenceTransaction {
    var notes: [UUID: SyncConvergenceMutableNoteRecord]
    var titleWinners: [UUID: SyncConvergenceTitleWinnerProjection] = [:]
    var roots: [UUID: SyncConvergenceIncorporatedRootProjection] = [:]
    var tombstones: [UUID: SyncConvergenceIncorporatedTombstoneProjection] = [:]
    var children: [UUID: SyncConvergenceIncorporatedChildrenProjection] = [:]
    var retainedOperations: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationProjection] = [:]
    var explicitDeleteProvenance: [SyncConvergenceRetainedOperationIdentity: ExplicitDeleteProvenanceProjection] = [:]
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
            modifiedAt: record.modifiedAt,
            deletedAt: record.deletedAt ?? existing?.deletedAt
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
            postCommitWorkPayloadData: record.postCommitWorkPayloadData,
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

    func loadExplicitDeleteProvenance(
        identity: SyncConvergenceRetainedOperationIdentity
    ) throws -> ExplicitDeleteProvenanceProjection? {
        explicitDeleteProvenance[identity]
    }

    func insertExplicitDeleteProvenance(_ record: ExplicitDeleteProvenanceRecord) throws {
        stageRollback()
        let canonicalData = try record.canonicalPayloadData()
        if let existing = explicitDeleteProvenance[record.identity] {
            guard existing.canonicalPayloadData == canonicalData else {
                throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: record.noteID)
            }
            return
        }
        explicitDeleteProvenance[record.identity] = ExplicitDeleteProvenanceProjection(
            record: record,
            canonicalPayloadData: canonicalData
        )
    }

    func compactExplicitDeleteProvenance(
        identity: SyncConvergenceRetainedOperationIdentity,
        using snapshot: SyncConvergenceSnapshotRecord
    ) throws -> ExplicitDeleteProvenanceCompactionResult {
        stageRollback()
        guard let existing = explicitDeleteProvenance[identity] else {
            return .retainedFull(.occurrenceNotFound)
        }
        let result = ExplicitDeleteProvenanceCompactor().compact(record: existing.record, baseSnapshot: snapshot)
        if case .compacted(let compacted) = result {
            explicitDeleteProvenance[identity] = ExplicitDeleteProvenanceProjection(
                record: compacted,
                canonicalPayloadData: try compacted.canonicalPayloadData()
            )
        }
        return result
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
        explicitDeleteProvenance = rollbackSnapshot.explicitDeleteProvenance
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
            postCommitWorkPayloadData: root.postCommitWorkPayloadData,
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
            explicitDeleteProvenance: explicitDeleteProvenance,
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
    let explicitDeleteProvenance: [SyncConvergenceRetainedOperationIdentity: ExplicitDeleteProvenanceProjection]
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

private struct SwiftDataState: Equatable {
    let notes: [PersistedNoteState]
    let titleWinners: [PersistedTitleWinnerState]
    let retainedOperations: [PersistedRetainedOperationState]
    let snapshots: [PersistedSnapshotState]
    let roots: [PersistedRootState]
    let operationIdentities: [PersistedOperationIdentityState]
    let noteEffects: [PersistedNoteEffectState]
    var resultEvidence: [PersistedResultEvidenceState]
}

private struct PersistedNoteState: Equatable {
    let id: UUID
    let folderID: UUID?
    let title: String
    let content: String
    let createdAt: Date
    let modifiedAt: Date
}

private struct PersistedTitleWinnerState: Equatable {
    let noteID: UUID
    let title: String
    let canonicalReplayKeyPayloadData: Data
    let operationIdentityPayloadData: Data
    let updatedAt: Date
}

private struct PersistedRetainedOperationState: Equatable {
    let noteID: UUID
    let batchID: UUID
    let originDeviceID: UUID
    let operationIndex: Int
    let operationKindRaw: String
    let utf16Offset: Int
    let utf16Length: Int?
    let text: String?
    let expectedText: String?
    let baseContentHash: String?
    let resultContentHash: String?
    let canonicalReplayKeyPayloadData: Data
    let modifiedAt: Date
    let sourceRaw: String
}

private struct PersistedSnapshotState: Equatable {
    let noteID: UUID
    let contentHash: String
    let body: String
    let generation: Int
    let createdAt: Date
}

private struct PersistedRootState: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let createdAt: Date
    let batchSequence: UInt64?
    let schemaVersion: Int
    let committedAt: Date
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let affectedNotesPayloadData: Data
    let authoritativeChildCount: Int
    let authoritativeChildBytes: Int
    let authoritativeChildrenDigest: String
    let postCommitStatePayloadData: Data
}

private struct PersistedOperationIdentityState: Equatable {
    let batchID: UUID
    let noteID: UUID
    let operationIndex: Int
    let operationIdentityPayloadData: Data
    let canonicalReplayKeyPayloadData: Data
}

private struct PersistedNoteEffectState: Equatable {
    let batchID: UUID
    let noteID: UUID
    let preBodyHash: String?
    let postBodyHash: String?
    let preTitleKeyPayloadData: Data?
    let postTitleKeyPayloadData: Data?
}

private struct PersistedResultEvidenceState: Equatable {
    let batchID: UUID
    let noteID: UUID
    let resultKindRaw: String
    let resultEvidencePayloadData: Data
}

private struct DecodedAffectedNotes: Equatable {
    let version: Int
    let noteIDs: [String]
}

private struct ExpectedAffectedNotesPayloadV1: Codable, Equatable {
    let version: Int
    let noteIDsLowercase: [String]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case noteIDsLowercase = "n"
    }
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

private func seed(note record: SyncConvergenceMutableNoteRecord, in context: ModelContext) {
    let note = Note(title: record.title, content: record.body)
    note.id = record.noteID
    note.createdAt = record.createdAt
    note.modifiedAt = record.modifiedAt
    context.insert(note)
}

private func seedTitleWinner(
    _ winner: SyncConvergenceTitleWinnerProjection,
    updatedAt: Date,
    in context: ModelContext
) throws {
    context.insert(NoteTitleWinner(
        noteID: winner.noteID,
        title: winner.title,
        canonicalReplayKeyPayloadData: try winner.canonicalReplayKey.encodedEvidenceData(),
        operationIdentityPayloadData: try winner.operationIdentity.encodedPayloadData(),
        updatedAt: updatedAt
    ))
}

private func unsupportedKindPayload(from data: Data) throws -> Data {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["kind"] = "unsupported"
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodedAffectedNotes(_ data: Data) throws -> DecodedAffectedNotes {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return DecodedAffectedNotes(
        version: try XCTUnwrap(object["v"] as? Int),
        noteIDs: try XCTUnwrap(object["n"] as? [String])
    )
}

private func captureSwiftDataState(in context: ModelContext) throws -> SwiftDataState {
    SwiftDataState(
        notes: try context.fetch(FetchDescriptor<Note>()).map {
            PersistedNoteState(
                id: $0.id,
                folderID: $0.folder?.id,
                title: $0.title,
                content: $0.content,
                createdAt: $0.createdAt,
                modifiedAt: $0.modifiedAt
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString },
        titleWinners: try context.fetch(FetchDescriptor<NoteTitleWinner>()).map {
            PersistedTitleWinnerState(
                noteID: $0.noteID,
                title: $0.title,
                canonicalReplayKeyPayloadData: $0.canonicalReplayKeyPayloadData,
                operationIdentityPayloadData: $0.operationIdentityPayloadData,
                updatedAt: $0.updatedAt
            )
        }.sorted { $0.noteID.uuidString < $1.noteID.uuidString },
        retainedOperations: try context.fetch(FetchDescriptor<RetainedBodyOperation>()).map {
            PersistedRetainedOperationState(
                noteID: $0.noteID,
                batchID: $0.batchID,
                originDeviceID: $0.originDeviceID,
                operationIndex: $0.operationIndex,
                operationKindRaw: $0.operationKindRaw,
                utf16Offset: $0.utf16Offset,
                utf16Length: $0.utf16Length,
                text: $0.text,
                expectedText: $0.expectedText,
                baseContentHash: $0.baseContentHash,
                resultContentHash: $0.resultContentHash,
                canonicalReplayKeyPayloadData: $0.canonicalReplayKeyPayloadData,
                modifiedAt: $0.modifiedAt,
                sourceRaw: $0.sourceRaw
            )
        }.sorted { ($0.batchID.uuidString, $0.operationIndex) < ($1.batchID.uuidString, $1.operationIndex) },
        snapshots: try context.fetch(FetchDescriptor<NoteContentSnapshot>()).map {
            PersistedSnapshotState(
                noteID: $0.noteID,
                contentHash: $0.contentHash,
                body: $0.body,
                generation: $0.generation,
                createdAt: $0.createdAt
            )
        }.sorted { ($0.noteID.uuidString, $0.generation) < ($1.noteID.uuidString, $1.generation) },
        roots: try context.fetch(FetchDescriptor<IncorporatedSyncBatch>()).map {
            PersistedRootState(
                batchID: $0.batchID,
                originDeviceID: $0.originDeviceID,
                createdAt: $0.createdAt,
                batchSequence: $0.batchSequence,
                schemaVersion: $0.schemaVersion,
                committedAt: $0.committedAt,
                canonicalPayloadDigest: $0.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: $0.canonicalPayloadDigestFormatVersion,
                committedResultDigest: $0.committedResultDigest,
                committedResultDigestFormatVersion: $0.committedResultDigestFormatVersion,
                affectedNotesPayloadData: $0.affectedNotesPayloadData,
                authoritativeChildCount: $0.authoritativeChildCount,
                authoritativeChildBytes: $0.authoritativeChildBytes,
                authoritativeChildrenDigest: $0.authoritativeChildrenDigest,
                postCommitStatePayloadData: $0.postCommitStatePayloadData
            )
        }.sorted { $0.batchID.uuidString < $1.batchID.uuidString },
        operationIdentities: try context.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>()).map {
            PersistedOperationIdentityState(
                batchID: $0.batchID,
                noteID: $0.noteID,
                operationIndex: $0.operationIndex,
                operationIdentityPayloadData: $0.operationIdentityPayloadData,
                canonicalReplayKeyPayloadData: $0.canonicalReplayKeyPayloadData
            )
        }.sorted { ($0.batchID.uuidString, $0.operationIndex) < ($1.batchID.uuidString, $1.operationIndex) },
        noteEffects: try context.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>()).map {
            PersistedNoteEffectState(
                batchID: $0.batchID,
                noteID: $0.noteID,
                preBodyHash: $0.preBodyHash,
                postBodyHash: $0.postBodyHash,
                preTitleKeyPayloadData: $0.preTitleKeyPayloadData,
                postTitleKeyPayloadData: $0.postTitleKeyPayloadData
            )
        }.sorted { $0.noteID.uuidString < $1.noteID.uuidString },
        resultEvidence: try context.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>()).map {
            PersistedResultEvidenceState(
                batchID: $0.batchID,
                noteID: $0.noteID,
                resultKindRaw: $0.resultKindRaw,
                resultEvidencePayloadData: $0.resultEvidencePayloadData
            )
        }.sorted { ($0.noteID.uuidString, $0.resultKindRaw) < ($1.noteID.uuidString, $1.resultKindRaw) }
    )
}

private func assertPersistedOperationIdentities(
    _ rows: [IncorporatedBatchOperationIdentity],
    fixture: SyncConvergenceIncorporationTests.Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let expected = Dictionary(
        uniqueKeysWithValues: fixture.plan.incorporationEvidence.operationIdentities.map {
            ($0.testIdentityKey, $0)
        }
    )
    let decodedRows = try rows.map { row in
        (row, try OperationIdentityPayload.decodePayloadData(row.operationIdentityPayloadData))
    }
    XCTAssertEqual(Set(decodedRows.map { $0.1.testIdentityKey }), Set(expected.keys), file: file, line: line)
    for row in rows {
        let decodedIdentity = try OperationIdentityPayload.decodePayloadData(row.operationIdentityPayloadData)
        let identity = try XCTUnwrap(expected[decodedIdentity.testIdentityKey], file: file, line: line)
        XCTAssertEqual(row.batchID, fixture.batch.id, file: file, line: line)
        XCTAssertEqual(row.noteID, fixture.noteID, file: file, line: line)
        XCTAssertEqual(row.operationIdentityPayloadData, try identity.encodedPayloadData(), file: file, line: line)
        XCTAssertEqual(row.canonicalReplayKeyPayloadData, try identity.canonicalReplayKey.encodedEvidenceData(), file: file, line: line)
        XCTAssertEqual(decodedIdentity, identity, file: file, line: line)
        XCTAssertEqual(try canonicalOperationIdentityBytes(identity), try row.testCanonicalChildBytes, file: file, line: line)
    }
}

private func assertPersistedNoteEffects(
    _ rows: [IncorporatedBatchNoteEffect],
    fixture: SyncConvergenceIncorporationTests.Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let row = try XCTUnwrap(rows.first, file: file, line: line)
    let notePlan = try XCTUnwrap(fixture.plan.affectedNotePlans.first, file: file, line: line)
    let expected = notePlan.testNoteEffectRecord(batchID: fixture.batch.id)
    XCTAssertEqual(rows.count, 1, file: file, line: line)
    XCTAssertEqual(row.batchID, expected.batchID, file: file, line: line)
    XCTAssertEqual(row.noteID, expected.noteID, file: file, line: line)
    XCTAssertEqual(row.preBodyHash, expected.preBodyHash, file: file, line: line)
    XCTAssertEqual(row.postBodyHash, expected.postBodyHash, file: file, line: line)
    XCTAssertEqual(row.preTitleKeyPayloadData, try expected.preTitleKey?.encodedEvidenceData(), file: file, line: line)
    XCTAssertEqual(row.postTitleKeyPayloadData, try expected.postTitleKey?.encodedEvidenceData(), file: file, line: line)

    let expectedKinds = notePlan.testExpectedEffectKinds
    let expectedCanonicalBytes = try canonicalNoteEffectBytes(
        batchID: expected.batchID,
        noteID: expected.noteID,
        kinds: expectedKinds
    )
    XCTAssertEqual(
        try row.testCanonicalChildBytes,
        expectedCanonicalBytes,
        file: file,
        line: line
    )
    XCTAssertTrue(
        SyncConvergenceNoteEffectKindMembership.validate(row.testEffectKinds, expected: Set(expectedKinds)),
        file: file,
        line: line
    )
}

private func assertPersistedResultEvidence(
    _ rows: [IncorporatedBatchResultEvidence],
    fixture: SyncConvergenceIncorporationTests.Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let expected = Dictionary(
        uniqueKeysWithValues: fixture.plan.incorporationEvidence.resultEvidence.map { ($0.kind.rawValue, $0) }
    )
    XCTAssertEqual(Set(rows.map(\.resultKindRaw)), Set(expected.keys), file: file, line: line)
    for row in rows {
        let evidence = try XCTUnwrap(expected[row.resultKindRaw], file: file, line: line)
        XCTAssertEqual(row.batchID, fixture.batch.id, file: file, line: line)
        XCTAssertEqual(row.noteID, fixture.noteID, file: file, line: line)
        XCTAssertEqual(try SyncConvergenceStableEncoding.decode(SyncConvergenceResultEvidence.self, from: row.resultEvidencePayloadData), evidence, file: file, line: line)
        XCTAssertEqual(row.resultEvidencePayloadData, try SyncConvergenceStableEncoding.encode(evidence), file: file, line: line)
        XCTAssertEqual(try canonicalResultEvidenceBytes(evidence), try row.testCanonicalChildBytes, file: file, line: line)
    }
}

private func assertAuthoritativeChildAccounting(
    root: IncorporatedSyncBatch,
    operationIdentities: [IncorporatedBatchOperationIdentity],
    noteEffects: [IncorporatedBatchNoteEffect],
    resultEvidence: [IncorporatedBatchResultEvidence],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let operationChildren = try operationIdentities.map {
        let identity = try OperationIdentityPayload.decodePayloadData($0.operationIdentityPayloadData)
        return PersistedChild(
            kind: "operation",
            key: identity.testIdentityKey,
            bytes: try $0.testCanonicalChildBytes
        )
    }
    let noteEffectChildren = try noteEffects.map {
        PersistedChild(kind: "note-effect", key: $0.noteID.uuidString.lowercased(), bytes: try $0.testCanonicalChildBytes)
    }
    let resultChildren = try resultEvidence.map {
        PersistedChild(kind: "result", key: "\($0.noteID.uuidString.lowercased())|\($0.resultKindRaw)", bytes: try $0.testCanonicalChildBytes)
    }
    let children = (operationChildren + noteEffectChildren + resultChildren).sorted()
    let concatenated = children.reduce(into: Data()) { $0.append($1.bytes) }
    XCTAssertEqual(root.authoritativeChildCount, children.count, file: file, line: line)
    XCTAssertEqual(root.authoritativeChildBytes, concatenated.count, file: file, line: line)
    XCTAssertEqual(root.authoritativeChildrenDigest, sha256Hex(concatenated), file: file, line: line)
}

private func assertPersistedRetainedOperations(
    _ rows: [RetainedBodyOperation],
    fixture: SyncConvergenceIncorporationTests.Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let expected = Dictionary(
        uniqueKeysWithValues: fixture.plan.historyPlan.retainedOperationAdditions.map {
            ($0.operationIdentity.testIdentityKey, $0.testRetainedOperationRecord)
        }
    )
    let rowKeys = try rows.map {
        try CanonicalReplayKeyPayload.decodeEvidenceData($0.canonicalReplayKeyPayloadData).testIdentityKey(
            batchID: $0.batchID,
            operationIndex: $0.operationIndex
        )
    }
    XCTAssertEqual(Set(rowKeys), Set(expected.keys), file: file, line: line)
    for row in rows {
        let key = try CanonicalReplayKeyPayload.decodeEvidenceData(row.canonicalReplayKeyPayloadData).testIdentityKey(
            batchID: row.batchID,
            operationIndex: row.operationIndex
        )
        let operation = try XCTUnwrap(expected[key], file: file, line: line)
        XCTAssertEqual(row.noteID, operation.noteID, file: file, line: line)
        XCTAssertEqual(row.batchID, operation.batchID, file: file, line: line)
        XCTAssertEqual(row.originDeviceID, operation.originDeviceID, file: file, line: line)
        XCTAssertEqual(row.operationKindRaw, operation.operationKind.rawValue, file: file, line: line)
        XCTAssertEqual(row.utf16Offset, operation.utf16Offset, file: file, line: line)
        XCTAssertEqual(row.utf16Length, operation.utf16Length, file: file, line: line)
        XCTAssertEqual(row.text, operation.text, file: file, line: line)
        XCTAssertEqual(row.expectedText, operation.expectedText, file: file, line: line)
        XCTAssertEqual(row.baseContentHash, operation.baseContentHash, file: file, line: line)
        XCTAssertEqual(row.resultContentHash, operation.resultContentHash, file: file, line: line)
        XCTAssertEqual(row.canonicalReplayKeyPayloadData, try operation.canonicalReplayKey.encodedEvidenceData(), file: file, line: line)
        XCTAssertEqual(try CanonicalReplayKeyPayload.decodeEvidenceData(row.canonicalReplayKeyPayloadData), operation.canonicalReplayKey, file: file, line: line)
        XCTAssertEqual(row.modifiedAt, operation.modifiedAt, file: file, line: line)
        XCTAssertEqual(row.sourceRaw, "remote", file: file, line: line)
    }
}

private func assertPersistedSnapshots(
    _ rows: [NoteContentSnapshot],
    fixture: SyncConvergenceIncorporationTests.Fixture,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let expected = Dictionary(
        uniqueKeysWithValues: fixture.plan.historyPlan.snapshotAdditions.map {
            ($0.generation, $0.testSnapshotRecord(createdAt: fixture.committedAt))
        }
    )
    XCTAssertEqual(Set(rows.map(\.generation)), Set(expected.keys), file: file, line: line)
    for row in rows {
        let snapshot = try XCTUnwrap(expected[row.generation], file: file, line: line)
        XCTAssertEqual(row.noteID, snapshot.noteID, file: file, line: line)
        XCTAssertEqual(row.contentHash, snapshot.contentHash, file: file, line: line)
        XCTAssertEqual(row.body, snapshot.body, file: file, line: line)
        XCTAssertEqual(row.createdAt, snapshot.createdAt, file: file, line: line)
    }
}

private struct PersistedChild: Comparable {
    let kind: String
    let key: String
    let bytes: Data

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.key < rhs.key
    }
}

private func canonicalOperationIdentityBytes(_ identity: OperationIdentityPayload) throws -> Data {
    var encoder = CanonicalPayloadDigestFormatV1()
    try encoder.appendOperationIdentity(identity)
    return encoder.data
}

private func canonicalResultEvidenceBytes(_ evidence: SyncConvergenceResultEvidence) throws -> Data {
    var encoder = CanonicalPayloadDigestFormatV1()
    try encoder.appendResultEvidence(evidence)
    return encoder.data
}

private func canonicalNoteEffectBytes(batchID: UUID, noteID: UUID, kinds: [String]) throws -> Data {
    var encoder = CanonicalPayloadDigestFormatV1()
    try encoder.appendProjectedNoteEffect(batchID: batchID, noteID: noteID, kinds: kinds)
    return encoder.data
}

private extension OperationIdentityPayload {
    var testIdentityKey: String {
        "\(batchIDLowercase)|\(operationIndex)"
    }
}

private extension CanonicalReplayKeyPayload {
    func testIdentityKey(batchID: UUID, operationIndex: Int) -> String {
        "\(batchID.uuidString.lowercased())|\(operationIndex)"
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private extension SyncConvergenceNotePlan {
    var plannedFinalBodyForTest: String? {
        switch bodyEffect {
        case .matchingBaseIncremental(let plan):
            return plan.finalBody
        case .reconstructedConflict(let plan):
            return plan.finalBody
        case .legacyPositional(let plan):
            return plan.finalBody
        case .compatibilityNoopMissingNote, .none:
            return nil
        }
    }

    var plannedModifiedAtForTest: Date? {
        if let titleEffect, titleEffect.verdict == .apply {
            return titleEffect.candidateCanonicalKey.modifiedAt
        }
        switch bodyEffect {
        case .matchingBaseIncremental(let plan):
            return plan.operations.map { $0.operationIdentity.canonicalReplayKey.modifiedAt }.max()
        case .reconstructedConflict(let plan):
            return plan.retainedOperationAdditions.map { $0.operationIdentity.canonicalReplayKey.modifiedAt }.max()
        case .legacyPositional(let plan):
            return plan.operations.map { $0.operationIdentity.canonicalReplayKey.modifiedAt }.max()
        case .compatibilityNoopMissingNote, .none:
            return nil
        }
    }

    func testNoteEffectRecord(batchID: UUID) -> SyncConvergenceNoteEffectRecord {
        let bodyHashes: (String?, String?)?
        switch bodyEffect {
        case .matchingBaseIncremental(let plan):
            bodyHashes = (plan.initialBodyHash, plan.finalBodyHash)
        case .reconstructedConflict(let plan):
            bodyHashes = (plan.projectedPreMergeCurrentHash, plan.finalBodyHash)
        case .legacyPositional(let plan):
            bodyHashes = (SyncBatchContentHash.sha256Hex(for: plan.initialBody), plan.finalBodyHash)
        case .compatibilityNoopMissingNote, .none:
            bodyHashes = nil
        }
        return SyncConvergenceNoteEffectRecord(
            batchID: batchID,
            noteID: noteID,
            preBodyHash: bodyHashes?.0,
            postBodyHash: bodyHashes?.1,
            preTitleKey: titleEffect?.priorWinningKey,
            postTitleKey: titleEffect?.resultingWinningKey
        )
    }

    var testExpectedEffectKinds: [String] {
        [
            bodyEffect == nil ? nil : "body",
            titleEffect == nil ? nil : "title",
            creationEffect == nil ? nil : "creation"
        ].compactMap { $0 }
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

private extension IncorporatedBatchOperationIdentity {
    var testCanonicalChildBytes: Data {
        get throws {
            try canonicalOperationIdentityBytes(try OperationIdentityPayload.decodePayloadData(operationIdentityPayloadData))
        }
    }
}

private extension IncorporatedBatchNoteEffect {
    var testEffectKinds: [String] {
        var kinds: [String] = []
        if preBodyHash != nil || postBodyHash != nil { kinds.append("body") }
        if preTitleKeyPayloadData != nil || postTitleKeyPayloadData != nil { kinds.append("title") }
        return kinds
    }

    var testCanonicalChildBytes: Data {
        get throws {
            try canonicalNoteEffectBytes(batchID: batchID, noteID: noteID, kinds: testEffectKinds)
        }
    }
}

private extension IncorporatedBatchResultEvidence {
    var testCanonicalChildBytes: Data {
        get throws {
            try canonicalResultEvidenceBytes(
                try SyncConvergenceStableEncoding.decode(
                    SyncConvergenceResultEvidence.self,
                    from: resultEvidencePayloadData
                )
            )
        }
    }
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
