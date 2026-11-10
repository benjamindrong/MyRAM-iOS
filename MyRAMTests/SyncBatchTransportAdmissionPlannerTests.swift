import AnchoredSequenceCore
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

    func testV3AdmissionAndRoutingMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: false
            ),
            .reject(.structuralMarkPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: true
            ),
            .admitV3
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: false,
                connectedPeers: [peer(index: 0, supportsStructuralMarks: true)]
            ),
            .withhold(.structuralMarkPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: true,
                connectedPeers: []
            ),
            .withhold(.noConnectedPeers)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: true,
                connectedPeers: [peer(index: 0)]
            ),
            .withhold(.peerLacksExplicitCurrentSessionStructuralMarkSupport)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: true,
                connectedPeers: [
                    peer(index: 0),
                    peer(index: 1, supportsStructuralMarks: true)
                ]
            ),
            .sendToPeer(transportIndex: 1)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                deliveryRepresentation: .structuralMarkV3,
                activationEnabled: true,
                structuralMarkEnabled: true,
                connectedPeers: [
                    peer(index: 0, supportsStructuralMarks: true),
                    peer(index: 1, supportsStructuralMarks: true)
                ]
            ),
            .withhold(.requiresExactlyOneStructuralMarkCapablePeer)
        )

        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v3,
                activationEnabled: true,
                hasExplicitCurrentSessionV2Support: true,
                hasExplicitCurrentSessionStructuralMarkSupport: false,
                structuralMarkEnabled: true
            ),
            .reject(.peerLacksExplicitCurrentSessionStructuralMarkSupport)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v3,
                activationEnabled: true,
                hasExplicitCurrentSessionV2Support: true,
                hasExplicitCurrentSessionStructuralMarkSupport: true,
                structuralMarkEnabled: false
            ),
            .reject(.structuralMarkPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v3,
                activationEnabled: true,
                hasExplicitCurrentSessionV2Support: true,
                hasExplicitCurrentSessionStructuralMarkSupport: true,
                structuralMarkEnabled: true
            ),
            .admitV3
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
        supportsV2: Bool = false,
        supportsStructuralMarks: Bool = false
    ) -> SyncBatchTransportPeer {
        SyncBatchTransportPeer(
            transportIndex: index,
            stableDeviceID: deviceID ?? "peer-\(index)",
            hasExplicitCurrentSessionV2Support: supportsV2,
            hasExplicitCurrentSessionStructuralMarkSupport: supportsStructuralMarks
        )
    }
}

