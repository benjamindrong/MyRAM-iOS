import AnchoredSequenceCore
@preconcurrency import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchControllerTests: XCTestCase {

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

    func testManualResendRetainsExactBatchUntilRealReceiverRedeliveryAcknowledgement() async throws {
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
        let noteB = Note(title: "Redelivery target", content: "B0")
        noteB.id = UUID(uuidString: "17800000-0000-0000-0000-000000000242")!
        receiverContext.insert(noteA)
        receiverContext.insert(noteB)
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

        receiver.session(
            receiverSession,
            didReceive: try MultipeerSyncMessageCoding.encodeBatch(batchA),
            fromPeer: senderPeerID
        )
        await fulfillment(of: [boundaryReached], timeout: 1)

        try await sender.acceptLocalBatch(batchB)
        await waitUntil { senderSends.count == 1 }
        receiver.session(receiverSession, didReceive: senderSends[0], fromPeer: senderPeerID)
        await waitUntil { FileBackedSyncBatchQueue(fileURL: receiverPendingURL).contains(batchB.id) }

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
            receiver.lastSyncAt == batchA.createdAt
        }
        XCTAssertEqual(noteB.content, "B0-once")
        XCTAssertEqual(receiver.lastSyncAt, batchA.createdAt)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: senderUnsentURL).pendingBatches, [batchB])

        sender.flushPendingBatch()
        await waitUntil { senderSends.count == 2 }
        let resentBatches = try senderSends.map { data in
            let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
            return try MultipeerSyncMessageCoding.decodeBatchPayload(message.payload).batch
        }
        XCTAssertEqual(resentBatches, [batchB, batchB])
        receiver.session(receiverSession, didReceive: senderSends[1], fromPeer: senderPeerID)
        await waitUntil {
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
        XCTAssertEqual(receiver.lastSyncAt, batchB.createdAt)
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
            connectedPeersProvider: nil,
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

    func testConnectedAnchoredLocalBatchRejectsBeforeQueueOrTransportMutation() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let remotePeerID = MCPeerID(displayName: "remote|anchored-outbound")
        let queue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        let beforeSnapshot = queue.snapshot()
        let beforePendingCount = queue.pendingCount
        let beforeBytes = try dataIfPresent(at: unsentURL)
        var recordedSends: [Data] = []
        let controller = try makeController(
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: queue,
            connectedPeersProvider: { [remotePeerID] },
            sendBatchDataOperation: { data, _, _ in recordedSends.append(data) }
        )
        let batch = try makeAnchoredBatch()
        let lastSyncAtBefore = controller.lastSyncAt

        XCTAssertTrue(controller.hasConnectedPeers)

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

        XCTAssertTrue(recordedSends.isEmpty)
        XCTAssertEqual(queue.snapshot(), beforeSnapshot)
        XCTAssertEqual(queue.pendingCount, beforePendingCount)
        XCTAssertEqual(try dataIfPresent(at: unsentURL), beforeBytes)
        XCTAssertEqual(controller.lastSyncAt, lastSyncAtBefore)
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
        XCTAssertTrue(macAppSources.contains("MacSyncBatchApplier.swift in Sources"))
        XCTAssertTrue(macTestSources.contains("MacSyncBatchApplierTests.swift in Sources"))
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

    private func makeController(unsentBatchQueueFileURL: URL?) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: unsentBatchQueueFileURL, unsentBatchQueue: nil)
    }

    private func makeController(unsentBatchQueue: FileBackedSyncBatchQueue) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: nil, unsentBatchQueue: unsentBatchQueue)
    }

    private func makeController(
        unsentBatchQueueFileURL: URL?,
        unsentBatchQueue: FileBackedSyncBatchQueue?,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil
    ) throws -> MacSyncBatchController {
        MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            unsentBatchQueue: unsentBatchQueue,
            startsNetworking: false,
            connectedPeersProvider: connectedPeersProvider,
            sendBatchDataOperation: sendBatchDataOperation
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

    private func makeAnchoredBatch() throws -> SyncBatch {
        let deviceID = UUID(uuidString: "17100000-0000-0000-0000-0000000000BB")!
        let state = try SyncTextSequenceState(runs: [], fragments: [])
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: UUID(uuidString: "17100000-0000-0000-0000-0000000000BC")!,
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_710),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(deviceID: deviceID, localCounter: 1),
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
            reloadSelectedEditor: { _, _ in true },
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
}
