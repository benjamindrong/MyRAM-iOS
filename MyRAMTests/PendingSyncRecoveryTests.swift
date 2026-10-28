import XCTest
import NearbySyncCore
import SwiftData
@testable import MyRAM

@MainActor
final class PendingSyncRecoveryTests: XCTestCase {
    func testStateBuilderAdmitsAnchoredBatchBeforeCurrentStateLookup() throws {
        let container = try makeContainer()
        let batch = try makeAnchoredInsertBatchForTest()

        XCTAssertThrowsError(try SyncRecoveryStateBuilder.build(
            context: container.mainContext,
            conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
            legacySnapshot: SyncQueueSnapshot(
                pendingChanges: [],
                appliedChangeIDs: [],
                pendingAcknowledgementIDs: []
            ),
            unsentBatches: [batch],
            localConvergenceBatches: [],
            currentDeviceID: "current-device",
            recoveryTimestamp: Date(timeIntervalSince1970: 1_710)
        )) {
            XCTAssertEqual(
                $0 as? SyncRecoveryStateBuilderError,
                .missingCurrentNoteReferencedByUnsentBatch(batch.changes[0].noteID)
            )
        }
    }

    func testStateBuilderReplacesQueuesWithCurrentSwiftDataState() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictFileURL = temporaryConflictURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let parentFolder = Folder(name: "Projects")
        parentFolder.id = UUID(uuidString: "00000000-0000-0000-0000-000000160101")!
        parentFolder.modifiedAt = Date(timeIntervalSince1970: 10)
        let childFolder = Folder(name: "MYR")
        childFolder.id = UUID(uuidString: "00000000-0000-0000-0000-000000160102")!
        childFolder.parentFolder = parentFolder
        childFolder.modifiedAt = Date(timeIntervalSince1970: 11)
        let note = Note(title: "Recovered", content: "Current body", folder: childFolder)
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000160103")!
        note.modifiedAt = Date(timeIntervalSince1970: 12)
        let thought = PinnedThought(text: "Pinned text", order: 0, note: note)
        thought.id = UUID(uuidString: "00000000-0000-0000-0000-000000160104")!
        thought.modifiedAt = Date(timeIntervalSince1970: 13)
        let attachment = NotePhotoAttachment(imageData: Data([1, 2, 3]), note: note)
        attachment.id = UUID(uuidString: "00000000-0000-0000-0000-000000160105")!
        attachment.createdAt = Date(timeIntervalSince1970: 14)
        note.pinnedThoughts.append(thought)
        note.photoAttachments.append(attachment)
        childFolder.notes.append(note)
        parentFolder.childFolders.append(childFolder)
        context.insert(parentFolder)
        context.insert(childFolder)
        context.insert(note)
        context.insert(thought)
        context.insert(attachment)
        try context.save()
        let staleChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160106")!,
            entityType: .item,
            entityID: note.id.uuidString,
            operation: .upsert,
            payload: Data("stale".utf8),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "old-device"
        )
        let appliedID = UUID(uuidString: "00000000-0000-0000-0000-000000160107")!
        let pendingAckID = UUID(uuidString: "00000000-0000-0000-0000-000000160108")!
        let recoveryTimestamp = Date(timeIntervalSince1970: 200)

        let replacement = try SyncRecoveryStateBuilder.build(
            context: context,
            conflictStore: conflictStore,
            legacySnapshot: SyncQueueSnapshot(
                pendingChanges: [staleChange],
                appliedChangeIDs: [appliedID],
                pendingAcknowledgementIDs: [pendingAckID]
            ),
            unsentBatches: [makeBatch(idSuffix: 11, noteID: note.id)],
            localConvergenceBatches: [makeBatch(idSuffix: 12, noteID: note.id)],
            currentDeviceID: "current-device",
            recoveryTimestamp: recoveryTimestamp
        )

        XCTAssertEqual(replacement.unsentBatches, [])
        XCTAssertEqual(replacement.localConvergenceBatches, [])
        XCTAssertEqual(replacement.replacedLegacyCount, 1)
        XCTAssertEqual(replacement.replacedUnsentBatchCount, 1)
        XCTAssertEqual(replacement.replacedLocalObligationCount, 1)
        XCTAssertEqual(replacement.legacySnapshot.appliedChangeIDs, [appliedID])
        XCTAssertEqual(replacement.legacySnapshot.pendingAcknowledgementIDs, [pendingAckID])
        XCTAssertEqual(
            replacement.legacySnapshot.pendingChanges.map { "\($0.entityType.rawValue):\($0.entityID)" },
            [
                "collection:\(parentFolder.id.uuidString)",
                "collection:\(childFolder.id.uuidString)",
                "item:\(note.id.uuidString)",
                "marker:\(thought.id.uuidString)",
                "attachment:\(attachment.id.uuidString)"
            ]
        )
        XCTAssertTrue(replacement.legacySnapshot.pendingChanges.allSatisfy { $0.originDeviceID == "current-device" })
        XCTAssertTrue(replacement.legacySnapshot.pendingChanges.allSatisfy { $0.updatedAt == recoveryTimestamp })
        XCTAssertFalse(replacement.legacySnapshot.pendingChanges.contains { $0.id == staleChange.id })

        let noteChange = try XCTUnwrap(replacement.legacySnapshot.pendingChanges.first { $0.entityType == .item })
        let notePayload = try MyRAMSyncPayloadCoding.decodeNote(from: noteChange.payload)
        XCTAssertEqual(notePayload.title, "Recovered")
        XCTAssertEqual(notePayload.content, "Current body")
        XCTAssertEqual(notePayload.folderID, childFolder.id)
    }

    func testStateBuilderFailsWhenAffectedNoteHasActiveConflict() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictFileURL = temporaryConflictURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Local", content: "Conflict body")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000160201")!
        context.insert(note)
        try context.save()
        _ = conflictStore.preserve(
            SyncConflictVersion(
                entityType: .note,
                entityID: note.id,
                noteID: note.id,
                field: .noteContent,
                localText: "Conflict body",
                remoteText: "Remote body",
                remoteModifiedAt: Date(timeIntervalSince1970: 10),
                preservedAt: Date(),
                expiresAt: Date().addingTimeInterval(1_000)
            )
        )

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: conflictStore,
                legacySnapshot: SyncQueueSnapshot(),
                unsentBatches: [makeBatch(idSuffix: 21, noteID: note.id)],
                localConvergenceBatches: [],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecoveryStateBuilderError,
                .activeConflict(entityType: .note, entityID: note.id)
            )
        }
    }

    func testStateBuilderRebuildsCurrentNoteForLegacyMarkerTarget() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictFileURL = temporaryConflictURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Marker note", content: "")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000160251")!
        let thought = PinnedThought(text: "Current pinned text", order: 0, note: note)
        thought.id = UUID(uuidString: "00000000-0000-0000-0000-000000160252")!
        note.pinnedThoughts.append(thought)
        context.insert(note)
        context.insert(thought)
        try context.save()
        let staleMarker = SyncChange(
            entityType: .marker,
            entityID: thought.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMPinnedThoughtSyncPayload(thought: thought)),
            updatedAt: Date(timeIntervalSince1970: 10),
            originDeviceID: "old-device"
        )

        let replacement = try SyncRecoveryStateBuilder.build(
            context: context,
            conflictStore: conflictStore,
            legacySnapshot: SyncQueueSnapshot(pendingChanges: [staleMarker]),
            unsentBatches: [],
            localConvergenceBatches: [],
            currentDeviceID: "current-device",
            recoveryTimestamp: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(replacement.legacySnapshot.pendingChanges.map(\.entityType), [.item, .marker])
        let markerChange = try XCTUnwrap(replacement.legacySnapshot.pendingChanges.first { $0.entityType == .marker })
        let markerPayload = try MyRAMSyncPayloadCoding.decodePinnedThought(from: markerChange.payload)
        XCTAssertEqual(markerPayload.noteID, note.id)
        XCTAssertEqual(markerPayload.text, "Current pinned text")
    }

    func testStateBuilderRetainsNewestLegacyOnlyDeletionTombstone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictFileURL = temporaryConflictURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let deletedNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160301")!
        let older = try makeDeletedNoteChange(
            noteID: deletedNoteID,
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = try makeDeletedNoteChange(
            noteID: deletedNoteID,
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let recoveryTimestamp = Date(timeIntervalSince1970: 200)

        let replacement = try SyncRecoveryStateBuilder.build(
            context: context,
            conflictStore: SyncConflictStore(fileURL: conflictFileURL),
            legacySnapshot: SyncQueueSnapshot(pendingChanges: [older, newer]),
            unsentBatches: [],
            localConvergenceBatches: [],
            currentDeviceID: "current-device",
            recoveryTimestamp: recoveryTimestamp
        )

        XCTAssertEqual(replacement.legacySnapshot.pendingChanges.count, 1)
        let retained = try XCTUnwrap(replacement.legacySnapshot.pendingChanges.first)
        XCTAssertEqual(retained.entityID, deletedNoteID.uuidString)
        XCTAssertEqual(retained.operation, .delete)
        XCTAssertEqual(retained.updatedAt, recoveryTimestamp)
        XCTAssertEqual(retained.originDeviceID, "current-device")
        XCTAssertNotEqual(retained.id, newer.id)
        let payload = try MyRAMSyncPayloadCoding.decodeNote(from: retained.payload)
        XCTAssertEqual(payload.title, "Newer")
        XCTAssertNotNil(payload.deletedAt)
    }

    func testStateBuilderRejectsInvalidLegacyEntityID() throws {
        let container = try makeContainer()
        let context = container.mainContext

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
                legacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "not-a-uuid")]),
                unsentBatches: [],
                localConvergenceBatches: [],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(error as? SyncRecoveryStateBuilderError, .invalidLegacyEntityID("not-a-uuid"))
        }
    }

    func testStateBuilderRejectsMissingNonDeleteLegacyNote() throws {
        let missingNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160501")!
        let container = try makeContainer()
        let context = container.mainContext

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
                legacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: missingNoteID.uuidString)]),
                unsentBatches: [],
                localConvergenceBatches: [],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecoveryStateBuilderError,
                .missingCurrentEntity(entityType: .item, entityID: missingNoteID)
            )
        }
    }

    func testStateBuilderRejectsMissingNoteReferencedOnlyByUnsentBatch() throws {
        let missingNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160502")!
        let container = try makeContainer()
        let context = container.mainContext

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
                legacySnapshot: SyncQueueSnapshot(),
                unsentBatches: [makeBatch(idSuffix: 41, noteID: missingNoteID)],
                localConvergenceBatches: [],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecoveryStateBuilderError,
                .missingCurrentNoteReferencedByUnsentBatch(missingNoteID)
            )
        }
    }

    func testStateBuilderRejectsMissingNoteReferencedOnlyByLocalObligation() throws {
        let missingNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160503")!
        let container = try makeContainer()
        let context = container.mainContext

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
                legacySnapshot: SyncQueueSnapshot(),
                unsentBatches: [],
                localConvergenceBatches: [makeBatch(idSuffix: 42, noteID: missingNoteID)],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncRecoveryStateBuilderError,
                .missingCurrentNoteReferencedByLocalObligation(missingNoteID)
            )
        }
    }

    func testStateBuilderAllowsMissingBatchNoteWhenValidatedTombstoneExists() throws {
        let deletedNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160504")!
        let container = try makeContainer()
        let context = container.mainContext
        let tombstone = try makeDeletedNoteChange(
            noteID: deletedNoteID,
            title: "Deleted",
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let replacement = try SyncRecoveryStateBuilder.build(
            context: context,
            conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
            legacySnapshot: SyncQueueSnapshot(pendingChanges: [tombstone]),
            unsentBatches: [makeBatch(idSuffix: 43, noteID: deletedNoteID)],
            localConvergenceBatches: [],
            currentDeviceID: "current-device",
            recoveryTimestamp: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(replacement.legacySnapshot.pendingChanges.map(\.entityID), [deletedNoteID.uuidString])
        XCTAssertEqual(replacement.legacySnapshot.pendingChanges.first?.operation, .delete)
    }

    func testStateBuilderRejectsPendingLegacyConflictMetadata() throws {
        let conflictID = UUID(uuidString: "00000000-0000-0000-0000-000000160505")!
        let container = try makeContainer()
        let context = container.mainContext
        let change = SyncChange(
            entityType: .conflict,
            entityID: conflictID.uuidString,
            operation: .upsert,
            payload: Data(),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "old-device"
        )

        XCTAssertThrowsError(
            try SyncRecoveryStateBuilder.build(
                context: context,
                conflictStore: SyncConflictStore(fileURL: temporaryConflictURL()),
                legacySnapshot: SyncQueueSnapshot(pendingChanges: [change]),
                unsentBatches: [],
                localConvergenceBatches: [],
                currentDeviceID: "current-device",
                recoveryTimestamp: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(error as? SyncRecoveryStateBuilderError, .unsupportedPendingLegacyConflictMetadata(conflictID))
        }
    }

    func testCoordinatorBuilderFailureLeavesQueuesAndJournalUntouched() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let originalLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: UUID().uuidString)])
        let originalUnsent = [makeBatch(idSuffix: 51)]
        let originalLocal = [makeBatch(idSuffix: 52)]
        var localBatches = originalLocal
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: originalLegacy,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(pendingBatches: originalUnsent, health: .healthy)
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: localBatches.map(SyncConvergenceLocalObligation.init(legacyBatch:)), health: .healthy)
            },
            replaceLocalObligations: { batches in
                localBatches = batches.map(\.batch)
            },
            flushReadyLocalBatch: { nil },
            journalStore: PendingSyncRecoveryJournalStore(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 100) },
            transactionID: { UUID(uuidString: "00000000-0000-0000-0000-000000160506")! }
        )

        do {
            try await coordinator.resetPendingSync(
                prepareDurableState: {},
                buildReplacement: { _, _, _, _ in
                    throw SyncRecoveryStateBuilderError.missingCurrentNoteReferencedByUnsentBatch(UUID())
                }
            )
            XCTFail("Expected builder failure")
        } catch {
            XCTAssertTrue(error is SyncRecoveryStateBuilderError)
        }

        XCTAssertEqual(admin.legacySnapshot, originalLegacy)
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, originalUnsent)
        XCTAssertEqual(localBatches, originalLocal)
        XCTAssertFalse(admin.isSuspended)
        XCTAssertNil(try PendingSyncRecoveryJournalStore(fileURL: fileURL).load())
    }

    func testLaunchRollbackPreservesWorkQueuedAfterFailedRecoveryAcrossRetry() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let journal = makeJournal()
        try store.save(journal)
        let laterChange = makeLegacyChange(entityID: "offline-note")
        let laterBatch = makeBatch(idSuffix: 81)
        let laterLocal = makeBatch(idSuffix: 82)
        var local = journal.replacementLocalObligations + [laterLocal]
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: SyncQueueSnapshot(pendingChanges: journal.replacementLegacySnapshot.pendingChanges + [laterChange]),
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(
                pendingBatches: journal.replacementUnsentBatches + [laterBatch], health: .healthy
            )
        )
        func coordinator() -> PendingSyncRecoveryCoordinator {
            PendingSyncRecoveryCoordinator(
                queueAdmin: admin,
                localQueueSnapshot: { FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: local.map(SyncConvergenceLocalObligation.init(legacyBatch:)), health: .healthy) },
                replaceLocalObligations: { local = $0.map(\.batch) },
                flushReadyLocalBatch: { nil },
                journalStore: store
            )
        }
        admin.failNextUnsentReplacement = true
        do {
            try await coordinator().rollbackIfNeededOnLaunch()
            XCTFail("Expected rollback failure")
        } catch {
            XCTAssertEqual(error as? PendingSyncRecoveryCoordinator.RecoveryError, .rollbackFailed)
        }
        XCTAssertTrue(admin.isSuspended)
        // Recreate the coordinator to exercise the durable continuation, not its memory.
        try await coordinator().rollbackIfNeededOnLaunch()
        XCTAssertEqual(admin.legacySnapshot.pendingChanges, journal.originalLegacySnapshot.pendingChanges + [laterChange])
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, journal.originalUnsentBatches + [laterBatch])
        XCTAssertEqual(local, journal.originalLocalObligations + [laterLocal])
        XCTAssertNil(try store.load())
    }

    func testRollbackRestoresCapturedEvidenceAfterQueueReplacementAndRelaunch() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let queueURL = fileURL.deletingLastPathComponent().appendingPathComponent("local.json")
        let batch = makeBatch(idSuffix: 83)
        let captured = SyncConvergenceLocalObligation(
            batch: batch,
            capturedChanges: batch.changes.map { SyncConvergenceCapturedLocalChange(change: $0, evidence: nil) }
        )
        try store.save(PendingSyncRecoveryJournal(
            originalLegacySnapshot: SyncQueueSnapshot(), originalUnsentBatches: [],
            originalLocalObligations: [batch], replacementLegacySnapshot: SyncQueueSnapshot(),
            replacementUnsentBatches: [], replacementLocalObligations: [], originalLocalEvidence: [captured]
        ))
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: SyncQueueSnapshot(),
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
        )
        let queue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: queueURL, limit: 1)
        let later = SyncConvergenceLocalObligation(legacyBatch: makeBatch(idSuffix: 84))
        try queue.enqueue(later)
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: { FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: queue.pendingObligations, health: queue.snapshot().health) },
            replaceLocalObligations: { try queue.replacePendingObligations($0) },
            flushReadyLocalBatch: { nil }, journalStore: store
        )
        try await coordinator.rollbackIfNeededOnLaunch()
        let reloaded = FileBackedSyncConvergenceLocalObligationQueue(fileURL: queueURL, limit: 1)
        XCTAssertEqual(reloaded.pendingObligations, [captured, later])
        XCTAssertThrowsError(try reloaded.enqueue(SyncConvergenceLocalObligation(legacyBatch: makeBatch(idSuffix: 85))))
        var unsent = SyncBatchUnsentQueue(limit: 1)
        unsent.replacePendingBatches([batch, later.batch])
        XCTAssertEqual(unsent.pendingBatches, [batch, later.batch])
    }

    func testJournalStorePersistsPhaseUpdatesAndDeletes() throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let journal = makeJournal()

        try store.save(journal)
        XCTAssertEqual(try store.load(), journal)

        var expected = journal
        expected.phase = .legacyReplaced
        XCTAssertEqual(try store.updatePhase(.legacyReplaced), expected)
        XCTAssertEqual(try store.load()?.phase, .legacyReplaced)

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testCoordinatorRollsBackOriginalQueuesWhenReplacementFailsAfterLegacy() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let originalLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-1")])
        let replacementLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-2")])
        let originalUnsent = [makeBatch(idSuffix: 1)]
        let originalLocal = [makeBatch(idSuffix: 2)]
        var localBatches = originalLocal
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: originalLegacy,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(
                pendingBatches: originalUnsent,
                health: .healthy
            )
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: localBatches.map(SyncConvergenceLocalObligation.init(legacyBatch:)), health: .healthy)
            },
            replaceLocalObligations: { batches in
                localBatches = batches.map(\.batch)
            },
            flushReadyLocalBatch: { nil },
            journalStore: PendingSyncRecoveryJournalStore(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 100) },
            transactionID: { UUID(uuidString: "00000000-0000-0000-0000-000000160001")! }
        )
        admin.failNextUnsentReplacement = true
        let replacement = SyncRecoveryReplacementState(
            legacySnapshot: replacementLegacy,
            unsentBatches: [],
            localConvergenceBatches: [],
            replacedLegacyCount: 1,
            replacedUnsentBatchCount: 1,
            replacedLocalObligationCount: 1
        )

        do {
            try await coordinator.commitReplacement(replacement)
            XCTFail("Expected replacement failure")
        } catch {
            XCTAssertEqual(error as? PendingSyncRecoveryCoordinator.RecoveryError, .replacementFailed)
        }

        XCTAssertEqual(admin.legacySnapshot, originalLegacy)
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, originalUnsent)
        XCTAssertEqual(localBatches, originalLocal)
        XCTAssertFalse(admin.isSuspended)
        XCTAssertNil(try PendingSyncRecoveryJournalStore(fileURL: fileURL).load())
    }

    func testCoordinatorBuildsReplacementWhileSuspendedAndFlushesAfterCommit() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let originalLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-1")])
        let replacementLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-2")])
        var localBatches = [makeBatch(idSuffix: 31)]
        var didPrepare = false
        var didFlushLocal = false
        var didBuildWhileSuspended = false
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: originalLegacy,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [makeBatch(idSuffix: 32)],
                health: .healthy
            )
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: localBatches.map(SyncConvergenceLocalObligation.init(legacyBatch:)), health: .healthy)
            },
            replaceLocalObligations: { batches in
                localBatches = batches.map(\.batch)
            },
            flushReadyLocalBatch: {
                didFlushLocal = true
                return nil
            },
            journalStore: PendingSyncRecoveryJournalStore(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 100) },
            transactionID: { UUID(uuidString: "00000000-0000-0000-0000-000000160401")! }
        )

        try await coordinator.resetPendingSync(
            prepareDurableState: {
                didPrepare = true
            },
            buildReplacement: { legacy, unsent, local, _ in
                XCTAssertTrue(didPrepare)
                XCTAssertTrue(didFlushLocal)
                XCTAssertEqual(legacy, originalLegacy)
                XCTAssertEqual(unsent.count, 1)
                XCTAssertEqual(local.count, 1)
                didBuildWhileSuspended = admin.isSuspended
                return SyncRecoveryReplacementState(
                    legacySnapshot: replacementLegacy,
                    unsentBatches: [],
                    localConvergenceBatches: [],
                    replacedLegacyCount: legacy.pendingChanges.count,
                    replacedUnsentBatchCount: unsent.count,
                    replacedLocalObligationCount: local.count
                )
            }
        )

        XCTAssertTrue(didBuildWhileSuspended)
        XCTAssertEqual(admin.legacySnapshot, replacementLegacy)
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, [])
        XCTAssertEqual(localBatches, [])
        XCTAssertFalse(admin.isSuspended)
        XCTAssertTrue(admin.didFlushAllOutboundWork)
        XCTAssertNil(try PendingSyncRecoveryJournalStore(fileURL: fileURL).load())
    }

    func testPrepareSnapshotsRejectsCapturedBatchMissingFromDurableQueues() async throws {
        let capturedBatchID = UUID(uuidString: "00000000-0000-0000-0000-000000160601")!
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: SyncQueueSnapshot(),
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: [], health: .healthy)
            },
            replaceLocalObligations: { _ in },
            flushReadyLocalBatch: { capturedBatchID }
        )

        do {
            _ = try await coordinator.prepareSnapshots()
            XCTFail("Expected captured batch durability failure")
        } catch {
            XCTAssertEqual(
                error as? PendingSyncRecoveryCoordinator.RecoveryError,
                .capturedBatchNotDurable(capturedBatchID)
            )
        }
    }

    private func temporaryJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pending-sync-recovery-journal.json")
    }

    private func temporaryConflictURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "PendingSyncRecoveryTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeJournal() -> PendingSyncRecoveryJournal {
        PendingSyncRecoveryJournal(
            transactionID: UUID(uuidString: "00000000-0000-0000-0000-000000160000")!,
            createdAt: Date(timeIntervalSince1970: 100),
            originalLegacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-1")]),
            originalUnsentBatches: [makeBatch(idSuffix: 1)],
            originalLocalObligations: [makeBatch(idSuffix: 2)],
            replacementLegacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-2")]),
            replacementUnsentBatches: [],
            replacementLocalObligations: []
        )
    }

    private func makeLegacyChange(entityID: String) -> SyncChange {
        SyncChange(
            entityType: .item,
            entityID: entityID,
            operation: .upsert,
            payload: Data(entityID.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
    }

    private func makeBatch(idSuffix: Int, noteID: UUID = UUID()) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000160999")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "Queued title \(idSuffix)",
                        modifiedAt: Date(timeIntervalSince1970: TimeInterval(idSuffix))
                    )
                )
            ]
        )
    }

    private func makeDeletedNoteChange(noteID: UUID, title: String, updatedAt: Date) throws -> SyncChange {
        let note = Note(title: title, content: "")
        note.id = noteID
        note.modifiedAt = updatedAt
        note.deletedAt = updatedAt
        return SyncChange(
            id: UUID(),
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: note)),
            updatedAt: updatedAt,
            originDeviceID: "old-device"
        )
    }
}

