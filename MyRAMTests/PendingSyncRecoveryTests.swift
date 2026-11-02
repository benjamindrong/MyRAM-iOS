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

    func testMYR238QueueOwnershipCaptureDetectsChangedOrUnhealthyQueues() async throws {
        let legacy = SyncQueueSnapshot(
            pendingChanges: [makeLegacyChange(entityID: "offline-note")],
            appliedChangeIDs: [UUID()],
            pendingAcknowledgementIDs: [UUID()]
        )
        let unsent = makeBatch(idSuffix: 251)
        let originalLocal = makeBatch(idSuffix: 252)
        var local = [SyncConvergenceLocalObligation(legacyBatch: originalLocal)]
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: legacy,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [unsent], health: .healthy
            )
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                    obligations: local, health: .healthy
                )
            },
            replaceLocalObligations: { local = $0 },
            flushReadyLocalBatch: { nil }
        )
        let incoming = makeBatch(idSuffix: 253)
        let healthyIncoming = FileBackedSyncBatchQueueSnapshot(
            pendingBatches: [incoming], health: .healthy
        )
        let captured = try await coordinator.captureLocalResolutionQueueOwnership(
            incomingSnapshot: healthyIncoming
        )
        XCTAssertEqual(captured.legacy, legacy)
        XCTAssertEqual(captured.unsent, [unsent])
        XCTAssertEqual(captured.incoming, [incoming])
        XCTAssertEqual(captured.localObligations, local)
        try await coordinator.requireUnchangedLocalResolutionQueueOwnership(
            captured, incomingSnapshot: healthyIncoming
        )

        local.append(SyncConvergenceLocalObligation(legacyBatch: makeBatch(idSuffix: 254)))
        do {
            try await coordinator.requireUnchangedLocalResolutionQueueOwnership(
                captured, incomingSnapshot: healthyIncoming
            )
            XCTFail("New pending local edit must invalidate queue ownership preimage")
        } catch let error as PendingSyncRecoveryCoordinator.RecoveryError {
            XCTAssertEqual(error, .staleLocalResolutionQueueOwnership)
        }

        do {
            _ = try await coordinator.captureLocalResolutionQueueOwnership(
                incomingSnapshot: FileBackedSyncBatchQueueSnapshot(
                    pendingBatches: [], health: .corrupt
                )
            )
            XCTFail("Unreadable incoming queue cannot be captured as empty")
        } catch let error as PendingSyncRecoveryCoordinator.RecoveryError {
            XCTAssertEqual(error, .unhealthyIncomingBatchQueue)
        }
        XCTAssertFalse(admin.isSuspended)
        XCTAssertFalse(admin.didFlushAllOutboundWork)
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

    func testRollbackRetainsAdmissionsDuringAwaitedQueueReplacement() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let journal = makeJournal()
        try store.save(journal)
        let admittedWhileLegacyReplaces = makeBatch(idSuffix: 91)
        let admittedWhileUnsentReplaces = makeBatch(idSuffix: 92)
        let transferredToUnsent = makeBatch(idSuffix: 93)
        let originalCaptured = SyncConvergenceLocalObligation(
            batch: journal.originalLocalObligations[0],
            capturedChanges: journal.originalLocalObligations[0].changes.map {
                SyncConvergenceCapturedLocalChange(change: $0, evidence: nil)
            }
        )
        let lateCaptured = SyncConvergenceLocalObligation(
            batch: admittedWhileUnsentReplaces,
            capturedChanges: admittedWhileUnsentReplaces.changes.map {
                SyncConvergenceCapturedLocalChange(change: $0, evidence: nil)
            }
        )
        var local = [originalCaptured]
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: journal.replacementLegacySnapshot,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
        )
        admin.afterLegacyReplacement = {
            // A local capture finishes while the legacy actor replacement awaits.
            admin.unsentSnapshot = FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [admittedWhileLegacyReplaces], health: .healthy
            )
            local.append(SyncConvergenceLocalObligation(legacyBatch: transferredToUnsent))
        }
        admin.afterUnsentReplacement = {
            // A second capture arrives before the local-obligation replacement.
            local.append(lateCaptured)
            // A transferred batch must have one durable owner, not two.
            admin.unsentSnapshot = FileBackedSyncBatchQueueSnapshot(
                pendingBatches: admin.unsentSnapshot.pendingBatches + [transferredToUnsent],
                health: .healthy
            )
        }
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: local, health: .healthy)
            },
            replaceLocalObligations: { local = $0 },
            flushReadyLocalBatch: { nil },
            journalStore: store
        )
        try await coordinator.rollbackIfNeededOnLaunch()
        XCTAssertEqual(
            admin.unsentSnapshot.pendingBatches,
            journal.originalUnsentBatches + [admittedWhileLegacyReplaces, transferredToUnsent]
        )
        XCTAssertEqual(local, [originalCaptured, lateCaptured])
        XCTAssertNil(try store.load())
    }

    func testInterruptedRollbackRetainsAdmissionsCapturedAtLaterPhase() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let journal = makeJournal()
        try store.save(journal)
        let afterLegacy = makeBatch(idSuffix: 94)
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: journal.replacementLegacySnapshot,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
        )
        var local = journal.originalLocalObligations.map(SyncConvergenceLocalObligation.init(legacyBatch:))
        admin.afterLegacyReplacement = {
            admin.unsentSnapshot = FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [afterLegacy], health: .healthy
            )
        }
        admin.failNextUnsentReplacement = true
        func coordinator() -> PendingSyncRecoveryCoordinator {
            PendingSyncRecoveryCoordinator(
                queueAdmin: admin,
                localQueueSnapshot: {
                    FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: local, health: .healthy)
                },
                replaceLocalObligations: { local = $0 },
                flushReadyLocalBatch: { nil },
                journalStore: store
            )
        }
        do {
            try await coordinator().rollbackIfNeededOnLaunch()
            XCTFail("Expected injected interruption")
        } catch {
            XCTAssertEqual(error as? PendingSyncRecoveryCoordinator.RecoveryError, .rollbackFailed)
        }
        XCTAssertTrue(try XCTUnwrap(store.load()).originalUnsentBatches.contains(afterLegacy))
        try await coordinator().rollbackIfNeededOnLaunch()
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, journal.originalUnsentBatches + [afterLegacy])
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
    func testMYR238RealStartupPathWithIsolatedCapturedNotes() async throws {
        // Provisioned only by the sealed-capture runner inside a disposable
        // iOS Simulator Verification app sandbox; never uses production storage.
        let documentRoot = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].resolvingSymlinksInPath()
        let fixture = documentRoot.appendingPathComponent(
            "MYR238-Isolated-Restore", isDirectory: true
        )
        let marker = fixture.appendingPathComponent("approval-marker.txt")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Dedicated isolated iOS restore fixture not staged")
        }
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "MYR238-ISOLATED-IOS-RESTORE-v1\n"
        )
        let restored = fixture.appendingPathComponent("restored", isDirectory: true)
        let storeURL = restored.appendingPathComponent(
            "group/Library/Application Support/MyRAM_Main.store"
        )
        let journalURL = restored.appendingPathComponent(
            "app/Library/Application Support/MyRAM/pending-sync-recovery-journal.json"
        )
        guard fixture.resolvingSymlinksInPath().path.hasPrefix(documentRoot.path + "/"),
              storeURL.resolvingSymlinksInPath().path.hasPrefix(fixture.path + "/"),
              journalURL.resolvingSymlinksInPath().path.hasPrefix(fixture.path + "/"),
              FileManager.default.fileExists(atPath: storeURL.path),
              !FileManager.default.fileExists(atPath: journalURL.path) else {
            XCTFail("Restoration fixture boundary or journal state invalid")
            return
        }

        struct PinSignature: Equatable {
            let id: UUID
            let text: String
            let order: Int
            let collapsed: Bool
            let createdAt: Date
            let modifiedAt: Date
        }
        struct AttachmentSignature: Equatable {
            let id: UUID
            let imageData: Data
            let createdAt: Date
        }
        struct NoteSignature: Equatable {
            let id: UUID
            let title: String
            let content: String
            let richText: Data?
            let pinned: Bool?
            let createdAt: Date
            let modifiedAt: Date
            let deletedAt: Date?
            let folderID: UUID?
            let pinnedText: [PinSignature]
            let attachments: [AttachmentSignature]
        }
        struct FolderSignature: Equatable {
            let id: UUID
            let name: String
            let createdAt: Date
            let modifiedAt: Date
            let parentID: UUID?
        }
        func signature(_ container: ModelContainer) throws -> ([NoteSignature], [FolderSignature]) {
            let context = ModelContext(container)
            let notes = try context.fetch(FetchDescriptor<Note>())
                .map { note in
                    NoteSignature(
                        id: note.id, title: note.title, content: note.content,
                        richText: note.richTextContentData, pinned: note.isPinned,
                        createdAt: note.createdAt, modifiedAt: note.modifiedAt,
                        deletedAt: note.deletedAt, folderID: note.folder?.id,
                        pinnedText: note.pinnedThoughts.map {
                            PinSignature(id: $0.id, text: $0.text, order: $0.order,
                                         collapsed: $0.isCollapsed,
                                         createdAt: $0.createdAt, modifiedAt: $0.modifiedAt)
                        }.sorted { $0.id.uuidString < $1.id.uuidString },
                        attachments: note.photoAttachments.map {
                            AttachmentSignature(id: $0.id, imageData: $0.imageData,
                                                createdAt: $0.createdAt)
                        }.sorted { $0.id.uuidString < $1.id.uuidString }
                    )
                }.sorted { $0.id.uuidString < $1.id.uuidString }
            let folders = try context.fetch(FetchDescriptor<Folder>())
                .map {
                    FolderSignature(id: $0.id, name: $0.name,
                                    createdAt: $0.createdAt, modifiedAt: $0.modifiedAt,
                                    parentID: $0.parentFolder?.id)
                }.sorted { $0.id.uuidString < $1.id.uuidString }
            return (notes, folders)
        }

        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR238-Isolated-Captured-Store", schema: schema, url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        container.mainContext.autosaveEnabled = false
        let before = try signature(container)
        XCTAssertFalse(before.0.isEmpty, "Captured note store unexpectedly empty")

        // Classify the persisted sequence authority BEFORE startup may write a
        // migration. Never print IDs, bodies, payloads, filenames, or error descriptions.
        let preflightContext = ModelContext(container)
        preflightContext.autosaveEnabled = false
        let persistedRows = try preflightContext.fetch(FetchDescriptor<NoteSequenceStateRecord>())
        var existingRows: [UUID: NoteSequenceStateRecord] = [:]
        var duplicateSequenceRows = 0
        for row in persistedRows {
            if existingRows.updateValue(row, forKey: row.noteID) != nil {
                duplicateSequenceRows += 1
            }
        }
        let inputNotes = try preflightContext.fetch(FetchDescriptor<Note>())
        var missingStateRows = 0
        var invalidStateRows = 0
        var mismatchedVisibleText = 0
        var validStateRows = 0
        var otherSequenceErrorRows = 0
        for note in inputNotes {
            guard let record = existingRows[note.id] else {
                missingStateRows += 1
                continue
            }
            do {
                let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                    record: record, noteID: note.id
                )
                if NoteSequenceStateExactText.matches(state.visibleText, note.content) {
                    validStateRows += 1
                } else {
                    mismatchedVisibleText += 1
                }
            } catch let error as NoteSequenceStateStoreError {
                if case .corruptState = error {
                    invalidStateRows += 1
                } else {
                    otherSequenceErrorRows += 1
                }
            } catch {
                otherSequenceErrorRows += 1
            }
        }
        let safeSequenceClassification =
            "MYR238_ISOLATED_SEQUENCE_PREFLIGHT" +
            " note_rows=\(inputNotes.count)" +
            " sequence_rows=\(persistedRows.count)" +
            " structurally_invalid=\(invalidStateRows)" +
            " visible_body_mismatch=\(mismatchedVisibleText)" +
            " missing_sequence=\(missingStateRows)" +
            " valid_sequence=\(validStateRows)" +
            " other_error=\(otherSequenceErrorRows)" +
            " duplicate_sequence=\(duplicateSequenceRows)"
        print(safeSequenceClassification)

        var startedNetworking = false
        var startupFailureStage = "unknown"
        var startupFailureType = "unknown"
        var startupFailureDomain = "unknown"
        var startupFailureCode = 0
        var startupUnderlyingDomain = "none"
        var startupUnderlyingCode = 0
        func recordSafeFailure(stage: String, error: Error) {
            let cocoaError = error as NSError
            startupFailureStage = stage
            startupFailureType = String(reflecting: type(of: error))
            startupFailureDomain = cocoaError.domain
            startupFailureCode = cocoaError.code
            if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError {
                startupUnderlyingDomain = underlying.domain
                startupUnderlyingCode = underlying.code
            }
        }
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false
        ) { vm, sync in
            NotesListState.BootstrapActions(
                rollbackIfNeededOnLaunch: {
                    do {
                        try await vm.rollbackIfNeededOnLaunch(
                            syncController: sync,
                            journalStore: PendingSyncRecoveryJournalStore(fileURL: journalURL)
                        )
                    } catch {
                        recordSafeFailure(stage: "pending_sync_recovery", error: error)
                        throw error
                    }
                },
                migrateNoteSequenceStates: {
                    do {
                        return try await NoteSequenceStateBootstrapMigrator(container: container)
                            .runPreservingDivergentStates()
                    } catch {
                        recordSafeFailure(stage: "note_state_migration", error: error)
                        throw error
                    }
                },
                completeModelInitializationAfterMigration: {
                    vm.completeStartupInitializationAfterMigration()
                },
                refreshPendingSyncStatus: { await sync.refreshPendingSyncStatus() },
                resumeOutboundAfterRecovery: {},
                startNetworkingIfNeeded: { startedNetworking = true },
                resumePendingConvergencePresentationIfNeeded: {}
            )
        }
        await state.bootstrapAfterRecovery()
        guard state.bootstrapState == .ready else {
            // Report only fixed diagnostic fields. Never expose private error
            // descriptions, note identifiers, titles, bodies, or filesystem paths.
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            func sanitized(_ value: String) -> String {
                let result = String(value.unicodeScalars.prefix(120).map {
                    safe.contains($0) ? Character($0) : "_"
                })
                return result.isEmpty ? "unknown" : result
            }
            XCTFail(
                "MYR238_ISOLATED_STARTUP_FAILURE stage=\(sanitized(startupFailureStage))" +
                " error_type=\(sanitized(startupFailureType))" +
                " error_domain=\(sanitized(startupFailureDomain))" +
                " error_code=\(startupFailureCode)" +
                " underlying_domain=\(sanitized(startupUnderlyingDomain))" +
                " underlying_code=\(startupUnderlyingCode)" +
                " sequence_invalid=\(invalidStateRows)" +
                " sequence_body_mismatch=\(mismatchedVisibleText)" +
                " sequence_missing=\(missingStateRows)" +
                " sequence_valid=\(validStateRows)" +
                " sequence_other=\(otherSequenceErrorRows)" +
                " sequence_duplicates=\(duplicateSequenceRows)"
            )
            return
        }
        XCTAssertEqual(state.divergentNoteIDs.count, mismatchedVisibleText)
        XCTAssertEqual(state.divergentNoteIDs.count, 1, "Exactly one captured note must be isolated")
        XCTAssertFalse(startedNetworking, "Startup must keep transport stopped while divergence remains")
        XCTAssertNotNil(state.syncRecoveryMessage)
        XCTAssertFalse(state.vm.notes.isEmpty, "Healthy local notes must remain available")
        let after = try signature(container)
        XCTAssertTrue(before.0 == after.0, "Stored note identities, contents, or metadata changed")
        XCTAssertTrue(before.1 == after.1, "Stored folder identities or metadata changed")
        let expectedVisible = before.0.filter {
            $0.deletedAt == nil && ($0.folderID == nil || $0.pinned == true)
        }
        XCTAssertEqual(
            Set(state.vm.notes.map(\.id)),
            Set(expectedVisible.map(\.id)),
            "Healthy startup must load the same root/pinned notes as the native list"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        print("MYR238_IOS_ISOLATED_REAL_STARTUP_PASS")
    }

    func testMYR238DivergentNoteReadOnlyHealthyNotesRemainEditableWithSyncPaused() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let protectedNote = Note(title: "Protected", content: "Prior sequence text")
        let healthyNote = Note(title: "Healthy", content: "Durable text")
        context.insert(protectedNote)
        context.insert(healthyNote)
        try context.save()

        try await NoteSequenceStateBootstrapMigrator(
            container: container, allowsExistingStateReplacement: false
        ).runToCompletion()
        let protectedID = protectedNote.id
        let existingRecord = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
                .first { $0.noteID == protectedID }
        )
        let retainedPayload = existingRecord.statePayloadData
        let retainedRevision = existingRecord.revision

        protectedNote.content = "Newer saved text"
        try context.save()
        var startedNetworking = false
        var resumedOutbound = false
        let state = NotesListState(
            context: context,
            startsBootstrapAutomatically: false
        ) { vm, _ in
            NotesListState.BootstrapActions(
                rollbackIfNeededOnLaunch: {},
                migrateNoteSequenceStates: {
                    try await NoteSequenceStateBootstrapMigrator(
                        container: container, allowsExistingStateReplacement: false
                    ).runPreservingDivergentStates()
                },
                completeModelInitializationAfterMigration: {
                    vm.completeStartupInitializationAfterMigration()
                },
                refreshPendingSyncStatus: {},
                resumeOutboundAfterRecovery: { resumedOutbound = true },
                startNetworkingIfNeeded: { startedNetworking = true },
                resumePendingConvergencePresentationIfNeeded: {}
            )
        }

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(state.divergentNoteIDs, Set([protectedID]))
        XCTAssertFalse(startedNetworking)
        XCTAssertFalse(resumedOutbound)
        XCTAssertNotNil(state.syncRecoveryMessage)
        XCTAssertTrue(state.vm.notes.contains { $0.id == healthyNote.id })
        XCTAssertTrue(state.vm.notes.contains { $0.id == protectedID })

        state.vm.renameNote(healthyNote, to: "Edited safely")
        XCTAssertEqual(healthyNote.title, "Edited safely")
        state.vm.renameNote(protectedNote, to: "Must not save")
        state.vm.deleteNote(protectedNote)
        state.vm.permanentlyDeleteNote(protectedNote)
        XCTAssertNil(state.vm.addPinnedThought(to: protectedNote, text: "Must not save"))
        XCTAssertEqual(protectedNote.title, "Protected")
        XCTAssertEqual(protectedNote.content, "Newer saved text")
        XCTAssertNil(protectedNote.deletedAt)
        let retained = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>())
                .first { $0.noteID == protectedID }
        )
        XCTAssertEqual(retained.statePayloadData, retainedPayload)
        XCTAssertEqual(retained.revision, retainedRevision)
        XCTAssertEqual(
            try NoteSequenceStatePersistenceCodec
                .decodeStructurallyValidatedState(record: retained, noteID: protectedID)
                .visibleText,
            "Prior sequence text"
        )
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<Note>())
                .first { $0.id == healthyNote.id }?.title,
            "Edited safely"
        )
    }

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
                        return []
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MYR238Synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftData may retain file handles after this scope. The Verification
        // evidence producer removes this synthetic directory after the host exits.
        let journalURL = directory.appendingPathComponent("journal.json")
        try Data("invalid synthetic journal".utf8).write(to: journalURL)
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR238Synthetic", schema: schema, url: directory.appendingPathComponent("notes.store"),
            cloudKitDatabase: .none
        )
        func openContainer() throws -> ModelContainer {
            let container = try ModelContainer(for: schema, configurations: configuration)
            container.mainContext.autosaveEnabled = false
            return container
        }
        var outboundResumes = 0
        func state(for container: ModelContainer) -> NotesListState {
            NotesListState(context: container.mainContext, startsBootstrapAutomatically: false) { vm, sync in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        try await vm.rollbackIfNeededOnLaunch(
                            syncController: sync, journalStore: PendingSyncRecoveryJournalStore(fileURL: journalURL)
                        )
                    },
                    migrateNoteSequenceStates: {
                        try await NoteSequenceStateBootstrapMigrator(container: container).runPreservingDivergentStates()
                    },
                    completeModelInitializationAfterMigration: { vm.completeStartupInitializationAfterMigration() },
                    refreshPendingSyncStatus: { await sync.refreshPendingSyncStatus() },
                    resumeOutboundAfterRecovery: {
                        outboundResumes += 1
                        sync.resumeOutboundAfterRecovery()
                    },
                    startNetworkingIfNeeded: {}, resumePendingConvergencePresentationIfNeeded: {}
                )
            }
        }
        let original = Note(title: "Existing synthetic note", content: "Existing durable content")
        let originalID = original.id
        let queuedBatch = SyncBatch(
            id: UUID(), originDeviceID: UUID(), createdAt: Date(),
            changes: [.noteTitleChanged(SyncBatchNoteTitleChangedChange(
                noteID: originalID, title: original.title, modifiedAt: original.modifiedAt
            ))]
        )
        let queuedLocalBatch = SyncBatch(
            id: UUID(), originDeviceID: UUID(), createdAt: Date(), changes: queuedBatch.changes
        )
        let faultBytes = try Data(contentsOf: journalURL)
        let id: UUID
        var pendingUnsent: [SyncBatch] = []
        var pendingLocal: [SyncBatch] = []
        do {
            let container = try openContainer()
            container.mainContext.insert(original)
            try container.mainContext.save()
            let first = state(for: container)
            // Seed through production queue APIs; no private queue-file edits.
            try await first.syncController.replaceUnsentBatches([queuedBatch])
            try await first.vm.replaceLocalConvergenceBatches([queuedLocalBatch])
            XCTAssertEqual(first.vm.localConvergenceQueueSnapshot().pendingBatches, [queuedLocalBatch])
            await first.bootstrapAfterRecovery()
            XCTAssertEqual(first.bootstrapState, .ready)
            XCTAssertNotNil(first.syncRecoveryMessage)
            XCTAssertEqual(first.vm.notes.first { $0.id == originalID }?.content, "Existing durable content")
            let note = try XCTUnwrap(first.vm.createNewNote())
            id = note.id
            let saved = await first.vm.commitNoteEditForProduction(note, title: "Synthetic offline", content: "Keep this exact text")
            XCTAssertTrue(saved)
            await first.vm.prepareLocalOwnershipForBootstrapForTesting()
            pendingUnsent = first.syncController.unsentBatchQueueSnapshot().pendingBatches
            pendingLocal = first.vm.localConvergenceQueueSnapshot().pendingBatches
            XCTAssertTrue(pendingUnsent.contains(queuedBatch))
            // Local obligations may transfer to the durable unsent queue, but
            // must remain owned until acknowledgement, even while sync pauses.
            let owned = pendingLocal + pendingUnsent
            XCTAssertTrue(owned.contains(queuedLocalBatch))
            XCTAssertTrue(owned.contains { batch in
                batch.changes.contains { change in
                    if case .noteCreated(let created) = change { return created.noteID == id }
                    return false
                }
            })
            await first.bootstrapAfterRecovery()
            XCTAssertNotNil(first.syncRecoveryMessage)
            XCTAssertEqual(first.syncController.unsentBatchQueueSnapshot().pendingBatches, pendingUnsent)
            XCTAssertEqual(first.vm.localConvergenceQueueSnapshot().pendingBatches, pendingLocal)
            XCTAssertEqual(try Data(contentsOf: journalURL), faultBytes)
            XCTAssertEqual(outboundResumes, 0)
        }
        let reopened = try openContainer()
        let relaunched = state(for: reopened)
        await relaunched.bootstrapAfterRecovery()
        XCTAssertEqual(relaunched.bootstrapState, .ready)
        let note = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Note>()).first { $0.id == id })
        XCTAssertEqual(note.title, "Synthetic offline")
        XCTAssertEqual(note.content, "Keep this exact text")
        XCTAssertEqual(relaunched.vm.notes.first { $0.id == originalID }?.content, "Existing durable content")
        XCTAssertEqual(relaunched.syncController.unsentBatchQueueSnapshot().pendingBatches, pendingUnsent)
        XCTAssertEqual(relaunched.vm.localConvergenceQueueSnapshot().pendingBatches, pendingLocal)
        XCTAssertEqual(try Data(contentsOf: journalURL), faultBytes)
        await relaunched.bootstrapAfterRecovery()
        XCTAssertNotNil(relaunched.syncRecoveryMessage)
        XCTAssertEqual(relaunched.syncController.unsentBatchQueueSnapshot().pendingBatches, pendingUnsent)
        XCTAssertEqual(relaunched.vm.localConvergenceQueueSnapshot().pendingBatches, pendingLocal)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<Note>()).filter { $0.id == id }.count, 1)
        XCTAssertEqual(outboundResumes, 0)
        // Remove only the synthetic fault; retry must preserve the current local version.
        try FileManager.default.removeItem(at: journalURL)
        await relaunched.bootstrapAfterRecovery()
        XCTAssertNil(relaunched.syncRecoveryMessage)
        XCTAssertEqual(outboundResumes, 1)
        XCTAssertEqual(relaunched.syncController.unsentBatchQueueSnapshot().pendingBatches, pendingUnsent)
        XCTAssertEqual(relaunched.vm.localConvergenceQueueSnapshot().pendingBatches, pendingLocal)
        XCTAssertEqual(note.content, "Keep this exact text")
        let durableContainer = try openContainer()
        let durable = try durableContainer.mainContext.fetch(FetchDescriptor<Note>()).filter { $0.id == id }
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(durable.first?.content, "Keep this exact text")
        withExtendedLifetime(durableContainer) {}
    }

    func testReadOnlySwiftDataStoreDoesNotBecomeWritableDuringSyncFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MYR238ReadOnly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(MyRAMModelRegistry.models)
        let storeURL = directory.appendingPathComponent("notes.store")
        let id: UUID
        do {
            let writable = try ModelContainer(for: schema, configurations: ModelConfiguration(
                "MYR238ReadOnly", schema: schema, url: storeURL, cloudKitDatabase: .none
            ))
            let note = Note(title: "Preserve", content: "Read-only durable content")
            id = note.id
            writable.mainContext.insert(note)
            try writable.mainContext.save()
        }
        let readOnly = try ModelContainer(for: schema, configurations: ModelConfiguration(
            "MYR238ReadOnly", schema: schema, url: storeURL, allowsSave: false, cloudKitDatabase: .none
        ))
        readOnly.mainContext.autosaveEnabled = false
        let journalURL = directory.appendingPathComponent("journal.json")
        let faultBytes = Data("invalid synthetic journal".utf8)
        try faultBytes.write(to: journalURL)
        let state = NotesListState(context: readOnly.mainContext, startsBootstrapAutomatically: false) { vm, sync in
            NotesListState.BootstrapActions(
                rollbackIfNeededOnLaunch: {
                    try await vm.rollbackIfNeededOnLaunch(
                        syncController: sync, journalStore: PendingSyncRecoveryJournalStore(fileURL: journalURL)
                    )
                },
                migrateNoteSequenceStates: {
                    try await NoteSequenceStateBootstrapMigrator(container: readOnly).runPreservingDivergentStates()
                },
                completeModelInitializationAfterMigration: { vm.completeStartupInitializationAfterMigration() },
                refreshPendingSyncStatus: { XCTFail("Unwritable store must not resume sync") },
                resumeOutboundAfterRecovery: { XCTFail("Unwritable store must not resume outbound") },
                startNetworkingIfNeeded: { XCTFail("Unwritable store must not start networking") },
                resumePendingConvergencePresentationIfNeeded: { XCTFail("Unwritable store must not resume convergence") }
            )
        }
        await state.bootstrapAfterRecovery()
        guard case .failed = state.bootstrapState else {
            return XCTFail("Real read-only SwiftData persistence must not enable the editor")
        }
        XCTAssertFalse(state.vm.didCompleteStartupModelInitializationForTesting)
        XCTAssertEqual(state.readableNotesDuringStartupFailure.map(\.id), [id])
        XCTAssertEqual(state.readableNotesDuringStartupFailure.first?.content, "Read-only durable content")
        XCTAssertEqual(try Data(contentsOf: journalURL), faultBytes)
    }

    func testMYR238UnfinishedOwnerResolutionPreventsSyncAdmissionAcrossRetry() async throws {
        let container = try makeContainer()
        var pending = true
        var starts = 0
        var resumes = 0
        var checks = 0
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { vm, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {},
                    migrateNoteSequenceStates: { [] },
                    completeModelInitializationAfterMigration: {
                        vm.completeStartupInitializationAfterMigration()
                    },
                    refreshPendingSyncStatus: {},
                    resumeOutboundAfterRecovery: { resumes += 1 },
                    startNetworkingIfNeeded: { starts += 1 },
                    resumePendingConvergencePresentationIfNeeded: {},
                    hasUnfinishedLocalResolution: {
                        checks += 1
                        return pending
                    }
                )
            }
        )

        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(resumes, 0)
        XCTAssertNotNil(state.syncRecoveryMessage)
        let note = try XCTUnwrap(state.vm.createNewNote())
        let saved = await state.vm.commitNoteEditForProduction(
            note, title: "Healthy", content: "Saved while resolution is unfinished"
        )
        XCTAssertTrue(saved)

        await state.bootstrapAfterRecovery()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(checks, 2)

        pending = false
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(resumes, 1)
        XCTAssertNil(state.syncRecoveryMessage)
        let loaded = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(
            loaded.first { $0.id == note.id }?.content,
            "Saved while resolution is unfinished"
        )
    }

    func testMYR238CorruptResolutionLedgerPausesSyncWithoutBlockingHealthyNotes() async throws {
        let container = try makeContainer()
        var unreadable = true
        var starts = 0
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { vm, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {},
                    migrateNoteSequenceStates: { [] },
                    completeModelInitializationAfterMigration: {
                        vm.completeStartupInitializationAfterMigration()
                    },
                    refreshPendingSyncStatus: {},
                    resumeOutboundAfterRecovery: {},
                    startNetworkingIfNeeded: { starts += 1 },
                    resumePendingConvergencePresentationIfNeeded: {},
                    hasUnfinishedLocalResolution: {
                        if unreadable {
                            throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
                        }
                        return false
                    }
                )
            }
        )
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(state.syncRecoveryMessage)
        XCTAssertNotNil(state.startupFailureSupportDetails)

        let note = try XCTUnwrap(state.vm.createNewNote())
        let saved = await state.vm.commitNoteEditForProduction(
            note, title: "Preserved", content: "Offline note"
        )
        XCTAssertTrue(saved)
        unreadable = false
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(starts, 1)
        XCTAssertNil(state.syncRecoveryMessage)
        let loaded = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(loaded.first { $0.id == note.id }?.content, "Offline note")
    }

    func testMYR238PendingResolutionDoesNotHideRollbackFailure() async throws {
        let container = try makeContainer()
        var started = false
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { vm, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: {
                        throw PendingSyncRecoveryCoordinator.RecoveryError.rollbackFailed
                    },
                    migrateNoteSequenceStates: { [] },
                    completeModelInitializationAfterMigration: {
                        vm.completeStartupInitializationAfterMigration()
                    },
                    refreshPendingSyncStatus: {},
                    resumeOutboundAfterRecovery: {},
                    startNetworkingIfNeeded: { started = true },
                    resumePendingConvergencePresentationIfNeeded: {},
                    hasUnfinishedLocalResolution: { true }
                )
            }
        )
        await state.bootstrapAfterRecovery()
        XCTAssertEqual(state.bootstrapState, .ready)
        XCTAssertFalse(started)
        XCTAssertTrue(
            state.startupFailureSupportDetails?.contains("Pending sync recovery") == true
        )
        let note = try XCTUnwrap(state.vm.createNewNote())
        let saved = await state.vm.commitNoteEditForProduction(
            note, title: "Offline", content: "Retained"
        )
        XCTAssertTrue(saved)
        XCTAssertFalse(started)
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
                    migrateNoteSequenceStates: { [] },
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
                        return []
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
                    migrateNoteSequenceStates: { [] },
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
    var afterLegacyReplacement: (() -> Void)?
    var afterUnsentReplacement: (() -> Void)?

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
        if let afterLegacyReplacement {
            await Task.yield()
            afterLegacyReplacement()
        }
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
        if let afterUnsentReplacement {
            await Task.yield()
            afterUnsentReplacement()
        }
    }

    func refreshPendingSyncStatus() async {}

    func flushAllOutboundWork() {
        didFlushAllOutboundWork = true
    }
}
