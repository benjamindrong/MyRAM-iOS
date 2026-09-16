import Foundation
import MultipeerConnectivity
import XCTest
@testable import MyRAM

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
final class MYR229QueueDrainRegressionTests: XCTestCase {
    func testWithheldHistoricalHeadDoesNotBlockNewerOrdinaryBatch() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-229-withheld-ios")
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let pendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR229-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pendingURL) }
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: pendingURL,
            startsNetworking: false,
            transport: transport
        )
        let snapshotID = UUID(uuidString: "22900000-0000-0000-0000-000000000001")!
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr-229-withheld-ios"
        )

        let originDeviceID = UUID(uuidString: "22900000-0000-0000-0000-000000000002")!
        let historical = SyncBatch(
            id: UUID(uuidString: "22900000-0000-0000-0000-000000000003")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 2_293),
            batchSequence: 1,
            changes: []
        )
        let newer = SyncBatch(
            id: UUID(uuidString: "22900000-0000-0000-0000-000000000004")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 2_294),
            batchSequence: 2,
            changes: []
        )

        try await controller.acceptLocalBatch(historical)
        XCTAssertTrue(transport.sentBatchIDs.isEmpty)
        await controller.beginBootstrapForTesting(to: peer)
        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshotID,
                coveredBatchIDs: []
            ),
            from: peer
        )

        XCTAssertTrue(
            controller.isOrdinarySyncReadyForTesting(
                peerDeviceID: "myr-229-withheld-ios"
            )
        )
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id),
            [historical.id]
        )
        XCTAssertTrue(transport.sentBatchIDs.isEmpty)

        try await controller.acceptLocalBatch(newer)

        XCTAssertEqual(transport.sentBatchIDs, [newer.id])
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id),
            [historical.id, newer.id]
        )
    }
}

private final class MYR229RecordingTransport: MyRAMSyncTransporting {
    private let peers: [MCPeerID]
    private(set) var sentBatchIDs: [SyncBatchID] = []

    init(connectedPeers: [MCPeerID]) {
        peers = connectedPeers
    }

    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        peers
    }

    func hasConnectedPeer(_ peerID: MCPeerID) -> Bool {
        peers.contains(peerID)
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        guard message.kind == .batchSync else { return }
        sentBatchIDs.append(try SyncBatchEnvelopeCodec.decode(message.payload).batch.id)
    }
}

final class SyncBatchAnchoredBootstrapConflictCoverageTests: XCTestCase {
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
        let edit = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
            state: bootstrapState,
            offset: 1,
            text: "B",
            operationID: SyncBatchAnchoredRecoveryTestFactory.operation(110)
        )
        let editedState = try SyncBatchAnchoredRecoveryTestFactory.applying(
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
                noteID: SyncBatchAnchoredRecoveryTestFactory.noteID,
                body: body,
                formatVersion: .v1
            )
        )
    }

    private func emptyRecoverySnapshot() -> SyncBatchAnchoredRecoveryStoreSnapshot {
        SyncBatchAnchoredRecoveryStoreSnapshot(records: [], health: .healthy)
    }
}