@MainActor
final class NotesListStateBootstrapTests: XCTestCase {
    func testBootstrapRunsLaunchRecoveryBeforeNetworkingAndEditing() async throws {
        let container = try makeContainer()
        var events: [String] = []
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        events.append("rollback")
                    },
                    migrateNoteSequenceStates: {
                        events.append("migrate-note-sequence-states")
                    },
                    refreshPendingSyncStatus: {
                        events.append("refresh-status")
                    },
                    resumeOutboundAfterRecovery: {
                        events.append("resume-outbound")
                    },
                    startNetworkingIfNeeded: {
                        events.append("start-networking")
                    },
                    resumePendingConvergencePresentationIfNeeded: {
                        events.append("resume-convergence-presentation")
                    }
                )
            }
        )

        XCTAssertEqual(state.bootstrapState, .recovering)

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(
            events,
            [
                "rollback",
                "migrate-note-sequence-states",
                "refresh-status",
                "resume-outbound",
                "start-networking",
                "resume-convergence-presentation"
            ]
        )
        XCTAssertEqual(state.bootstrapState, .ready)
    }

    func testPendingEditorPersistenceMustFinishBeforeSyncRecoveryCanResume() async {
        var canSave = false
        var persisted: [String] = []
        let core = NoteEditorLifecyclePersistenceCore(persist: { snapshot in
            guard canSave else { return false }
            persisted.append(snapshot.body)
            return true
        })
        let snapshot = NoteEditorLifecycleSnapshot(
            noteID: UUID(), title: "Synthetic", body: "Pending edit", richTextContentData: nil,
            structuralFormattingProjection: nil, generation: UUID()
        )
        core.accept(snapshot)
        let failed = await core.awaitAllDurableCompletion()
        XCTAssertFalse(failed)
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: snapshot.noteID), snapshot.generation)
        canSave = true
        let recovered = await core.awaitAllDurableCompletion()
        XCTAssertTrue(recovered)
        XCTAssertEqual(persisted, ["Pending edit"])
    }

    func testCorruptSyncJournalDoesNotBlockDiskBackedNotesAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        try Data("invalid synthetic journal".utf8).write(to: journalURL)
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR238Synthetic", schema: schema, url: directory.appendingPathComponent("notes.store"),
            cloudKitDatabase: .none
        )
        func openContainer() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: configuration)
        }
        func state(for container: ModelContainer) -> NotesListState {
            NotesListState(context: container.mainContext, startsBootstrapAutomatically: false) { vm, sync in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        try await vm.rollbackIfNeededOnLaunch(
                            syncController: sync, journalStore: PendingSyncRecoveryJournalStore(fileURL: journalURL)
                        )
                    },
                    migrateNoteSequenceStates: {
                        try await NoteSequenceStateBootstrapMigrator(container: container).runToCompletion()
                    },
                    completeModelInitializationAfterMigration: { vm.completeStartupInitializationAfterMigration() },
                    refreshPendingSyncStatus: {}, resumeOutboundAfterRecovery: {},
                    startNetworkingIfNeeded: {}, resumePendingConvergencePresentationIfNeeded: {}
                )
            }
        }
        let id: UUID
        do {
            let container = try openContainer()
            let first = state(for: container)
            await first.bootstrapAfterRecovery()
            XCTAssertEqual(first.bootstrapState, .ready)
            XCTAssertNotNil(first.syncRecoveryMessage)
            let note = try XCTUnwrap(first.vm.createNewNote())
            id = note.id
            let saved = await first.vm.commitNoteEditForProduction(note, title: "Synthetic offline", content: "Keep this exact text")
            XCTAssertTrue(saved)
        }
        let reopened = try openContainer()
        let relaunched = state(for: reopened)
        await relaunched.bootstrapAfterRecovery()
        XCTAssertEqual(relaunched.bootstrapState, .ready)
        let note = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Note>()).first { $0.id == id })
        XCTAssertEqual(note.title, "Synthetic offline")
        XCTAssertEqual(note.content, "Keep this exact text")
        // Remove only the synthetic fault; retry must preserve the current local version.
        try FileManager.default.removeItem(at: journalURL)
        await relaunched.bootstrapAfterRecovery()
        XCTAssertNil(relaunched.syncRecoveryMessage)
        XCTAssertEqual(note.content, "Keep this exact text")
    }

    func testSyncRecoveryFailureAllowsLocalCreateEditSaveAndRetry() async throws {
        let container = try makeContainer()
        var fails = true
        var networkingStarts = 0
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { vm, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        if fails { throw PendingSyncRecoveryCoordinator.RecoveryError.rollbackFailed }
                    },
                    migrateNoteSequenceStates: {},
                    completeModelInitializationAfterMigration: { vm.completeStartupInitializationAfterMigration() },
                    refreshPendingSyncStatus: {},
                    resumeOutboundAfterRecovery: {},
                    startNetworkingIfNeeded: { networkingStarts += 1 },
                    resumePendingConvergencePresentationIfNeeded: {}
                )
            }
        )
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(networkingStarts, 0)
        let note = try XCTUnwrap(state.vm.createNewNote())
        let saved = await state.vm.commitNoteEditForProduction(note, title: "Offline", content: "Durable local edit")
        XCTAssertTrue(saved)
        let id = note.id
        fails = false
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(networkingStarts, 1)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(reloaded.first { $0.id == id }?.content, "Durable local edit")
        XCTAssertEqual(state.vm.currentNote?.id, id)
    }

    func testBootstrapKeepsLocalNotesReadyWhenLaunchRecoveryFails() async throws {
        let container = try makeContainer()
        let saved = Note(title: "Preserved title", content: "Preserved body")
        container.mainContext.insert(saved)
        try container.mainContext.save()
        var events: [String] = []
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        events.append("rollback")
                        throw PendingSyncRecoveryCoordinator.RecoveryError.rollbackFailed
                    },
                    migrateNoteSequenceStates: {
                        events.append("migrate-note-sequence-states")
                    },
                    refreshPendingSyncStatus: {
                        events.append("refresh-status")
                    },
                    resumeOutboundAfterRecovery: {
                        events.append("resume-outbound")
                    },
                    startNetworkingIfNeeded: {
                        events.append("start-networking")
                    },
                    resumePendingConvergencePresentationIfNeeded: {
                        events.append("resume-convergence-presentation")
                    }
                )
            }
        )

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(events, ["rollback", "migrate-note-sequence-states"])
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertNotNil(state.syncRecoveryMessage)
        XCTAssertFalse(state.didFailToReadNotesDuringStartupFailure)
        XCTAssertFalse(state.isBootstrapping)
    }

    func testMigrationFailurePreservesReadOnlyAccessWithoutStartingSync() async throws {
        let container = try makeContainer()
        let saved = Note(title: "Original", content: "Unchanged content")
        container.mainContext.insert(saved)
        try container.mainContext.save()
        var events: [String] = []
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: { events.append("rollback") },
                    migrateNoteSequenceStates: {
                        events.append("migration")
                        throw NoteSequenceStateStoreError.persistenceFailure
                    },
                    completeModelInitializationAfterMigration: { events.append("initialize") },
                    refreshPendingSyncStatus: { events.append("status") },
                    resumeOutboundAfterRecovery: { events.append("outbound") },
                    startNetworkingIfNeeded: { events.append("networking") },
                    resumePendingConvergencePresentationIfNeeded: { events.append("convergence") }
                )
            }
        )

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(events, ["rollback", "migration"])
        XCTAssertEqual(state.readableNotesDuringStartupFailure.map(\.id), [saved.id])
        XCTAssertEqual(state.readableNotesDuringStartupFailure.first?.content, "Unchanged content")
        XCTAssertFalse(state.didFailToReadNotesDuringStartupFailure)
        guard case .failed = state.bootstrapState else {
            return XCTFail("Unfinished migration must not enable editing or syncing")
        }
    }

    func testSuccessfulRetryRestoresNormalBootstrapWithoutDroppingNotes() async throws {
        let container = try makeContainer()
        let saved = Note(title: "Original", content: "Durable text")
        container.mainContext.insert(saved)
        try container.mainContext.save()
        var rollbackFails = true
        var starts = 0
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        if rollbackFails {
                            throw PendingSyncRecoveryCoordinator.RecoveryError.rollbackFailed
                        }
                    },
                    migrateNoteSequenceStates: {},
                    refreshPendingSyncStatus: {},
                    resumeOutboundAfterRecovery: {},
                    startNetworkingIfNeeded: { starts += 1 },
                    resumePendingConvergencePresentationIfNeeded: {}
                )
            }
        )

        await state.bootstrapAfterRecovery()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertNotNil(state.syncRecoveryMessage)

        rollbackFails = false
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(state.readableNotesDuringStartupFailure.isEmpty)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Note>()).first?.content, "Durable text")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "NotesListStateBootstrapTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

