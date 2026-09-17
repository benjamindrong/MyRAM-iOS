import AnchoredSequenceCore
import Foundation
@preconcurrency import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

final class SyncBatchTransportAdmissionPlannerTests: XCTestCase {
    func testDurableAdmissionMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .none,
                activationEnabled: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .legacy,
                activationEnabled: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .anchored,
                activationEnabled: false
            ),
            .reject(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .anchored,
                activationEnabled: true
            ),
            .admitV2
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .mixed,
                activationEnabled: true
            ),
            .reject(.mixedBodyOperationRepresentations)
        )
    }

    func testV1RoutingBroadcastsEveryConnectedEntry() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .legacy,
                activationEnabled: false,
                connectedPeers: []
            ),
            .withhold(.noConnectedPeers)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .legacy,
                activationEnabled: false,
                connectedPeers: [peer(index: 0), peer(index: 1)]
            ),
            .sendToAllConnectedPeers
        )
    }

    func testV2RoutingMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: false,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .withhold(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: []
            ),
            .withhold(.noConnectedPeers)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0), peer(index: 1)]
            ),
            .withhold(.requiresExactlyOneConnectedPeer)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [
                    peer(index: 0, deviceID: "duplicate", supportsV2: true),
                    peer(index: 1, deviceID: "duplicate", supportsV2: true)
                ]
            ),
            .withhold(.requiresExactlyOneConnectedPeer)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0)]
            ),
            .withhold(.peerLacksExplicitCurrentSessionV2Support)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .sendToPeer(transportIndex: 0)
        )
    }

    func testMixedRoutingIsWithheld() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .mixed,
                activationEnabled: true,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .withhold(.mixedBodyOperationRepresentations)
        )
    }

    func testInboundAdmissionMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v1,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: false
            ),
            .reject(.peerLacksExplicitCurrentSessionV2Support)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: true
            ),
            .reject(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: true,
                hasExplicitCurrentSessionV2Support: true
            ),
            .admitV2
        )
    }

    private func peer(
        index: Int,
        deviceID: String? = nil,
        supportsV2: Bool = false
    ) -> SyncBatchTransportPeer {
        SyncBatchTransportPeer(
            transportIndex: index,
            stableDeviceID: deviceID ?? "peer-\(index)",
            hasExplicitCurrentSessionV2Support: supportsV2
        )
    }
}