@MainActor
final class MYR229QueueDrainRegressionTests: XCTestCase {
    func testBootstrapCandidateRaceRestartsBeforeFreezingHistory() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-229-bootstrap-race-ios")
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let pendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR229-bootstrap-race-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pendingURL) }
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: pendingURL,
            startsNetworking: false,
            transport: transport
        )
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr-229-bootstrap-race-ios"
        )
        let racedBatch = SyncBatch(
            id: UUID(uuidString: "22900000-0000-0000-0000-000000000021")!,
            originDeviceID: UUID(uuidString: "22900000-0000-0000-0000-000000000022")!,
            createdAt: Date(timeIntervalSince1970: 2_295),
            batchSequence: 3,
            changes: []
        )
        var injected = false
        controller.onBootstrapCandidateCapturedForTesting = {
            guard !injected else { return }
            injected = true
            try? await controller.acceptLocalBatch(racedBatch)
        }

        await controller.beginBootstrapForTesting(to: peer)

        XCTAssertTrue(injected)
        XCTAssertEqual(transport.bootstrapSnapshots.count, 1)
        XCTAssertEqual(
            transport.bootstrapSnapshots[0].historyCoverage.map(\.batchID),
            [racedBatch.id]
        )
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id),
            [racedBatch.id]
        )
    }

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
    func testIncapablePeerWithheldStructuralMarksDoNotBlockNewerCompatibleBatch() async throws {
        let peer = MCPeerID(displayName: "Remote|myr-227-incapable-ios")
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: nil,
            startsNetworking: false,
            transport: transport
        )
        controller.recordBootstrapCapabilityForTesting(
            nil,
            forPeerDeviceID: "myr-227-incapable-ios"
        )
        let actorID = UUID(
            uuidString: "22700000-0000-0000-0000-000000000901"
        )!
        let mark = try SyncTextMarkOperation(
            operationID: SyncOperationID(
                deviceID: actorID,
                localCounter: 1
            ),
            logicalClock: 1,
            key: .bold,
            assignment: .enabled,
            startAnchor: .empty,
            endAnchor: .empty
        )
        let markBatch = SyncBatch(
            id: UUID(uuidString: "22700000-0000-0000-0000-000000000902")!,
            originDeviceID: actorID,
            createdAt: Date(timeIntervalSince1970: 227_902),
            batchSequence: 1,
            changes: [
                .noteStructuralMarksChanged(
                    SyncBatchNoteStructuralMarksChangedChange(
                        noteID: UUID(
                            uuidString: "22700000-0000-0000-0000-000000000903"
                        )!,
                        operations: [mark],
                        modifiedAt: Date(timeIntervalSince1970: 227_902)
                    )
                )
            ]
        )
        let compatibleBatch = SyncBatch(
            id: UUID(uuidString: "22700000-0000-0000-0000-000000000904")!,
            originDeviceID: actorID,
            createdAt: Date(timeIntervalSince1970: 227_904),
            batchSequence: 2,
            changes: []
        )

        try await controller.acceptLocalBatch(markBatch)
        XCTAssertTrue(transport.sentBatchIDs.isEmpty)

        try await controller.acceptLocalBatch(compatibleBatch)

        XCTAssertEqual(transport.sentBatchIDs, [compatibleBatch.id])
        XCTAssertEqual(
            controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id),
            [markBatch.id, compatibleBatch.id]
        )

        let acknowledgementData = try MultipeerSyncMessageCoding.encode(
            kind: .batchAcknowledgement,
            payload: JSONEncoder().encode(
                SyncBatchAcknowledgement(batchID: compatibleBatch.id)
            )
        )
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-device")
        )
        controller.session(
            dummySession,
            didReceive: acknowledgementData,
            fromPeer: peer
        )
        await Task.yield()

        XCTAssertEqual(
            controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id),
            [markBatch.id]
        )
    }
}

@MainActor
final class MYR232DeliveryLifecycleTests: XCTestCase {
    private let peer = MCPeerID(displayName: "Remote|myr-232-peer")

