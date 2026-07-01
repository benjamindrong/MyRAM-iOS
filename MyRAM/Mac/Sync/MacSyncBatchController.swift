#if os(macOS)
import Foundation
@preconcurrency import MultipeerConnectivity
import SwiftData

struct MacSyncDiscoveredPeer: Identifiable, Equatable {
    let peerID: MCPeerID
    let deviceID: String
    let displayName: String

    var id: String { deviceID }
}

@MainActor
final class MacSyncBatchController: NSObject, ObservableObject {
    @Published private(set) var availablePeers: [MacSyncDiscoveredPeer] = []
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var lastConnectionEvent = "Browsing for nearby MyRAM devices"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncAt: Date?

    var onBatchApplied: (() -> Void)?

    private let serviceType = "myram-sync"
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let accumulator: MacSyncBatchAccumulator
    private var readyBatchTask: Task<Void, Never>?
    private var unsentBatches = SyncBatchUnsentQueue()

    override init() {
        let identity = MacSyncDeviceIdentityProvider().currentIdentity()
        peerID = MCPeerID(displayName: "\(identity.displayName)|\(identity.id.uuidString)")
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        accumulator = MacSyncBatchAccumulator(originDeviceID: identity.id)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()

        readyBatchTask = Task { [weak self, accumulator] in
            let stream = await accumulator.readyBatches()
            for await batch in stream {
                await self?.send(batch)
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
        !session.connectedPeers.isEmpty
    }

    func invite(_ peer: MacSyncDiscoveredPeer) {
        lastConnectionEvent = "Inviting \(peer.displayName)"
        browser.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 12)
    }

    func record(_ change: MacSyncChange) {
        Task {
            await accumulator.record(change)
        }
    }

    func flushPendingBatch() {
        Task {
            await accumulator.emitReadyBatches(at: .now)
            await flushUnsentBatches()
        }
    }

    private func send(_ batch: MacSyncBatch) async {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            enqueueUnsent(batch)
            return
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: batch))
            try session.send(data, toPeers: peers, with: .reliable)
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
        } catch {
            enqueueUnsent(batch)
            lastErrorMessage = "Unable to sync nearby batch changes."
        }
    }

    private func flushUnsentBatches() async {
        guard !session.connectedPeers.isEmpty, !unsentBatches.isEmpty else { return }

        for batch in unsentBatches.drain() {
            await send(batch)
        }
    }

    private func enqueueUnsent(_ batch: MacSyncBatch) {
        unsentBatches.enqueue(batch)
    }

    private func receive(_ batch: MacSyncBatch) {
        do {
            try MacSyncBatchApplier(context: PersistenceManager.shared.context).apply(batch)
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
            onBatchApplied?()
        } catch {
            lastErrorMessage = "Unable to apply nearby batch changes."
        }
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
}

extension MacSyncBatchController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
            lastConnectionEvent = "\(state.syncDescription): \(displayName(for: peerID))"
            if state == .connected {
                remember(peerID)
                await flushUnsentBatches()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                  message.canDecodeWithCurrentSchema,
                  message.kind == .batchSync,
                  let envelope = try? JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload),
                  envelope.canDecodeWithCurrentSchema else { return }
            receive(envelope.batch)
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
