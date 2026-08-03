import AnchoredSequenceCore
import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class SyncBatchPeerCapabilityTests: XCTestCase {
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

    func testProductionCapabilityRemainsV1Only() {
        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
        XCTAssertEqual(SyncBatchPeerCapabilityCodec.productionCapability, .v1Only)
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            [SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1"]
        )
        XCTAssertEqual(
            SyncBatchPeerCapabilityCodec.productionInvitationContext,
            Data("1".utf8)
        )
    }

    func testRegistryRules() {
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

        registry.clearEvidence(forPeerDeviceID: "peer")
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "peer"),
            .v1Only
        )
    }

    func testMissingMalformedAndNonunionEvidenceRemainFailClosed() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordDiscoveryValue(nil, forPeerDeviceID: "missing")
        registry.recordInvitationContext(Data([0xFF]), forPeerDeviceID: "missing")
        XCTAssertEqual(
            registry.effectiveCapability(forPeerDeviceID: "missing"),
            .v1Only
        )

        registry.recordDiscoveryValue("1", forPeerDeviceID: "contradictory")
        registry.recordInvitationContext(
            Data("2".utf8),
            forPeerDeviceID: "contradictory"
        )
        XCTAssertTrue(
            registry.effectiveCapability(
                forPeerDeviceID: "contradictory"
            ).schemas.isEmpty
        )
    }

    func testDecodedTrafficDoesNotUpgradeRegistry() throws {
        let registry = SyncBatchPeerCapabilityRegistry()
        _ = try SyncBatchPeerCapabilityCodec.decode("1,2")
        XCTAssertFalse(
            registry.hasExplicitCurrentSessionV2Support(
                forPeerDeviceID: "peer"
            )
        )
    }

    func testControllerAdvertisesAndInvitesWithCanonicalV1Context() throws {
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
            [SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1"]
        )

        controller.invite(MacSyncDiscoveredPeer(
            peerID: peerID,
            deviceID: "capability-peer",
            displayName: "Remote"
        ))

        XCTAssertEqual(invitedPeerIDs, [peerID])
        XCTAssertEqual(invitationContexts, [Data("1".utf8)])
    }

    func testControllerIntersectsDiscoveryAndInvitationEvidenceAndClearsIt() async throws {
        let controller = try makeController()
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
        var recipientLists: [[MCPeerID]] = []
        let controller = try makeController(
            connectedPeersProvider: { [firstPeer, secondPeer] },
            sendBatchDataOperation: { _, peers, _ in
                recipientLists.append(peers)
            }
        )

        try await controller.acceptLocalBatch(makeV1Batch(idSuffix: 1))

        XCTAssertEqual(recipientLists, [[firstPeer, secondPeer]])
    }

    func testExplicitV2NegotiationStillRejectsInboundV2BeforeSideEffects() async throws {
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
        XCTAssertTrue(
            controller.hasExplicitPeerV2Support(
                forPeerDeviceID: "capability-peer"
            )
        )

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
        XCTAssertEqual(controller.lastConnectionEvent, lastConnectionEvent)
    }

    private func makeController(
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil,
        invitePeerOperation:
            ((MCPeerID, Data, TimeInterval) -> Void)? = nil
    ) throws -> MacSyncBatchController {
        MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
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