    func testPendingStructuralMarkBatchSurvivesRestartAndSendsAfterCapabilityAppears() async throws {
        let unsentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR227-v3-restart-\(UUID().uuidString).json")
        let firstPendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR227-v3-pending-1-\(UUID().uuidString).json")
        let secondPendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR227-v3-pending-2-\(UUID().uuidString).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: unsentURL)
            try? FileManager.default.removeItem(at: firstPendingURL)
            try? FileManager.default.removeItem(at: secondPendingURL)
        }
        let batch = try makeStructuralMarkBatch(idSuffix: 232_701)
        let firstTransport = MYR229RecordingTransport(connectedPeers: [peer])
        let firstController = MyRAMSyncController(
            unsentBatchQueueFileURL: unsentURL,
            pendingChangesFileURL: firstPendingURL,
            startsNetworking: false,
            transport: firstTransport
        )
        firstController.recordBootstrapCapabilityForTesting(
            nil,
            forPeerDeviceID: "myr-232-peer"
        )

        try await firstController.acceptLocalBatch(batch)

        XCTAssertTrue(firstTransport.sentBatchIDs.isEmpty)
        XCTAssertEqual(
            firstController.unsentBatchQueueSnapshot().pendingBatches,
            [batch]
        )

        let secondTransport = MYR229RecordingTransport(connectedPeers: [peer])
        let secondController = MyRAMSyncController(
            unsentBatchQueueFileURL: unsentURL,
            pendingChangesFileURL: secondPendingURL,
            startsNetworking: false,
            transport: secondTransport
        )
        secondController.recordBootstrapCapabilityForTesting(
            nil,
            forPeerDeviceID: "myr-232-peer"
        )
        secondController.recordStructuralMarkCapabilityForTesting(
            SyncBatchPeerCapabilityCodec.structuralMarkDiscoveryInfoValue,
            forPeerDeviceID: "myr-232-peer"
        )

        secondController.flushAllOutboundWork()
        await waitUntil { secondTransport.sentBatchIDs == [batch.id] }

        XCTAssertEqual(secondTransport.sentBatchIDs, [batch.id])
        XCTAssertEqual(
            secondController.unsentBatchQueueSnapshot().pendingBatches,
            [batch]
        )
    }

    func testRepeatedFlushWhileSendIsInFlightDoesNotMultiplyDelivery() async throws {
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        transport.suspendBatchSends = true
        let controller = makeController(transport: transport)
        let batch = makeBatch(idSuffix: 2321)

        let firstSend = Task { try await controller.acceptLocalBatch(batch) }
        await waitUntil { transport.attemptedBatchIDs == [batch.id] }

        controller.flushAllOutboundWork()
        controller.flushAllOutboundWork()
        await Task.yield()
        XCTAssertEqual(transport.attemptedBatchIDs, [batch.id])

        transport.resumeNextBatchSend()
        try await firstSend.value
        XCTAssertEqual(transport.sentBatchIDs, [batch.id])
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])
    }

    func testSendFailureReleasesOnlyItsReservationAndRemainsRetryable() async throws {
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let batch = makeBatch(idSuffix: 2322)
        transport.failNextBatchID = batch.id

        try await controller.acceptLocalBatch(batch)
        XCTAssertEqual(transport.attemptedBatchIDs, [batch.id])
        XCTAssertTrue(transport.sentBatchIDs.isEmpty)

        controller.flushAllOutboundWork()
        await waitUntil { transport.sentBatchIDs == [batch.id] }
        XCTAssertEqual(transport.attemptedBatchIDs, [batch.id, batch.id])
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])
    }

    func testDisconnectReconnectAllowsExactlyOneRetransmissionAndStaleSendCannotReleaseIt() async throws {
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        transport.suspendBatchSends = true
        let controller = makeController(transport: transport)
        let batch = makeBatch(idSuffix: 2323)

        let oldSessionSend = Task { try await controller.acceptLocalBatch(batch) }
        await waitUntil { transport.attemptedBatchIDs == [batch.id] }

        transport.connectedPeers = []
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr-232-peer")
        transport.suspendBatchSends = false
        transport.connectedPeers = [peer]
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "myr-232-peer")
        controller.flushAllOutboundWork()
        await waitUntil { transport.sentBatchIDs == [batch.id] }
        XCTAssertEqual(transport.attemptedBatchIDs, [batch.id, batch.id])

        transport.resumeNextBatchSend()
        try await oldSessionSend.value
        controller.flushAllOutboundWork()
        await Task.yield()

        XCTAssertEqual(transport.attemptedBatchIDs, [batch.id, batch.id])
        XCTAssertEqual(transport.sentBatchIDs, [batch.id, batch.id])
    }

    func testDuplicateReceiveWhileOriginalIsPendingDoesNotMultiplyConvergenceWork() async throws {
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let batch = makeBatch(idSuffix: 2324)
        var captureCount = 0
        var convergenceCount = 0
        var captureContinuation: CheckedContinuation<Bool, Never>?
        controller.onDurablyCaptureIncomingBatch = { _ in
            captureCount += 1
            return await withCheckedContinuation { continuation in
                captureContinuation = continuation
            }
        }
        controller.onBatchReceived = { _ in
            convergenceCount += 1
            return .acknowledgementPermitted
        }
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let session = MCSession(
            peer: MCPeerID(displayName: "Local|myr-232-local"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(session, didReceive: data, fromPeer: peer)
        await waitUntil { captureCount == 1 }
        controller.session(session, didReceive: data, fromPeer: peer)
        await Task.yield()

        XCTAssertEqual(captureCount, 1)
        captureContinuation?.resume(returning: true)
        await waitUntil { convergenceCount == 1 }
        XCTAssertEqual(convergenceCount, 1)
        await waitUntil { transport.sentAcknowledgementBatchIDs == [batch.id] }
    }

    func testDeferredConvergenceCompletionRetainsAcknowledgementWithoutRedelivery() async throws {
        let transport = MYR229RecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let batch = makeBatch(idSuffix: 2325)
        var deliveryCount = 0
        controller.onDurablyCaptureIncomingBatch = { _ in true }
        controller.onBatchReceived = { _ in
            deliveryCount += 1
            return .acknowledgementDeferred
        }
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let session = MCSession(
            peer: MCPeerID(displayName: "Local|myr-232-local"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(session, didReceive: data, fromPeer: peer)
        await waitUntil { deliveryCount == 1 }
        XCTAssertTrue(transport.sentAcknowledgementBatchIDs.isEmpty)

        await controller.retainCompletedRemoteBatchAcknowledgements([batch.id])
        await waitUntil { transport.sentAcknowledgementBatchIDs == [batch.id] }

        XCTAssertEqual(deliveryCount, 1)
        XCTAssertEqual(transport.receivedBatchDeliveryCount, 0)
    }

    private func makeController(transport: MYR229RecordingTransport) -> MyRAMSyncController {
        let pendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR232-legacy-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: pendingURL) }
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: pendingURL,
            startsNetworking: false,
            transport: transport
        )
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "myr-232-peer")
        return controller
    }

    private func makeStructuralMarkBatch(idSuffix: Int) throws -> SyncBatch {
        let actorID = UUID(
            uuidString: "22700000-0000-0000-0000-000000000950"
        )!
        let operation = try SyncTextMarkOperation(
            operationID: SyncOperationID(
                deviceID: actorID,
                localCounter: UInt64(idSuffix)
            ),
            logicalClock: UInt64(idSuffix),
            key: .italic,
            assignment: .enabled,
            startAnchor: .empty,
            endAnchor: .empty
        )
        return SyncBatch(
            id: UUID(
                uuidString: String(
                    format: "22700000-0000-0000-0000-%012d",
                    idSuffix
                )
            )!,
            originDeviceID: actorID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            batchSequence: UInt64(idSuffix),
            changes: [
                .noteStructuralMarksChanged(
                    SyncBatchNoteStructuralMarksChangedChange(
                        noteID: UUID(
                            uuidString: "22700000-0000-0000-0000-000000000951"
                        )!,
                        operations: [operation],
                        modifiedAt: Date(
                            timeIntervalSince1970: TimeInterval(idSuffix)
                        )
                    )
                )
            ]
        )
    }

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "23200000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "23200000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            batchSequence: UInt64(idSuffix),
            changes: []
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
}

