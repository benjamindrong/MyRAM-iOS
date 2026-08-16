import MultipeerConnectivity
import XCTest
@testable import MyRAM

@MainActor
final class SyncBatchPeerCapabilityTests: XCTestCase {
    func testCanonicalEncoding() throws {
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.encode(.v1Only),
            "1"
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.encode(.v2Only),
            "2"
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.encode(.v1AndV2),
            "1,2"
        )
    }

    func testCanonicalDecoding() throws {
        XCTAssertEqual(
            try SyncBatchPeerCapabilityCodec.decode("1"),
            .v1Only
        )
        XCTAssertEqual(
            try SyncBatchPeerCapabilityCodec.decode("2"),
            .v2Only
        )
        XCTAssertEqual(
            try SyncBatchPeerCapabilityCodec.decode("1,2"),
            .v1AndV2
        )
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
        let rejectedValues = [
            "",
            ",1",
            "1,",
            "1,,2",
            "1,1",
            "3",
            "0",
            "-1",
            "+1",
            "01",
            "1,02",
            " 1",
            "1 ",
            "1, 2",
            "1,2 ",
            "one",
            "2,1"
        ]

        for value in rejectedValues {
            XCTAssertThrowsError(
                try SyncBatchPeerCapabilityCodec.decode(value),
                "Expected strict capability rejection for \(value.debugDescription)"
            )
        }
    }

    func testMalformedUTF8InvitationContextIsRejected() {
        XCTAssertThrowsError(
            try SyncBatchPeerCapabilityCodec.decodeInvitationContext(
                Data([0xFF])
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncBatchPeerCapabilityCodecError,
                .malformedUTF8
            )
        }
    }

    func testProductionCapabilityAdvertisesV1AndV2() {
        XCTAssertTrue(SyncBatchAnchoredPayloadCapability.isEnabled)
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionCapability,
            .v1AndV2
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            [SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"]
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionInvitationContext,
            Data("1,2".utf8)
        )
    }

    func testUnknownPeerDefaultsToV1Only() {
        let registry = SyncBatchPeerCapabilityRegistry()

        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1Only
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testDiscoveryOnlyAndInvitationOnlyEvidence() {
        var discoveryRegistry = SyncBatchPeerCapabilityRegistry()
        discoveryRegistry.recordDiscoveryValue(
            "1,2",
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            discoveryRegistry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1AndV2
        )
        XCTAssertTrue(
            discoveryRegistry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )

        var invitationRegistry = SyncBatchPeerCapabilityRegistry()
        invitationRegistry.recordInvitationContext(
            Data("1,2".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            invitationRegistry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1AndV2
        )
        XCTAssertTrue(
            invitationRegistry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testMatchingAndContradictoryEvidenceIntersects() {
        var matchingRegistry = SyncBatchPeerCapabilityRegistry()
        matchingRegistry.recordDiscoveryValue(
            "1,2",
            forPeerDeviceID: "peer"
        )
        matchingRegistry.recordInvitationContext(
            Data("1,2".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            matchingRegistry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1AndV2
        )

        var contradictoryRegistry = SyncBatchPeerCapabilityRegistry()
        contradictoryRegistry.recordDiscoveryValue(
            "1,2",
            forPeerDeviceID: "peer"
        )
        contradictoryRegistry.recordInvitationContext(
            Data("1".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertEqual(
            contradictoryRegistry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1Only
        )
        XCTAssertFalse(
            contradictoryRegistry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testEvidenceIsNeverUnioned() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue("1", forPeerDeviceID: "peer")
        registry.recordInvitationContext(
            Data("2".utf8),
            forPeerDeviceID: "peer"
        )

        XCTAssertTrue(
            registry.effectiveCapability(
                forPeerDeviceID: "peer"
            ).schemas.isEmpty
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testMissingAndMalformedEvidenceNormalizeToV1() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue(nil, forPeerDeviceID: "missing")
        registry.recordInvitationContext(nil, forPeerDeviceID: "missing")
        registry.recordDiscoveryValue("1,", forPeerDeviceID: "malformed")
        registry.recordInvitationContext(
            Data([0xFF]),
            forPeerDeviceID: "malformed"
        )

        XCTAssertEqual(
            registry.effectiveCapability(
                forPeerDeviceID: "missing"
            ),
            .v1Only
        )
        XCTAssertEqual(
            registry.effectiveCapability(
                forPeerDeviceID: "malformed"
            ),
            .v1Only
        )
    }

    func testSameSourceReplacementAndSessionClearing() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue(
            "1,2",
            forPeerDeviceID: "peer"
        )
        registry.recordDiscoveryValue("1", forPeerDeviceID: "peer")
        XCTAssertEqual(
            registry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1Only
        )

        registry.clearEvidence(forPeerDeviceID: "peer")
        XCTAssertEqual(
            registry.effectiveCapability(
                forPeerDeviceID: "peer"
            ),
            .v1Only
        )
        XCTAssertNil(
            registry.evidence(
                from: .discoveryInformation,
                forPeerDeviceID: "peer"
            )
        )

        registry.recordInvitationContext(
            Data("1,2".utf8),
            forPeerDeviceID: "peer"
        )
        XCTAssertTrue(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testDecodedTrafficDoesNotUpgradeRegistry() throws {
        let registry = SyncBatchPeerCapabilityRegistry()
        _ = try SyncBatchPeerCapabilityCodec.decode("1,2")

        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1Only
        )
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testControllerAdvertisesAndInvitesWithCanonicalV1AndV2Context() throws {
        let transport = CapabilityRecordingTransport()
        let controller = makeController(transport: transport)
        let peerID = MCPeerID(displayName: "Remote|capability-peer")

        XCTAssertEqual(
            controller.advertisedBatchSchemaDiscoveryInfo,
            [SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"]
        )

        controller.invite(MyRAMDiscoveredPeer(
            peerID: peerID,
            deviceID: "capability-peer",
            displayName: "Remote",
            isTrusted: false
        ))

        XCTAssertEqual(transport.invitedPeerIDs, [peerID])
        XCTAssertEqual(transport.invitationContexts, [Data("1,2".utf8)])
    }

    func testControllerIntersectsDiscoveryAndInvitationEvidenceAndClearsIt() async {
        let transport = CapabilityRecordingTransport()
        let controller = makeController(transport: transport)
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let remotePeerID = MCPeerID(displayName: "Remote|capability-peer")
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
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: remotePeerID,
            withContext: Data("1".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        XCTAssertEqual(
            controller.effectivePeerCapability(
                forPeerDeviceID: "capability-peer"
            ),
            .v1Only
        )

        controller.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: remotePeerID,
            withContext: Data("1,2".utf8),
            invitationHandler: { _, _ in }
        )
        await Task.yield()
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

        controller.session(session, peer: remotePeerID, didChange: .notConnected)
        await Task.yield()
        XCTAssertFalse(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

        controller.browser(
            browser,
            foundPeer: remotePeerID,
            withDiscoveryInfo: [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2"
            ]
        )
        await Task.yield()
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

        controller.browser(browser, lostPeer: remotePeerID)
        await Task.yield()
        XCTAssertFalse(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )
    }

    func testControllerBroadcastsV1BatchToEveryConnectedEntry() async throws {
        let firstPeer = MCPeerID(displayName: "First|first-device")
        let secondPeer = MCPeerID(displayName: "Second|second-device")
        let transport = CapabilityRecordingTransport(
            connectedPeers: [firstPeer, secondPeer]
        )
        let controller = makeController(transport: transport)
        let batch = makeV1Batch(idSuffix: 1)

        try await controller.acceptLocalBatch(batch)

        XCTAssertEqual(transport.batchRecipientLists, [[firstPeer, secondPeer]])
    }

    func testExplicitV2NegotiationAdmitsInboundV2WhenProductionActivated() async throws {
        let remotePeerID = MCPeerID(displayName: "Remote|capability-peer")
        let transport = CapabilityRecordingTransport(
            connectedPeers: [remotePeerID]
        )
        let controller = makeController(transport: transport)
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
        let batch = try makeAnchoredInsertBatchForTest()
        var durableCaptureCount = 0
        var callbackCount = 0
        controller.onDurablyCaptureIncomingBatch = { _ in
            durableCaptureCount += 1
            return true
        }
        controller.onBatchReceived = { _ in
            callbackCount += 1
            return .acknowledgementPermitted
        }

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
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

        let previousConnectionEvent = controller.lastConnectionEvent
        let data = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: SyncBatchEnvelopeCodec.encode(batch: batch)
        )
        controller.session(session, didReceive: data, fromPeer: remotePeerID)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(durableCaptureCount, 1)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(
            transport.sentBatchAcknowledgements.map(\.batchID),
            [batch.id]
        )
        XCTAssertTrue(controller.unsentBatchQueueSnapshot().pendingBatches.isEmpty)
        XCTAssertEqual(controller.lastSyncAt, batch.createdAt)
        XCTAssertNotEqual(controller.lastConnectionEvent, previousConnectionEvent)
    }

    private func makeController(
        transport: CapabilityRecordingTransport
    ) -> MyRAMSyncController {
        MyRAMSyncController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            pendingChangesFileURL: temporaryQueueFileURL(),
            startsNetworking: false,
            transport: transport
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

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-queue.json")
    }
}

private final class CapabilityRecordingTransport: MyRAMSyncTransporting {
    var connectedPeerValues: [MCPeerID]
    private(set) var invitedPeerIDs: [MCPeerID] = []
    private(set) var invitationContexts: [Data] = []
    private(set) var batchRecipientLists: [[MCPeerID]] = []
    private(set) var sentBatchAcknowledgements: [SyncBatchAcknowledgement] = []

    init(connectedPeers: [MCPeerID] = []) {
        connectedPeerValues = connectedPeers
    }

    func invite(
        _ peerID: MCPeerID,
        context: Data,
        timeout: TimeInterval
    ) {
        invitedPeerIDs.append(peerID)
        invitationContexts.append(context)
    }

    func connectedPeers() async -> [MCPeerID] {
        connectedPeerValues
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        switch message.kind {
        case .batchSync:
            batchRecipientLists.append(peers)
        case .batchAcknowledgement:
            sentBatchAcknowledgements.append(
                try JSONDecoder().decode(
                    SyncBatchAcknowledgement.self,
                    from: message.payload
                )
            )
        case .legacySyncEnvelope:
            break
        }
    }
}
