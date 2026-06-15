import Foundation
import MultipeerConnectivity
import NearbySyncCore

@MainActor
final class MyRAMSyncController: NSObject, ObservableObject {
    @Published private(set) var availablePeers: [MyRAMDiscoveredPeer] = []
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastConnectionEvent = "Browsing for nearby MyRAM devices"

    let localPeerName: String
    var onChangesReceived: (([SyncChange]) async -> Void)?

    private let serviceType = "myram-sync"
    private let peerID: MCPeerID
    private let trustedPeerStore = UserDefaultsTrustedPeerStore(key: "myram.sync.trustedPeers")
    private let syncStore = InMemorySyncStore()
    private let syncEngine: SyncEngine
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private lazy var debouncedSender = DebouncedChangeSender { [weak self] in
        await self?.sendPendingChanges()
    }

    override init() {
        let deviceName = MyRAMDeviceIdentity.currentDisplayName()
        let storedDeviceID = MyRAMDeviceIdentity.currentDeviceID()
        let peer = MCPeerID(displayName: "\(deviceName)|\(storedDeviceID)")

        localPeerName = deviceName
        peerID = peer
        syncEngine = SyncEngine(
            deviceID: storedDeviceID,
            store: syncStore,
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: Self.pendingChangesFileURL()))
        )
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()

        Task {
            await updatePendingCount()
            await sendPendingChanges()
        }
    }

    deinit {
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

    func invite(_ peer: MyRAMDiscoveredPeer) {
        lastConnectionEvent = "Inviting \(peer.displayName)"
        browser.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 12)
    }

    func recordLocalChange(
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation = .upsert,
        payload: Data,
        updatedAt: Date
    ) {
        Task {
            _ = await syncEngine.recordLocalChange(
                entityType: entityType,
                entityID: entityID,
                operation: operation,
                payload: payload,
                updatedAt: updatedAt
            )
            await updatePendingCount()
            debouncedSender.schedule()
        }
    }

    func flushPendingChanges() {
        debouncedSender.flushNow()
    }

    private func sendPendingChanges() async {
        guard !session.connectedPeers.isEmpty else {
            await updatePendingCount()
            return
        }

        guard let envelope = await syncEngine.nextEnvelope() else {
            await updatePendingCount()
            return
        }

        do {
            let data = try JSONEncoder().encode(envelope)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            lastSyncAt = envelope.sentAt
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to sync nearby changes."
        }

        await updatePendingCount()
    }

    private func updatePendingCount() async {
        pendingChangeCount = await syncEngine.pendingChangeCount()
    }

    private func sendAcknowledgement(for changes: [SyncChange], to peerID: MCPeerID) async {
        guard !changes.isEmpty else { return }

        let envelope = SyncEnvelope(
            senderDeviceID: syncEngine.deviceID,
            changes: [],
            acknowledgedChangeIDs: changes.map(\.id)
        )

        do {
            let data = try JSONEncoder().encode(envelope)
            try session.send(data, toPeers: [peerID], with: .reliable)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to confirm nearby sync."
        }
    }

    private static func pendingChangesFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("sync-pending-changes.json")
    }

    private func rememberTrustedPeer(_ peerID: MCPeerID) {
        let identity = MyRAMPeerIdentity(peerID: peerID)
        trustedPeerStore.trust(TrustedPeer(id: identity.deviceID, displayName: identity.displayName))
        trustedPeerStore.markSeen(peerID: identity.deviceID)
        updateAvailableTrustState()
    }

    private func updateAvailableTrustState() {
        availablePeers = availablePeers.map { peer in
            var updated = peer
            updated.isTrusted = trustedPeerStore.contains(peerID: peer.deviceID)
            return updated
        }
    }

    private func displayName(for peerID: MCPeerID) -> String {
        MyRAMPeerIdentity(peerID: peerID).displayName
    }

    private func description(for state: MCSessionState) -> String {
        switch state {
        case .notConnected:
            "Not connected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        @unknown default:
            "Unknown"
        }
    }
}

extension MyRAMSyncController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            connectedPeers = session.connectedPeers.map { MyRAMPeerIdentity(peerID: $0).displayName }
            lastConnectionEvent = "\(description(for: state)): \(displayName(for: peerID))"

            if state == .connected {
                rememberTrustedPeer(peerID)
                await sendPendingChanges()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: data) else { return }
            await syncEngine.acknowledgeChanges(envelope.acknowledgedChangeIDs)
            let result = await syncEngine.applyIncomingEnvelope(envelope)
            let changesByID = Dictionary(uniqueKeysWithValues: envelope.changes.map { ($0.id, $0) })
            let appliedChanges = result.appliedChangeIDs.compactMap { changesByID[$0] }
            await onChangesReceived?(appliedChanges)
            await sendAcknowledgement(for: envelope.changes, to: peerID)
            rememberTrustedPeer(peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: peerID))"
            lastSyncAt = envelope.sentAt
            await updatePendingCount()
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

extension MyRAMSyncController: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            lastConnectionEvent = "Invitation from \(displayName(for: peerID))"
            rememberTrustedPeer(peerID)
            invitationHandler(true, session)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        Task { @MainActor in
            lastConnectionEvent = "Advertising failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}

extension MyRAMSyncController: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            let identity = MyRAMPeerIdentity(peerID: peerID)
            guard !availablePeers.contains(where: { $0.deviceID == identity.deviceID }) else { return }
            lastConnectionEvent = "Found \(identity.displayName)"

            let discoveredPeer = MyRAMDiscoveredPeer(
                peerID: peerID,
                deviceID: identity.deviceID,
                displayName: identity.displayName,
                isTrusted: trustedPeerStore.contains(peerID: identity.deviceID)
            )
            availablePeers.append(discoveredPeer)

            if discoveredPeer.isTrusted {
                invite(discoveredPeer)
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            let identity = MyRAMPeerIdentity(peerID: peerID)
            lastConnectionEvent = "Lost \(identity.displayName)"
            availablePeers.removeAll { $0.deviceID == identity.deviceID }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            lastConnectionEvent = "Browsing failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}
