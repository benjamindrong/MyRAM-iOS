import AnchoredSequenceCore
import NearbySyncCore
@preconcurrency import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchControllerTests: XCTestCase {
    private var retainedContainers: [ModelContainer] = []

    func testMYR223LegacyFolderReceiptRedrivesDeferredConvergence() async throws {
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let controller = try makeController(
            context: context,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: nil
        )

        let noteID = UUID()
        let folderID = UUID()
        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteCreated(SyncBatchNoteCreatedChange(
                    noteID: noteID,
                    title: "Imported",
                    body: "Body",
                    folderID: folderID,
                    createdAt: Date(timeIntervalSince1970: 1),
                    modifiedAt: Date(timeIntervalSince1970: 2)
                ))
            ]
        )

        let initialDisposition = await coordinator.submitRemoteBatch(batch)
        XCTAssertEqual(initialDisposition, .acknowledgementDeferred)
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)

        let folder = Folder(name: "Imported Folder")
        folder.id = folderID
        folder.createdAt = Date(timeIntervalSince1970: 1)
        folder.modifiedAt = Date(timeIntervalSince1970: 2)
        let folderChange = SyncChange(
            entityType: .collection,
            entityID: folderID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMFolderSyncPayload(folder: folder)),
            updatedAt: folder.modifiedAt,
            originDeviceID: "remote"
        )
        let envelope = SyncEnvelope(
            senderDeviceID: "remote",
            changes: [folderChange]
        )
        let data = try MultipeerSyncMessageCoding.encode(
            kind: .legacySyncEnvelope,
            payload: JSONEncoder().encode(envelope)
        )
        let peer = MCPeerID(displayName: "remote|myr223")
        let session = MCSession(
            peer: MCPeerID(displayName: "local|myr223"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(session, didReceive: data, fromPeer: peer)

        await waitUntil {
            let requestedNoteID = noteID
            guard let created = try? context.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { $0.id == requestedNoteID }
            )).first else {
                return false
            }
            return created.folder?.id == folderID
                && coordinator.pendingIncomingBatchCount == 0
        }

        let created = try XCTUnwrap(context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == noteID }
        )).first)
        XCTAssertEqual(created.folder?.id, folderID)
    }

    func testMYR233PersistedBootstrapOwnedRedeliveryRetiresIncomingQueueAndAcknowledges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-bootstrap-owned-redelivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let noteID = UUID(uuidString: "23300000-0000-0000-0000-0000000000E1")!
        let batchID = UUID(uuidString: "23300000-0000-0000-0000-0000000000E2")!
        let originDeviceID = UUID(uuidString: "23300000-0000-0000-0000-0000000000E3")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_331)
        let modifiedAt = createdAt.addingTimeInterval(1)

        let note = Note(title: "Shared", content: "B")
        note.id = noteID
        note.createdAt = createdAt
        note.modifiedAt = createdAt
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()

        let initial = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 1,
            text: "A",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "B"),
            operationID: SyncOperationID(deviceID: originDeviceID, localCounter: 1),
            state: initial.state
        )
        guard case .noteBodyTextInsertedAnchored(let anchoredInsertion) = change else {
            return XCTFail("Expected anchored insertion")
        }
        let remoteState = try SyncBatchAnchoredInsertReplay.applying(
            anchoredInsertion,
            to: initial.state
        ).sequenceState
        let payload = try NoteSequenceStatePersistenceCodec.encode(
            state: remoteState,
            noteID: noteID
        )
        let snapshot = SyncPeerBootstrapSnapshot(
            id: UUID(uuidString: "23300000-0000-0000-0000-0000000000E4")!,
            folders: [],
            notes: [SyncPeerBootstrapNoteSnapshot(
                id: noteID,
                title: note.title,
                body: remoteState.visibleText,
                isPinned: false,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                deletedAt: nil,
                folderID: nil,
                formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
                revision: 1,
                visibleUTF16Count: remoteState.visibleUTF16Count,
                tombstonedUTF16Count: remoteState.tombstonedUTF16Count,
                payloadByteCount: payload.count,
                statePayloadData: payload
            )],
            historyCoverage: [SyncPeerBootstrapHistoryBatchCoverage(
                batchID: batchID,
                noteIDs: [noteID],
                anchoredRecoveryChanges: [.insertion(anchoredInsertion)]
            )]
        )

        let recoveryURL = directory.appendingPathComponent("anchored-recovery.json")
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: recoveryURL)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: context,
            anchoredRecoveryStore: recoveryStore
        )

        let recoveryChange = SyncBatchAnchoredRecoveryChange.insertion(anchoredInsertion)
        if recoveryStore.snapshot().record(for: recoveryChange.recordKey) == nil {
            // The physical MYR-233 state contains bootstrap-owned recovery evidence
            // for historical batches that remain durably queued for redelivery.
            let persistedOwnership = try SyncBatchAnchoredRecoveryRecord(
                change: recoveryChange,
                lifecycle: .bootstrapOwned
            )
            XCTAssertTrue(try recoveryStore.apply([
                .insertExpectedAbsent(persistedOwnership)
            ]))
        }
        let ownership = try XCTUnwrap(
            recoveryStore.snapshot().record(for: recoveryChange.recordKey)
        )
        XCTAssertEqual(ownership.lifecycle, .bootstrapOwned)

        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: modifiedAt,
            batchSequence: 1,
            changes: [change]
        )
        let pendingURL = directory.appendingPathComponent("pending-incoming.json")
        let pendingQueue = FileBackedSyncBatchQueue(fileURL: pendingURL)
        try pendingQueue.enqueueIncoming(batch)

        let peer = MCPeerID(displayName: "remote|myr233-bootstrap-owned-redelivery")
        var sentMessages: [Data] = []
        let controller = try makeController(
            context: context,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sentMessages.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil,
            anchoredRecoveryStore: recoveryStore
        )

        let localPeerID = MCPeerID(displayName: "local|myr233-local")
        let browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: "myram-sync"
        )
        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: nil,
            serviceType: "myram-sync"
        )
        let session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        controller.browser(
            browser,
            foundPeer: peer,
            withDiscoveryInfo: [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2",
                SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey: "1"
            ]
        )
        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: peer,
            withContext: Data("1,2".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        controller.session(session, peer: peer, didChange: .connected)
        await Task.yield()
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "myr233-bootstrap-owned-redelivery"
            )
        )
        XCTAssertTrue(
            controller.isBootstrapCapabilityResolvedForTesting(
                peerDeviceID: "myr233-bootstrap-owned-redelivery"
            )
        )
        controller.session(
            session,
            didReceive: try MultipeerSyncMessageCoding.encodeBatch(batch),
            fromPeer: peer
        )

        await waitUntil(timeout: .seconds(2)) {
            sentMessages.contains { data in
                guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                      message.kind == .batchAcknowledgement,
                      let acknowledgement = try? JSONDecoder().decode(
                        SyncBatchAcknowledgement.self,
                        from: message.payload
                      ) else {
                    return false
                }
                return acknowledgement.batchID == batchID
            }
        }


        XCTAssertFalse(FileBackedSyncBatchQueue(fileURL: pendingURL).contains(batchID))
        XCTAssertNil(recoveryStore.snapshot().record(for: recoveryChange.recordKey))
        XCTAssertEqual(note.content, remoteState.visibleText)
        XCTAssertTrue(
            sentMessages.contains { data in
                guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                      message.kind == .batchAcknowledgement,
                      let acknowledgement = try? JSONDecoder().decode(
                        SyncBatchAcknowledgement.self,
                        from: message.payload
                      ) else {
                    return false
                }
                return acknowledgement.batchID == batchID
            }
        )
    }

    func testMYR233DeferredBatchDoesNotBlockDisjointSameOriginBatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-same-origin-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let blockedNoteID = UUID(uuidString: "23300000-0000-0000-0000-000000000101")!
        let disjointNoteID = UUID(uuidString: "23300000-0000-0000-0000-000000000102")!
        let originDeviceID = UUID(uuidString: "23300000-0000-0000-0000-000000000103")!

        let blockedNote = Note(title: "Blocked", content: "local-a")
        blockedNote.id = blockedNoteID
        let disjointNote = Note(title: "Before", content: "local-b")
        disjointNote.id = disjointNoteID
        context.insert(blockedNote)
        context.insert(disjointNote)
        try context.save()

        let pendingURL = directory.appendingPathComponent("pending-incoming.json")
        let controller = try makeController(
            context: context,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )

        let deferredBatch = SyncBatch(
            id: UUID(uuidString: "23300000-0000-0000-0000-000000000104")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_334),
            batchSequence: 1,
            changes: [.noteBodyTextInserted(.init(
                noteID: blockedNoteID,
                utf16Offset: 4,
                text: " remote",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 2_334),
                baseContentHash: SyncBatchContentHash.sha256Hex(for: "base")
            ))]
        )
        let disjointBatch = SyncBatch(
            id: UUID(uuidString: "23300000-0000-0000-0000-000000000105")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_335),
            batchSequence: 2,
            changes: [.noteTitleChanged(.init(
                noteID: disjointNoteID,
                title: "After",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 2_335)
            ))]
        )

        XCTAssertEqual(
            await coordinator.submitRemoteBatch(deferredBatch),
            .acknowledgementDeferred
        )
        XCTAssertEqual(
            await coordinator.submitRemoteBatch(disjointBatch),
            .acknowledgementPermitted,
            "A deferred batch must not head-of-line block disjoint work from the same peer."
        )
        XCTAssertEqual(disjointNote.title, "After")
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches.map(\.id),
            [deferredBatch.id]
        )
    }

    func testInviteDoesNotStartAnotherAttemptForConnectedPeer() throws {
        let peerID = MCPeerID(displayName: "remote|connected-mac")
        var invitedPeerIDs: [MCPeerID] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peerID] },
            invitePeerOperation: { peerID, _, _ in invitedPeerIDs.append(peerID) }
        )
        let peer = MacSyncDiscoveredPeer(
            peerID: peerID,
            deviceID: "connected-mac",
            displayName: "Remote"
        )

        controller.invite(peer)

        XCTAssertTrue(invitedPeerIDs.isEmpty)
        XCTAssertEqual(controller.lastConnectionEvent, "Connected: Remote")
    }

    func testBootstrapBarrierPositiveAckPrunesCapturedBatchesAndPreservesNewerWork() async throws {
        let peer = MCPeerID(displayName: "remote|bootstrap-mac")
        var sends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-mac")
        let covered = makeBatch(idSuffix: 2161)
        let newer = makeBatch(idSuffix: 2162)
        try await controller.acceptLocalBatch(covered)
        XCTAssertTrue(sends.isEmpty)

        controller.beginBootstrapForTesting(to: peer)
        let bootstrapData = try XCTUnwrap(sends.first)
        let bootstrapMessage = try MultipeerSyncMessageCoding.decodeMessage(from: bootstrapData)
        let snapshot = try JSONDecoder().decode(
            SyncPeerBootstrapSnapshot.self,
            from: bootstrapMessage.payload
        )
        try await controller.acceptLocalBatch(newer)
        XCTAssertEqual(sends.count, 1)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshot.id, coveredBatchIDs: [covered.id]),
            from: peer
        )

        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id), [newer.id])
        XCTAssertTrue(controller.bootstrapStateForTesting(peerDeviceID: "bootstrap-mac")?.ordinarySyncReady == true)
        XCTAssertEqual(try MultipeerSyncMessageCoding.decodeMessage(from: sends.last!).kind, .batchSync)
    }

    func testBootstrapBarrierWithholdsUncoveredHistoricalWork() async throws {
        let peer = MCPeerID(displayName: "remote|bootstrap-mac")
        var sends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-mac")
        let covered = makeBatch(idSuffix: 2163)
        try await controller.acceptLocalBatch(covered)
        controller.beginBootstrapForTesting(to: peer)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: sends[0])
        let snapshot = try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshot.id, coveredBatchIDs: []),
            from: peer
        )

        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id), [covered.id])
        XCTAssertEqual(try MultipeerSyncMessageCoding.decodeMessage(from: sends.last!).kind, .bootstrapSnapshot)
    }

    func testReconnectBootstrapRecoversWithFullUnsentQueueAndDurableLocalObligations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-full-queue-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Mirrors the captured persisted-stuck shape: transport at capacity with local work behind it.
        let unsentURL = directory.appendingPathComponent("unsent-batches.json")
        let localURL = directory.appendingPathComponent("local-obligations.json")
        let unsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        for index in 0..<100 {
            try unsentQueue.enqueueDurably(makeBatch(idSuffix: 233_000 + index))
        }
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localURL)
        for index in 0..<36 {
            try localQueue.enqueue(
                SyncConvergenceLocalObligation(
                    legacyBatch: makeBatch(idSuffix: 234_000 + index)
                )
            )
        }

        let peer = MCPeerID(displayName: "remote|myr233-full-queue-mac")
        var sends: [Data] = []
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let controller = try makeController(
            context: container.mainContext,
            unsentBatchQueueFileURL: unsentURL,
            unsentBatchQueue: unsentQueue,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localURL
        )
        _ = coordinator
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr233-full-queue-mac"
        )

        await controller.beginReconnectBootstrapForTesting(to: peer)

        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count, 100)
        XCTAssertEqual(coordinator.pendingLocalObligationCount, 36)
        let data = try XCTUnwrap(sends.first)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        XCTAssertEqual(message.kind, .bootstrapSnapshot)
        let snapshot = try JSONDecoder().decode(
            SyncPeerBootstrapSnapshot.self,
            from: message.payload
        )
        XCTAssertEqual(
            snapshot.historyCoverage.count,
            136,
            "Bootstrap must own both full unsent history and durable local obligations without transport promotion."
        )
    }

    func testOrdinaryBatchAcknowledgementWakesPendingLocalObligationAfterCapacityFrees() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-ack-capacity-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsentURL = directory.appendingPathComponent("unsent-batches.json")
        let localURL = directory.appendingPathComponent("local-obligations.json")
        let unsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL, limit: 1)
        let occupying = makeBatch(idSuffix: 234_900)
        let local = makeBatch(idSuffix: 234_901)
        try unsentQueue.enqueueDurably(occupying)

        let peer = MCPeerID(displayName: "remote|myr233-ack-capacity-wake")
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let controller = try makeController(
            context: container.mainContext,
            unsentBatchQueueFileURL: unsentURL,
            unsentBatchQueue: unsentQueue,
            connectedPeersProvider: { [] },
            sendBatchDataOperation: { _, _, _ in }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localURL
        )

        _ = await coordinator.submitLocalObligation(
            SyncConvergenceLocalObligation(legacyBatch: local)
        )
        XCTAssertEqual(coordinator.pendingLocalObligationCount, 1)
        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id), [occupying.id])

        await controller.handleBatchAcknowledgementForTesting(
            SyncBatchAcknowledgement(batchID: occupying.id),
            from: peer
        )

        XCTAssertEqual(coordinator.pendingLocalObligationCount, 0)
        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id), [local.id])
    }

    func testBootstrapDeduplicatesIdenticalCrossDomainBatchAndAckRetiresBothOwners() async throws {
        let batch = makeBatch(idSuffix: 235_001)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [batch],
            localBatches: [batch],
            peerDeviceID: "myr233-duplicate-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)

        let snapshot = try fixture.firstBootstrapSnapshot()
        XCTAssertEqual(snapshot.historyCoverage.map(\.batchID), [batch.id])

        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshot.id,
                coveredBatchIDs: [batch.id]
            ),
            from: fixture.peer
        )

        XCTAssertTrue(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 0)
        XCTAssertTrue(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-duplicate-mac")?
                .ordinarySyncReady == true
        )
    }

    func testBootstrapRejectsConflictingCrossDomainDuplicateBeforeTransmission() throws {
        let batch = makeBatch(idSuffix: 235_002)
        let conflicting = batchWithSameID(batch, createdAtOffset: 1)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [batch],
            localBatches: [conflicting],
            peerDeviceID: "myr233-conflict-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)

        XCTAssertTrue(fixture.sentMessages.values.isEmpty)
        XCTAssertNil(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-conflict-mac")
        )
        XCTAssertEqual(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [batch])
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 1)
    }

    func testBootstrapUnsentCleanupFailureRemainsRetryableOnAckReplay() async throws {
        let batch = makeBatch(idSuffix: 235_003)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [batch],
            localBatches: [],
            peerDeviceID: "myr233-unsent-replay-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)
        let snapshot = try fixture.firstBootstrapSnapshot()
        fixture.unsentQueue.injectPersistenceFailureForNextWrite()

        let acknowledgement = SyncPeerBootstrapAcknowledgement(
            snapshotID: snapshot.id,
            coveredBatchIDs: [batch.id]
        )
        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: fixture.peer
        )

        XCTAssertEqual(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [batch])
        XCTAssertFalse(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-unsent-replay-mac")?
                .ordinarySyncReady == true
        )

        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: fixture.peer
        )

        XCTAssertTrue(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
        XCTAssertTrue(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-unsent-replay-mac")?
                .ordinarySyncReady == true
        )
    }

    func testBootstrapPartialCleanupLocalFailureConvergesOnAckReplay() async throws {
        let batch = makeBatch(idSuffix: 235_004)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [batch],
            localBatches: [batch],
            peerDeviceID: "myr233-local-replay-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)
        let snapshot = try fixture.firstBootstrapSnapshot()
        fixture.coordinator.injectLocalBootstrapOwnershipPersistenceFailureForTesting()

        let acknowledgement = SyncPeerBootstrapAcknowledgement(
            snapshotID: snapshot.id,
            coveredBatchIDs: [batch.id]
        )
        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: fixture.peer
        )

        XCTAssertTrue(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 1)
        XCTAssertFalse(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-local-replay-mac")?
                .ordinarySyncReady == true
        )

        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: fixture.peer
        )

        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 0)
        XCTAssertTrue(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-local-replay-mac")?
                .ordinarySyncReady == true
        )
    }

    func testFrozenLocalObligationPromotedWhileAckPendingIsRemovedFromBothDomains() async throws {
        let batch = makeBatch(idSuffix: 235_005)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [],
            localBatches: [batch],
            peerDeviceID: "myr233-moved-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)
        let snapshot = try fixture.firstBootstrapSnapshot()
        try await fixture.controller.acceptLocalBatch(batch)

        XCTAssertEqual(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [batch])
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 1)

        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshot.id,
                coveredBatchIDs: [batch.id]
            ),
            from: fixture.peer
        )

        XCTAssertTrue(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 0)
        XCTAssertTrue(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-moved-mac")?
                .ordinarySyncReady == true
        )
    }

    func testFrozenLocalObligationSameIDDifferentContentWhileAckPendingFailsClosed() async throws {
        let batch = makeBatch(idSuffix: 235_006)
        let conflicting = batchWithSameID(batch, createdAtOffset: 1)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [],
            localBatches: [batch],
            peerDeviceID: "myr233-moved-conflict-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.beginBootstrapForTesting(to: fixture.peer)
        let snapshot = try fixture.firstBootstrapSnapshot()
        try await fixture.controller.acceptLocalBatch(conflicting)

        await fixture.controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshot.id,
                coveredBatchIDs: [batch.id]
            ),
            from: fixture.peer
        )

        XCTAssertEqual(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [conflicting])
        XCTAssertEqual(fixture.coordinator.pendingLocalObligationCount, 1)
        XCTAssertFalse(
            fixture.controller.bootstrapStateForTesting(peerDeviceID: "myr233-moved-conflict-mac")?
                .ordinarySyncReady == true
        )
    }

    func testBootstrapMutationBetweenFreezePassesRetriesBeforeTransmission() async throws {
        let batch = makeBatch(idSuffix: 235_007)
        let replacement = batchWithSameID(batch, createdAtOffset: 1)
        let fixture = try makeMYR233BootstrapFixture(
            unsentBatches: [batch],
            localBatches: [],
            peerDeviceID: "myr233-freeze-race-mac"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var captureCount = 0
        var mutationError: Error?
        fixture.controller.onBootstrapCandidateCapturedForTesting = {
            captureCount += 1
            guard captureCount == 1 else { return }
            do {
                try fixture.unsentQueue.removeBatches(withIDs: [batch.id])
                try fixture.unsentQueue.enqueueDurably(replacement)
            } catch {
                mutationError = error
            }
        }

        await fixture.controller.beginReconnectBootstrapForTesting(to: fixture.peer)

        XCTAssertNil(mutationError)
        XCTAssertGreaterThanOrEqual(captureCount, 2)
        XCTAssertEqual(fixture.sentMessages.values.count, 1)
        let snapshot = try fixture.firstBootstrapSnapshot()
        XCTAssertEqual(snapshot.historyCoverage.map(\.batchID), [batch.id])
        XCTAssertEqual(fixture.controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [replacement])
    }

    func testReconnectBootstrapCapturesPendingAccumulatorWorkWithoutQuietWindow() async throws {
        let peer = MCPeerID(displayName: "remote|myr229-accumulator-mac")
        var sends: [Data] = []
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let controller = try makeController(
            context: container.mainContext,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: nil
        )
        _ = coordinator
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "myr229-accumulator-mac")
        let operation87 = try makeAnchoredCapturedChange(localCounter: 87)
        let note = Note(title: "Shared", content: "")
        note.id = operation87.change.noteID
        container.mainContext.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: container.mainContext
        )
        let initialSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: container.mainContext
        )
        guard case .noteBodyTextInsertedAnchored(let inserted) = operation87.change else {
            return XCTFail("Expected operation 87 to be an anchored insertion")
        }
        let finalState = try SyncBatchAnchoredInsertReplay.applying(
            inserted,
            to: initialSnapshot.state
        ).sequenceState
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: initialSnapshot,
            newBody: finalState.visibleText,
            finalState: finalState,
            in: container.mainContext
        )
        try container.mainContext.save()
        await controller.record(
            operation87,
            at: Date(timeIntervalSince1970: 229)
        )

        await controller.beginReconnectBootstrapForTesting(to: peer)

        let capturedBatch = try XCTUnwrap(
            controller.unsentBatchQueueSnapshotForTesting().pendingBatches.first
        )
        _ = try XCTUnwrap(sends.first)
        XCTAssertEqual(
            controller.bootstrapStateForTesting(peerDeviceID: "myr229-accumulator-mac")?
                .snapshot.historyCoverage.map(\.batchID),
            [capturedBatch.id]
        )
    }

    func testBootstrapPruningFailureKeepsMacBarrierClosedAndHistoryQueued() async throws {
        let peer = MCPeerID(displayName: "remote|bootstrap-mac")
        var sends: [Data] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-216-mac-pruning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueURL = directory.appendingPathComponent("unsent-batches.json")
        let queue = FileBackedSyncBatchQueue(fileURL: queueURL)
        let controller = try makeController(
            unsentBatchQueueFileURL: queueURL,
            unsentBatchQueue: queue,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-mac")
        let historical = makeBatch(idSuffix: 2164)
        try await controller.acceptLocalBatch(historical)
        controller.beginBootstrapForTesting(to: peer)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: sends[0])
        let snapshot = try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
        queue.injectPersistenceFailureForNextWrite()

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshot.id,
                coveredBatchIDs: [historical.id]
            ),
            from: peer
        )

        XCTAssertFalse(controller.bootstrapStateForTesting(peerDeviceID: "bootstrap-mac")?.ordinarySyncReady == true)
        XCTAssertEqual(queue.pendingBatches, [historical])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches, [historical])
        XCTAssertEqual(sends.count, 1)
    }

    func testMacCapabilityAnnouncementResolvesPeerAndStartsBootstrapBeforeBatchSync() async throws {
        let peer = MCPeerID(displayName: "remote|announcement-mac")
        var kinds: [MultipeerSyncMessageKind] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                kinds.append(try MultipeerSyncMessageCoding.decodeMessage(from: data).kind)
            }
        )
        try await controller.acceptLocalBatch(makeBatch(idSuffix: 2165))
        XCTAssertTrue(kinds.isEmpty)

        controller.handleBootstrapCapabilityAnnouncementForTesting(from: peer)

        XCTAssertTrue(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "announcement-mac"))
        XCTAssertEqual(kinds, [.bootstrapSnapshot])
    }

    func testMacUnresolvedPeerFallsBackBeforeBatchSyncAndLateSupportStartsBootstrap() async throws {
        let peer = MCPeerID(displayName: "remote|fallback-mac")
        var kinds: [MultipeerSyncMessageKind] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                kinds.append(try MultipeerSyncMessageCoding.decodeMessage(from: data).kind)
            }
        )
        try await controller.acceptLocalBatch(makeBatch(idSuffix: 2166))
        XCTAssertTrue(kinds.isEmpty)

        await controller.resolveBootstrapCapabilityFallbackForTesting(peerID: peer)
        XCTAssertEqual(kinds, [.batchSync])

        controller.handleBootstrapCapabilityAnnouncementForTesting(from: peer)
        XCTAssertEqual(kinds.last, .bootstrapSnapshot)
    }

    func testMacBootstrapSnapshotSendFailureAutomaticallyRetriesSameSnapshot() async throws {
        let peer = MCPeerID(displayName: "remote|retry-mac")
        var shouldFail = true
        var attemptedSnapshots: [SyncPeerBootstrapSnapshot] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                guard message.kind == .bootstrapSnapshot else { return }
                let snapshot = try JSONDecoder().decode(
                    SyncPeerBootstrapSnapshot.self,
                    from: message.payload
                )
                attemptedSnapshots.append(snapshot)
                if shouldFail {
                    shouldFail = false
                    throw MacBootstrapSendTestError.injected
                }
            }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "retry-mac")
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            1_000_000,
            1_000_000_000,
            1_000_000_000
        ])

        controller.beginBootstrapForTesting(to: peer)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThanOrEqual(attemptedSnapshots.count, 2)
        XCTAssertEqual(Set(attemptedSnapshots.map(\.id)).count, 1)
        let snapshotID = try XCTUnwrap(attemptedSnapshots.first?.id)
        XCTAssertEqual(
            controller.bootstrapStateForTesting(peerDeviceID: "retry-mac")?.snapshotID,
            snapshotID
        )

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )
        let attemptsAfterAck = attemptedSnapshots.count
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertEqual(attemptedSnapshots.count, attemptsAfterAck)
    }

    func testMacBootstrapAckTimeoutRetransmitsSameSnapshotUntilAck() async throws {
        let peer = MCPeerID(displayName: "remote|ack-timeout-mac")
        var attemptedSnapshots: [SyncPeerBootstrapSnapshot] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                guard message.kind == .bootstrapSnapshot else { return }
                attemptedSnapshots.append(
                    try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
                )
            }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "ack-timeout-mac")
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            1_000_000,
            1_000_000_000,
            1_000_000_000
        ])

        controller.beginBootstrapForTesting(to: peer)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThanOrEqual(attemptedSnapshots.count, 2)
        XCTAssertEqual(Set(attemptedSnapshots.map(\.id)).count, 1)
        let snapshotID = try XCTUnwrap(attemptedSnapshots.first?.id)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )
        let attemptsAfterAck = attemptedSnapshots.count
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(attemptedSnapshots.count, attemptsAfterAck)
        XCTAssertTrue(
            controller.bootstrapStateForTesting(peerDeviceID: "ack-timeout-mac")?.ordinarySyncReady == true
        )
    }

    func testMacDisconnectCancelsPendingBootstrapRetry() async throws {
        let peer = MCPeerID(displayName: "remote|disconnect-mac")
        var snapshotSendCount = 0
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                if try MultipeerSyncMessageCoding.decodeMessage(from: data).kind == .bootstrapSnapshot {
                    snapshotSendCount += 1
                }
            }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "disconnect-mac")
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            20_000_000,
            1_000_000_000,
            1_000_000_000
        ])
        controller.beginBootstrapForTesting(to: peer)
        XCTAssertTrue(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "disconnect-mac"))
        let sendsBeforeDisconnect = snapshotSendCount

        controller.handlePeerDisconnectForTesting(peerDeviceID: "disconnect-mac")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "disconnect-mac"))
        XCTAssertNil(controller.bootstrapStateForTesting(peerDeviceID: "disconnect-mac"))
        XCTAssertEqual(snapshotSendCount, sendsBeforeDisconnect)
    }

    func testMacReceiveBootstrapPersistsBeforeAckAndResumesRealPendingWorkAfterSuccessfulAck() async throws {
        let peer = MCPeerID(displayName: "remote|ordering-mac")
        let destinationContainer = try makeInMemoryContainer()
        let destinationContext = destinationContainer.mainContext
        let sourceContainer = try makeInMemoryContainer()
        let sourceContext = sourceContainer.mainContext
        let noteID = UUID(uuidString: "21600000-0000-0000-0000-0000000000A1")!

        let sourceNote = Note(title: "", content: "")
        sourceNote.id = noteID
        sourceContext.insert(sourceNote)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: sourceNote,
            in: sourceContext
        )
        try sourceContext.save()

        let sourceRecord = try XCTUnwrap(
            try sourceContext.fetch(FetchDescriptor<NoteSequenceStateRecord>())
                .first(where: { $0.noteID == noteID })
        )
        let initialState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: sourceRecord,
            noteID: noteID
        )
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: sourceContext)
        XCTAssertEqual(snapshot.notes.map(\.id), [noteID])

        let originDeviceID = UUID(uuidString: "21600000-0000-0000-0000-0000000000A2")!
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 216),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(deviceID: originDeviceID, localCounter: 1),
            state: initialState
        )
        let historicalBatch = SyncBatch(
            id: UUID(uuidString: "21600000-0000-0000-0000-0000000000A3")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 216),
            batchSequence: 1,
            changes: [change]
        )

        var acknowledgementAttempts = 0
        var acknowledgementBodies: [String] = []
        var successfulAcknowledgement: SyncPeerBootstrapAcknowledgement?
        let controller = try makeController(
            context: destinationContext,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                guard message.kind == .bootstrapAcknowledgement else { return }
                acknowledgementAttempts += 1

                let notes = try destinationContext.fetch(FetchDescriptor<Note>())
                let records = try destinationContext.fetch(
                    FetchDescriptor<NoteSequenceStateRecord>()
                )
                if let note = notes.first(where: { $0.id == noteID }),
                   let record = records.first(where: { $0.noteID == noteID }) {
                    let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                        record: record,
                        noteID: noteID
                    )
                    XCTAssertTrue(NoteSequenceStateExactText.matches(note.content, ""))
                    XCTAssertTrue(NoteSequenceStateExactText.matches(state.visibleText, ""))
                    acknowledgementBodies.append(note.content)
                }

                let acknowledgement = try JSONDecoder().decode(
                    SyncPeerBootstrapAcknowledgement.self,
                    from: message.payload
                )
                if acknowledgementAttempts == 1 {
                    throw MacBootstrapSendTestError.injected
                }
                successfulAcknowledgement = acknowledgement
            }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: destinationContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: temporaryQueueFileURL(
                named: "ordering-pending-incoming.json"
            ),
            localObligationQueueFileURL: temporaryQueueFileURL(
                named: "ordering-local-obligations.json"
            )
        )
        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(historicalBatch))
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)

        await controller.receiveBootstrapSnapshotForTesting(snapshot, from: peer)

        XCTAssertEqual(acknowledgementAttempts, 1)
        XCTAssertEqual(acknowledgementBodies, [""])
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)
        let persistedBaseline = try XCTUnwrap(
            try destinationContext.fetch(FetchDescriptor<Note>())
                .first(where: { $0.id == noteID })
        )
        XCTAssertTrue(NoteSequenceStateExactText.matches(persistedBaseline.content, ""))

        await controller.receiveBootstrapSnapshotForTesting(snapshot, from: peer)

        XCTAssertEqual(acknowledgementAttempts, 2)
        XCTAssertEqual(acknowledgementBodies, ["", ""])
        XCTAssertEqual(successfulAcknowledgement?.snapshotID, snapshot.id)
        let finalNote = try XCTUnwrap(
            try destinationContext.fetch(FetchDescriptor<Note>())
                .first(where: { $0.id == noteID })
        )
        let finalRecord = try XCTUnwrap(
            try destinationContext.fetch(FetchDescriptor<NoteSequenceStateRecord>())
                .first(where: { $0.noteID == noteID })
        )
        let finalState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: finalRecord,
            noteID: noteID
        )
        XCTAssertTrue(NoteSequenceStateExactText.matches(finalNote.content, "A"))
        XCTAssertTrue(NoteSequenceStateExactText.matches(finalState.visibleText, "A"))
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 0)
        _ = coordinator
    }

    func testMYR178MacConsumerUsesSharedMatchingBaseDecisionSemantics() {
        let noteID = UUID(uuidString: "17800000-0000-0000-0000-000000000001")!
        let body = "Mac authoritative body"

        let matching: SyncBatchChange = .noteBodyTextInserted(.init(
            noteID: noteID,
            utf16Offset: 0,
            text: "x",
            modifiedAt: Date(timeIntervalSince1970: 1_780),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: body)
        ))

        let hashless: SyncBatchChange = .noteBodyTextDeleted(.init(
            noteID: noteID,
            utf16Offset: 0,
            utf16Length: 3,
            expectedText: "Mac",
            modifiedAt: Date(timeIntervalSince1970: 1_780)
        ))

        guard case .eligible =
            SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                change: matching,
                authoritativeBody: body
            )
        else {
            return XCTFail("Expected matching hash eligibility on native Mac")
        }

        XCTAssertEqual(
            SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                change: hashless,
                authoritativeBody: body
            ),
            .unavailableEvidence(noteID: noteID)
        )
    }

    func testMacControllerDoesNotStartNetworkingBeforeExplicitStart() throws {
        var advertisingCalls = 0
        var browsingCalls = 0

        _ = MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            startAdvertisingOperation: { advertisingCalls += 1 },
            startBrowsingOperation: { browsingCalls += 1 }
        )

        XCTAssertEqual(advertisingCalls, 0)
        XCTAssertEqual(browsingCalls, 0)
    }

    func testMacControllerBootstrapsWithBoundedMultibytePeerIdentityBeforeNetworking() throws {
        var advertisingCalls = 0
        var browsingCalls = 0
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000210")!
        let identity = MacSyncDeviceIdentity(
            id: id,
            displayName: String(repeating: "é", count: 100)
        )

        _ = MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            identityProvider: { identity },
            startAdvertisingOperation: { advertisingCalls += 1 },
            startBrowsingOperation: { browsingCalls += 1 }
        )

        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
        XCTAssertEqual(advertisingCalls, 0)
        XCTAssertEqual(browsingCalls, 0)
    }

    func testMacControllerAdvertisingAndBrowsingEachStartExactlyOnce() throws {
        var advertisingCalls = 0
        var browsingCalls = 0
        let controller = MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            startAdvertisingOperation: { advertisingCalls += 1 },
            startBrowsingOperation: { browsingCalls += 1 }
        )

        controller.startNetworkingIfNeeded()
        controller.startNetworkingIfNeeded()

        XCTAssertEqual(advertisingCalls, 1)
        XCTAssertEqual(browsingCalls, 1)
    }

    func testDisconnectedTransportAcceptsByDurablyEnqueuingUnsentBatch() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let controller = try makeController(unsentBatchQueueFileURL: unsentURL)
        let batch = makeBatch(idSuffix: 1)

        try await controller.acceptLocalBatch(batch)

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).pendingBatches, [batch])
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testConnectedTransportSendsAndRetainsLegacyBatchUntilAcknowledgement() async throws {
        let remotePeerID = MCPeerID(displayName: "remote|legacy-outbound")
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        var recordedSends: [(data: Data, peers: [MCPeerID], mode: MCSessionSendDataMode)] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: unsentURL,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [remotePeerID] },
            sendBatchDataOperation: { data, peers, mode in
                recordedSends.append((data, peers, mode))
            }
        )
        controller.recordBootstrapCapabilityForTesting(
            nil,
            forPeerDeviceID: "legacy-outbound"
        )
        let batch = makeLegacyBodyBatch(idSuffix: 2)

        XCTAssertTrue(controller.hasConnectedPeers)
        try await controller.acceptLocalBatch(batch)

        let recordedSend = try XCTUnwrap(recordedSends.first)
        XCTAssertEqual(recordedSends.count, 1)
        XCTAssertEqual(recordedSend.peers, [remotePeerID])
        XCTAssertEqual(recordedSend.mode, .reliable)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: recordedSend.data)
        XCTAssertEqual(message.kind, .batchSync)
        XCTAssertEqual(
            try MultipeerSyncMessageCoding.decodeBatchPayload(message.payload).batch,
            batch
        )
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: unsentURL).pendingBatches,
            [batch]
        )
        XCTAssertEqual(controller.lastSyncAt, batch.createdAt)
    }

    func testMYR221BatchAcceptedDuringActiveDrainRetainsAcknowledgementOwnership() async throws {
        let senderPeerID = MCPeerID(displayName: "remote|compatible-redelivery-sender")
        let receiverPeerID = MCPeerID(displayName: "remote|compatible-redelivery-receiver")
        let senderUnsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let receiverPendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        var senderSends: [Data] = []
        var receiverSends: [Data] = []

        let sender = MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: senderUnsentURL,
            startsNetworking: false,
            connectedPeersProvider: { [receiverPeerID] },
            sendBatchDataOperation: { data, _, _ in senderSends.append(data) }
        )
        sender.recordBootstrapCapabilityForTesting(
            nil,
            forPeerDeviceID: "compatible-redelivery-receiver"
        )
        let receiverContainer = try makeInMemoryContainer()
        let receiverContext = receiverContainer.mainContext
        let receiver = MacSyncBatchController(
            context: receiverContext,
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            connectedPeersProvider: { [senderPeerID] },
            sendBatchDataOperation: { data, _, _ in receiverSends.append(data) }
        )
        let noteA = Note(title: "Drain holder", content: "A0")
        noteA.id = UUID(uuidString: "17800000-0000-0000-0000-000000000241")!
        let noteB = Note(title: "FIFO target", content: "B0")
        noteB.id = UUID(uuidString: "17800000-0000-0000-0000-000000000242")!
        let noteC = Note(title: "Unrelated deferred target", content: "C0")
        noteC.id = UUID(uuidString: "17800000-0000-0000-0000-000000000243")!
        receiverContext.insert(noteA)
        receiverContext.insert(noteB)
        receiverContext.insert(noteC)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: noteA, in: receiverContext)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: noteB, in: receiverContext)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: noteC, in: receiverContext)
        try receiverContext.save()

        let boundaryReached = expectation(description: "Batch A holds the active drain")
        var boundaryContinuation: CheckedContinuation<MacIncomingBoundaryResult, Never>?
        var didSuspendBatchA = false
        let coordinator = MacSyncConvergenceCoordinator(
            context: receiverContext,
            syncController: receiver,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { noteIDs in
                    if noteIDs.contains(noteA.id), !didSuspendBatchA {
                        didSuspendBatchA = true
                        return await withCheckedContinuation { continuation in
                            boundaryContinuation = continuation
                            boundaryReached.fulfill()
                        }
                    }
                    return .ready
                }
            ),
            pendingIncomingQueueFileURL: receiverPendingURL,
            localObligationQueueFileURL: nil
        )
        let batchA = makeCompatibleBodyBatch(
            idSuffix: 241,
            noteID: noteA.id,
            base: "A0",
            inserted: "-hold"
        )
        let batchB = makeCompatibleBodyBatch(
            idSuffix: 242,
            noteID: noteB.id,
            base: "B0",
            inserted: "-once"
        )
        let unrelatedDeferredBatch = SyncBatch(
            id: UUID(uuidString: "17800000-0000-0000-0000-000000000243")!,
            originDeviceID: UUID(uuidString: "17800000-0000-0000-0000-000000000244")!,
            createdAt: Date(timeIntervalSince1970: 243),
            changes: [.noteBodyTextInserted(.init(
                noteID: noteC.id,
                utf16Offset: noteC.content.utf16.count,
                text: "-deferred",
                modifiedAt: Date(timeIntervalSince1970: 243)
            ))]
        )
        let receiverSession = MCSession(
            peer: MCPeerID(displayName: "local|compatible-redelivery-receiver"),
            securityIdentity: nil,
            encryptionPreference: .required
        )
        let senderSession = MCSession(
            peer: MCPeerID(displayName: "local|compatible-redelivery-sender"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(batchA))
        let activeDrain = Task { await coordinator.submitRemoteBatch(batchA) }
        await fulfillment(of: [boundaryReached], timeout: 1)

        try await sender.acceptLocalBatch(batchB)
        await waitUntil { senderSends.count == 1 }
        receiver.session(receiverSession, didReceive: senderSends[0], fromPeer: senderPeerID)
        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(unrelatedDeferredBatch))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(FileBackedSyncBatchQueue(fileURL: receiverPendingURL).contains(batchB.id))
        XCTAssertTrue(
            receiverSends.allSatisfy { data in
                guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                      message.kind == .batchAcknowledgement,
                      let acknowledgement = try? JSONDecoder().decode(
                        SyncBatchAcknowledgement.self,
                        from: message.payload
                      ) else {
                    return true
                }
                return acknowledgement.batchID != batchB.id
            }
        )
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: senderUnsentURL).pendingBatches, [batchB])
        XCTAssertEqual(noteB.content, "B0")

        boundaryContinuation?.resume(returning: .ready)
        await waitUntil {
            noteB.content == "B0-once" &&
            receiverSends.contains { data in
                guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                      message.kind == .batchAcknowledgement,
                      let acknowledgement = try? JSONDecoder().decode(
                        SyncBatchAcknowledgement.self,
                        from: message.payload
                      ) else {
                    return false
                }
                return acknowledgement.batchID == batchB.id
            }
        }

        let sentBatches = try senderSends.map { data in
            let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
            return try MultipeerSyncMessageCoding.decodeBatchPayload(message.payload).batch
        }
        XCTAssertEqual(sentBatches, [batchB])

        let acknowledgementData = try XCTUnwrap(
            receiverSends.first { data in
                guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                      message.kind == .batchAcknowledgement,
                      let acknowledgement = try? JSONDecoder().decode(
                        SyncBatchAcknowledgement.self,
                        from: message.payload
                      ) else {
                    return false
                }
                return acknowledgement.batchID == batchB.id
            }
        )
        sender.session(senderSession, didReceive: acknowledgementData, fromPeer: receiverPeerID)
        await waitUntil { FileBackedSyncBatchQueue(fileURL: senderUnsentURL).pendingBatches.isEmpty }

        let batchBAcknowledgementCount = receiverSends.reduce(into: 0) { count, data in
            guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                  message.kind == .batchAcknowledgement,
                  let acknowledgement = try? JSONDecoder().decode(
                    SyncBatchAcknowledgement.self,
                    from: message.payload
                  ), acknowledgement.batchID == batchB.id else {
                return
            }
            count += 1
        }
        XCTAssertEqual(batchBAcknowledgementCount, 1)
        XCTAssertEqual(noteB.content, "B0-once")
        let activeDrainDisposition = await activeDrain.value
        XCTAssertEqual(activeDrainDisposition, .acknowledgementPermitted)
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: receiverPendingURL).pendingBatches,
            [unrelatedDeferredBatch]
        )
        XCTAssertNil(receiver.lastSyncAt)
        _ = coordinator
    }

    func testSessionLevelLegacyBatchAcknowledgesOnlyAfterDurableCapture() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let remotePeerID = MCPeerID(displayName: "remote|legacy-inbound")
        var recordedSends: [Data] = []
        var pendingSnapshotAtSend: FileBackedSyncBatchQueueSnapshot?
        let acknowledgementSent = expectation(description: "Legacy batch acknowledgement sent")
        let boundaryReached = expectation(description: "Durable capture precedes incorporation")
        var boundaryContinuation: CheckedContinuation<MacIncomingBoundaryResult, Never>?
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: { [remotePeerID] },
            sendBatchDataOperation: { data, _, _ in
                recordedSends.append(data)
                pendingSnapshotAtSend = FileBackedSyncBatchQueue(
                    fileURL: pendingURL
                ).snapshot()
                acknowledgementSent.fulfill()
            }
        )
        let container = try makeInMemoryContainer()
        let note = Note(title: "Legacy", content: "")
        note.id = UUID(uuidString: "17100000-0000-0000-0000-0000000000BA")!
        container.mainContext.insert(note)
        try container.mainContext.save()
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in
                    await withCheckedContinuation { continuation in
                        boundaryContinuation = continuation
                        boundaryReached.fulfill()
                    }
                }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let batch = makeLegacyBodyBatch(idSuffix: 3)
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "local|legacy-inbound"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: remotePeerID)
        await fulfillment(of: [boundaryReached], timeout: 1)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches, [batch])
        XCTAssertTrue(recordedSends.isEmpty)

        boundaryContinuation?.resume(returning: .ready)
        await fulfillment(of: [acknowledgementSent], timeout: 1)

        let recordedData = try XCTUnwrap(recordedSends.first)
        XCTAssertEqual(recordedSends.count, 1)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: recordedData)
        XCTAssertEqual(message.kind, .batchAcknowledgement)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SyncBatchAcknowledgement.self,
                from: message.payload
            ).batchID,
            batch.id
        )
        XCTAssertEqual(pendingSnapshotAtSend?.pendingBatches, [])
        XCTAssertEqual(note.content, "A")
        _ = coordinator
    }

    func testSessionLevelHashlessBodyBatchRemainsDurableWithoutAcknowledgement() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let remotePeerID = MCPeerID(displayName: "remote|hashless-inbound")
        var recordedSends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: nil,
            sendBatchDataOperation: { data, _, _ in recordedSends.append(data) }
        )
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "17800000-0000-0000-0000-0000000000A1")!
        let note = Note(title: "Local", content: "local")
        note.id = noteID
        container.mainContext.insert(note)
        try container.mainContext.save()
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let batch = SyncBatch(
            id: UUID(uuidString: "17800000-0000-0000-0000-0000000000A2")!,
            originDeviceID: UUID(uuidString: "17800000-0000-0000-0000-0000000000A3")!,
            createdAt: Date(timeIntervalSince1970: 1780),
            changes: [.noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 5,
                text: "!",
                modifiedAt: Date(timeIntervalSince1970: 1781)
            ))]
        )
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "local|hashless-inbound"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: remotePeerID)
        try await Task.sleep(for: .milliseconds(100))
        controller.session(dummySession, didReceive: data, fromPeer: remotePeerID)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(recordedSends.isEmpty)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches, [batch])
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)
        XCTAssertEqual(note.content, "local")
        XCTAssertNil(controller.lastSyncAt)
    }

    func testConnectedAnchoredLocalBatchIsDurablyQueuedWithoutCompatiblePeer() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let remotePeerID = MCPeerID(displayName: "remote|anchored-outbound")
        let queue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        var recordedSends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: queue,
            connectedPeersProvider: { [remotePeerID] },
            sendBatchDataOperation: { data, _, _ in recordedSends.append(data) }
        )
        let batch = try makeAnchoredBatch()
        XCTAssertTrue(controller.hasConnectedPeers)

        try await controller.acceptLocalBatch(batch)

        XCTAssertTrue(recordedSends.isEmpty)
        XCTAssertEqual(queue.pendingBatches, [batch])
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertNotNil(try dataIfPresent(at: unsentURL))
        XCTAssertNil(controller.lastSyncAt)
        XCTAssertTrue(controller.hasConnectedPeers)
    }

    func testDirectReceiveRejectsAnchoredBatchBeforeCoordinatorSubmission() async throws {
        let controller = try makeController(unsentBatchQueueFileURL: nil)
        let batch = try makeAnchoredBatch()

        controller.receive(batch)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
        XCTAssertNil(controller.lastSyncAt)
    }

    func testSessionLevelAnchoredBatchRejectsBeforeCaptureAcknowledgementOrStatus() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let remotePeerID = MCPeerID(displayName: "remote|anchored-inbound")
        var recordedSends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: nil,
            sendBatchDataOperation: { data, _, _ in recordedSends.append(data) }
        )
        let container = try makeInMemoryContainer()
        var boundaryCalls = 0
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in
                    boundaryCalls += 1
                    return .ready
                }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let batch = try makeAnchoredBatch()
        let beforeSnapshot = FileBackedSyncBatchQueue(fileURL: pendingURL).snapshot()
        let beforeBytes = try dataIfPresent(at: pendingURL)
        let beforePendingCount = coordinator.pendingIncomingBatchCount
        let lastSyncAtBefore = controller.lastSyncAt
        let lastConnectionEventBefore = controller.lastConnectionEvent
        let data = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: SyncBatchEnvelopeCodec.encode(batch: batch)
        )
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "local|anchored-inbound"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: remotePeerID)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(recordedSends.isEmpty)
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, beforePendingCount)
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: pendingURL).snapshot(),
            beforeSnapshot
        )
        XCTAssertEqual(try dataIfPresent(at: pendingURL), beforeBytes)
        XCTAssertEqual(controller.lastSyncAt, lastSyncAtBefore)
        XCTAssertEqual(controller.lastConnectionEvent, lastConnectionEventBefore)
        XCTAssertEqual(boundaryCalls, 0)
    }

    func testOuterSchemaZeroRejectsBatchBeforeControllerSideEffects() async throws {
        try await assertInvalidOuterBatchSchemaRejected(
            schemaVersion: 0,
            peerDeviceID: "outer-schema-zero",
            batchIDSuffix: 4
        )
    }

    func testOuterSchemaNegativeOneRejectsBatchBeforeControllerSideEffects() async throws {
        try await assertInvalidOuterBatchSchemaRejected(
            schemaVersion: -1,
            peerDeviceID: "outer-schema-negative-one",
            batchIDSuffix: 5
        )
    }

    func testFailedDurableUnsentEnqueueThrowsAndLeavesQueueUnchanged() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let queue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        let existing = makeBatch(idSuffix: 1)
        try queue.enqueueDurably(existing)
        let before = queue.snapshot()
        let beforeBytes = try Data(contentsOf: unsentURL)
        let failingQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        failingQueue.injectPersistenceFailureForNextWrite()
        let controller = try makeController(unsentBatchQueue: failingQueue)
        let batch = makeBatch(idSuffix: 2)

        var thrownError: Error?
        do {
            try await controller.acceptLocalBatch(batch)
        } catch {
            thrownError = error
        }
        XCTAssertNotNil(thrownError)
        XCTAssertEqual(failingQueue.snapshot().pendingBatches, before.pendingBatches)
        XCTAssertEqual(try Data(contentsOf: unsentURL), beforeBytes)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).snapshot(), before)
    }

    func testReceiveDoesNotIndependentlyEnqueueRemoteBatchBeforeRuntimeSubmission() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let controller = try makeController(unsentBatchQueueFileURL: nil)
        let container = try makeInMemoryContainer()
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in .ready }),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let emptyBatch = makeBatch(idSuffix: 1)

        controller.receive(emptyBatch)
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = coordinator

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches, [])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
    }

    func testQuarantinedConvergenceStatusPreservesWorkReason() throws {
        let controller = try makeController(unsentBatchQueueFileURL: nil)
        let item = SyncConvergenceQuarantinedItem(
            domain: .localObligation,
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            affectedNoteIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000202")!],
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            reason: .localEvidenceBaseHashMismatch
        )
        let work = SyncConvergenceQuarantinedWork(items: [item])

        controller.markConvergenceQuarantined(work)

        XCTAssertEqual(controller.quarantinedWork, work)
        XCTAssertNotEqual(
            controller.lastErrorMessage,
            SyncBatchDrainFailureClassifier.userMessage(
                for: SyncBatchDrainFailure(batchID: item.batchID, kind: .corruptHistory)
            )
        )
    }

    func testProductionMacSyncFilesDoNotConstructOldDrainEngine() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try ProtectedRepositoryAuditPolicy.skipIfNeeded(repositoryURL: repo)
        let checkedFiles = [
            "MyRAM/Mac/MyRAMMacRootView.swift",
            "MyRAM/Mac/MacNotePersistenceAdapter.swift",
            "MyRAM/Mac/Sync/MacSyncBatchController.swift",
            "MyRAM/Mac/Sync/MacSyncBatchAccumulator.swift",
            "MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift",
            "MyRAM/Mac/Sync/MacSyncConvergencePresentationAdapter.swift"
        ]
        let forbiddenTokens = [
            "MacSyncBatchApplier",
            "SyncBatchDrainCoordinator",
            "drainPendingIncomingBatchesIfPossible",
            "onBeforeApplyingRemoteBatch",
            "onBatchApplied",
            "handleAppliedSyncBatch",
            "MacAppliedSyncBatch",
            "submitLocalBatch(",
            "bodyTextChanged(",
            "record(_ change: SyncBatchChange",
            "func record(_ change",
            "import UIKit"
        ]

        for relativePath in checkedFiles {
            let source = try String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) contains forbidden token \(token)")
            }
        }

        let coordinatorSource = try String(
            contentsOf: repo.appendingPathComponent("MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(coordinatorSource.contains("kind: .corruptHistory"))
    }

    func testSyncTargetMembershipIncludesSharedCaptureAndMacPresentationTests() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try ProtectedRepositoryAuditPolicy.skipIfNeeded(repositoryURL: repo)
        let project = try String(
            contentsOf: repo.appendingPathComponent("MyRAM.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertGreaterThanOrEqual(project.countOccurrences(of: "SyncBatchNoteChangeCapture.swift in Sources"), 2)
        XCTAssertGreaterThanOrEqual(project.countOccurrences(of: "SyncBatchAnchoredPayloadAdapter.swift in Sources"), 2)
        XCTAssertGreaterThanOrEqual(project.countOccurrences(of: "SyncBatchAnchoredPayloadPolicy.swift in Sources"), 2)
        XCTAssertEqual(project.countOccurrences(of: "SyncBatchAnchoredPayloadTests.swift in Sources"), 2)
        XCTAssertEqual(project.countOccurrences(of: "SyncBatchAnchoredInsertReplay.swift in Sources"), 4)
        XCTAssertEqual(project.countOccurrences(of: "SyncBatchAnchoredInsertReplayTests.swift in Sources"), 4)
        XCTAssertTrue(project.contains("MacSyncConvergencePresentationAdapter.swift in Sources"))
        XCTAssertTrue(project.contains("MacSyncConvergencePresentationAdapterTests.swift in Sources"))
        XCTAssertTrue(project.contains("MacSyncConvergenceCoordinatorTests.swift in Sources"))
        XCTAssertTrue(project.contains("MacSyncIncomingLocalBoundaryTests.swift in Sources"))
        XCTAssertTrue(project.contains("MacNotePersistenceAdapterTests.swift in Sources"))

        let iosAppSources = try XCTUnwrap(project.section(startingWith: "\t\tBC9F1BA82EA47D2E0045FD72 /* Sources */ = {"))
        let iosTestSources = try XCTUnwrap(project.section(startingWith: "\t\tBC9F1BBA2EA47D310045FD72 /* Sources */ = {"))
        let macAppSources = try XCTUnwrap(project.section(startingWith: "\t\tBCA105040000000000000001 /* Sources */ = {"))
        let macTestSources = try XCTUnwrap(project.section(startingWith: "\t\tBCA107040000000000000001 /* Sources */ = {"))
        XCTAssertTrue(iosAppSources.contains("SyncBatchAnchoredInsertReplay.swift in Sources"))
        XCTAssertTrue(macAppSources.contains("SyncBatchAnchoredInsertReplay.swift in Sources"))
        XCTAssertTrue(iosTestSources.contains("SyncBatchAnchoredInsertReplayTests.swift in Sources"))
        XCTAssertTrue(macTestSources.contains("SyncBatchAnchoredInsertReplayTests.swift in Sources"))
        XCTAssertTrue(iosTestSources.contains("SyncBatchAnchoredPayloadTests.swift in Sources"))
        XCTAssertFalse(macTestSources.contains("SyncBatchAnchoredPayloadTests.swift in Sources"))
        XCTAssertFalse(macAppSources.contains("MacSyncBatchApplier.swift in Sources"))
        XCTAssertFalse(macTestSources.contains("MacSyncBatchApplierTests.swift in Sources"))
    }

    func testMyRAMMacSchemeScopesHostedTestModeToTestAction() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try ProtectedRepositoryAuditPolicy.skipIfNeeded(repositoryURL: repo)
        let scheme = try String(
            contentsOf: repo.appendingPathComponent(
                "MyRAM.xcodeproj/xcshareddata/xcschemes/MyRAMMac.xcscheme"
            ),
            encoding: .utf8
        )
        let testAction = try XCTUnwrap(scheme.xmlSection(named: "TestAction"))
        let launchAction = try XCTUnwrap(scheme.xmlSection(named: "LaunchAction"))

        XCTAssertTrue(testAction.contains("MYRAM_HOSTED_TEST_MODE"))
        XCTAssertTrue(testAction.contains("value = \"1\""))
        XCTAssertFalse(launchAction.contains("MYRAM_HOSTED_TEST_MODE"))
    }

    func testProtectedRepositoryAuditPolicyClassifiesProtectedCheckoutBeforeRead() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let repository = home.appendingPathComponent("Documents/ChatGPT/MyRAM", isDirectory: true)

        XCTAssertEqual(
            ProtectedRepositoryAuditPolicy.protectedDirectory(
                containing: repository,
                homeDirectoryURL: home
            ),
            "Documents"
        )
    }

    func testProtectedRepositoryAuditPolicyAllowsCIStyleCheckout() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let repository = URL(fileURLWithPath: "/private/tmp/ci/MyRAM", isDirectory: true)

        XCTAssertNil(
            ProtectedRepositoryAuditPolicy.protectedDirectory(
                containing: repository,
                homeDirectoryURL: home
            )
        )
    }

    private func assertInvalidOuterBatchSchemaRejected(
        schemaVersion: Int,
        peerDeviceID: String,
        batchIDSuffix: Int
    ) async throws {
        let pendingURL = temporaryQueueFileURL(
            named: "mac-pending-invalid-outer-schema.json"
        )
        let remotePeerID = MCPeerID(
            displayName: "remote|\(peerDeviceID)"
        )
        var recordedSends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: nil,
            connectedPeersProvider: nil,
            sendBatchDataOperation: { data, _, _ in
                recordedSends.append(data)
            }
        )
        let container = try makeInMemoryContainer()
        var boundaryCalls = 0
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in
                    boundaryCalls += 1
                    return .ready
                }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let batch = makeLegacyBodyBatch(idSuffix: batchIDSuffix)
        let beforeSnapshot = FileBackedSyncBatchQueue(
            fileURL: pendingURL
        ).snapshot()
        let beforeBytes = try dataIfPresent(at: pendingURL)
        let beforePendingCount = coordinator.pendingIncomingBatchCount
        let beforeLastSyncAt = controller.lastSyncAt
        let beforeLastConnectionEvent = controller.lastConnectionEvent
        let beforeAvailablePeers = controller.availablePeers
        let innerPayload = try SyncBatchEnvelopeCodec.encode(batch: batch)
        let outerEnvelope = MultipeerSyncMessageEnvelope(
            kind: .batchSync,
            schemaVersion: schemaVersion,
            payload: innerPayload
        )
        let data = try JSONEncoder().encode(outerEnvelope)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "local|outer-schema"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(
            dummySession,
            didReceive: data,
            fromPeer: remotePeerID
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(recordedSends.isEmpty)
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: pendingURL).snapshot(),
            beforeSnapshot
        )
        XCTAssertEqual(try dataIfPresent(at: pendingURL), beforeBytes)
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, beforePendingCount)
        XCTAssertEqual(boundaryCalls, 0)
        XCTAssertEqual(controller.lastSyncAt, beforeLastSyncAt)
        XCTAssertEqual(controller.lastConnectionEvent, beforeLastConnectionEvent)
        XCTAssertEqual(controller.availablePeers, beforeAvailablePeers)
    }

    private func makeMYR233BootstrapFixture(
        unsentBatches: [SyncBatch],
        localBatches: [SyncBatch],
        peerDeviceID: String
    ) throws -> MYR233MacBootstrapFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unsentURL = directory.appendingPathComponent("unsent-batches.json")
        let localURL = directory.appendingPathComponent("local-obligations.json")

        let unsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        for batch in unsentBatches {
            try unsentQueue.enqueueDurably(batch)
        }
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localURL)
        for batch in localBatches {
            try localQueue.enqueue(SyncConvergenceLocalObligation(legacyBatch: batch))
        }

        let peer = MCPeerID(displayName: "remote|\(peerDeviceID)")
        let sentMessages = MYR233MacSentMessageRecorder()
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let controller = try makeController(
            context: container.mainContext,
            unsentBatchQueueFileURL: unsentURL,
            unsentBatchQueue: unsentQueue,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                sentMessages.values.append(data)
            }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localURL
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: peerDeviceID)
        return MYR233MacBootstrapFixture(
            directory: directory,
            controller: controller,
            coordinator: coordinator,
            unsentQueue: unsentQueue,
            peer: peer,
            sentMessages: sentMessages
        )
    }

    private func batchWithSameID(
        _ batch: SyncBatch,
        createdAtOffset: TimeInterval
    ) -> SyncBatch {
        SyncBatch(
            id: batch.id,
            originDeviceID: batch.originDeviceID,
            createdAt: batch.createdAt.addingTimeInterval(createdAtOffset),
            batchSequence: batch.batchSequence,
            changes: batch.changes
        )
    }

    private func makeController(unsentBatchQueueFileURL: URL?) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: unsentBatchQueueFileURL, unsentBatchQueue: nil)
    }

    private func makeController(unsentBatchQueue: FileBackedSyncBatchQueue) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: nil, unsentBatchQueue: unsentBatchQueue)
    }

    private func makeController(
        context: ModelContext? = nil,
        unsentBatchQueueFileURL: URL?,
        unsentBatchQueue: FileBackedSyncBatchQueue?,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil,
        invitePeerOperation:
            ((MCPeerID, Data, TimeInterval) -> Void)? = nil
    ) throws -> MacSyncBatchController {
        let resolvedContext: ModelContext
        if let context {
            resolvedContext = context
        } else {
            let container = try makeInMemoryContainer()
            retainedContainers.append(container)
            resolvedContext = container.mainContext
        }
        return MacSyncBatchController(
            context: resolvedContext,
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            unsentBatchQueue: unsentBatchQueue,
            startsNetworking: false,
            connectedPeersProvider: connectedPeersProvider,
            sendBatchDataOperation: sendBatchDataOperation,
            invitePeerOperation: invitePeerOperation
        )
    }

    private func makeBatch(idSuffix: Int) -> MacSyncBatch {
        MacSyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func makeLegacyBodyBatch(idSuffix: Int) -> MacSyncBatch {
        let batch = makeBatch(idSuffix: idSuffix)
        let noteID = UUID(uuidString: "17100000-0000-0000-0000-0000000000BA")!
        return SyncBatch(
            id: batch.id,
            originDeviceID: batch.originDeviceID,
            createdAt: batch.createdAt,
            batchSequence: batch.batchSequence,
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: noteID,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: batch.createdAt,
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                ))
            ]
        )
    }

    private func makeCompatibleBodyBatch(
        idSuffix: Int,
        noteID: UUID,
        base: String,
        inserted: String
    ) -> SyncBatch {
        let batch = makeBatch(idSuffix: idSuffix)
        return SyncBatch(
            id: batch.id,
            originDeviceID: batch.originDeviceID,
            createdAt: batch.createdAt,
            batchSequence: batch.batchSequence,
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: noteID,
                    utf16Offset: base.utf16.count,
                    text: inserted,
                    modifiedAt: batch.createdAt,
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: base)
                ))
            ]
        )
    }

    private func makeAnchoredBatch(localCounter: UInt64 = 1) throws -> SyncBatch {
        let deviceID = UUID(uuidString: "17100000-0000-0000-0000-0000000000BB")!
        let state = try SyncTextSequenceState(runs: [], fragments: [])
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: UUID(uuidString: "17100000-0000-0000-0000-0000000000BC")!,
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_710),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(deviceID: deviceID, localCounter: localCounter),
            state: state
        )
        return SyncBatch(
            id: UUID(uuidString: "17100000-0000-0000-0000-0000000000BD")!,
            originDeviceID: deviceID,
            createdAt: Date(timeIntervalSince1970: 1_710),
            batchSequence: 1,
            changes: [change]
        )
    }

    private func makeAnchoredCapturedChange(
        localCounter: UInt64
    ) throws -> SyncConvergenceCapturedLocalChange {
        let initialState = try SyncTextSequenceState(runs: [], fragments: [])
        let change = try XCTUnwrap(makeAnchoredBatch(localCounter: localCounter).changes.first)
        guard case .noteBodyTextInsertedAnchored(let inserted) = change else {
            throw MacBootstrapSendTestError.injected
        }
        let finalState = try SyncBatchAnchoredInsertReplay.applying(
            inserted,
            to: initialState
        ).sequenceState
        return try SyncConvergenceLocalEvidenceCapture.capturedAnchoredChange(
            for: change,
            structuralPreState: initialState,
            structuralPostState: finalState
        )
    }

    private func temporaryQueueFileURL(named filename: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return directory.appendingPathComponent(filename)
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
    }

    private func completingPresentationSurface() -> MacSyncConvergencePresentationSurface {
        MacSyncConvergencePresentationSurface(
            selectedNoteID: { nil },
            hasUnsavedChanges: { false },
            refreshNotesList: {},
            closeRemovedSelectedEditor: { _ in },
            applyIncremental: { _, _, _ in
                EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
            },
            reloadSelectedEditor: { _ in true },
            currentEditorBody: { nil }
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "MacSyncBatchControllerTests-\(UUID().uuidString)",
            schema: Schema(MyRAMModelRegistry.models),
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: configuration
        )
    }
}

