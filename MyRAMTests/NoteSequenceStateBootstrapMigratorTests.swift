import Foundation
import SwiftData
import XCTest
import AnchoredSequenceCore
@preconcurrency import MultipeerConnectivity

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

@MainActor
final class NoteSequenceStateBootstrapMigratorTests: XCTestCase {
    func testMigrationCoversActiveDeletedEmptyAndNonemptyNotes() async throws {
        let container = try makeContainer()
        let fixtures = [
            try insertNote(body: "", deleted: false, in: container),
            try insertNote(body: "Active", deleted: false, in: container),
            try insertNote(body: "", deleted: true, in: container),
            try insertNote(body: "Deleted", deleted: true, in: container)
        ]

        try await makeMigrator(container).runToCompletion()

        XCTAssertEqual(Set(try fetchRecords(in: container).map(\.noteID)), Set(fixtures))
    }

    func testMigrationProcessesNoteIDsInDeterministicOrder() async throws {
        let container = try makeContainer()
        let ids = [
            UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        ]
        for id in ids {
            _ = try insertNote(noteID: id, body: id.uuidString, in: container)
        }
        let recorder = IDRecorder()

        try await makeMigrator(container) { recorder.record($0) }.runToCompletion()

        XCTAssertEqual(
            recorder.ids,
            ids.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        )
    }

    func testMigrationRerunIsIdempotentForExactRows() async throws {
        let container = try makeContainer()
        _ = try insertNote(body: "Body", in: container)
        let migrator = await makeMigrator(container)
        try await migrator.runToCompletion()
        let original = try XCTUnwrap(fetchRecords(in: container).first)
        let payload = original.statePayloadData

        try await migrator.runToCompletion()

        let rerun = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(rerun.revision, 0)
        XCTAssertEqual(rerun.statePayloadData, payload)
    }

    func testActivatedMigrationStopsAtValidStaleRowWithoutReplacingLineage() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old", in: container)
        try await makeMigrator(container).runToCompletion()
        let original = try XCTUnwrap(fetchRecords(in: container).first)
        let originalPayload = original.statePayloadData
        try updateNote(noteID: noteID, body: "Current", in: container)

        do {
            try await makeMigrator(container).runToCompletion()
            XCTFail("Expected activated migration to preserve the established lineage and stop")
        } catch {
            XCTAssertEqual(error as? NoteSequenceStateStoreError, .corruptState)
        }

        let persisted = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(persisted.revision, 0)
        XCTAssertEqual(persisted.statePayloadData, originalPayload)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: persisted, noteID: noteID)
        XCTAssertEqual(state.visibleText, "Old")

        let verificationContext = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            verificationContext.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedID })
            ).first
        )
        XCTAssertEqual(note.content, "Current")
    }

    func testMigrationReestablishesValidStaleRowsWhenExplicitlyAllowed() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old", in: container)
        try await makeMigrator(container).runToCompletion()
        try updateNote(noteID: noteID, body: "Current", in: container)

        try await makeMigrator(
            container,
            allowsExistingStateReplacement: true
        ).runToCompletion()

        let record = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(record.revision, 1)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        XCTAssertEqual(state.visibleText, "Current")
    }

    func testMigrationStopsAtCorruptRowWithoutOverwritingIt() async throws {
        try await assertMigrationStopsWithoutOverwriting { record in
            record.statePayloadData = Data("corrupt".utf8)
            record.payloadByteCount = record.statePayloadData.count
        }
    }

    func testMigrationStopsAtUnsupportedRowWithoutOverwritingIt() async throws {
        try await assertMigrationStopsWithoutOverwriting { $0.formatVersion = 2 }
    }

    func testMigrationPersistsEarlierNotesBeforeInjectedInterruption() async throws {
        let container = try makeContainer()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try insertNote(noteID: first, body: "First", in: container)
        _ = try insertNote(noteID: second, body: "Second", in: container)

        do {
            try await makeMigrator(container) { id in
                if id == second {
                    throw MigratorTestFailure.interrupted
                }
            }.runToCompletion()
            XCTFail("Expected interruption")
        } catch MigratorTestFailure.interrupted {
        }

        XCTAssertEqual(try fetchRecords(in: container).map(\.noteID), [first])
    }

    func testMigrationResumesRemainingNotesAfterInterruption() async throws {
        let container = try makeContainer()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try insertNote(noteID: first, body: "First", in: container)
        _ = try insertNote(noteID: second, body: "Second", in: container)

        do {
            try await makeMigrator(container) { id in
                if id == second {
                    throw MigratorTestFailure.interrupted
                }
            }.runToCompletion()
        } catch MigratorTestFailure.interrupted {
        }
        try await makeMigrator(container).runToCompletion()

        let records = try fetchRecords(in: container)
        XCTAssertEqual(Set(records.map(\.noteID)), Set([first, second]))
        XCTAssertTrue(records.allSatisfy { $0.revision == 0 })
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-170-Migration-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeMigrator(
        _ container: ModelContainer,
        allowsExistingStateReplacement: Bool = !SyncBatchAnchoredPayloadCapability.isEnabled,
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) async -> NoteSequenceStateBootstrapMigrator {
        await NoteSequenceStateBootstrapMigrator(
            container: container,
            allowsExistingStateReplacement: allowsExistingStateReplacement,
            beforeEachNote: beforeEachNote
        )
    }

    @discardableResult
    private func insertNote(
        noteID: UUID = UUID(),
        body: String,
        deleted: Bool = false,
        in container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        let note = Note(content: body)
        note.id = noteID
        note.deletedAt = deleted ? .now : nil
        context.insert(note)
        try context.save()
        return noteID
    }

    private func updateNote(
        noteID: UUID,
        body: String,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedID })
            ).first
        )
        note.content = body
        try context.save()
    }

    private func fetchRecords(
        in container: ModelContainer
    ) throws -> [NoteSequenceStateRecord] {
        try ModelContext(container).fetch(
            FetchDescriptor<NoteSequenceStateRecord>(
                sortBy: [SortDescriptor(\.noteID)]
            )
        )
    }

    private func assertMigrationStopsWithoutOverwriting(
        mutation: (NoteSequenceStateRecord) -> Void
    ) async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        try await makeMigrator(container).runToCompletion()
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        mutation(record)
        try context.save()
        let originalPayload = record.statePayloadData
        let originalVersion = record.formatVersion

        do {
            try await makeMigrator(container).runToCompletion()
            XCTFail("Expected migration to stop")
        } catch {
        }

        let persisted = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(persisted.noteID, noteID)
        XCTAssertEqual(persisted.statePayloadData, originalPayload)
        XCTAssertEqual(persisted.formatVersion, originalVersion)
    }
}