@MainActor
final class MYR229MacQueueDrainRegressionTests: XCTestCase {
    func testReconnectRetriesProvider265BeforeDependent269() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-229-mac")
        let providerBatchID = UUID(uuidString: "7BDBBD6A-7843-4022-AE43-B8C80C033CD3")!
        let bootstrapSent = expectation(description: "Connected lifecycle sends bootstrap snapshot")
        var bootstrapSnapshotID: UUID?
        var attemptedBatchIDs: [SyncBatchID] = []
        var sentBatchIDs: [SyncBatchID] = []
        var failProviderOnce = false
        let container = try makeContainer()
        let controller = makeController(
            context: container.mainContext,
            connectedPeers: [peer],
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                switch message.kind {
                case .bootstrapSnapshot:
                    bootstrapSnapshotID = try JSONDecoder().decode(
                        SyncPeerBootstrapSnapshot.self,
                        from: message.payload
                    ).id
                    bootstrapSent.fulfill()
                case .batchSync:
                    let batch = try SyncBatchEnvelopeCodec.decode(message.payload).batch
                    attemptedBatchIDs.append(batch.id)
                    if failProviderOnce, batch.id == providerBatchID {
                        failProviderOnce = false
                        throw MYR229MacQueueDrainError.injected
                    }
                    sentBatchIDs.append(batch.id)
                default:
                    break
                }
            }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in
                    EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
                },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: nil
        )
        _ = coordinator

        let localPeerID = MCPeerID(displayName: "Local|myr-229-mac-local")
        let browser = MCNearbyServiceBrowser(
            peer: localPeerID,
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
            withDiscoveryInfo: SyncBatchPeerCapabilityCodec.productionDiscoveryInfo
        )
        await waitUntil {
            controller.effectivePeerCapability(
                forPeerDeviceID: "myr-229-mac"
            ).supportsV2
        }
        controller.session(session, peer: peer, didChange: .connected)
        await fulfillment(of: [bootstrapSent], timeout: 1)
        let snapshotID = try XCTUnwrap(bootstrapSnapshotID)
        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )

        let noteID = UUID(uuidString: "300BB942-B5DA-49D4-BDEA-D251D56D58CF")!
        let actorID = UUID(uuidString: "280CD3D7-6663-4881-B097-CD79AF5C88AF")!
        let providerID = SyncOperationID(deviceID: actorID, localCounter: 265)
        let dependentID = SyncOperationID(deviceID: actorID, localCounter: 269)
        let baseline = SyncTextSequenceState.empty
        let providerChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 0,
            text: "iOS-op-261\n",
            modifiedAt: Date(timeIntervalSince1970: 2_290),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: providerID,
            state: baseline
        )
        guard case .noteBodyTextInsertedAnchored(let providerInsertion) = providerChange else {
            return XCTFail("Expected anchored provider")
        }
        let stateWithProvider = try SyncBatchAnchoredInsertReplay.applying(
            providerInsertion,
            to: baseline
        ).sequenceState
        let dependentChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 11,
            text: "!",
            modifiedAt: Date(timeIntervalSince1970: 2_291),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: stateWithProvider.visibleText),
            operationID: dependentID,
            state: stateWithProvider
        )
        guard case .noteBodyTextInsertedAnchored(let dependentInsertion) = dependentChange else {
            return XCTFail("Expected anchored dependent")
        }
        XCTAssertEqual(
            dependentInsertion.payload.anchor,
            .after(try SyncTextElementID(operationID: providerID, elementOffset: 10))
        )

        let provider = SyncBatch(
            id: providerBatchID,
            originDeviceID: actorID,
            createdAt: Date(timeIntervalSince1970: 2_290),
            batchSequence: 264,
            changes: [providerChange]
        )
        let dependent = SyncBatch(
            id: UUID(uuidString: "E3C5B753-1B2F-46B9-B2B2-D003D68E42F5")!,
            originDeviceID: actorID,
            createdAt: Date(timeIntervalSince1970: 2_291),
            batchSequence: 268,
            changes: [dependentChange]
        )
        let receiverOutcome = try SyncConvergenceAnchoredBatchPlanner().plan(
            indexedChanges: [(0, dependentChange)],
            batch: dependent,
            expectedSnapshot: NoteSequenceStateMutationSnapshot(
                noteID: noteID,
                body: "",
                revision: 0,
                state: baseline
            ),
            recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot(records: [], health: .healthy)
        )
        guard case .deferred(let deferred) = receiverOutcome else {
            return XCTFail("A receiver missing operation 265 must defer operation 269")
        }
        XCTAssertEqual(
            deferred.dependency,
            .insertionAnchor(try SyncTextElementID(operationID: providerID, elementOffset: 10))
        )

        failProviderOnce = true
        try await controller.acceptLocalBatch(provider)
        try await controller.acceptLocalBatch(dependent)

        XCTAssertEqual(
            attemptedBatchIDs,
            [provider.id, provider.id, dependent.id]
        )
        XCTAssertEqual(sentBatchIDs, [provider.id, dependent.id])
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id),
            [provider.id, dependent.id]
        )
    }

    func testReconnectCaptureDuringPreflightRestartsBeforeSnapshotFreeze() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-229-race-mac")
        var bootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []
        let container = try makeContainer()
        let context = container.mainContext
        let noteID = UUID(uuidString: "22900000-0000-0000-0000-000000000031")!
        let note = Note(title: "Before", content: "")
        note.id = noteID
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()

        let controller = makeController(
            context: context,
            connectedPeers: [peer],
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                if message.kind == .bootstrapSnapshot {
                    bootstrapSnapshots.append(
                        try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
                    )
                }
            }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in
                    EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
                },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: nil
        )
        _ = coordinator
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "myr-229-race-mac")
        let captured = SyncConvergenceCapturedLocalChange(
            change: .noteTitleChanged(
                SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: "After",
                    modifiedAt: Date(timeIntervalSince1970: 2_296)
                )
            ),
            evidence: nil
        )
        var injected = false
        controller.onBootstrapOwnershipPreflightCompletedForTesting = {
            guard !injected else { return }
            injected = true
            await controller.record(captured, at: Date(timeIntervalSince1970: 2_296))
        }

        await controller.beginReconnectBootstrapForTesting(to: peer)

        XCTAssertTrue(injected)
        XCTAssertEqual(bootstrapSnapshots.count, 1)
        XCTAssertEqual(bootstrapSnapshots[0].historyCoverage.count, 1)
        XCTAssertEqual(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count, 1)
    }

    func testWithheldHistoricalHeadDoesNotBlockNewerOrdinaryBatch() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-229-withheld-mac")
        var bootstrapSnapshotID: UUID?
        var sentBatchIDs: [SyncBatchID] = []
        let container = try makeContainer()
        let controller = makeController(
            context: container.mainContext,
            connectedPeers: [peer],
            sendBatchDataOperation: { data, _, _ in
                let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
                switch message.kind {
                case .bootstrapSnapshot:
                    bootstrapSnapshotID = try JSONDecoder().decode(
                        SyncPeerBootstrapSnapshot.self,
                        from: message.payload
                    ).id
                case .batchSync:
                    sentBatchIDs.append(try SyncBatchEnvelopeCodec.decode(message.payload).batch.id)
                default:
                    break
                }
            }
        )
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr-229-withheld-mac"
        )

        let originDeviceID = UUID(uuidString: "22900000-0000-0000-0000-000000000012")!
        let historical = SyncBatch(
            id: UUID(uuidString: "22900000-0000-0000-0000-000000000013")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 2_293),
            batchSequence: 1,
            changes: []
        )
        let newer = SyncBatch(
            id: UUID(uuidString: "22900000-0000-0000-0000-000000000014")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 2_294),
            batchSequence: 2,
            changes: []
        )

        try await controller.acceptLocalBatch(historical)
        controller.beginBootstrapForTesting(to: peer)
        let snapshotID = try XCTUnwrap(bootstrapSnapshotID)
        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )

        XCTAssertEqual(
            controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id),
            [historical.id]
        )
        XCTAssertTrue(sentBatchIDs.isEmpty)

        try await controller.acceptLocalBatch(newer)

        XCTAssertEqual(sentBatchIDs, [newer.id])
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshotForTesting().pendingBatches.map(\.id),
            [historical.id, newer.id]
        )
    }

    private func makeController(
        context: ModelContext,
        connectedPeers: [MCPeerID],
        sendBatchDataOperation: @escaping (Data, [MCPeerID], MCSessionSendDataMode) throws -> Void
    ) -> MacSyncBatchController {
        MacSyncBatchController(
            context: context,
            conflictStore: SyncConflictStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent("conflicts.json")
            ),
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            connectedPeersProvider: { connectedPeers },
            sendBatchDataOperation: sendBatchDataOperation
        )
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

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "MYR229MacQueueDrainRegressionTests-\(UUID().uuidString)",
            schema: Schema(MyRAMModelRegistry.models),
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: configuration
        )
    }
}

