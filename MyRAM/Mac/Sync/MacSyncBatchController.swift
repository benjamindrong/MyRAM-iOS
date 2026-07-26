#if os(macOS)
import Foundation
@preconcurrency import MultipeerConnectivity
import NearbySyncCore
import SwiftData

struct MacSyncDiscoveredPeer: Identifiable, Equatable {
    let peerID: MCPeerID
    let deviceID: String
    let displayName: String

    var id: String { deviceID }
}

@MainActor
final class MacSyncBatchController: NSObject, ObservableObject, SyncConvergenceLocalBatchTransportAdapter {
    @Published private(set) var availablePeers: [MacSyncDiscoveredPeer] = []
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var lastConnectionEvent = "Browsing for nearby MyRAM devices"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var quarantinedWork: SyncConvergenceQuarantinedWork?

    weak var convergenceCoordinator: MacSyncConvergenceCoordinator?

    private let serviceType = "myram-sync"
    private let peerID: MCPeerID
    private let session: MCSession
    /// Keeps batch transport observable in tests without making capability policy configurable.
    private let connectedPeersProvider: () -> [MCPeerID]
    private let sendBatchDataOperation:
        (Data, [MCPeerID], MCSessionSendDataMode) throws -> Void
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let accumulator: MacSyncBatchAccumulator
    private let context: ModelContext
    private var readyBatchTask: Task<Void, Never>?
    private let unsentBatches: FileBackedSyncBatchQueue
    private let legacyReceiver: MacLegacySyncReceiver
    private let startAdvertisingOperation: () -> Void
    private let startBrowsingOperation: () -> Void
    private var hasStartedNetworking = false

    init(
        context: ModelContext,
        unsentBatchQueueFileURL: URL? = MacSyncBatchController.unsentBatchQueueFileURL(),
        unsentBatchQueue: FileBackedSyncBatchQueue? = nil,
        startsNetworking: Bool = true,
        legacyReceiver: MacLegacySyncReceiver? = nil,
        startAdvertisingOperation: (() -> Void)? = nil,
        startBrowsingOperation: (() -> Void)? = nil,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil
    ) {
        let identity = MacSyncDeviceIdentityProvider().currentIdentity()
        let retainedPeerID = MCPeerID(
            displayName: "\(identity.displayName)|\(identity.id.uuidString)"
        )
        let retainedSession = MCSession(
            peer: retainedPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        peerID = retainedPeerID
        session = retainedSession
        self.connectedPeersProvider =
            connectedPeersProvider ?? {
                retainedSession.connectedPeers
            }
        self.sendBatchDataOperation =
            sendBatchDataOperation ?? { data, peers, mode in
                try retainedSession.send(data, toPeers: peers, with: mode)
            }
        advertiser = MCNearbyServiceAdvertiser(
            peer: retainedPeerID,
            discoveryInfo: nil,
            serviceType: serviceType
        )
        browser = MCNearbyServiceBrowser(peer: retainedPeerID, serviceType: serviceType)
        accumulator = MacSyncBatchAccumulator(originDeviceID: identity.id)
        self.context = context
        unsentBatches = unsentBatchQueue ?? FileBackedSyncBatchQueue(fileURL: unsentBatchQueueFileURL)
        self.legacyReceiver = legacyReceiver ?? MacLegacySyncReceiver(context: context)
        self.startAdvertisingOperation = startAdvertisingOperation
            ?? { [advertiser] in advertiser.startAdvertisingPeer() }
        self.startBrowsingOperation = startBrowsingOperation
            ?? { [browser] in browser.startBrowsingForPeers() }

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        if startsNetworking {
            startNetworkingIfNeeded()
        }

        readyBatchTask = Task { [weak self, accumulator] in
            let stream = await accumulator.readyLocalObligations()
            for await obligation in stream {
                await self?.convergenceCoordinator?.submitLocalObligation(obligation)
            }
        }
    }

    deinit {
        readyBatchTask?.cancel()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    var connectionSummary: String {
        connectedPeers.isEmpty ? "Disconnected" : connectedPeers.joined(separator: ", ")
    }

    var hasConnectedPeers: Bool {
        !connectedPeersProvider().isEmpty
    }

    /// Starts the retained nearby-sync transports exactly once after startup migration succeeds.
    func startNetworkingIfNeeded() {
        guard !hasStartedNetworking else { return }
        hasStartedNetworking = true
        startAdvertisingOperation()
        startBrowsingOperation()
    }

    func invite(_ peer: MacSyncDiscoveredPeer) {
        lastConnectionEvent = "Inviting \(peer.displayName)"
        browser.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 12)
    }

    func record(_ capturedChanges: [SyncConvergenceCapturedLocalChange], at date: Date = .now) async {
        await accumulator.record(capturedChanges, at: date)
        await updateSequenceReservationIssue()
    }

    func record(_ capturedChange: SyncConvergenceCapturedLocalChange, at date: Date = .now) async {
        await record([capturedChange], at: date)
    }

    func recordAndTakeBoundaryObligation(
        adding capturedChanges: [SyncConvergenceCapturedLocalChange],
        affecting noteID: UUID,
        at date: Date = .now
    ) async -> SyncConvergenceLocalObligation? {
        let obligation = await accumulator.recordAndTakeBoundaryObligation(
            adding: capturedChanges,
            affecting: noteID,
            at: date
        )
        await updateSequenceReservationIssue()
        return obligation
    }

    func takePendingLocalObligationIfAffecting(noteID: UUID) async -> SyncConvergenceLocalObligation? {
        await accumulator.takePendingObligationIfAffecting(noteID: noteID)
    }

    private func updateSequenceReservationIssue() async {
        if let issue = await accumulator.takeLastSequenceReservationIssue() {
            lastErrorMessage = SyncBatchSequenceIssueDescription.message(for: issue)
        }
    }

    func flushPendingBatch() {
        Task {
            await accumulator.emitReadyBatches(at: .now)
            await flushUnsentBatches()
            await convergenceCoordinator?.resumePendingWork()
        }
    }

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        try SyncBatchAnchoredPayloadPolicy.validateOutbound(batch)
        // Durability comes first: a peer accepting a `send()` call only means the
        // data was handed to the transport, not that it survived to the other side.
        // Removal from this queue happens only once the peer acknowledges receipt
        // (see handleBatchAcknowledgement), so termination right after a send can
        // never silently drop the batch.
        do {
            try unsentBatches.enqueueDurably(batch)
        } catch {
            lastErrorMessage = "Unable to save nearby sync changes for retry."
            throw error
        }
        _ = await sendQueuedBatch(batch)
    }