@MainActor
final class MYR221BootstrapOwnershipMonotonicityTests: XCTestCase {
    func testRepeatedBootstrapDoesNotRecreateOwnershipAfterFullIncorporation() throws {
        try assertRepeatedBootstrapDoesNotRecreateOwnership(after: .fullIncorporation)
    }

    func testRepeatedBootstrapDoesNotRecreateOwnershipAfterTombstone() throws {
        try assertRepeatedBootstrapDoesNotRecreateOwnership(after: .tombstone)
    }

    private func assertRepeatedBootstrapDoesNotRecreateOwnership(
        after durableProof: DurableProof
    ) throws {
        let source = try makeContainer()
        let sourceContext = ModelContext(source)
        sourceContext.autosaveEnabled = false
        let note = Note(title: "Peer title", content: "AB")
        sourceContext.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: sourceContext
        )
        try sourceContext.save()

        let mutationSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: sourceContext
        )
        guard case .noteBodyTextInsertedAnchored(let insertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: note.id,
            utf16Offset: 1,
            text: "S",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000221001")!,
                localCounter: 1
            ),
            state: mutationSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let peerState = try mutationSnapshot.state.incorporating(
            insert: insertion.payload,
            insertedText: insertion.text
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: mutationSnapshot,
            newBody: peerState.visibleText,
            finalState: peerState,
            in: sourceContext
        )
        try sourceContext.save()

        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000221002")!
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000221003")!
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 222),
            changes: [
                .noteBodyTextInsertedAnchored(insertion),
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Peer title",
                        modifiedAt: Date(timeIntervalSinceReferenceDate: 223)
                    )
                )
            ]
        )
        let baseSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: sourceContext)
        let staleSnapshot = baseSnapshot.attachingHistoryCoverage(for: [batch])

        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        destinationContext.autosaveEnabled = false
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            baseSnapshot,
            to: destinationContext
        )
        let requestedNoteID = note.id
        let destinationNote = try XCTUnwrap(
            destinationContext.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedNoteID })
            ).first
        )
        destinationNote.title = "Local title"
        try destinationContext.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-stale-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("anchored-recovery.json")
        )
        let firstApply = try SyncPeerBootstrapSnapshotPersistence.apply(
            staleSnapshot,
            to: destinationContext,
            anchoredRecoveryStore: recoveryStore
        )
        XCTAssertFalse(firstApply.coveredBatchIDs.contains(batchID))

        let recoveryChange = SyncBatchAnchoredRecoveryChange.insertion(insertion)
        let owned = try XCTUnwrap(
            recoveryStore.snapshot().record(for: recoveryChange.recordKey)
        )
        XCTAssertEqual(owned.lifecycle, .bootstrapOwned)
        XCTAssertTrue(try recoveryStore.apply([.removeCommitted(expected: owned)]))
        XCTAssertNil(recoveryStore.snapshot().record(for: recoveryChange.recordKey))

        let committedAt = Date(timeIntervalSinceReferenceDate: 224)
        switch durableProof {
        case .fullIncorporation:
            destinationContext.insert(IncorporatedSyncBatch(
                batchID: batchID,
                originDeviceID: originDeviceID,
                createdAt: batch.createdAt,
                batchSequence: batch.batchSequence,
                schemaVersion: 1,
                committedAt: committedAt,
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1,
                affectedNotesPayloadData: Data(),
                authoritativeChildCount: 0,
                authoritativeChildBytes: 0,
                authoritativeChildrenDigest: String(repeating: "c", count: 64),
                postCommitStatePayloadData: Data(),
                hasPendingPostCommitWork: false
            ))
        case .tombstone:
            destinationContext.insert(try IncorporatedBatchTombstone.makeValidated(
                batchID: batchID,
                originDeviceID: originDeviceID,
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                schemaVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1,
                committedAtOrderingPayloadData: try CommittedAtOrderingPayload(
                    batchID: batchID,
                    committedAt: committedAt
                ).encodedEvidenceData()
            ))
        }
        try destinationContext.save()

        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            staleSnapshot,
            to: destinationContext,
            anchoredRecoveryStore: recoveryStore
        )

        XCTAssertNil(
            recoveryStore.snapshot().record(for: recoveryChange.recordKey),
            "A stale bootstrap retry must not recreate ownership after durable incorporation."
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-221-BootstrapOwnership-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private enum DurableProof {
        case fullIncorporation
        case tombstone
    }
}