private final class MYR233MacSentMessageRecorder {
    var values: [Data] = []
}

private struct MYR233MacBootstrapFixture {
    let directory: URL
    let controller: MacSyncBatchController
    let coordinator: MacSyncConvergenceCoordinator
    let unsentQueue: FileBackedSyncBatchQueue
    let peer: MCPeerID
    let sentMessages: MYR233MacSentMessageRecorder

    func firstBootstrapSnapshot() throws -> SyncPeerBootstrapSnapshot {
        let data = try XCTUnwrap(sentMessages.values.first)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        XCTAssertEqual(message.kind, .bootstrapSnapshot)
        return try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
    }
}

private enum MacBootstrapSendTestError: Error {
    case injected
}

private enum ProtectedRepositoryAuditPolicy {
    static func protectedDirectory(
        containing repositoryURL: URL,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let repositoryPath = repositoryURL.standardizedFileURL.path
        for directory in ["Documents", "Desktop", "Downloads"] {
            let protectedPath = homeDirectoryURL
                .appendingPathComponent(directory, isDirectory: true)
                .standardizedFileURL.path
            if repositoryPath == protectedPath || repositoryPath.hasPrefix(protectedPath + "/") {
                return directory
            }
        }
        return nil
    }

    static func skipIfNeeded(repositoryURL: URL) throws {
        guard let directory = protectedDirectory(containing: repositoryURL) else { return }
        throw XCTSkip(
            "Repository static audit intentionally deferred to CI/static completion verification because the checkout is under the macOS-protected \(directory) folder"
        )
    }
}

private extension String {
    func countOccurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }

    func section(startingWith marker: String) -> String? {
        guard let startRange = range(of: marker),
              let endRange = range(of: "\n\t\t};", range: startRange.upperBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.upperBound])
    }

    func xmlSection(named element: String) -> String? {
        guard let startRange = range(of: "<\(element)"),
              let endRange = range(of: "</\(element)>", range: startRange.upperBound..<endIndex) else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.upperBound])
    }
}
