import AnchoredSequenceCore
import Foundation
@preconcurrency import MultipeerConnectivity
import NearbySyncCore
import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class MYR184SyncConflictResolutionTests: XCTestCase {
    func testMYR222NonMergeableBootstrapRequiresDurableStructuralConflict() throws {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-StructuralConflict-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false

        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000201")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_220)
        let localModifiedAt = Date(timeIntervalSinceReferenceDate: 2_221)
        let remoteModifiedAt = Date(timeIntervalSinceReferenceDate: 2_222)
        let note = Note(title: "", content: "Local")
        note.id = noteID
        note.createdAt = createdAt
        note.modifiedAt = localModifiedAt
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()

        let localSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        let unrelatedRemote = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(uuidString: "22200000-0000-0000-0000-000000000299")!,
            body: "Remote"
        ).state
        XCTAssertThrowsError(
            try localSnapshot.state.mergingRetainedLineage(with: unrelatedRemote)
        ) { error in
            XCTAssertEqual(error as? SyncTextSequenceMergeError, .noSharedRetainedLineage)
        }

        let remotePayload = try NoteSequenceStatePersistenceCodec.encode(
            state: unrelatedRemote,
            noteID: noteID
        )
        let historicalBatchID = UUID(uuidString: "22200000-0000-0000-0000-000000000203")!
        let snapshot = SyncPeerBootstrapSnapshot(
            id: UUID(uuidString: "22200000-0000-0000-0000-000000000202")!,
            folders: [],
            notes: [
                SyncPeerBootstrapNoteSnapshot(
                    id: noteID,
                    title: "",
                    body: "Remote",
                    isPinned: false,
                    createdAt: createdAt,
                    modifiedAt: remoteModifiedAt,
                    deletedAt: nil,
                    folderID: nil,
                    formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
                    revision: 0,
                    visibleUTF16Count: unrelatedRemote.visibleUTF16Count,
                    tombstonedUTF16Count: unrelatedRemote.tombstonedUTF16Count,
                    payloadByteCount: remotePayload.count,
                    statePayloadData: remotePayload
                )
            ],
            historyCoverage: [SyncPeerBootstrapHistoryBatchCoverage(
                batchID: historicalBatchID,
                noteIDs: [noteID],
                anchoredRecoveryChanges: nil
            )]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json"))
        let sidecarURL = directory.appendingPathComponent("bootstrap-structural.json")

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: context,
            structuralConflictStore: store,
            structuralConflictSidecarFileURL: sidecarURL
        )

        let persisted = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        XCTAssertEqual(note.content, "Local")
        XCTAssertEqual(persisted, localSnapshot)
        XCTAssertFalse(disposition.coveredNoteIDs.contains(noteID))
        XCTAssertFalse(disposition.coveredBatchIDs.contains(historicalBatchID))
        XCTAssertTrue(disposition.presentationRefreshRequired)

        let conflicts = store.activeConflicts()
        XCTAssertEqual(
            conflicts.count,
            1,
            "A non-mergeable bootstrap must preserve an actionable durable conflict instead of silently leaving the note uncovered."
        )
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.entityType, .note)
        XCTAssertEqual(conflict.entityID, noteID)
        XCTAssertEqual(conflict.noteID, noteID)
        XCTAssertEqual(conflict.field, .noteContent)
        XCTAssertEqual(conflict.localText, "Local")
        XCTAssertEqual(conflict.remoteText, "Remote")
        let record = try XCTUnwrap(store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: sidecarURL
        ))
        XCTAssertEqual(record.remoteStatePayloadData, remotePayload)
        XCTAssertEqual(try store.validatedBootstrapStructuralRemoteState(record), unrelatedRemote)

        let replay = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: context,
            structuralConflictStore: store,
            structuralConflictSidecarFileURL: sidecarURL
        )
        XCTAssertFalse(replay.coveredNoteIDs.contains(noteID))
        XCTAssertFalse(replay.coveredBatchIDs.contains(historicalBatchID))
        XCTAssertTrue(replay.presentationRefreshRequired)
        XCTAssertEqual(store.activeConflicts(), [conflict])
        XCTAssertEqual(
            try store.bootstrapStructuralConflictRecordChecked(id: conflict.id, sidecarFileURL: sidecarURL),
            record
        )
    }

    func testMYR222BootstrapStructuralConflictPersistenceFailureThrowsWithoutChangingLocalState() throws {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-StructuralConflictFailure-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000221")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_220)
        let note = Note(title: "", content: "Local")
        note.id = noteID
        note.createdAt = createdAt
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()
        let localSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        let remoteState = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(uuidString: "22200000-0000-0000-0000-000000000229")!,
            body: "Remote"
        ).state
        let remotePayload = try NoteSequenceStatePersistenceCodec.encode(state: remoteState, noteID: noteID)
        let snapshot = SyncPeerBootstrapSnapshot(
            id: UUID(uuidString: "22200000-0000-0000-0000-000000000222")!,
            folders: [],
            notes: [SyncPeerBootstrapNoteSnapshot(
                id: noteID,
                title: "",
                body: "Remote",
                isPinned: false,
                createdAt: createdAt,
                modifiedAt: createdAt.addingTimeInterval(1),
                deletedAt: nil,
                folderID: nil,
                formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
                revision: 0,
                visibleUTF16Count: remoteState.visibleUTF16Count,
                tombstonedUTF16Count: remoteState.tombstonedUTF16Count,
                payloadByteCount: remotePayload.count,
                statePayloadData: remotePayload
            )]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-sidecar-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json"))
        var failingFileIO = SyncBootstrapStructuralConflictFileIO.live
        failingFileIO.writeData = { _, _ in throw CocoaError(.fileWriteUnknown) }

        XCTAssertThrowsError(try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: context,
            structuralConflictStore: store,
            structuralConflictSidecarFileURL: directory.appendingPathComponent("bootstrap-structural.json"),
            structuralConflictFileIO: failingFileIO
        ))
        XCTAssertEqual(note.content, "Local")
        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context),
            localSnapshot
        )
        XCTAssertTrue(store.activeConflicts().isEmpty)
    }

    func testMYR222StructuralSidecarMaterializesVisibleConflictWithExactRemoteState() throws {
        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000211")!
        let bootstrapID = UUID(uuidString: "22200000-0000-0000-0000-000000000212")!
        let localState = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: noteID,
            body: "Local"
        ).state
        let remoteState = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(uuidString: "22200000-0000-0000-0000-000000000219")!,
            body: "Remote"
        ).state
        XCTAssertThrowsError(try localState.mergingRetainedLineage(with: remoteState)) { error in
            XCTAssertEqual(error as? SyncTextSequenceMergeError, .noSharedRetainedLineage)
        }
        let remotePayload = try NoteSequenceStatePersistenceCodec.encode(
            state: remoteState,
            noteID: noteID
        )
        let remoteSnapshot = SyncPeerBootstrapNoteSnapshot(
            id: noteID,
            title: "",
            body: "Remote",
            isPinned: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_210),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2_211),
            deletedAt: nil,
            folderID: nil,
            formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
            revision: 0,
            visibleUTF16Count: remoteState.visibleUTF16Count,
            tombstonedUTF16Count: remoteState.tombstonedUTF16Count,
            payloadByteCount: remotePayload.count,
            statePayloadData: remotePayload
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json"))
        let sidecarURL = directory.appendingPathComponent("bootstrap-structural.json")

        let conflict = try store.materializeBootstrapStructuralConflictChecked(
            noteID: noteID,
            localText: "Local",
            localState: localState,
            remoteSnapshot: remoteSnapshot,
            bootstrapSnapshotID: bootstrapID,
            sidecarFileURL: sidecarURL
        )

        XCTAssertEqual(store.activeConflicts(), [conflict])
        XCTAssertEqual(conflict.localText, "Local")
        XCTAssertEqual(conflict.remoteText, "Remote")
        XCTAssertEqual(conflict.expiresAt, .distantFuture)
        let record = try XCTUnwrap(store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: sidecarURL
        ))
        XCTAssertEqual(record.lifecycle, .active)
        XCTAssertEqual(record.bootstrapSnapshotID, bootstrapID)
        XCTAssertEqual(record.remoteStatePayloadData, remotePayload)
        XCTAssertEqual(record.remotePayloadByteCount, remotePayload.count)
        XCTAssertEqual(
            record.localStructuralFingerprint,
            try SyncConflictStore.bootstrapStructuralFingerprint(noteID: noteID, state: localState)
        )
        XCTAssertEqual(
            record.remoteStructuralFingerprint,
            try SyncConflictStore.bootstrapStructuralFingerprint(noteID: noteID, state: remoteState)
        )
        XCTAssertEqual(try store.validatedBootstrapStructuralRemoteState(record), remoteState)
    }

    func testMYR222AcceptIncomingInstallsExactRemoteStructuralStateAndTerminalizes() async throws {
        let fixture = try makeStructuralResolutionFixture()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL
        )

        _ = try await service.acceptIncomingChecked(fixture.conflict, activeNoteID: fixture.note.id)

        XCTAssertEqual(fixture.note.content, "Remote")
        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
                for: fixture.note,
                in: fixture.context
            ).state,
            fixture.remoteState,
            "Accept Incoming must preserve the remote operation identities, not synthesize replacement operations."
        )
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
        let record = try XCTUnwrap(fixture.store.bootstrapStructuralConflictRecordChecked(
            id: fixture.conflict.id,
            sidecarFileURL: fixture.sidecarURL
        ))
        XCTAssertEqual(record.lifecycle, .terminallySuperseded)
        XCTAssertEqual(
            try fixture.store.bootstrapStructuralResolutionReceiptChecked(
                conflictID: fixture.conflict.id,
                sidecarFileURL: fixture.sidecarURL
            )?.choice,
            .acceptIncoming
        )
    }

    func testMYR222StaleAcceptIncomingFailsClosedWithEvidenceIntact() async throws {
        let fixture = try makeStructuralResolutionFixture()
        _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
            of: fixture.note,
            with: "Later local edit",
            in: fixture.context
        )
        try fixture.context.save()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL
        )

        do {
            _ = try await service.acceptIncomingChecked(fixture.conflict, activeNoteID: nil)
            XCTFail("A stale local structural state must not be overwritten.")
        } catch {
            XCTAssertEqual(error as? MyRAMSyncConflictResolutionError, .staleStructuralConflict)
        }
        XCTAssertEqual(fixture.note.content, "Later local edit")
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        XCTAssertEqual(
            try fixture.store.bootstrapStructuralConflictRecordChecked(
                id: fixture.conflict.id,
                sidecarFileURL: fixture.sidecarURL
            )?.lifecycle,
            .active
        )
    }

    func testMYR222KeepLocalRetainsOneWaitingConflictAndCanSwitchToAcceptIncoming() async throws {
        let fixture = try makeStructuralResolutionFixture()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL
        )

        _ = try await service.keepLocalChecked(fixture.conflict, activeNoteID: nil)

        XCTAssertEqual(fixture.note.content, "Local")
        XCTAssertEqual(fixture.store.activeConflicts().count, 1)
        XCTAssertEqual(
            try fixture.store.bootstrapStructuralResolutionReceiptChecked(
                conflictID: fixture.conflict.id,
                sidecarFileURL: fixture.sidecarURL
            )?.choice,
            .keepLocal
        )
        let waiting = try XCTUnwrap(fixture.store.activeConflicts().first)
        _ = try await service.acceptIncomingChecked(waiting, activeNoteID: nil)
        XCTAssertEqual(fixture.note.content, "Remote")
        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
                for: fixture.note,
                in: fixture.context
            ).state,
            fixture.remoteState
        )
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
    }

    func testMYR222MergedResolutionIsDeterministicAndRetainsWaitingConflict() async throws {
        let fixture = try makeStructuralResolutionFixture()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL
        )

        _ = try await service.saveMergedTextChecked(
            fixture.conflict,
            text: "Local + Remote",
            activeNoteID: nil
        )

        let chosen = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: fixture.note,
            in: fixture.context
        )
        let expected = try SyncTextLegacyBootstrap.makeLineagePreservingState(
            noteID: fixture.note.id,
            currentState: fixture.localState,
            body: "Local + Remote"
        )
        XCTAssertEqual(chosen.state, expected)
        XCTAssertEqual(fixture.store.activeConflicts().count, 1)
        let receipt = try XCTUnwrap(fixture.store.bootstrapStructuralResolutionReceiptChecked(
            conflictID: fixture.conflict.id,
            sidecarFileURL: fixture.sidecarURL
        ))
        XCTAssertEqual(receipt.choice, .merged)
        XCTAssertEqual(
            receipt.chosenFingerprint,
            try SyncConflictStore.bootstrapStructuralFingerprint(noteID: fixture.note.id, state: expected)
        )
    }

    func testMYR222AcceptIncomingSaveFailurePreservesActionableEvidence() async throws {
        let fixture = try makeStructuralResolutionFixture()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL,
            saveOperation: { _ in throw CocoaError(.persistentStoreSave) }
        )

        do {
            _ = try await service.acceptIncomingChecked(fixture.conflict, activeNoteID: nil)
            XCTFail("The injected model save must fail.")
        } catch {
            XCTAssertEqual(error as? MyRAMSyncConflictResolutionError, .modelSaveFailed)
        }
        XCTAssertEqual(fixture.note.content, "Local")
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        XCTAssertEqual(
            try fixture.store.bootstrapStructuralConflictRecordChecked(
                id: fixture.conflict.id,
                sidecarFileURL: fixture.sidecarURL
            )?.pendingResolution?.choice,
            .acceptIncoming
        )
    }

    func testMYR222ExactPeerAdoptionTerminalizesWaitingLocalAuthorityAndPermitsCoverage() async throws {
        let fixture = try makeStructuralResolutionFixture()
        let service = MyRAMSyncConflictService(
            context: fixture.context,
            store: fixture.store,
            bootstrapStructuralConflictFileURL: fixture.sidecarURL
        )
        _ = try await service.keepLocalChecked(fixture.conflict, activeNoteID: nil)
        let chosen = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: fixture.note,
            in: fixture.context
        )
        let payload = try NoteSequenceStatePersistenceCodec.encode(
            state: chosen.state,
            noteID: fixture.note.id
        )
        let batchID = UUID()
        let snapshot = SyncPeerBootstrapSnapshot(
            id: UUID(),
            folders: [],
            notes: [SyncPeerBootstrapNoteSnapshot(
                id: fixture.note.id,
                title: fixture.note.title,
                body: fixture.note.content,
                isPinned: fixture.note.isPinned ?? false,
                createdAt: fixture.note.createdAt,
                modifiedAt: fixture.note.modifiedAt,
                deletedAt: fixture.note.deletedAt,
                folderID: nil,
                formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
                revision: chosen.revision,
                visibleUTF16Count: chosen.state.visibleUTF16Count,
                tombstonedUTF16Count: chosen.state.tombstonedUTF16Count,
                payloadByteCount: payload.count,
                statePayloadData: payload
            )],
            historyCoverage: [SyncPeerBootstrapHistoryBatchCoverage(
                batchID: batchID,
                noteIDs: [fixture.note.id],
                anchoredRecoveryChanges: nil
            )]
        )

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: fixture.context,
            structuralConflictStore: fixture.store,
            structuralConflictSidecarFileURL: fixture.sidecarURL
        )

        XCTAssertTrue(disposition.coveredNoteIDs.contains(fixture.note.id))
        XCTAssertTrue(disposition.coveredBatchIDs.contains(batchID))
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
        XCTAssertEqual(
            try fixture.store.bootstrapStructuralConflictRecordChecked(
                id: fixture.conflict.id,
                sidecarFileURL: fixture.sidecarURL
            )?.lifecycle,
            .terminallySuperseded
        )
    }

    func testDeferredResolutionExactRedeliveryIsIdempotentAndContradictionFailsClosed() throws {
        let store = makeStore()
        let id = UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!
        let first = conflict(id: id, remoteText: "winner", preservedAt: 10, expiresAt: 20)
        let redelivery = conflict(id: id, remoteText: "winner", preservedAt: 30, expiresAt: 40)

        try store.persistDeferredRemoteLifecycleResolutionChecked(first)
        let afterFirst = try store.snapshot().lifecycle
        try store.persistDeferredRemoteLifecycleResolutionChecked(redelivery)
        XCTAssertEqual(try store.snapshot().lifecycle, afterFirst)

        XCTAssertThrowsError(
            try store.persistDeferredRemoteLifecycleResolutionChecked(
                conflict(id: id, remoteText: "contradiction", preservedAt: 30, expiresAt: 40)
            )
        )
        XCTAssertEqual(try store.snapshot().lifecycle, afterFirst)
    }

    func testMalformedVersion8ResolutionFailsClosed() throws {
        let id = UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!
        let missingNote = conflict(
            id: id,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20,
            noteID: nil
        )
        XCTAssertThrowsError(
            try SyncDeferredRemoteLifecycleResolution(conflict: missingNote, receivedAt: Date()).validate()
        )

        for field in [SyncConflictField.folderTitle, .pinnedText] {
            let wrongField = conflict(
                id: id,
                remoteText: "winner",
                preservedAt: 10,
                expiresAt: 20,
                field: field
            )
            XCTAssertThrowsError(
                try SyncDeferredRemoteLifecycleResolution(conflict: wrongField, receivedAt: Date()).validate()
            )
        }
    }