@MainActor
final class MYR222DisconnectedConcurrentEditTests: XCTestCase {
#if os(macOS)
    func testReconnectBootstrapIncludesDurablePendingLocalObligationHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-failure-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeDisconnectedEditFixture()
        let localQueueURL = directory.appendingPathComponent("local-obligations.json")
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localQueueURL)
        try localQueue.enqueue(fixture.obligation)
        XCTAssertEqual(localQueue.pendingBatches.map(\.id), [fixture.obligation.batch.id])

        let conflictStore = SyncConflictStore(
            fileURL: directory.appendingPathComponent("conflicts.json")
        )
        let remotePeer = MCPeerID(displayName: "remote|myr222-peer")
        var sentMessages: [Data] = []
        let controller = MacSyncBatchController(
            context: fixture.context,
            conflictStore: conflictStore,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: FileBackedSyncBatchQueue(fileURL: nil),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "22200000-0000-0000-0000-000000000010")!,
                    displayName: "MYR222"
                )
            },
            startAdvertisingOperation: {},
            startBrowsingOperation: {},
            connectedPeersProvider: { [remotePeer] },
            sendBatchDataOperation: { data, peers, _ in
                if !peers.isEmpty {
                    sentMessages.append(data)
                }
            }
        )
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("anchored-recovery.json")
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: fixture.context,
            syncController: controller,
            conflictStore: conflictStore,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in fatalError("Not used by bootstrap coverage regression") },
                reloadSelectedEditor: { _, _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localQueueURL,
            anchoredRecoveryStore: recoveryStore
        )
        _ = coordinator

        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr222-peer"
        )
        await controller.beginReconnectBootstrapForTesting(to: remotePeer)

        let wireData = try XCTUnwrap(sentMessages.first)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: wireData)
        XCTAssertEqual(message.kind, .bootstrapSnapshot)
        let snapshot = try JSONDecoder().decode(
            SyncPeerBootstrapSnapshot.self,
            from: message.payload
        )

        XCTAssertEqual(
            Set(snapshot.historyCoverage.map(\.batchID)),
            [fixture.obligation.batch.id],
            "Reconnect bootstrap must carry durable local-obligation ownership before ordinary sync can resume."
        )
    }