private enum MYR229MacQueueDrainError: Error {
    case injected
}

final class SyncBatchAnchoredBootstrapConflictCoverageTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "17710000-0000-0000-0000-000000000001"
    )!
    private let deviceID = UUID(
        uuidString: "17710000-0000-0000-0000-000000000002"
    )!
    private let modifiedAt = Date(timeIntervalSince1970: 1_771)

    func testDifferentBootstrapAgainstEstablishedBootstrapCreatesConflict() throws {
        let establishedBootstrap = try bootstrapChange(body: "A")
        guard case .bootstrap(let establishedValue) = establishedBootstrap else {
            return XCTFail("Expected established bootstrap change")
        }
        let establishedState = try establishedValue.makeDescriptor().state
        let incomingBootstrap = try bootstrapChange(body: "B")

        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: incomingBootstrap,
            foundation: .established(establishedState),
            recoverySnapshot: emptyRecoverySnapshot()
        )

        XCTAssertEqual(plan.finalFoundation, .established(establishedState))
        XCTAssertFalse(plan.didChangeApplicationState)
        XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
        guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
              case .bootstrapContentConflict(let conflict) = record.lifecycle else {
            return XCTFail("Expected bootstrap-content conflict")
        }
        XCTAssertEqual(record.change, incomingBootstrap)
        XCTAssertEqual(conflict.reason, .nonEquivalentEstablishedState)
        XCTAssertEqual(
            try conflict.establishedState.makeValidatedSequenceState(),
            establishedState
        )
    }

    func testLateBootstrapAfterOrdinaryEditCreatesConflict() throws {
        let bootstrap = try bootstrapChange(body: "A")
        guard case .bootstrap(let bootstrapValue) = bootstrap else {
            return XCTFail("Expected bootstrap change")
        }
        let bootstrapState = try bootstrapValue.makeDescriptor().state
        let edit = try insertionChange(
            state: bootstrapState,
            offset: 1,
            text: "B",
            counter: 110
        )
        let editedState = try SyncBatchAnchoredRecoveryReplay.apply(
            edit,
            to: bootstrapState
        )

        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: bootstrap,
            foundation: .established(editedState),
            recoverySnapshot: emptyRecoverySnapshot()
        )

        XCTAssertEqual(plan.finalFoundation, .established(editedState))
        XCTAssertEqual(plan.visibleText, "AB")
        XCTAssertFalse(plan.didChangeApplicationState)
        XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
        guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
              case .bootstrapContentConflict(let conflict) = record.lifecycle else {
            return XCTFail("Expected late-bootstrap content conflict")
        }
        XCTAssertEqual(record.change, bootstrap)
        XCTAssertEqual(conflict.reason, .nonEquivalentEstablishedState)
        XCTAssertEqual(
            try conflict.establishedState.makeValidatedSequenceState(),
            editedState
        )
    }

    private func bootstrapChange(body: String) throws -> SyncBatchAnchoredRecoveryChange {
        .bootstrap(
            try SyncBatchAnchoredBootstrapChange(
                noteID: noteID,
                body: body,
                formatVersion: .v1
            )
        )
    }

    private func insertionChange(
        state: SyncTextSequenceState,
        offset: Int,
        text: String,
        counter: UInt64
    ) throws -> SyncBatchAnchoredRecoveryChange {
        let batchChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: modifiedAt,
            baseContentHash: nil,
            operationID: SyncOperationID(
                deviceID: deviceID,
                localCounter: counter
            ),
            state: state
        )
        guard case .noteBodyTextInsertedAnchored(let change) = batchChange else {
            throw CoverageError.unexpectedChange
        }
        return .insertion(change)
    }

    private func emptyRecoverySnapshot() -> SyncBatchAnchoredRecoveryStoreSnapshot {
        SyncBatchAnchoredRecoveryStoreSnapshot(records: [], health: .healthy)
    }

    private enum CoverageError: Error {
        case unexpectedChange
    }
}