private final class MYR229RecordingTransport: MyRAMSyncTransporting {
    var connectedPeers: [MCPeerID]
    var suspendBatchSends = false
    var failNextBatchID: SyncBatchID?
    private(set) var attemptedBatchIDs: [SyncBatchID] = []
    private(set) var sentBatchIDs: [SyncBatchID] = []
    private(set) var sentAcknowledgementBatchIDs: [SyncBatchID] = []
    private(set) var bootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []
    private var suspendedBatchSendContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedBatchDeliveryCount = 0

    init(connectedPeers: [MCPeerID]) {
        self.connectedPeers = connectedPeers
    }

    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        connectedPeers
    }

    func hasConnectedPeer(_ peerID: MCPeerID) -> Bool {
        connectedPeers.contains(peerID)
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        switch message.kind {
        case .batchSync:
            let batch = try SyncBatchEnvelopeCodec.decode(message.payload).batch
            attemptedBatchIDs.append(batch.id)
            if failNextBatchID == batch.id {
                failNextBatchID = nil
                throw MYR232RecordingTransportError.injected
            }
            if suspendBatchSends {
                await withCheckedContinuation { continuation in
                    suspendedBatchSendContinuations.append(continuation)
                }
            }
            sentBatchIDs.append(batch.id)
        case .batchAcknowledgement:
            sentAcknowledgementBatchIDs.append(
                try JSONDecoder().decode(
                    SyncBatchAcknowledgement.self,
                    from: message.payload
                ).batchID
            )
        case .bootstrapSnapshot:
            bootstrapSnapshots.append(
                try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
            )
        default:
            break
        }
    }

    func resumeNextBatchSend() {
        guard !suspendedBatchSendContinuations.isEmpty else { return }
        suspendedBatchSendContinuations.removeFirst().resume()
    }
}

private enum MYR232RecordingTransportError: Error {
    case injected
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