#else
    func testReconnectBootstrapIncludesDurablePendingLocalObligationHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-ios-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeDisconnectedEditFixture()
        let remotePeer = MCPeerID(displayName: "remote|myr222-ios-peer")
        let transport = MYR222BootstrapRecordingTransport(connectedPeers: [remotePeer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: directory.appendingPathComponent("legacy.json"),
            startsNetworking: false,
            transport: transport
        )
        var pendingLocalCount = 1
        var admissionError: Error?
        controller.localConvergencePendingCountProvider = { pendingLocalCount }
        controller.onFlushLocalConvergenceRequested = { [weak controller] in
            guard let controller else { return }
            do {
                try await controller.acceptLocalBatch(fixture.obligation.batch)
                pendingLocalCount = 0
            } catch {
                admissionError = error
            }
        }
        controller.buildBootstrapSnapshot = {
            try SyncPeerBootstrapSnapshotPersistence.build(from: fixture.context)
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr222-ios-peer"
        )
        controller.setBootstrapRetryDelayNanosecondsForTesting([1_000_000_000])

        await controller.beginBootstrapForTesting(to: remotePeer)

        XCTAssertNil(admissionError)
        XCTAssertEqual(pendingLocalCount, 0)
        let snapshot = try XCTUnwrap(transport.sentBootstrapSnapshots.first)
        XCTAssertEqual(
            Set(snapshot.historyCoverage.map(\.batchID)),
            [fixture.obligation.batch.id],
            "iPhone reconnect bootstrap must transfer durable local-obligation ownership before snapshot capture."
        )
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr222-ios-peer")
    }

    func testReconnectBootstrapFailsClosedWhileLocalObligationRemainsPending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-ios-fail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let remotePeer = MCPeerID(displayName: "remote|myr222-ios-blocked-peer")
        let transport = MYR222BootstrapRecordingTransport(connectedPeers: [remotePeer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: directory.appendingPathComponent("legacy.json"),
            startsNetworking: false,
            transport: transport
        )
        var pendingLocalCount = 1
        var flushCount = 0
        var buildCount = 0
        controller.localConvergencePendingCountProvider = { pendingLocalCount }
        controller.onFlushLocalConvergenceRequested = {
            flushCount += 1
        }
        controller.buildBootstrapSnapshot = {
            buildCount += 1
            return SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr222-ios-blocked-peer"
        )
        controller.setBootstrapRetryDelayNanosecondsForTesting([1_000_000_000])

        await controller.beginBootstrapForTesting(to: remotePeer)

        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(buildCount, 0)
        XCTAssertTrue(transport.sentBootstrapSnapshots.isEmpty)
        XCTAssertFalse(
            controller.isOrdinarySyncReadyForTesting(peerDeviceID: "myr222-ios-blocked-peer")
        )
        XCTAssertEqual(
            controller.lastErrorMessage,
            "Unable to prepare nearby bootstrap state while local sync work is pending."
        )

        pendingLocalCount = 0
        await controller.beginBootstrapForTesting(to: remotePeer)

        XCTAssertEqual(flushCount, 2)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(transport.sentBootstrapSnapshots.count, 1)
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr222-ios-blocked-peer")
    }
#endif

    private func makeDisconnectedEditFixture() async throws -> (
        container: ModelContainer,
        context: ModelContext,
        obligation: SyncConvergenceLocalObligation
    ) {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-DisconnectedEdit-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000001")!
        let note = Note(title: "", content: "AB")
        note.id = noteID
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: context
        )
        try context.save()

        let initial = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        let originDeviceID = UUID(uuidString: "22200000-0000-0000-0000-000000000002")!
        let capture = try await SyncBatchAnchoredLocalCapture.capture(
            noteID: noteID,
            oldBody: "AB",
            newBody: "AxB",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 222),
            initialState: initial.state,
            operationIDReserver: MYR222OperationIDReserver(
                deviceID: originDeviceID,
                nextCounter: 1
            )
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: initial,
            newBody: capture.finalState.visibleText,
            finalState: capture.finalState,
            in: context
        )
        note.modifiedAt = Date(timeIntervalSinceReferenceDate: 222)
        try context.save()

        let persisted = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        XCTAssertEqual(note.content, persisted.state.visibleText)
        XCTAssertEqual(note.content, "AxB")

        let batch = SyncBatch(
            id: UUID(uuidString: "22200000-0000-0000-0000-000000000003")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 222),
            batchSequence: 1,
            changes: capture.capturedChanges.map(\.change)
        )
        return (
            container,
            context,
            SyncConvergenceLocalObligation(
                batch: batch,
                capturedChanges: capture.capturedChanges
            )
        )
    }
}

#if !os(macOS)
private final class MYR222BootstrapRecordingTransport: MyRAMSyncTransporting {
    private let connectedPeerValues: [MCPeerID]
    private(set) var sentBootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []

    init(connectedPeers: [MCPeerID]) {
        connectedPeerValues = connectedPeers
    }

    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        connectedPeerValues
    }

    func hasConnectedPeer(_ peerID: MCPeerID) -> Bool {
        connectedPeerValues.contains(peerID)
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        guard message.kind == .bootstrapSnapshot else { return }
        sentBootstrapSnapshots.append(
            try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
        )
    }
}
#endif

private actor MYR222OperationIDReserver: SyncOperationIDReserving {
    private let deviceID: UUID
    private var nextCounter: UInt64

    init(deviceID: UUID, nextCounter: UInt64) {
        self.deviceID = deviceID
        self.nextCounter = nextCounter
    }

    func reserveOperationID() async throws -> SyncOperationID {
        let operationID = SyncOperationID(deviceID: deviceID, localCounter: nextCounter)
        nextCounter &+= 1
        return operationID
    }
}

private enum MigratorTestFailure: Error {
    case interrupted
}

private final class IDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }
}