#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one preimage, found {count}: {old[:100]!r}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_region(path: str, start: str, end: str, replacement: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if text.count(start) != 1 or text.count(end) != 1:
        raise SystemExit(f"{path}: non-unique region anchors")
    a = text.index(start)
    b = text.index(end, a)
    p.write_text(text[:a] + replacement + text[b:], encoding="utf-8")


replace_once(
    "MyRAM/Sync/Batch/SyncBatchEnvelope.swift",
    "struct SyncBatchAcknowledgement: Codable, Equatable, Sendable {\n    let batchID: SyncBatchID\n}\n",
    """struct SyncBatchAcknowledgement: Codable, Equatable, Sendable {
    let batchID: SyncBatchID
}

struct SyncBatchAcknowledgementOutbox: Equatable, Sendable {
    private var batchIDsByPeerDeviceID: [String: [SyncBatchID]] = [:]

    mutating func enqueue(_ batchID: SyncBatchID, forPeerDeviceID peerDeviceID: String) {
        var pending = batchIDsByPeerDeviceID[peerDeviceID] ?? []
        guard !pending.contains(batchID) else { return }
        pending.append(batchID)
        batchIDsByPeerDeviceID[peerDeviceID] = pending
    }

    func pendingBatchIDs(forPeerDeviceID peerDeviceID: String) -> [SyncBatchID] {
        batchIDsByPeerDeviceID[peerDeviceID] ?? []
    }

    mutating func remove(_ batchID: SyncBatchID, forPeerDeviceID peerDeviceID: String) {
        guard var pending = batchIDsByPeerDeviceID[peerDeviceID] else { return }
        pending.removeAll { $0 == batchID }
        if pending.isEmpty {
            batchIDsByPeerDeviceID.removeValue(forKey: peerDeviceID)
        } else {
            batchIDsByPeerDeviceID[peerDeviceID] = pending
        }
    }
}
""",
)

replace_once(
    "MyRAM/Sync/MyRAMSyncModels.swift",
    "    case batchConvergenceCompleted\n    case batchAcknowledgementSent\n    case batchAcknowledgementSendFailed\n",
    "    case batchConvergenceCompleted\n    case batchAcknowledgementDeferred\n    case batchAcknowledgementSent\n    case batchAcknowledgementSendFailed\n",
)

ios = "MyRAM/Sync/MyRAMSyncController.swift"
replace_once(
    ios,
    "    private let unsentBatches: FileBackedSyncBatchQueue\n    private var isFlushingLegacy = false\n",
    "    private let unsentBatches: FileBackedSyncBatchQueue\n    private var acknowledgementOutbox = SyncBatchAcknowledgementOutbox()\n    private var isFlushingLegacy = false\n",
)
replace_region(
    ios,
    "    private func sendBatchAcknowledgement(batchID: SyncBatchID, to peerID: MCPeerID) async {\n",
    "    private func enqueueIncomingBatch(_ batch: SyncBatch, from peerID: MCPeerID) {\n",
    """    private func enqueueBatchAcknowledgement(
        batchID: SyncBatchID,
        peerDeviceID: String
    ) async {
        acknowledgementOutbox.enqueue(batchID, forPeerDeviceID: peerDeviceID)
        await flushBatchAcknowledgements(forPeerDeviceID: peerDeviceID)
    }

    private func flushBatchAcknowledgements(forPeerDeviceID peerDeviceID: String) async {
        let connectedPeers = await transport.connectedPeers()
        guard let peerID = connectedPeers.first(where: {
            MyRAMPeerIdentity(peerID: $0).deviceID == peerDeviceID
        }) else {
            for batchID in acknowledgementOutbox.pendingBatchIDs(forPeerDeviceID: peerDeviceID) {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchAcknowledgementDeferred,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID,
                    outcome: "peerNotConnected"
                )
            }
            return
        }

        for batchID in acknowledgementOutbox.pendingBatchIDs(forPeerDeviceID: peerDeviceID) {
            do {
                let payload = try JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
                let data = try MultipeerSyncMessageCoding.encode(
                    kind: .batchAcknowledgement,
                    payload: payload
                )
                try await transport.send(data, toPeers: [peerID], mode: .reliable)
                acknowledgementOutbox.remove(batchID, forPeerDeviceID: peerDeviceID)
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchAcknowledgementSent,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID
                )
            } catch {
                let peerStillConnected = await transport.connectedPeers().contains {
                    MyRAMPeerIdentity(peerID: $0).deviceID == peerDeviceID
                }
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    peerStillConnected ? .batchAcknowledgementSendFailed : .batchAcknowledgementDeferred,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID,
                    outcome: peerStillConnected ? "transportFailed" : "peerDisconnectedDuringSend"
                )
                return
            }
        }
    }

""",
)
replace_once(
    ios,
    "                    await sendBatchAcknowledgement(batchID: work.batch.id, to: work.peerID)\n",
    "                    await enqueueBatchAcknowledgement(\n                        batchID: work.batch.id,\n                        peerDeviceID: peerDeviceID\n                    )\n",
)
replace_once(
    ios,
    "                rememberTrustedPeer(peerID)\n                await sendBootstrapCapabilityAnnouncement(to: peerID)\n",
    "                rememberTrustedPeer(peerID)\n                await flushBatchAcknowledgements(forPeerDeviceID: identity.deviceID)\n                await sendBootstrapCapabilityAnnouncement(to: peerID)\n",
)

