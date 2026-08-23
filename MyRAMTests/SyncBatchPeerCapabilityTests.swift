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

    func testBootstrapRequiresExplicitCurrentDiscoveryMarkerAndClearsOnDisconnect() {
        var registry = SyncBatchPeerCapabilityRegistry()
        XCTAssertFalse(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
        XCTAssertFalse(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))

        registry.recordBootstrapDiscoveryValue(nil, forPeerDeviceID: "peer")
        XCTAssertTrue(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
        XCTAssertFalse(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))

        registry.recordBootstrapDiscoveryValue("1", forPeerDeviceID: "peer")
        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))

        registry.clearEvidence(forPeerDeviceID: "peer")
        XCTAssertFalse(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
        XCTAssertFalse(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
    }

    func testBootstrapAnnouncementResolvesSupportedWithoutDiscovery() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")
        XCTAssertTrue(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
    }

    func testBootstrapAnnouncementCannotBeDowngradedByMissingDiscoveryMarker() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")
        registry.recordBootstrapDiscoveryValue(nil, forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
        XCTAssertTrue(registry.isBootstrapCapabilityResolved(forPeerDeviceID: "peer"))
    }

    func testLostPeerClearsOnlyDiscoveryBootstrapEvidence() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapDiscoveryValue("1", forPeerDeviceID: "peer")
        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")

        registry.clearDiscoveryEvidence(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
    }

    func testDiscoveryOnlyBootstrapSupportUsedBySessionSurvivesDiscoveryLossUntilDisconnect() {
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

    func testDiscoveryLossBeforeConnectionDoesNotCreateBootstrapSessionEvidence() async {
        let transport = CapabilityRecordingTransport()
        let controller = makeController(transport: transport)
        let localPeerID = MCPeerID(displayName: "Local|local-device")
        let remotePeerID = MCPeerID(displayName: "Remote|never-connected-bootstrap")
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
                peerDeviceID: "never-connected-bootstrap"
            )
        )

        controller.browser(browser, lostPeer: remotePeerID)
        await Task.yield()

        XCTAssertFalse(
            controller.isBootstrapCapabilityResolvedForTesting(
                peerDeviceID: "never-connected-bootstrap"
            )
        )
    }

    func testLateBootstrapAnnouncementSupersedesSessionFallback() {
        var registry = SyncBatchPeerCapabilityRegistry()
        registry.recordBootstrapSessionFallbackUnsupported(forPeerDeviceID: "peer")
        XCTAssertFalse(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))

        registry.recordBootstrapV1Announcement(forPeerDeviceID: "peer")

        XCTAssertTrue(registry.hasExplicitCurrentSessionBootstrapV1Support(forPeerDeviceID: "peer"))
    }

    func testBootstrapCapablePeerWithholdsBatchesUntilPositiveAckAndPrunesOnlyCapturedIDs() async throws {
        let peer = MCPeerID(displayName: "Remote|bootstrap-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-peer")
        let covered = makeV1Batch(idSuffix: 2161)
        let newer = makeV1Batch(idSuffix: 2162)

        try await controller.acceptLocalBatch(covered)
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
        await controller.beginBootstrapForTesting(to: peer)
        try await controller.acceptLocalBatch(newer)
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: [covered.id]),
            from: peer
        )

        XCTAssertTrue(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "bootstrap-peer"))
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id), [newer.id])
        XCTAssertEqual(transport.batchRecipientLists, [[peer]])
        controller.clearBootstrapStateForTesting(peerDeviceID: "bootstrap-peer")
        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "bootstrap-peer"))
    }

    func testManifestedButUncoveredHistoryContinuesIncrementalReplayAfterBarrier() async throws {
        let peer = MCPeerID(displayName: "Remote|behind-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        let noteID = UUID()
        controller.buildBootstrapSnapshot = {
            try self.makeBootstrapSnapshot(id: snapshotID, noteID: noteID)
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "behind-peer")
        let historical = makeV1TitleBatch(idSuffix: 2170, noteID: noteID)

        try await controller.acceptLocalBatch(historical)
        await controller.beginBootstrapForTesting(to: peer)
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )

        XCTAssertTrue(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "behind-peer"))
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [historical])
        XCTAssertEqual(transport.batchRecipientLists, [[peer]])
    }

    func testCapturedButUnmanifestedCoverageAcknowledgementFailsClosed() async throws {
        let peer = MCPeerID(displayName: "Remote|unmanifested-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "unmanifested-peer")
        let historical = makeV1TitleBatch(idSuffix: 2171, noteID: UUID())

        try await controller.acceptLocalBatch(historical)
        await controller.beginBootstrapForTesting(to: peer)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshotID,
                coveredBatchIDs: [historical.id]
            ),
            from: peer
        )

        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "unmanifested-peer"))
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [historical])
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
    }

    func testUncoveredBootstrapHistoryIsWithheldAfterBarrierOpens() async throws {
        let peer = MCPeerID(displayName: "Remote|bootstrap-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-peer")
        let covered = makeV1Batch(idSuffix: 2163)
        try await controller.acceptLocalBatch(covered)
        await controller.beginBootstrapForTesting(to: peer)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshotID, coveredBatchIDs: []),
            from: peer
        )

        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches.map(\.id), [covered.id])
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
    }

    func testBootstrapPruningFailureKeepsBarrierClosedAndHistoryQueued() async throws {
        let peer = MCPeerID(displayName: "Remote|bootstrap-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-peer")
        let historical = makeV1Batch(idSuffix: 2164)
        try await controller.acceptLocalBatch(historical)
        await controller.beginBootstrapForTesting(to: peer)
        controller.injectUnsentBatchPersistenceFailureForNextWrite()

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshotID,
                coveredBatchIDs: [historical.id]
            ),
            from: peer
        )

        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "bootstrap-peer"))
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [historical])
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
    }

    func testInvalidBootstrapCoverageAcknowledgementFailsClosed() async throws {
        let peer = MCPeerID(displayName: "Remote|bootstrap-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshotID = UUID()
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: snapshotID, folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "bootstrap-peer")
        let historical = makeV1Batch(idSuffix: 2165)
        try await controller.acceptLocalBatch(historical)
        await controller.beginBootstrapForTesting(to: peer)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(
                snapshotID: snapshotID,
                coveredBatchIDs: [UUID()]
            ),
            from: peer
        )

        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "bootstrap-peer"))
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [historical])
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
    }

    func testCapabilityAnnouncementResolvesPeerAndStartsBootstrapBeforeBatchSync() async throws {
        let peer = MCPeerID(displayName: "Remote|announcement-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        try await controller.acceptLocalBatch(makeV1Batch(idSuffix: 2166))
        XCTAssertTrue(transport.sentMessageKinds.isEmpty)

        await controller.handleBootstrapCapabilityAnnouncementForTesting(from: peer)

        XCTAssertTrue(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "announcement-peer"))
        XCTAssertEqual(transport.sentMessageKinds, [.bootstrapSnapshot])
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)
    }

    func testUnresolvedPeerFallsBackBeforeReceivingBatchSyncAndLateSupportStartsBootstrap() async throws {
        let peer = MCPeerID(displayName: "Remote|fallback-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        let batch = makeV1Batch(idSuffix: 2167)
        try await controller.acceptLocalBatch(batch)
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)

        await controller.resolveBootstrapCapabilityFallbackForTesting(peerID: peer)

        XCTAssertEqual(transport.batchRecipientLists, [[peer]])
        await controller.handleBootstrapCapabilityAnnouncementForTesting(from: peer)
        XCTAssertEqual(transport.sentMessageKinds.last, .bootstrapSnapshot)
    }

    func testBootstrapSnapshotSendFailureAutomaticallyRetriesSameSnapshot() async throws {
        let peer = MCPeerID(displayName: "Remote|retry-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        transport.failNextBootstrapSnapshotSend = true
        let controller = makeController(transport: transport)
        let snapshot = SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "retry-peer")
        controller.buildBootstrapSnapshot = { snapshot }
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            1_000_000,
            1_000_000_000,
            1_000_000_000
        ])

        await controller.beginBootstrapForTesting(to: peer)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThanOrEqual(transport.attemptedBootstrapSnapshots.count, 2)
        XCTAssertEqual(
            Set(transport.attemptedBootstrapSnapshots.map(\.id)),
            Set([snapshot.id])
        )
        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "retry-peer"))

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshot.id, coveredBatchIDs: []),
            from: peer
        )
        let attemptsAfterAck = transport.attemptedBootstrapSnapshots.count
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(transport.attemptedBootstrapSnapshots.count, attemptsAfterAck)
        XCTAssertTrue(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "retry-peer"))
    }

    func testBootstrapAckTimeoutRetransmitsSameSnapshotUntilAck() async throws {
        let peer = MCPeerID(displayName: "Remote|ack-timeout-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        let snapshot = SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "ack-timeout-peer")
        controller.buildBootstrapSnapshot = { snapshot }
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            1_000_000,
            1_000_000_000,
            1_000_000_000
        ])

        await controller.beginBootstrapForTesting(to: peer)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThanOrEqual(transport.attemptedBootstrapSnapshots.count, 2)
        XCTAssertEqual(
            Set(transport.attemptedBootstrapSnapshots.map(\.id)),
            Set([snapshot.id])
        )
        XCTAssertTrue(transport.batchRecipientLists.isEmpty)

        await controller.handleBootstrapAcknowledgementForTesting(
            SyncPeerBootstrapAcknowledgement(snapshotID: snapshot.id, coveredBatchIDs: []),
            from: peer
        )
        let attemptsAfterAck = transport.attemptedBootstrapSnapshots.count
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(transport.attemptedBootstrapSnapshots.count, attemptsAfterAck)
        XCTAssertTrue(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "ack-timeout-peer"))
    }

    func testBootstrapAckSendLossIsRecoveredByDuplicateSnapshot() async {
        let peer = MCPeerID(displayName: "Remote|ack-loss-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        transport.failNextBootstrapAcknowledgementSend = true
        let controller = makeController(transport: transport)
        let snapshot = SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        var applyCount = 0
        var resumeCount = 0
        controller.applyBootstrapSnapshot = { _ in
            applyCount += 1
            return SyncPeerBootstrapApplyDisposition(
                coveredBatchIDs: [],
                insertedNoteIDs: [],
                presentationRefreshRequired: false
            )
        }
        controller.onResumeIncomingAfterBootstrap = {
            resumeCount += 1
        }

        await controller.receiveBootstrapSnapshotForTesting(snapshot, from: peer)
        XCTAssertEqual(applyCount, 1)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertTrue(transport.sentBootstrapAcknowledgements.isEmpty)

        await controller.receiveBootstrapSnapshotForTesting(snapshot, from: peer)

        XCTAssertEqual(applyCount, 2)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(transport.sentBootstrapAcknowledgements.map(\.snapshotID), [snapshot.id])
    }

    func testDisconnectCancelsPendingBootstrapRetry() async throws {
        let peer = MCPeerID(displayName: "Remote|disconnect-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting("1", forPeerDeviceID: "disconnect-peer")
        controller.setBootstrapRetryDelayNanosecondsForTesting([
            20_000_000,
            1_000_000_000,
            1_000_000_000
        ])
        await controller.beginBootstrapForTesting(to: peer)
        XCTAssertTrue(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "disconnect-peer"))
        let attemptsBeforeDisconnect = transport.attemptedBootstrapSnapshots.count

        controller.handlePeerDisconnectForTesting(peerDeviceID: "disconnect-peer")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(controller.isBootstrapCapabilityResolvedForTesting(peerDeviceID: "disconnect-peer"))
        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "disconnect-peer"))
        XCTAssertEqual(transport.attemptedBootstrapSnapshots.count, attemptsBeforeDisconnect)
    }

    func testReceiveBootstrapOrdersApplyThenAcknowledgementThenResume() async {
        let peer = MCPeerID(displayName: "Remote|ordering-peer")
        let transport = CapabilityRecordingTransport(connectedPeers: [peer])
        let controller = makeController(transport: transport)
        var events: [String] = []
        transport.onSendKind = { kind in
            if kind == .bootstrapAcknowledgement { events.append("ack") }
        }
        controller.applyBootstrapSnapshot = { _ in
            events.append("apply")
            return SyncPeerBootstrapApplyDisposition(
                coveredBatchIDs: [],
                insertedNoteIDs: [],
                presentationRefreshRequired: false
            )
        }
        controller.onResumeIncomingAfterBootstrap = { events.append("resume") }

        await controller.receiveBootstrapSnapshotForTesting(
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: []),
            from: peer
        )

        XCTAssertEqual(events, ["apply", "ack", "resume"])
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
            [
                SyncBatchPeerCapabilityCodec.discoveryInfoKey: "1,2",
                SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey: "1"
            ]
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
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "first-device")
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "second-device")
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

    private func makeBootstrapSnapshot(id: UUID, noteID: UUID) throws -> SyncPeerBootstrapSnapshot {
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: noteID,
            body: ""
        )
        let record = prepared.makeRevisionZeroRecord()
        let timestamp = Date(timeIntervalSince1970: 2_160)
        return SyncPeerBootstrapSnapshot(
            id: id,
            folders: [],
            notes: [
                SyncPeerBootstrapNoteSnapshot(
                    id: noteID,
                    title: "Authoritative",
                    body: "",
                    isPinned: false,
                    createdAt: timestamp,
                    modifiedAt: timestamp,
                    deletedAt: nil,
                    folderID: nil,
                    formatVersion: record.formatVersion,
                    revision: record.revision,
                    visibleUTF16Count: record.visibleUTF16Count,
                    tombstonedUTF16Count: record.tombstonedUTF16Count,
                    payloadByteCount: record.payloadByteCount,
                    statePayloadData: record.statePayloadData
                )
            ]
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
    private(set) var attemptedBootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []
    private(set) var sentBootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []
    private(set) var sentBootstrapAcknowledgements: [SyncPeerBootstrapAcknowledgement] = []
    private(set) var sentMessageKinds: [MultipeerSyncMessageKind] = []
    var onSendKind: ((MultipeerSyncMessageKind) -> Void)?
    var failNextBootstrapSnapshotSend = false
    var failNextBootstrapAcknowledgementSend = false

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
        if message.kind == .bootstrapSnapshot {
            attemptedBootstrapSnapshots.append(
                try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
            )
            if failNextBootstrapSnapshotSend {
                failNextBootstrapSnapshotSend = false
                throw CapabilityRecordingTransportError.injected
            }
        }
        if message.kind == .bootstrapAcknowledgement,
           failNextBootstrapAcknowledgementSend {
            failNextBootstrapAcknowledgementSend = false
            throw CapabilityRecordingTransportError.injected
        }
        sentMessageKinds.append(message.kind)
        onSendKind?(message.kind)
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
        case .bootstrapSnapshot:
            sentBootstrapSnapshots.append(
                try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
            )
        case .bootstrapAcknowledgement:
            sentBootstrapAcknowledgements.append(
                try JSONDecoder().decode(
                    SyncPeerBootstrapAcknowledgement.self,
                    from: message.payload
                )
            )
        case .legacySyncEnvelope, .bootstrapCapability:
            break
        }
    }
}

private enum CapabilityRecordingTransportError: Error {
    case injected
}
