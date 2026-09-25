import AnchoredSequenceCore
import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class SyncBatchPeerCapabilityTests: XCTestCase {
    private var retainedContainers: [ModelContainer] = []

    func testCanonicalEncoding() throws {
        XCTAssertEqual(SyncBatchPeerCapabilityCodec.encode(.v1Only), "1")
        XCTAssertEqual(SyncBatchPeerCapabilityCodec.encode(.v2Only), "2")
        XCTAssertEqual(SyncBatchPeerCapabilityCodec.encode(.v1AndV2), "1,2")
    }

    func testCanonicalDecoding() throws {
        XCTAssertEqual(try SyncBatchPeerCapabilityCodec.decode("1"), .v1Only)
        XCTAssertEqual(try SyncBatchPeerCapabilityCodec.decode("2"), .v2Only)
        XCTAssertEqual(try SyncBatchPeerCapabilityCodec.decode("1,2"), .v1AndV2)
    }

    func testDiscoveryAndInvitationRepresentationsAreIdentical() throws {
        let discoveryValue = try XCTUnwrap(
            SyncBatchPeerCapabilityCodec.productionDiscoveryInfo[
                SyncBatchPeerCapabilityCodec.discoveryInfoKey
            ]
        )
        XCTAssertEqual(
            Data(discoveryValue.utf8),
            SyncBatchPeerCapabilityCodec.productionInvitationContext
        )
    }

    func testStrictDecoderRejectsNoncanonicalValues() {
        for value in [
            "", ",1", "1,", "1,,2", "1,1", "3", "0", "-1",
            "+1", "01", "1,02", " 1", "1 ", "1, 2", "1,2 ",
            "one", "2,1"
        ] {
            XCTAssertThrowsError(
                try SyncBatchPeerCapabilityCodec.decode(value),
                "Expected strict capability rejection for \(value.debugDescription)"
            )
        }
    }

    func testMalformedUTF8InvitationContextIsRejected() {
        XCTAssertThrowsError(
            try SyncBatchPeerCapabilityCodec.decodeInvitationContext(Data([0xFF]))
        ) { error in
            XCTAssertEqual(
                error as? SyncBatchPeerCapabilityCodecError,
                .malformedUTF8
            )
        }
    }

    func testProductionCapabilityAdvertisesV1AndV2() {
        XCTAssertTrue(SyncBatchAnchoredPayloadCapability.isEnabled)
        XCTAssertEqual(SyncBatchPeerCapabilityCodec.productionCapability, .v1AndV2)
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2",
                SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey: "1"
            ]
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionInvitationContext,
            Data("1,2".utf8)
        )
    }

    func testRegistryRulesRequireSessionBindingAndRecomputeWhileConnected() {
        var registry = SyncBatchPeerCapabilityRegistry()
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1Only
        )

        registry.recordDiscoveryValue("1,2", forPeerDeviceID: "peer")
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1AndV2
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )

        registry.bindCurrentSessionV2Support(forPeerDeviceID: "peer")
        XCTAssertTrue(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )

        registry.recordInvitationContext(
            Data("1".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1Only
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )

        registry.recordInvitationContext(
            Data("1,2".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1AndV2
        )
        XCTAssertTrue(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )

        registry.clearCurrentSessionEvidence(forPeerDeviceID: "peer")
        XCTAssertFalse(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "peer"))
        XCTAssertEqual(registry.effectiveCapability(forPeerDeviceID: "peer"), .v1AndV2)

        registry.bindCurrentSessionV2Support(forPeerDeviceID: "peer")
        XCTAssertTrue(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "peer"))
    }

    func testMissingMalformedAndNonunionEvidenceRemainFailClosed() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue(nil, forPeerDeviceID: "missing")
        registry.recordInvitationContext(Data([0xFF]), forPeerDeviceID: "missing")
        registry.bindCurrentSessionV2Support(forPeerDeviceID: "missing")
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "missing"),
            .v1Only
        )
        XCTAssertFalse(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "missing"))

        registry.recordDiscoveryValue("1", forPeerDeviceID: "contradictory")
        registry.recordInvitationContext(
            Data("2".utf8),
            forPeerDeviceID: "contradictory"
        )
        registry.bindCurrentSessionV2Support(forPeerDeviceID: "contradictory")
        XCTAssertTrue(
            registry.effectiveCapability(
                forPeerDeviceID: "contradictory"
            ).schemas.isEmpty
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "contradictory"
            )
        )
    }

    func testDifferentStableDeviceCannotConsumeRetainedEvidenceOnMac() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue("1,2", forPeerDeviceID: "peer-a")
        registry.bindCurrentSessionV2Support(forPeerDeviceID: "peer-b")

        XCTAssertFalse(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "peer-b"))
        XCTAssertEqual(registry.effectiveCapability(forPeerDeviceID: "peer-b"), .v1Only)
        XCTAssertFalse(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "peer-a"))
    }

    func testBrowserLossPreservesRetainedAndBoundV2CapabilityOnMac() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue("1,2", forPeerDeviceID: "peer")
        registry.recordBootstrapDiscoveryValue("1", forPeerDeviceID: "peer")
        registry.bindCurrentSessionV2Support(forPeerDeviceID: "peer")

        registry.clearDiscoveryEvidence(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: "peer"))
        XCTAssertEqual(registry.effectiveCapability(forPeerDeviceID: "peer"), .v1AndV2)
        XCTAssertFalse(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
    }

    func testDecodedTrafficDoesNotUpgradeRegistry() throws {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.bindCurrentSessionV2Support(forPeerDeviceID: "peer")
        _ = try SyncBatchPeerCapabilityCodec.decode("1,2")
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testBootstrapAnnouncementRemainsSupportedAfterDiscoveryLossOrMissingMarker() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")
        registry.recordBootstrapDiscoveryValue(nil, forPeerDeviceID: "peer")
        registry.clearDiscoveryEvidence(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
        XCTAssertTrue(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
    }

    func testDiscoveryOnlyBootstrapSupportUsedByMacSessionSurvivesDiscoveryLossUntilDisconnect() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapDiscoveryValue("1", forPeerDeviceID: "peer")
        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))

        registry.clearDiscoveryEvidence(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
        XCTAssertTrue(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))

        registry.clearEvidence(forPeerDeviceID: "peer")
        XCTAssertFalse(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
        XCTAssertFalse(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
    }

    func testMacDiscoveryLossBeforeConnectionDoesNotCreateBootstrapSessionEvidence() async throws {
        let controller = try makeController(connectedPeersProvider: { [] })
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let remotePeerID = MCPeerID(displayName: "Remote|never-connected-mac")
        let browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: "myram-sync"
        )

        controller.browser(
            browser,
            foundPeer: remotePeerID,
            withDiscoveryInfo: [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2",
                SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey: "1"
            ]
        )
        await Task.yield()
        XCTAssertTrue(
            controller.isBootstrapCapabilityResolvedForTesting(
                peerDeviceID: "never-connected-mac"
            )
        )
        XCTAssertFalse(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "never-connected-mac"
            )
        )

        controller.browser(browser, lostPeer: remotePeerID)
        await Task.yield()

        XCTAssertFalse(
            controller.isBootstrapCapabilityResolvedForTesting(
                peerDeviceID: "never-connected-mac"
            )
        )
        XCTAssertFalse(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "never-connected-mac"
            )
        )
    }

    func testDiscoveryLossDuringActiveMacBootstrapKeepsSameSnapshotRetryAlive() async throws {
        let peer = MCPeerID(displayName: "Remote|lost-discovery-mac")
        var attemptedSnapshots: [SyncPeerBootstrapSnapshot] = []
        let controller = try makeController(
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                guard message.kind == .bootstrapSnapshot else { return }
                attemptedSnapshots.append(
                    try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
                )
            }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "lost-discovery-mac")
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            5_000_000,
            1_000_000_000,
            1_000_000_000
        ])
        controller.beginBootstrapForTesting(to: peer)
        let snapshotID = try XCTUnwrap(attemptedSnapshots.first?.id)
        let attemptsBeforeLoss = attemptedSnapshots.count
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: "myram-sync")

        controller.browser(browser, lostPeer: peer)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThan(attemptedSnapshots.count, attemptsBeforeLoss)
        XCTAssertEqual(Set(attemptedSnapshots.map(\.id)), Set([snapshotID]))
        XCTAssertFalse(
            controller.bootstrapStateForTesting(peerDeviceID: "lost-discovery-mac")?.ordinarySyncReady == true
        )
    }

    func testExistingMacBaselineContinuesManifestedHistoryAfterBootstrapAck() async throws {
        let peer = MCPeerID(displayName: "Remote|behind-mac")
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let noteID = UUID(uuidString: "21600000-0000-0000-0000-0000000000B1")!
        let note = Note(title: "Authoritative", content: "")
        note.id = noteID
        context.insert(note)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: context
        )
        try context.save()

        var kinds: [MultipeerSyncMessageKind] = []
        let controller = try makeController(
            context: context,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                kinds.append(try MultipeerSyncMessageCoding.decodeMessage(from: data).kind)
            }
        )
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "behind-mac")
        let historical = makeV1TitleBatch(idSuffix: 2172, noteID: noteID)

        try await controller.acceptLocalBatch(historical)
        controller.beginBootstrapForTesting(to: peer)
        let state = try XCTUnwrap(controller.bootstrapStateForTesting(peerDeviceID: "behind-mac"))
        XCTAssertEqual(kinds, [.bootstrapSnapshot])

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: state.snapshotID,
                coveredBatchIDs: [],
                coveredNoteIDs: []
            ),
            from: peer
        )

        XCTAssertFalse(
            controller.bootstrapStateForTesting(peerDeviceID: "behind-mac")?.ordinarySyncReady == true
        )
        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches, [historical])
        XCTAssertEqual(kinds, [.bootstrapSnapshot])

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: state.snapshotID,
                coveredBatchIDs: [],
                coveredNoteIDs: [noteID]
            ),
            from: peer
        )

        XCTAssertTrue(
            controller.bootstrapStateForTesting(peerDeviceID: "behind-mac")?.ordinarySyncReady == true
        )
        XCTAssertEqual(kinds, [.bootstrapSnapshot, .batchSync])
    }

    func testPartialBootstrapNoteCoverageReplaysBaselineSafeHistoryWithoutOpeningMacBarrier() async throws {
        let peer = MCPeerID(displayName: "Remote|partial-bootstrap-mac")
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let coveredNoteID = UUID(uuidString: "23300000-0000-0000-0000-0000000000C1")!
        let uncoveredNoteID = UUID(uuidString: "23300000-0000-0000-0000-0000000000C2")!
        let coveredNote = Note(title: "Covered", content: "")
        coveredNote.id = coveredNoteID
        let uncoveredNote = Note(title: "Uncovered", content: "")
        uncoveredNote.id = uncoveredNoteID
        context.insert(coveredNote)
        context.insert(uncoveredNote)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: coveredNote,
            in: context
        )
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: uncoveredNote,
            in: context
        )
        try context.save()

        var kinds: [MultipeerSyncMessageKind] = []
        var sentBatchIDs: [SyncBatchID] = []
        let controller = try makeController(
            context: context,
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                kinds.append(message.kind)
                if message.kind == .batchSync {
                    sentBatchIDs.append(try SyncBatchEnvelopeCodec.decode(message.payload).batch.id)
                }
            }
        )
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "partial-bootstrap-mac"
        )
        let blockedHistorical = makeV1TitleBatch(idSuffix: 2173, noteID: uncoveredNoteID)
        let safeHistorical = makeV1TitleBatch(idSuffix: 2174, noteID: coveredNoteID)

        try await controller.acceptLocalBatch(blockedHistorical)
        try await controller.acceptLocalBatch(safeHistorical)
        controller.beginBootstrapForTesting(to: peer)
        let state = try XCTUnwrap(
            controller.bootstrapStateForTesting(peerDeviceID: "partial-bootstrap-mac")
        )

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: state.snapshotID,
                coveredBatchIDs: [],
                coveredNoteIDs: [coveredNoteID]
            ),
            from: peer
        )

        XCTAssertFalse(
            controller.bootstrapStateForTesting(peerDeviceID: "partial-bootstrap-mac")?
                .ordinarySyncReady == true
        )
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id),
            [blockedHistorical.id, safeHistorical.id]
        )
        XCTAssertEqual(sentBatchIDs, [safeHistorical.id])

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: state.snapshotID,
                coveredBatchIDs: [blockedHistorical.id, safeHistorical.id],
                coveredNoteIDs: [coveredNoteID, uncoveredNoteID]
            ),
            from: peer
        )

        XCTAssertTrue(
            controller.bootstrapStateForTesting(peerDeviceID: "partial-bootstrap-mac")?
                .ordinarySyncReady == true
        )
        XCTAssertTrue(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
        XCTAssertTrue(kinds.contains(.batchSync))
    }

    func testBootstrapApplyRejectsDirtyDestinationWithoutSavingOrRollingBackLocalChanges() throws {
        let sourceContainer = try makeInMemoryContainer()
        let sourceContext = sourceContainer.mainContext
        let remoteNote = Note(title: "Remote", content: "")
        sourceContext.insert(remoteNote)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: remoteNote,
            in: sourceContext
        )
        try sourceContext.save()
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: sourceContext)

        let destinationContainer = try makeInMemoryContainer()
        let destinationContext = destinationContainer.mainContext
        let localNote = Note(title: "Local", content: "")
        destinationContext.insert(localNote)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: localNote,
            in: destinationContext
        )
        try destinationContext.save()
        localNote.title = "Unsaved local edit"
        XCTAssertTrue(destinationContext.hasChanges)

        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: destinationContext)
        ) { error in
            XCTAssertEqual(
                error as? SyncPeerBootstrapError,
                .destinationContextHasPendingChanges
            )
        }

        XCTAssertEqual(localNote.title, "Unsaved local edit")
        XCTAssertTrue(destinationContext.hasChanges)
        XCTAssertFalse(
            try destinationContext.fetch(FetchDescriptor<Note>())
                .contains(where: { $0.id == remoteNote.id })
        )
    }

    func testBootstrapMergeReportsCausallySubsumedHistoricalBatchAsCovered() throws {
        let container = try makeInMemoryContainer()
        retainedContainers.append(container)
        let context = container.mainContext
        let noteID = UUID(uuidString: "23300000-0000-0000-0000-0000000000D1")!
        let batchID = UUID(uuidString: "23300000-0000-0000-0000-0000000000D2")!
        let originDeviceID = UUID(uuidString: "23300000-0000-0000-0000-0000000000D3")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_330)
        let modifiedAt = createdAt.addingTimeInterval(1)
        let note = Note(title: "Shared", content: "B")
        note.id = noteID
        note.createdAt = createdAt
        note.modifiedAt = createdAt
        context.insert(note)
        try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()

        let initial = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        let insertion = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 1,
            text: "A",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "B"),
            operationID: SyncOperationID(deviceID: originDeviceID, localCounter: 1),
            state: initial.state
        )
        guard case .noteBodyTextInsertedAnchored(let anchoredInsertion) = insertion else {
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
            id: UUID(uuidString: "23300000-0000-0000-0000-0000000000D4")!,
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

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        XCTAssertEqual(note.content, "BA")
        XCTAssertEqual(disposition.coveredNoteIDs, [noteID])
        XCTAssertEqual(
            disposition.coveredBatchIDs,
            [batchID],
            "History incorporated by the committed bootstrap baseline must retire through the bootstrap acknowledgement instead of replaying against that newer baseline."
        )
    }

    func testMYR222NonMergeableBootstrapMaterializesDurableStructuralConflict() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000231")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 2_230)
        let note = Note(title: "", content: "Local")
        note.id = noteID
        note.createdAt = createdAt
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()
        let localSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        let remoteState = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(uuidString: "22200000-0000-0000-0000-000000000239")!,
            body: "Remote"
        ).state
        let remotePayload = try NoteSequenceStatePersistenceCodec.encode(state: remoteState, noteID: noteID)
        let snapshot = SyncPeerBootstrapSnapshot(
            id: UUID(uuidString: "22200000-0000-0000-0000-000000000232")!,
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
            .appendingPathComponent("MYR-222-mac-structural-\(UUID().uuidString)", isDirectory: true)
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

        XCTAssertEqual(note.content, "Local")
        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context),
            localSnapshot
        )
        XCTAssertFalse(disposition.coveredNoteIDs.contains(noteID))
        XCTAssertTrue(disposition.presentationRefreshRequired)
        XCTAssertEqual(store.activeConflicts().count, 1)
        let conflict = try XCTUnwrap(store.activeConflicts().first)
        XCTAssertEqual(conflict.field, .noteContent)
        XCTAssertEqual(conflict.localText, "Local")
        XCTAssertEqual(conflict.remoteText, "Remote")
        let record = try XCTUnwrap(store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: sidecarURL
        ))
        XCTAssertEqual(record.remoteStatePayloadData, remotePayload)
        XCTAssertEqual(try store.validatedBootstrapStructuralRemoteState(record), remoteState)
    }

    func testLateBootstrapAnnouncementSupersedesFallbackOnMac() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapSessionFallbackUnsupported(forPeerDeviceID: "peer")
        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
    }

    func testControllerAdvertisesAndInvitesWithCanonicalV1AndV2Context() throws {
        var invitedPeerIDs: [MCPeerID] = []
        var invitationContexts: [Data] = []
        let controller = try makeController(
            invitePeerOperation: { peerID, context, _ in
                invitedPeerIDs.append(peerID)
                invitationContexts.append(context)
            }
        )
        let peerID = MCPeerID(displayName: "Remote|capability-peer")

        XCTAssertEqual(
            controller.advertisedBatchSchemaDiscoveryInfo,
            [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2",
                SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey: "1"
            ]
        )

        controller.invite(MacSyncDiscoveredPeer(
            peerID: peerID,
            deviceID: "capability-peer",
            displayName: "Remote"
        ))

        XCTAssertEqual(invitedPeerIDs, [peerID])
        XCTAssertEqual(invitationContexts, [Data("1,2".utf8)])
    }

    func testControllerReconnectRebindsWithoutRediscoveryAndUpdatesRevokeImmediately() async throws {
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let remotePeerID = MCPeerID(displayName: "Remote|capability-peer")
        var connectedPeers = [remotePeerID]
        let controller = try makeController(connectedPeersProvider: { connectedPeers })
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
            foundPeer: remotePeerID,
            withDiscoveryInfo: [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"
            ]
        )
        await Task.yield()
        XCTAssertFalse(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        controller.session(session, peer: remotePeerID, didChange: .connected)
        await Task.yield()
        XCTAssertTrue(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: remotePeerID,
            withContext: Data("1".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        XCTAssertFalse(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: remotePeerID,
            withContext: Data("1,2".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        XCTAssertTrue(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        connectedPeers = []
        controller.session(session, peer: remotePeerID, didChange: .notConnected)
        await Task.yield()
        XCTAssertFalse(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))
        XCTAssertEqual(
            controller.effectivePeerCapability(forPeerDeviceID: "capability-peer"),
            .v1AndV2
        )

        connectedPeers = [remotePeerID]
        controller.session(session, peer: remotePeerID, didChange: .connected)
        await Task.yield()
        XCTAssertTrue(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        controller.browser(browser, lostPeer: remotePeerID)
        await Task.yield()
        XCTAssertTrue(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))
    }

    func testControllerBroadcastsV1BatchToEveryConnectedEntry() async throws {
        let firstPeer = MCPeerID(displayName: "First|first-device")
        let secondPeer = MCPeerID(displayName: "Second|second-device")
        var recipientLists: [[MCPeerID]] = []
        let controller = try makeController(
            connectedPeersProvider: { [firstPeer, secondPeer] },
            sendBatchDataOperation: { _, peers, _ in
                recipientLists.append(peers)
            }
        )
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: "myram-sync"
        )
        let legacyDiscoveryInfo = [
            SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"
        ]

        controller.browser(
            browser,
            foundPeer: firstPeer,
            withDiscoveryInfo: legacyDiscoveryInfo
        )
        controller.browser(
            browser,
            foundPeer: secondPeer,
            withDiscoveryInfo: legacyDiscoveryInfo
        )
        await Task.yield()
        recipientLists.removeAll()

        try await controller.acceptLocalBatch(makeV1Batch(idSuffix: 1))

        XCTAssertEqual(recipientLists, [[firstPeer, secondPeer]])
    }

    func testExplicitV2NegotiationReachesActivatedInboundPath() async throws {
        let remotePeerID = MCPeerID(displayName: "Remote|capability-peer")
        var sentData: [Data] = []
        let controller = try makeController(
            connectedPeersProvider: { [remotePeerID] },
            sendBatchDataOperation: { data, _, _ in sentData.append(data) }
        )
        let localPeerID = MCPeerID(displayName: "Local|local-device")
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
        let batch = try makeAnchoredBatch()

        controller.browser(
            browser,
            foundPeer: remotePeerID,
            withDiscoveryInfo: [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"
            ]
        )
        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: remotePeerID,
            withContext: Data("1,2".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        XCTAssertFalse(controller.hasExplicitPeerV2Support(forPeerDeviceID: "capability-peer"))

        controller.session(session, peer: remotePeerID, didChange: .connected)
        await Task.yield()
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )
        sentData.removeAll()

        let lastConnectionEvent = controller.lastConnectionEvent
        let data = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: SyncBatchEnvelopeCodec.encode(batch: batch)
        )
        controller.session(session, didReceive: data, fromPeer: remotePeerID)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(sentData.isEmpty)
        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
        XCTAssertNil(controller.lastSyncAt)
        XCTAssertNotEqual(controller.lastConnectionEvent, lastConnectionEvent)
        XCTAssertEqual(controller.lastConnectionEvent, "Received sync from Remote")
    }

    private func makeController(
        context: ModelContext? = nil,
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
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            startsNetworking: false,
            connectedPeersProvider: connectedPeersProvider,
            sendBatchDataOperation: sendBatchDataOperation,
            invitePeerOperation: invitePeerOperation
        )
    }

    private func makeV1Batch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                idSuffix
            ))!,
            originDeviceID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func makeV1TitleBatch(idSuffix: Int, noteID: UUID) -> SyncBatch {
        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(idSuffix))
        return SyncBatch(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                idSuffix
            ))!,
            originDeviceID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!,
            createdAt: modifiedAt,
            changes: [
                .noteTitleChanged(.init(
                    noteID: noteID,
                    title: "Historical title",
                    modifiedAt: modifiedAt
                ))
            ]
        )
    }

    private func makeAnchoredBatch() throws -> SyncBatch {
        let deviceID = UUID(
            uuidString: "17400000-0000-0000-0000-000000000001"
        )!
        let state = try SyncTextSequenceState(runs: [], fragments: [])
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: UUID(
                uuidString: "17400000-0000-0000-0000-000000000002"
            )!,
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_740),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(
                deviceID: deviceID,
                localCounter: 1
            ),
            state: state
        )
        return SyncBatch(
            id: UUID(
                uuidString: "17400000-0000-0000-0000-000000000003"
            )!,
            originDeviceID: deviceID,
            createdAt: Date(timeIntervalSince1970: 1_740),
            batchSequence: 1,
            changes: [change]
        )
    }

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "SyncBatchPeerCapabilityTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