mac = "MyRAM/Mac/Sync/MacSyncBatchController.swift"
replace_once(
    mac,
    "    private let unsentBatches: FileBackedSyncBatchQueue\n    private let legacyReceiver: MacLegacySyncReceiver\n",
    "    private let unsentBatches: FileBackedSyncBatchQueue\n    private var acknowledgementOutbox = SyncBatchAcknowledgementOutbox()\n    private let legacyReceiver: MacLegacySyncReceiver\n",
)
replace_region(
    mac,
    "    private func sendBatchAcknowledgement(batchID: SyncBatchID, to peerID: MCPeerID) throws {\n",
    "    private func beginBootstrap(to peerID: MCPeerID) async {\n",
    """    private func enqueueBatchAcknowledgement(
        batchID: SyncBatchID,
        peerDeviceID: String
    ) {
        acknowledgementOutbox.enqueue(batchID, forPeerDeviceID: peerDeviceID)
        flushBatchAcknowledgements(forPeerDeviceID: peerDeviceID)
    }

    private func flushBatchAcknowledgements(forPeerDeviceID peerDeviceID: String) {
        let connectedPeers = connectedPeersProvider()
        guard let peerID = connectedPeers.first(where: {
            MacSyncPeerIdentity(peerID: $0).deviceID == peerDeviceID
        }) else {
            for batchID in acknowledgementOutbox.pendingBatchIDs(forPeerDeviceID: peerDeviceID) {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchAcknowledgementDeferred,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID,
                    outcome: "peerNotConnected"
                )
            }
            return
        }

        for batchID in acknowledgementOutbox.pendingBatchIDs(forPeerDeviceID: peerDeviceID) {
            do {
                let payload = try JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
                let data = try MultipeerSyncMessageCoding.encode(
                    kind: .batchAcknowledgement,
                    payload: payload
                )
                try sendBatchDataOperation(data, [peerID], .reliable)
                acknowledgementOutbox.remove(batchID, forPeerDeviceID: peerDeviceID)
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchAcknowledgementSent,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID
                )
            } catch {
                let peerStillConnected = connectedPeersProvider().contains {
                    MacSyncPeerIdentity(peerID: $0).deviceID == peerDeviceID
                }
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    peerStillConnected ? .batchAcknowledgementSendFailed : .batchAcknowledgementDeferred,
                    batchID: String(describing: batchID),
                    peerDeviceID: peerDeviceID,
                    outcome: peerStillConnected ? "transportFailed" : "peerDisconnectedDuringSend"
                )
                return
            }
        }
    }

""",
)
replace_once(
    mac,
    "                    try? sendBatchAcknowledgement(batchID: work.batch.id, to: work.peerID)\n",
    "                    enqueueBatchAcknowledgement(\n                        batchID: work.batch.id,\n                        peerDeviceID: peerDeviceID\n                    )\n",
)
replace_once(
    mac,
    "                remember(peerID)\n                sendBootstrapCapabilityAnnouncement(to: peerID)\n",
    "                remember(peerID)\n                flushBatchAcknowledgements(forPeerDeviceID: identity.deviceID)\n                sendBootstrapCapabilityAnnouncement(to: peerID)\n",
)

