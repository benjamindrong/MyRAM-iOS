import MultipeerConnectivity
import NearbySyncCore
import SwiftData
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
            return changes.map { LegacyIncomingChangeResult(changeID: $0.id, disposition: .applied) }
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

    func testRetryRequiredLegacyCandidateIsNotAcknowledgedOrMarkedHandledAndRedelivers() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        let incomingChange = makeChange(entityID: "remote-note", originDeviceID: "remote-device")
        var deliveryCount = 0
        controller.onChangesReceived = { changes in
            deliveryCount += changes.count
            return changes.map {
                LegacyIncomingChangeResult(
                    changeID: $0.id,
                    disposition: deliveryCount < 3 ? .retryRequired : .applied
                )
            }
        }

        let envelope = SyncEnvelope(senderDeviceID: "remote-device", changes: [incomingChange])
        await deliverLegacyEnvelope(to: controller, envelope)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty)

        await deliverLegacyEnvelope(to: controller, envelope)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty)

        await deliverLegacyEnvelope(to: controller, envelope)
        await waitUntil { transport.sentLegacyEnvelopes.count == 1 }
        XCTAssertEqual(deliveryCount, 3)
        XCTAssertEqual(transport.sentLegacyEnvelopes.last?.acknowledgedChangeIDs, [incomingChange.id])

        transport.removeAllSentLegacyEnvelopes()
        await deliverLegacyEnvelope(to: controller, envelope)
        await waitUntil { transport.sentLegacyEnvelopes.count == 1 }
        XCTAssertEqual(deliveryCount, 3, "engine-proven duplicates must not re-enter the app callback")
        XCTAssertEqual(transport.sentLegacyEnvelopes.last?.acknowledgedChangeIDs, [incomingChange.id])
    }

    func testPartialLegacyEnvelopeAcknowledgesOnlyAppliedCandidate() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        let appliedChange = makeChange(entityID: "remote-note-1", originDeviceID: "remote-device")
        let retryChange = makeChange(entityID: "remote-note-2", originDeviceID: "remote-device")
        var receivedBatches: [[UUID]] = []
        controller.onChangesReceived = { changes in
            receivedBatches.append(changes.map(\.id))
            return changes.map {
                LegacyIncomingChangeResult(
                    changeID: $0.id,
                    disposition: $0.id == appliedChange.id ? .applied : .retryRequired
                )
            }
        }

        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [appliedChange, retryChange])
        )
        await waitUntil { transport.sentLegacyEnvelopes.count == 1 }

        XCTAssertEqual(transport.sentLegacyEnvelopes.last?.acknowledgedChangeIDs, [appliedChange.id])
        XCTAssertEqual(receivedBatches.map(Set.init), [Set([appliedChange.id, retryChange.id])])

        transport.removeAllSentLegacyEnvelopes()
        controller.onChangesReceived = { changes in
            receivedBatches.append(changes.map(\.id))
            return changes.map { LegacyIncomingChangeResult(changeID: $0.id, disposition: .applied) }
        }
        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [appliedChange, retryChange])
        )
        await waitUntil { transport.sentLegacyEnvelopes.count == 1 }

        XCTAssertEqual(
            receivedBatches.map(Set.init),
            [Set([appliedChange.id, retryChange.id]), Set([retryChange.id])]
        )
        XCTAssertEqual(Set(transport.sentLegacyEnvelopes.last?.acknowledgedChangeIDs ?? []), Set([appliedChange.id, retryChange.id]))
    }

    func testUnknownLegacyDispositionResultFailsClosed() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        let incomingChange = makeChange(entityID: "remote-note", originDeviceID: "remote-device")
        var deliveryCount = 0
        controller.onChangesReceived = { _ in
            deliveryCount += 1
            return [LegacyIncomingChangeResult(changeID: UUID(), disposition: .applied)]
        }

        let envelope = SyncEnvelope(senderDeviceID: "remote-device", changes: [incomingChange])
        await deliverLegacyEnvelope(to: controller, envelope)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty)

        await deliverLegacyEnvelope(to: controller, envelope)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty)
    }

    func testHandledCommitFailurePreventsLegacyAcknowledgement() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let blockedDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data().write(to: blockedDirectoryURL)
        let controller = try makeController(
            pendingChangesFileURL: blockedDirectoryURL.appendingPathComponent("sync-pending-changes.json"),
            transport: transport
        )
        controller.onChangesReceived = { changes in
            changes.map { LegacyIncomingChangeResult(changeID: $0.id, disposition: .applied) }
        }

        await deliverLegacyEnvelope(
            to: controller,
            SyncEnvelope(senderDeviceID: "remote-device", changes: [makeChange(entityID: "remote-note", originDeviceID: "remote-device")])
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(transport.sentLegacyEnvelopes.isEmpty)
        XCTAssertEqual(controller.lastErrorMessage, "Unable to confirm nearby sync.")
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

    func testLegacyFlushRequestedDuringActiveSendRunsFollowUpWithoutOverlap() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        transport.suspendLegacySends = true
        let controller = try makeController(transport: transport)

        controller.recordLocalChange(
            entityType: .item,
            entityID: "note-1",
            payload: Data("payload-1".utf8),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await waitUntil { controller.pendingChangeCount == 1 }
        controller.flushPendingChanges()
        await waitUntil { transport.hasSuspendedLegacySend }

        controller.recordLocalChange(
            entityType: .item,
            entityID: "note-2",
            payload: Data("payload-2".utf8),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        await waitUntil { controller.pendingChangeCount == 2 }
        controller.flushPendingChanges()

        XCTAssertEqual(transport.maximumConcurrentLegacySends, 1)

        transport.suspendLegacySends = false
        transport.resumeNextLegacySend()
        await waitUntil { transport.sentLegacyEnvelopes.count == 2 }

        XCTAssertEqual(transport.maximumConcurrentLegacySends, 1)
        XCTAssertTrue(
            transport.sentLegacyEnvelopes.last?.changes.contains(where: { $0.entityID == "note-2" }) == true,
            "the request remembered during the active send should produce a follow-up envelope"
        )
    }

    func testRecoverySuspendedBatchRequestFlushesOnceOnResume() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let batch = makeBatch(idSuffix: 199)

        controller.suspendOutboundForRecovery()
        try await controller.acceptLocalBatch(batch)

        XCTAssertTrue(transport.sentBatchEnvelopes.isEmpty)
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)

        controller.resumeOutboundAfterRecovery()
        await waitUntil { transport.sentBatchEnvelopes.count == 1 }

        XCTAssertEqual(transport.sentBatchEnvelopes.map(\.batch), [batch])
        // Sent, but not yet acknowledged: the batch must stay durable until the
        // peer confirms receipt, otherwise a send followed immediately by
        // termination would silently drop it.
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)

        await deliverBatchAcknowledgement(to: controller, batchID: batch.id)
        await waitUntil { controller.pendingSyncStatus.unsentBatches == 0 }
    }

    func testManualSyncFlushesUnsentBatchQueue() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(transport: transport)
        let batch = makeBatch(idSuffix: 201)

        try await controller.acceptLocalBatch(batch)
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)

        transport.connectedPeers = [Self.remotePeerID]
        controller.flushPendingChanges()

        await waitUntil { !transport.sentBatchEnvelopes.isEmpty }
        XCTAssertEqual(transport.sentBatchEnvelopes.map(\.batch), [batch])
        // Sent, but not yet acknowledged: still durably queued.
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)

        await deliverBatchAcknowledgement(to: controller, batchID: batch.id)
        await waitUntil { controller.unsentBatchQueueSnapshot().pendingBatches.isEmpty }
        await waitUntil { controller.pendingSyncStatus.unsentBatches == 0 }
    }

    func testDisconnectedAcceptLocalBatchRefreshesUnsentStatusBeforeReturning() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let batch = makeBatch(idSuffix: 204)

        try await controller.acceptLocalBatch(batch)

        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)
        XCTAssertEqual(controller.pendingSyncStatus.totalOutboundItems, 1)
    }

    func testRecoverySuspendedAcceptLocalBatchThrowsWhenDurableEnqueueFails() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let batch = makeBatch(idSuffix: 202)

        controller.suspendOutboundForRecovery()
        controller.injectUnsentBatchPersistenceFailureForNextWrite()

        do {
            try await controller.acceptLocalBatch(batch)
            XCTFail("Expected durable enqueue failure to propagate")
        } catch {
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }

        XCTAssertTrue(controller.unsentBatchQueueSnapshot().pendingBatches.isEmpty)
        XCTAssertTrue(
            controller.pendingSyncStatus.healthIssues.contains {
                $0.domain == .unsentBatches
            },
            "unsent queue persistence failures should surface in aggregate status immediately"
        )
    }

    // Regression test for MYR-165: a `session.send()` call that doesn't throw only
    // means the framework accepted the bytes, not that the peer received them. If
    // the queue were cleared right after a successful send (the old behavior),
    // terminating the app in the gap between "sent" and "acknowledged" would
    // silently and permanently lose the batch. It must stay durable until acked.
    func testSentBatchIsNotRemovedFromQueueWithoutAcknowledgement() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let batch = makeBatch(idSuffix: 203)

        try await controller.acceptLocalBatch(batch)

        XCTAssertEqual(transport.sentBatchEnvelopes.map(\.batch), [batch])
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [batch])
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 1)
    }

    func testAcknowledgementRemovesOnlyMatchingBatchFromUnsentQueue() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let firstBatch = makeBatch(idSuffix: 206)
        let secondBatch = makeBatch(idSuffix: 207)

        try await controller.acceptLocalBatch(firstBatch)
        try await controller.acceptLocalBatch(secondBatch)
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 2)

        await deliverBatchAcknowledgement(to: controller, batchID: firstBatch.id)

        await waitUntil { controller.pendingSyncStatus.unsentBatches == 1 }
        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches, [secondBatch])
    }

    func testIncomingBatchSyncSendsAcknowledgementWhenDurablyCaptured() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        controller.onDurablyCaptureIncomingBatch = { _ in true }
        let batch = makeBatch(idSuffix: 208)

        await deliverBatchSync(to: controller, batch)

        await waitUntil { !transport.sentBatchAcknowledgements.isEmpty }
        XCTAssertEqual(transport.sentBatchAcknowledgements, [SyncBatchAcknowledgement(batchID: batch.id)])
    }

    func testIncomingBatchSyncDoesNotAcknowledgeWhenNotDurablyCaptured() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        controller.onDurablyCaptureIncomingBatch = { _ in false }
        let batch = makeBatch(idSuffix: 209)

        await deliverBatchSync(to: controller, batch)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(transport.sentBatchAcknowledgements.isEmpty)
    }

    func testAnchoredLocalBatchRejectsBeforeQueueOrTransportMutation() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let batch = try makeAnchoredInsertBatchForTest()

        do {
            try await controller.acceptLocalBatch(batch)
            XCTFail("Expected anchored local admission to fail")
        } catch {
            XCTAssertEqual(
                error as? SyncBatchAnchoredPayloadPolicyError,
                .anchoredPayloadDisabled(
                    boundary: .outboundController,
                    noteID: batch.changes[0].noteID
                )
            )
        }

        XCTAssertTrue(controller.unsentBatchQueueSnapshot().pendingBatches.isEmpty)
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 0)
        XCTAssertTrue(transport.sentBatchEnvelopes.isEmpty)
        XCTAssertNil(controller.lastSyncAt)
    }

    func testDirectlyEncodedInboundAnchoredBatchRejectsBeforeCallbacksAndAck() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [Self.remotePeerID])
        let controller = try makeController(transport: transport)
        let batch = try makeAnchoredInsertBatchForTest()
        var durableCaptureCount = 0
        var receiveCount = 0
        controller.onDurablyCaptureIncomingBatch = { _ in
            durableCaptureCount += 1
            return true
        }
        controller.onBatchReceived = { _ in receiveCount += 1 }

        let data = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: JSONEncoder().encode(SyncBatchEnvelope(batch: batch))
        )
        let dummySession = MCSession(peer: MCPeerID(displayName: "local|local-device"))
        controller.session(dummySession, didReceive: data, fromPeer: Self.remotePeerID)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(durableCaptureCount, 0)
        XCTAssertEqual(receiveCount, 0)
        XCTAssertTrue(transport.sentBatchAcknowledgements.isEmpty)
        XCTAssertEqual(controller.pendingSyncStatus.unsentBatches, 0)
        XCTAssertNil(controller.lastSyncAt)
    }

    func testLocalConvergenceReplacementRefreshesAggregateStatusImmediately() async throws {
        let transport = FakeMyRAMSyncTransport(connectedPeers: [])
        let controller = try makeController(
            unsentBatchQueueFileURL: temporaryQueueFileURL(),
            transport: transport
        )
        let container = try makeContainer()
        let viewModel = NotesViewModel(
            context: container.mainContext,
            syncController: controller,
            pendingIncomingBatchQueueFileURL: temporaryQueueFileURL(),
            pendingLocalConvergenceBatchQueueFileURL: temporaryQueueFileURL(),
            resumesPendingConvergenceOnInit: false
        )

        try await viewModel.replaceLocalConvergenceBatches([makeBatch(idSuffix: 205)])

        XCTAssertEqual(controller.pendingSyncStatus.localConvergenceObligations, 1)
        XCTAssertEqual(controller.pendingSyncStatus.totalOutboundItems, 1)

        try await viewModel.replaceLocalConvergenceBatches([])

        XCTAssertEqual(controller.pendingSyncStatus.localConvergenceObligations, 0)
        XCTAssertEqual(controller.pendingSyncStatus.totalOutboundItems, 0)
    }

    // MARK: - Helpers

    private static let remotePeerID = MCPeerID(displayName: "Remote|remote-device")

    private func makeController(
        unsentBatchQueueFileURL: URL? = nil,
        pendingChangesFileURL: URL? = nil,
        transport: FakeMyRAMSyncTransport
    ) throws -> MyRAMSyncController {
        MyRAMSyncController(
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            pendingChangesFileURL: pendingChangesFileURL ?? temporaryQueueFileURL(),
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

    private func deliverBatchSync(to controller: MyRAMSyncController, _ batch: SyncBatch) async {
        let data = try! MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: batch))
        let dummySession = MCSession(peer: MCPeerID(displayName: "local|local-device"))
        controller.session(dummySession, didReceive: data, fromPeer: Self.remotePeerID)
        await Task.yield()
    }

    private func deliverBatchAcknowledgement(to controller: MyRAMSyncController, batchID: SyncBatchID) async {
        let data = try! MultipeerSyncMessageCoding.encode(
            kind: .batchAcknowledgement,
            payload: JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
        )
        let dummySession = MCSession(peer: MCPeerID(displayName: "local|local-device"))
        controller.session(dummySession, didReceive: data, fromPeer: Self.remotePeerID)
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

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-pending-changes.json")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MyRAMSyncControllerTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
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
    var suspendLegacySends = false
    private(set) var sentLegacyEnvelopes: [SyncEnvelope] = []
    private(set) var sentBatchEnvelopes: [SyncBatchEnvelope] = []
    private(set) var sentBatchAcknowledgements: [SyncBatchAcknowledgement] = []
    private(set) var activeLegacySendCount = 0
    private(set) var maximumConcurrentLegacySends = 0
    private var suspendedLegacySendContinuations: [CheckedContinuation<Void, Never>] = []

    var hasSuspendedLegacySend: Bool {
        !suspendedLegacySendContinuations.isEmpty
    }

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
            activeLegacySendCount += 1
            maximumConcurrentLegacySends = max(maximumConcurrentLegacySends, activeLegacySendCount)
            sentLegacyEnvelopes.append(try JSONDecoder().decode(SyncEnvelope.self, from: message.payload))
            if suspendLegacySends {
                await withCheckedContinuation { continuation in
                    suspendedLegacySendContinuations.append(continuation)
                }
            }
            activeLegacySendCount -= 1
        case .batchSync:
            sentBatchEnvelopes.append(try JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload))
        case .batchAcknowledgement:
            sentBatchAcknowledgements.append(try JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload))
        }
    }

    func resumeNextLegacySend() {
        guard !suspendedLegacySendContinuations.isEmpty else { return }
        suspendedLegacySendContinuations.removeFirst().resume()
    }

    func removeAllSentLegacyEnvelopes() {
        sentLegacyEnvelopes.removeAll()
    }
}
