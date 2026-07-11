import MultipeerConnectivity
import NearbySyncCore
import XCTest
@testable import MyRAM

@MainActor
final class MyRAMSyncControllerTests: XCTestCase {
    func testRecordedChangeIsSentAsLegacyEnvelopeOnManualFlush() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)

        controller.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await waitUntil { controller.pendingChangeCount == 1 }

        controller.flushPendingChanges()
        await waitUntil { !transport.sentLegacyEnvelopes.isEmpty }

        let envelope = try XCTUnwrap(transport.sentLegacyEnvelopes.first)
        XCTAssertEqual(envelope.changes.map(\.entityID), ["note-1"])
    }

    func testAcknowledgementRemovesPendingChangeAndRefreshesAggregateStatus() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)

        controller.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await waitUntil { controller.pendingChangeCount == 1 }
        controller.flushPendingChanges()
        await waitUntil { !transport.sentLegacyEnvelopes.isEmpty }
        let sentChangeID = try XCTUnwrap(transport.sentLegacyEnvelopes.first?.changes.first?.id)

        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [], acknowledgedChangeIDs: [sentChangeID])
        )
        await waitUntil { controller.pendingChangeCount == 0 }

        XCTAssertEqual(controller.pendingSyncStatus.legacyChanges, 0)
        XCTAssertEqual(controller.pendingSyncStatus.totalOutboundItems, 0)
    }

    func testAckOnlyEnvelopeDoesNotTriggerReplyAcknowledgement() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)

        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [], acknowledgedChangeIDs: [UUID()])
        )
        // Give any (incorrect) reply-send path a chance to run before asserting silence.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty, "an acknowledgement-only envelope must not be answered with another acknowledgement")
    }

    func testIncomingContentChangeTriggersAcknowledgementReply() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        var receivedChangeIDs: [UUID] = []
        controller.onChangesReceived = { changes in
            receivedChangeIDs.append(contentsOf: changes.map(\.id))
        }

        let incomingChange = makeChange(entityID: "remote-note", originDeviceID: "remote-device")
        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [incomingChange])
        )
        await waitUntil { !transport.sentLegacyEnvelopes.isEmpty }

        XCTAssertEqual(receivedChangeIDs, [incomingChange.id])
        let ack = try XCTUnwrap(transport.sentLegacyEnvelopes.first)
        XCTAssertTrue(ack.changes.isEmpty)
        XCTAssertEqual(ack.acknowledgedChangeIDs, [incomingChange.id])
    }

    func test101DistinctTargetsDrainAcrossTwoAcknowledgementCyclesWithoutManualSync() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)

        for index in 0..<101 {
            controller.recordLocalChange(
                entityType: .item,
                entityID: "note-\(index)",
                payload: Data("payload".utf8),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        await waitUntil { controller.pendingChangeCount == 101 }

        controller.flushPendingChanges()
        await waitUntil { transport.sentLegacyEnvelopes.count == 1 }

        let firstEnvelope = try XCTUnwrap(transport.sentLegacyEnvelopes.first)
        XCTAssertEqual(firstEnvelope.changes.count, 100, "the first page must stay within SyncEngine's 100-change limit")

        // Acknowledge the first page the way the real peer would; this alone,
        // with no further Manual Sync trigger, must pull the remaining page.
        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(
                senderDeviceID: "remote-device",
                changes: [],
                acknowledgedChangeIDs: firstEnvelope.changes.map(\.id)
            )
        )
        await waitUntil { transport.sentLegacyEnvelopes.count == 2 }

        let secondEnvelope = try XCTUnwrap(transport.sentLegacyEnvelopes.last)
        XCTAssertEqual(secondEnvelope.changes.count, 1, "the remaining single change must drain automatically")

        let allSentIDs = Set(firstEnvelope.changes.map(\.entityID) + secondEnvelope.changes.map(\.entityID))
        XCTAssertEqual(allSentIDs, Set((0..<101).map { "note-\($0)" }))

        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(
                senderDeviceID: "remote-device",
                changes: [],
                acknowledgedChangeIDs: secondEnvelope.changes.map(\.id)
            )
        )
        await waitUntil { controller.pendingChangeCount == 0 }
    }

    func testReconnectFlushesQueuedLegacyChange() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(transport: transport)

        controller.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await waitUntil { controller.pendingChangeCount == 1 }
        controller.flushPendingChanges()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty, "nothing should send while no peer is connected")

        transport.connectedPeers = [Self.remotePeerID]
        let dummySession = MCSession(peer: MCPeerID(displayName: "local|local-device"))
        controller.session(dummySession, peer: Self.remotePeerID, didChange: .connected)

        await waitUntil { !transport.sentLegacyEnvelopes.isEmpty }
        XCTAssertEqual(transport.sentLegacyEnvelopes.first?.changes.map(\.entityID), ["note-1"])
    }

    func testManualSyncFlushesUnsentBatchQueue() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(transport: transport)
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: []
        )

        try await controller.acceptLocalBatch(batch)
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])

        transport.connectedPeers = [Self.remotePeerID]
        controller.flushPendingChanges()

        await waitUntil { controller.unsentBatchQueueSnapshot().pendingBatches.isEmpty }
        XCTAssertEqual(transport.sentBatchEnvelopes.map(\.batch), [batch])
    }

    // MARK: - Helpers

    private static let remotePeerID = MCPeerID(displayName: "Remote|remote-device")

    private func makeController(
        transport: FakeMyRAMSyncTransport
    ) throws -> MyRAMSyncController {
        MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: temporaryQueueFileURL(),
            startsNetworking: false,
            transport: transport
        )
    }

    private func deliverLegacyEnvelope(to controller: MyRAMSyncController, _ envelope: SyncEnvelope) async {
        let data = try! MultipeerSyncMessageCoding.encode(kind: .legacySyncEnvelope, payload: JSONEncoder().encode(envelope))
        let dummySession = MCSession(peer: MCPeerID(displayName: "local|local-device"))
        controller.session(dummySession, didReceive: data, fromPeer: Self.remotePeerID)
        // The delegate callback dispatches onto a Task; give it a turn to run
        // before returning control to the assertion.
        await Task.yield()
    }

    private func makeChange(entityID: String, originDeviceID: String) -> SyncChange {
        SyncChange(
            entityType: .item,
            entityID: entityID,
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: originDeviceID
        )
    }

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-pending-changes.json")
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeMyRAMSyncTransport: MyRAMSyncTransporting {
    var connectedPeers: [MCPeerID]
    private(set) var sentLegacyEnvelopes: [SyncEnvelope] = []
    private(set) var sentBatchEnvelopes: [SyncBatchEnvelope] = []

    init(connectedPeers: [MCPeerID]) {
        self.connectedPeers = connectedPeers
    }

    func invite(_ peerID: MCPeerID, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        connectedPeers
    }

    func send(_ data: Data, toPeers peers: [MCPeerID], mode: MCSessionSendDataMode) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        switch message.kind {
        case .legacySyncEnvelope:
            sentLegacyEnvelopes.append(try JSONDecoder().decode(SyncEnvelope.self, from: message.payload))
        case .batchSync:
            sentBatchEnvelopes.append(try JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload))
        }
    }
}