ios_test = "MyRAMTests/SyncBatchEnvelopeV2Tests.swift"
ios_marker = "    func testControllerRecordsTransportFailureWithoutSuccess() async throws {\n"
ios_test_body = """    func testControllerDefersPermittedAcknowledgementUntilPeerReconnects() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .iOS,
            deviceID: "local-ios",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|ack-reconnect-peer")
        let transport = BenchmarkRecordingTransport(connectedPeers: [])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: directory.appendingPathComponent("unsent-ack-reconnect.json"),
            pendingChangesFileURL: directory.appendingPathComponent("legacy-ack-reconnect.json"),
            startsNetworking: false,
            transport: transport
        )
        controller.onDurablyCaptureIncomingBatch = { _ in true }
        controller.onBatchReceived = { _ in .acknowledgementPermitted }
        let batch = makeBatch(idSuffix: 2301)
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-ios"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: peer)
        let batchID = String(describing: batch.id)
        await waitUntil {
            guard let recordedEvents = try? self.events(from: recorder) else { return false }
            return recordedEvents.contains {
                $0.eventType == .batchAcknowledgementDeferred &&
                $0.batchID == batchID &&
                $0.peerDeviceID == "ack-reconnect-peer" &&
                $0.outcome == "peerNotConnected"
            }
        }
        XCTAssertTrue(transport.sentBatchAcknowledgements.isEmpty)
        XCTAssertFalse(try events(from: recorder).contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })

        transport.connectedPeers = [peer]
        controller.session(dummySession, peer: peer, didChange: .connected)
        await waitUntil { transport.sentBatchAcknowledgements.count == 1 }

        XCTAssertEqual(
            transport.sentBatchAcknowledgements,
            [SyncBatchAcknowledgement(batchID: batch.id)]
        )
        let finalEvents = try events(from: recorder)
        XCTAssertTrue(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSent &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "ack-reconnect-peer"
        })
        XCTAssertFalse(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })
    }

"""
replace_once(ios_test, ios_marker, ios_test_body + ios_marker)

mac_test = "MyRAMMacTests/MacSyncDeviceIdentityTests.swift"
mac_marker = "    func testControllerRecordsTransportFailureWithoutSuccess() async throws {\n"
mac_test_body = """    func testControllerDefersPermittedAcknowledgementUntilPeerReconnects() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "local-mac",
            runID: "ack-reconnect",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|ack-reconnect-peer")
        let container = try makeContainer()
        var connectedPeers: [MCPeerID] = []
        var sends: [Data] = []
        let controller = MacSyncBatchController(
            context: container.mainContext,
            unsentBatchQueueFileURL: directory.appendingPathComponent("unsent-ack-reconnect.json"),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "23000000-0000-0000-0000-000000000012")!,
                    displayName: "Telemetry Mac"
                )
            },
            connectedPeersProvider: { connectedPeers },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in
                    EditorRemoteBatchApplyResult(
                        appliedCount: 0,
                        disposition: .noApplicableMutations
                    )
                },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: directory.appendingPathComponent("pending-ack-reconnect.json"),
            localObligationQueueFileURL: directory.appendingPathComponent("obligations-ack-reconnect.json")
        )
        _ = coordinator
        let note = Note(title: "ACK reconnect fixture", content: "")
        note.id = UUID(uuidString: "23000000-0000-0000-0000-000000000030")!
        container.mainContext.insert(note)
        try container.mainContext.save()
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002301")!,
            originDeviceID: UUID(uuidString: "23000000-0000-0000-0000-000000000020")!,
            createdAt: Date(timeIntervalSince1970: 2_301),
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: note.id,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: Date(timeIntervalSince1970: 2_301),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                ))
            ]
        )
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-mac"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: peer)
        let batchID = String(describing: batch.id)
        await waitUntil {
            guard let recordedEvents = try? self.events(from: recorder) else { return false }
            return recordedEvents.contains {
                $0.eventType == .batchAcknowledgementDeferred &&
                $0.batchID == batchID &&
                $0.peerDeviceID == "ack-reconnect-peer" &&
                $0.outcome == "peerNotConnected"
            }
        }
        XCTAssertTrue(sends.isEmpty)
        XCTAssertFalse(try events(from: recorder).contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })

        connectedPeers = [peer]
        controller.session(dummySession, peer: peer, didChange: .connected)
        await waitUntil {
            sends.contains { data in
                (try? MultipeerSyncMessageCoding.decodeMessage(from: data).kind)
                    == .batchAcknowledgement
            }
        }

        let acknowledgements = try sends.compactMap { data -> SyncBatchAcknowledgement? in
            let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
            guard message.kind == .batchAcknowledgement else { return nil }
            return try JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload)
        }
        XCTAssertEqual(acknowledgements, [SyncBatchAcknowledgement(batchID: batch.id)])
        let finalEvents = try events(from: recorder)
        XCTAssertTrue(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSent &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "ack-reconnect-peer"
        })
        XCTAssertFalse(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })
    }

"""
replace_once(mac_test, mac_marker, mac_test_body + mac_marker)