    private func sendQueuedBatch(_ batch: SyncBatch) async -> Bool {
        let peers = connectedPeersProvider()
        guard !peers.isEmpty else {
            return false
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: batch))
            try sendBatchDataOperation(data, peers, .reliable)
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to sync nearby batch changes."
            return false
        }
    }

    private func flushUnsentBatches() async {
        guard !connectedPeersProvider().isEmpty, !unsentBatches.isEmpty else { return }

        for batch in unsentBatches.pendingBatches {
            _ = await sendQueuedBatch(batch)
        }
    }

    private func handleBatchAcknowledgement(_ acknowledgement: SyncBatchAcknowledgement) {
        unsentBatches.removeAll(withIDs: [acknowledgement.batchID])
    }

    private func sendBatchAcknowledgement(batchID: SyncBatchID, to peerID: MCPeerID) throws {
        let payload = try JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
        let data = try MultipeerSyncMessageCoding.encode(kind: .batchAcknowledgement, payload: payload)
        try sendBatchDataOperation(data, [peerID], .reliable)
    }

    func receive(_ batch: MacSyncBatch) {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(batch)) != nil else {
            return
        }
        Task { await convergenceCoordinator?.submitRemoteBatch(batch) }
    }

    var pendingIncomingBatchCount: Int {
        convergenceCoordinator?.pendingIncomingBatchCount ?? 0
    }

    func clearConvergenceStatus(appliedBatch batch: SyncBatch?) {
        if let batch {
            lastSyncAt = batch.createdAt
        }
        lastErrorMessage = nil
        quarantinedWork = nil
    }

    func markConvergenceWaiting() {
        lastErrorMessage = nil
    }

    func markConvergenceBlocked(_ failure: SyncBatchDrainFailure) {
        lastErrorMessage = SyncBatchDrainFailureClassifier.userMessage(for: failure)
    }

    func markConvergenceQuarantined(_ work: SyncConvergenceQuarantinedWork) {
        quarantinedWork = work
        lastErrorMessage = "Some nearby sync work is quarantined until local evidence can be inspected."
    }

    private func receiveLegacyEnvelope(_ envelope: SyncEnvelope, from peerID: MCPeerID) {
        do {
            let result = try legacyReceiver.receive(envelope)
            guard !result.acknowledgementIDs.isEmpty else { return }
            try sendLegacyAcknowledgement(ids: result.acknowledgementIDs, to: peerID)
            lastErrorMessage = nil
            lastSyncAt = Date()
        } catch {
            lastErrorMessage = "Unable to apply nearby legacy changes."
        }
    }

    private func sendLegacyAcknowledgement(ids: [UUID], to peerID: MCPeerID) throws {
        let acknowledgement = SyncEnvelope(
            senderDeviceID: MacSyncDeviceIdentityProvider().currentIdentity().id.uuidString,
            changes: [],
            acknowledgedChangeIDs: ids
        )
        let payload = try JSONEncoder().encode(acknowledgement)
        let data = try MultipeerSyncMessageCoding.encode(kind: .legacySyncEnvelope, payload: payload)
        try session.send(data, toPeers: [peerID], with: .reliable)
    }

    private func remember(_ peerID: MCPeerID) {
        let identity = MacSyncPeerIdentity(peerID: peerID)
        if !availablePeers.contains(where: { $0.deviceID == identity.deviceID }) {
            availablePeers.append(MacSyncDiscoveredPeer(peerID: peerID, deviceID: identity.deviceID, displayName: identity.displayName))
        }
    }

    private func displayName(for peerID: MCPeerID) -> String {
        MacSyncPeerIdentity(peerID: peerID).displayName
    }

    nonisolated private static func unsentBatchQueueFileURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("mac-unsent-batch-queue.json")
    }

}