@MainActor
private final class FakePendingSyncQueueAdmin: PendingSyncQueueAdministrating {
    var legacySnapshot: SyncQueueSnapshot
    var legacyHealth: SyncQueuePersistenceHealth = .healthy
    var unsentSnapshot: FileBackedSyncBatchQueueSnapshot
    var isSuspended = false
    var didFlushAllOutboundWork = false
    var failNextUnsentReplacement = false

    init(legacySnapshot: SyncQueueSnapshot, unsentSnapshot: FileBackedSyncBatchQueueSnapshot) {
        self.legacySnapshot = legacySnapshot
        self.unsentSnapshot = unsentSnapshot
    }

    func suspendOutboundForRecovery() {
        isSuspended = true
    }

    func resumeOutboundAfterRecovery() {
        isSuspended = false
    }

    func legacyQueueSnapshot() async -> SyncQueueSnapshot {
        legacySnapshot
    }

    func legacyQueueHealth() async -> SyncQueuePersistenceHealth {
        legacyHealth
    }

    func replaceLegacyQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws {
        legacySnapshot = snapshot
    }

    func unsentBatchQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot {
        unsentSnapshot
    }

    func replaceUnsentBatches(_ batches: [SyncBatch]) async throws {
        if failNextUnsentReplacement {
            failNextUnsentReplacement = false
            throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
        }
        unsentSnapshot = FileBackedSyncBatchQueueSnapshot(pendingBatches: batches, health: .healthy)
    }

    func refreshPendingSyncStatus() async {}

    func flushAllOutboundWork() {
        didFlushAllOutboundWork = true
    }
}