#if DEBUG
    func testOrdinarySameTargetWriteStartedFirstCannotSupersedeCheckedResolution() async throws {
        let controller = makeController()
        let gate = MYR184AsyncGate()
        let legacyConflict = conflict(
            id: UUID(uuidString: "12345678-1234-4234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20
        )
        let preservedPayload = MyRAMSyncConflictPayload(
            action: .preserved,
            conflict: legacyConflict,
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let resolvedPayload = MyRAMSyncConflictPayload(
            action: .resolved,
            conflict: legacyConflict,
            resolvedText: "winner",
            baseText: "local",
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        controller.onOrdinaryTargetMutationReadyForTesting = {
            await gate.arriveAndWait()
        }
        controller.recordLocalChange(
            entityType: .conflict,
            entityID: legacyConflict.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(preservedPayload),
            updatedAt: preservedPayload.updatedAt
        )
        await gate.waitUntilArrived()

        let checkedTask = Task { @MainActor in
            try await controller.publishConflictResolutionChecked(resolvedPayload)
        }
        await Task.yield()
        await gate.release()
        try await checkedTask.value

        let snapshot = await controller.legacyQueueSnapshot()
        let queued = try XCTUnwrap(snapshot.pendingChanges.first)
        XCTAssertEqual(snapshot.pendingChanges.count, 1)
        XCTAssertEqual(queued.entityType, .conflict)
        XCTAssertEqual(queued.entityID, legacyConflict.id.uuidString)
        XCTAssertEqual(try MyRAMSyncPayloadCoding.decodeSyncConflict(from: queued.payload), resolvedPayload)
    }

    func testCheckedPublicationAlreadyOwningLeaseCompletesBeforeRecovery() async throws {
        let controller = makeController()
        let lifecycleConflict = conflict(
            id: UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20
        )
        let payload = MyRAMSyncConflictPayload(
            action: .resolved,
            conflict: lifecycleConflict,
            resolvedText: "winner",
            baseText: "local",
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        controller.onCheckedPublicationLeaseAcquiredForTesting = {
            await controller.suspendOutboundForRecovery()
        }

        try await controller.publishConflictResolutionChecked(payload)
        let snapshot = await controller.legacyQueueSnapshot()
        let queued = try XCTUnwrap(snapshot.pendingChanges.first)

        XCTAssertEqual(snapshot.pendingChanges.count, 1)
        XCTAssertEqual(queued.entityType, .conflict)
        XCTAssertEqual(queued.entityID, lifecycleConflict.id.uuidString)
        XCTAssertEqual(try MyRAMSyncPayloadCoding.decodeSyncConflict(from: queued.payload), payload)

        controller.resumeOutboundAfterRecovery()
    }

    func testRecoveryOwningFirstRejectsCheckedPublicationBeforeQueueMutation() async throws {
        let controller = makeController()
        let lifecycleConflict = conflict(
            id: UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20
        )
        let payload = MyRAMSyncConflictPayload(
            action: .resolved,
            conflict: lifecycleConflict,
            resolvedText: "winner",
            baseText: "local",
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        controller.suspendOutboundForRecovery()
        do {
            try await controller.publishConflictResolutionChecked(payload)
            XCTFail("publication must fail while recovery owns the exclusion boundary")
        } catch {
            XCTAssertEqual(error as? CheckedConflictPublicationError, .recoveryInProgress)
        }

        let snapshot = await controller.legacyQueueSnapshot()
        XCTAssertTrue(snapshot.pendingChanges.isEmpty)
        controller.resumeOutboundAfterRecovery()
    }
#endif

    private func makeStore() -> SyncConflictStore {
        SyncConflictStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("conflicts.json")
        )
    }

    private func makeStructuralResolutionFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        note: Note,
        store: SyncConflictStore,
        sidecarURL: URL,
        conflict: SyncConflictVersion,
        localState: SyncTextSequenceState,
        remoteState: SyncTextSequenceState
    ) {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-Resolution-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let noteID = UUID()
        let note = Note(title: "", content: "Local")
        note.id = noteID
        note.createdAt = Date(timeIntervalSinceReferenceDate: 2_220)
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()
        let localState = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        ).state
        let remoteState = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(),
            body: "Remote"
        ).state
        let payload = try NoteSequenceStatePersistenceCodec.encode(state: remoteState, noteID: noteID)
        let remoteSnapshot = SyncPeerBootstrapNoteSnapshot(
            id: noteID,
            title: "",
            body: "Remote",
            isPinned: false,
            createdAt: note.createdAt,
            modifiedAt: note.createdAt.addingTimeInterval(1),
            deletedAt: nil,
            folderID: nil,
            formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
            revision: 0,
            visibleUTF16Count: remoteState.visibleUTF16Count,
            tombstonedUTF16Count: remoteState.tombstonedUTF16Count,
            payloadByteCount: payload.count,
            statePayloadData: payload
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json"))
        let sidecarURL = directory.appendingPathComponent("bootstrap-structural.json")
        let conflict = try store.materializeBootstrapStructuralConflictChecked(
            noteID: noteID,
            localText: note.content,
            localState: localState,
            remoteSnapshot: remoteSnapshot,
            bootstrapSnapshotID: UUID(),
            sidecarFileURL: sidecarURL
        )
        return (container, context, note, store, sidecarURL, conflict, localState, remoteState)
    }

    private func makeController() -> MyRAMSyncController {
        MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("pending.json"),
            startsNetworking: false,
            transport: MYR184NoopSyncTransport()
        )
    }

    private func conflict(
        id: UUID,
        remoteText: String,
        preservedAt: TimeInterval,
        expiresAt: TimeInterval,
        noteID: UUID? = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
        field: SyncConflictField = .noteContent
    ) -> SyncConflictVersion {
        let entityID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        return SyncConflictVersion(
            id: id,
            entityType: .note,
            entityID: entityID,
            noteID: noteID,
            field: field,
            localText: "local",
            remoteText: remoteText,
            remoteModifiedAt: Date(timeIntervalSince1970: 5),
            preservedAt: Date(timeIntervalSince1970: preservedAt),
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }
}

private actor MYR184AsyncGate {
    private var hasArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasArrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class MYR184NoopSyncTransport: MyRAMSyncTransporting {
    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        []
    }

    func hasConnectedPeer(_ peerID: MCPeerID) -> Bool {
        false
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {}
}