extension MacSyncBatchController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
            lastConnectionEvent = "\(state.syncDescription): \(displayName(for: peerID))"
            if state == .connected {
                remember(peerID)
                await flushUnsentBatches()
                await convergenceCoordinator?.resumePendingWork()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                  message.canDecodeWithCurrentSchema else { return }

            switch message.kind {
            case .batchSync:
                guard let envelope = try? JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload),
                      envelope.canDecodeWithCurrentSchema else { return }
                guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(envelope.batch)) != nil else {
                    return
                }
                let captured = convergenceCoordinator?.durablyCaptureIncomingBatch(envelope.batch) ?? false
                receive(envelope.batch)
                if captured {
                    try? sendBatchAcknowledgement(batchID: envelope.batch.id, to: peerID)
                }
            case .legacySyncEnvelope:
                guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: message.payload) else { return }
                receiveLegacyEnvelope(envelope, from: peerID)
            case .batchAcknowledgement:
                guard let acknowledgement = try? JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload) else { return }
                handleBatchAcknowledgement(acknowledgement)
            }

            remember(peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: peerID))"
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MacSyncBatchController: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            remember(peerID)
            lastConnectionEvent = "Invitation from \(displayName(for: peerID))"
            invitationHandler(true, session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            lastConnectionEvent = "Advertising failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}

extension MacSyncBatchController: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            remember(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            let identity = MacSyncPeerIdentity(peerID: peerID)
            availablePeers.removeAll { $0.deviceID == identity.deviceID }
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            lastConnectionEvent = "Browsing failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}

private struct MacSyncPeerIdentity {
    let displayName: String
    let deviceID: String

    init(peerID: MCPeerID) {
        let parts = peerID.displayName.split(separator: "|", maxSplits: 1).map(String.init)
        displayName = parts.first ?? peerID.displayName
        deviceID = parts.count > 1 ? parts[1] : peerID.displayName
    }
}

private extension MCSessionState {
    var syncDescription: String {
        switch self {
        case .notConnected: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        @unknown default: "Unknown"
        }
    }
}
#endif
