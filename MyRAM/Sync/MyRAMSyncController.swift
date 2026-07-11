import Foundation
@preconcurrency import MultipeerConnectivity
import NearbySyncCore

// Keeps trusted-peer auto-reconnect idempotent while Multipeer is still negotiating.
struct TrustedPeerReconnectTracker {
    struct Attempt: Equatable {
        let peerID: String
        fileprivate let token: UUID
    }

    private var connectingAttemptsByPeerID: [String: Attempt] = [:]

    mutating func beginConnecting(to peerID: String) -> Attempt? {
        guard connectingAttemptsByPeerID[peerID] == nil else { return nil }

        let attempt = Attempt(peerID: peerID, token: UUID())
        connectingAttemptsByPeerID[peerID] = attempt
        return attempt
    }

    mutating func finishConnecting(to peerID: String) {
        connectingAttemptsByPeerID.removeValue(forKey: peerID)
    }

    mutating func finishConnecting(_ attempt: Attempt) {
        guard connectingAttemptsByPeerID[attempt.peerID] == attempt else { return }

        finishConnecting(to: attempt.peerID)
    }

    func isConnecting(to peerID: String) -> Bool {
        connectingAttemptsByPeerID[peerID] != nil
    }
}

protocol MyRAMSyncTransporting: AnyObject {
    func invite(_ peerID: MCPeerID, timeout: TimeInterval)
    func connectedPeers() async -> [MCPeerID]
    func send(_ data: Data, toPeers peers: [MCPeerID], mode: MCSessionSendDataMode) async throws
}

// Runs potentially blocking Multipeer operations away from SwiftUI's main actor.
private final class MyRAMMultipeerTransport: MyRAMSyncTransporting {
    private let browser: MCNearbyServiceBrowser
    private let session: MCSession
    private let queue = DispatchQueue(label: "com.myram.nearby-sync.transport")

    init(browser: MCNearbyServiceBrowser, session: MCSession) {
        self.browser = browser
        self.session = session
    }

    func invite(_ peerID: MCPeerID, timeout: TimeInterval) {
        queue.async { [browser, session] in
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: timeout)
        }
    }

    func connectedPeers() async -> [MCPeerID] {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                continuation.resume(returning: session.connectedPeers)
            }
        }
    }

    func send(_ data: Data, toPeers peers: [MCPeerID], mode: MCSessionSendDataMode) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [session] in
                do {
                    try session.send(data, toPeers: peers, with: mode)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
protocol MyRAMSyncControlling: AnyObject {
    var onChangesReceived: (([SyncChange]) async -> Void)? { get set }
    var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)? { get set }
    var onBatchReceived: ((SyncBatch) async -> Void)? { get set }

    func recordLocalChange(
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation,
        payload: Data,
        updatedAt: Date
    )

    func acceptLocalBatch(_ batch: SyncBatch) async throws
}

@MainActor
protocol MyRAMSyncConvergenceStatusConfiguring: AnyObject {
    var onFlushLocalConvergenceRequested: (() async -> Void)? { get set }
    var localConvergencePendingCountProvider: (() -> Int)? { get set }
}

@MainActor
protocol PendingSyncQueueAdministrating: AnyObject {
    func suspendOutboundForRecovery()
    func resumeOutboundAfterRecovery()

    func legacyQueueSnapshot() async -> SyncQueueSnapshot
    func legacyQueueHealth() async -> SyncQueuePersistenceHealth
    func replaceLegacyQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws

    func unsentBatchQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot
    func replaceUnsentBatches(_ batches: [SyncBatch]) throws

    func refreshPendingSyncStatus() async
    func flushAllOutboundWork()
}

extension MyRAMSyncControlling {
    func recordLocalChange(
        entityType: SyncEntityType,
        entityID: String,
        payload: Data,
        updatedAt: Date
    ) {
        recordLocalChange(
            entityType: entityType,
            entityID: entityID,
            operation: .upsert,
            payload: payload,
            updatedAt: updatedAt
        )
    }
}

@MainActor
final class MyRAMSyncController: NSObject, ObservableObject {
    @Published private(set) var availablePeers: [MyRAMDiscoveredPeer] = []
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var pendingSyncStatus = PendingSyncStatus.empty
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastConnectionEvent = "Browsing for nearby MyRAM devices"

    let localPeerName: String
    var onChangesReceived: (([SyncChange]) async -> Void)?
    var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)?
    var onBatchReceived: ((SyncBatch) async -> Void)?
    var onFlushLocalConvergenceRequested: (() async -> Void)?
    var localConvergencePendingCountProvider: (() -> Int)?

    private let serviceType = "myram-sync"
    private let peerID: MCPeerID
    private let trustedPeerStore = UserDefaultsTrustedPeerStore(key: "myram.sync.trustedPeers")
    private let syncStore = InMemorySyncStore()
    private let syncEngine: SyncEngine
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let transport: MyRAMSyncTransporting
    private var reconnectTracker = TrustedPeerReconnectTracker()
    private lazy var debouncedSender = DebouncedChangeSender { [weak self] in
        await self?.requestLegacyFlush()
    }
    private let unsentBatches: FileBackedSyncBatchQueue
    private var isFlushingLegacy = false
    private var legacyFlushRequestedWhileActive = false
    private var isOutboundSuspendedForRecovery = false

    init(
        unsentBatchQueueFileURL: URL? = MyRAMSyncController.unsentBatchQueueFileURL(),
        pendingChangesFileURL: URL? = nil,
        startsNetworking: Bool = true,
        transport: MyRAMSyncTransporting? = nil
    ) {
        let deviceName = MyRAMDeviceIdentity.currentDisplayName()
        let storedDeviceID = MyRAMDeviceIdentity.currentDeviceID()
        let peer = MCPeerID(displayName: "\(deviceName)|\(storedDeviceID)")

        localPeerName = deviceName
        peerID = peer
        syncEngine = SyncEngine(
            deviceID: storedDeviceID,
            store: syncStore,
            queue: SyncQueue(persistence: FileBackedSyncQueuePersistence(
                fileURL: pendingChangesFileURL ?? Self.pendingChangesFileURL()
            ))
        )
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)
        unsentBatches = FileBackedSyncBatchQueue(fileURL: unsentBatchQueueFileURL)
        self.transport = transport ?? MyRAMMultipeerTransport(browser: browser, session: session)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self

        guard startsNetworking else { return }

        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()

        Task {
            await updatePendingCount()
            await requestLegacyFlush()
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

    var currentDeviceID: String {
        syncEngine.deviceID
    }

    func invite(_ peer: MyRAMDiscoveredPeer) {
        guard let attempt = reconnectTracker.beginConnecting(to: peer.deviceID) else { return }

        lastConnectionEvent = "Inviting \(peer.displayName)"
        let timeout: TimeInterval = 12
        transport.invite(peer.peerID, timeout: timeout)
        clearConnectingStateAfterInviteTimeout(for: attempt, timeout: timeout)
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
            await debouncedSender.schedule()
        }
    }

    func flushPendingChanges() {
        flushAllOutboundWork()
    }

    func flushAllOutboundWork() {
        Task {
            await debouncedSender.flushNow()
            await onFlushLocalConvergenceRequested?()
            await requestLegacyFlush()
            await flushUnsentBatches()
            await updatePendingCount()
        }
    }

    private func requestLegacyFlush() async {
        if isOutboundSuspendedForRecovery {
            legacyFlushRequestedWhileActive = true
            await updatePendingCount()
            return
        }

        if isFlushingLegacy {
            legacyFlushRequestedWhileActive = true
            return
        }

        isFlushingLegacy = true
        legacyFlushRequestedWhileActive = false
        defer {
            isFlushingLegacy = false
        }

        let peers = await transport.connectedPeers()
        guard !peers.isEmpty else {
            await updatePendingCount()
            return
        }

        guard let envelope = await syncEngine.nextEnvelope() else {
            await updatePendingCount()
            return
        }

        do {
            let payload = try JSONEncoder().encode(envelope)
            let data = try MultipeerSyncMessageCoding.encode(kind: .legacySyncEnvelope, payload: payload)
            try await transport.send(data, toPeers: peers, mode: .reliable)
            lastSyncAt = envelope.sentAt
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to sync nearby changes."
        }

        await updatePendingCount()
    }

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        try await sendBatch(batch)
    }

    private func updatePendingCount() async {
        let legacyCount = await syncEngine.pendingChangeCount()
        let unsentSnapshot = unsentBatches.snapshot()
        let localConvergenceCount = localConvergencePendingCountProvider?() ?? 0
        let healthIssues = await pendingSyncHealthIssues(unsentHealth: unsentSnapshot.health)
        pendingSyncStatus = PendingSyncStatus(
            legacyChanges: legacyCount,
            unsentBatches: unsentSnapshot.pendingBatches.count,
            localConvergenceObligations: localConvergenceCount,
            healthIssues: healthIssues
        )
        pendingChangeCount = pendingSyncStatus.totalOutboundItems
    }

    private func pendingSyncHealthIssues(unsentHealth: PersistedQueueHealth) async -> [PendingSyncHealthIssue] {
        var issues: [PendingSyncHealthIssue] = []
        switch await syncEngine.queuePersistenceHealth() {
        case .healthy, .fileMissing:
            break
        case .corrupt:
            issues.append(PendingSyncHealthIssue(domain: .legacy, description: "Legacy pending queue is unreadable."))
        case .readFailed:
            issues.append(PendingSyncHealthIssue(domain: .legacy, description: "Legacy pending queue could not be read or saved."))
        }

        switch unsentHealth {
        case .healthy, .fileMissing:
            break
        case .corrupt:
            issues.append(PendingSyncHealthIssue(domain: .unsentBatches, description: "Unsent batch queue is unreadable."))
        case .unsupportedVersion:
            issues.append(PendingSyncHealthIssue(domain: .unsentBatches, description: "Unsent batch queue needs a newer app version."))
        case .readFailed:
            issues.append(PendingSyncHealthIssue(domain: .unsentBatches, description: "Unsent batch queue could not be read or saved."))
        }
        return issues
    }

    private func clearConnectingStateAfterInviteTimeout(
        for attempt: TrustedPeerReconnectTracker.Attempt,
        timeout: TimeInterval
    ) {
        Task { [weak self] in
            let nanoseconds = UInt64((timeout + 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.clearConnectingState(for: attempt)
        }
    }

    private func clearConnectingState(for deviceID: String) {
        reconnectTracker.finishConnecting(to: deviceID)
    }

    private func clearConnectingState(for attempt: TrustedPeerReconnectTracker.Attempt) {
        reconnectTracker.finishConnecting(attempt)
    }

    private func sendAcknowledgement(for changes: [SyncChange], to peerID: MCPeerID) async {
        guard !changes.isEmpty else { return }

        let envelope = SyncEnvelope(
            senderDeviceID: syncEngine.deviceID,
            changes: [],
            acknowledgedChangeIDs: changes.map(\.id)
        )

        do {
            let payload = try JSONEncoder().encode(envelope)
            let data = try MultipeerSyncMessageCoding.encode(kind: .legacySyncEnvelope, payload: payload)
            try await transport.send(data, toPeers: [peerID], mode: .reliable)
            await syncEngine.markAcknowledgementSent(changes.map(\.id))
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to confirm nearby sync."
        }
    }

    private func sendBatch(_ batch: SyncBatch) async throws {
        if isOutboundSuspendedForRecovery {
            enqueueUnsentBatch(batch)
            legacyFlushRequestedWhileActive = true
            await updatePendingCount()
            return
        }

        let sent = await sendQueuedBatch(batch)
        if sent {
            unsentBatches.removeAll(withIDs: [batch.id])
        } else {
            enqueueUnsentBatch(batch)
        }
        guard sent || unsentBatches.contains(batch.id) else {
            throw SyncConvergenceLocalBatchTransportError.acceptanceNotDurable(batchID: batch.id)
        }
    }

    private func sendQueuedBatch(_ batch: SyncBatch) async -> Bool {
        let peers = await transport.connectedPeers()
        guard !peers.isEmpty else {
            return false
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: batch))
            try await transport.send(data, toPeers: peers, mode: .reliable)
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Unable to sync nearby batch changes."
            return false
        }
    }

    private func flushUnsentBatches() async {
        if isOutboundSuspendedForRecovery {
            legacyFlushRequestedWhileActive = true
            await updatePendingCount()
            return
        }

        guard !(await transport.connectedPeers()).isEmpty, !unsentBatches.isEmpty else { return }

        for batch in unsentBatches.pendingBatches {
            let sent = await sendQueuedBatch(batch)
            if sent {
                unsentBatches.removeAll(withIDs: [batch.id])
            }
        }
    }

    private func enqueueUnsentBatch(_ batch: SyncBatch) {
        unsentBatches.enqueue(batch)
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

    nonisolated private static func unsentBatchQueueFileURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("ios-unsent-batch-queue.json")
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

    private func addOrUpdateAvailablePeer(_ peer: MyRAMDiscoveredPeer) {
        if let index = availablePeers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            availablePeers[index] = peer
        } else {
            availablePeers.append(peer)
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

extension MyRAMSyncController: MyRAMSyncControlling {}

extension MyRAMSyncController: MyRAMSyncConvergenceStatusConfiguring {}

extension MyRAMSyncController: PendingSyncQueueAdministrating {
    func suspendOutboundForRecovery() {
        isOutboundSuspendedForRecovery = true
    }

    func resumeOutboundAfterRecovery() {
        let shouldFlush = legacyFlushRequestedWhileActive
        isOutboundSuspendedForRecovery = false
        legacyFlushRequestedWhileActive = false
        if shouldFlush {
            flushAllOutboundWork()
        }
    }

    func legacyQueueSnapshot() async -> SyncQueueSnapshot {
        await syncEngine.queueSnapshot()
    }

    func legacyQueueHealth() async -> SyncQueuePersistenceHealth {
        await syncEngine.queuePersistenceHealth()
    }

    func replaceLegacyQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws {
        try await syncEngine.replaceQueueSnapshot(snapshot)
        await updatePendingCount()
    }

    func unsentBatchQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot {
        unsentBatches.snapshot()
    }

    func replaceUnsentBatches(_ batches: [SyncBatch]) throws {
        try unsentBatches.replacePendingBatches(batches)
    }

    func refreshPendingSyncStatus() async {
        await updatePendingCount()
    }
}

extension MyRAMSyncController: SyncConvergenceLocalBatchTransportAdapter {}

extension MyRAMSyncController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            connectedPeers = session.connectedPeers.map { MyRAMPeerIdentity(peerID: $0).displayName }
            lastConnectionEvent = "\(description(for: state)): \(displayName(for: peerID))"

            if state == .connected || state == .notConnected {
                clearConnectingState(for: MyRAMPeerIdentity(peerID: peerID).deviceID)
            }

            if state == .connected {
                rememberTrustedPeer(peerID)
                flushAllOutboundWork()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                  message.canDecodeWithCurrentSchema else { return }

            switch message.kind {
            case .legacySyncEnvelope:
                guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: message.payload) else { return }
                await receiveLegacyEnvelope(envelope, from: peerID)

            case .batchSync:
                guard let envelope = try? JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload),
                      envelope.canDecodeWithCurrentSchema else { return }
                await onBatchReceived?(envelope.batch)
                lastSyncAt = envelope.batch.createdAt
            }

            rememberTrustedPeer(peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: peerID))"
            await updatePendingCount()
        }
    }

    private func receiveLegacyEnvelope(_ envelope: SyncEnvelope, from peerID: MCPeerID) async {
        let result = await syncEngine.applyIncomingEnvelope(envelope)
        if !result.acknowledgedLocalChanges.isEmpty {
            await onLocalChangesAcknowledged?(result.acknowledgedLocalChanges)
        }
        let changesByID = Dictionary(uniqueKeysWithValues: envelope.changes.map { ($0.id, $0) })
        let appliedChanges = result.appliedChangeIDs.compactMap { changesByID[$0] }
        await onChangesReceived?(appliedChanges)
        await sendAcknowledgement(for: envelope.changes, to: peerID)
        lastSyncAt = envelope.sentAt
        await updatePendingCount()
        if !isOutboundSuspendedForRecovery,
           !(await transport.connectedPeers()).isEmpty,
           await syncEngine.pendingChangeCount() > 0 {
            await requestLegacyFlush()
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
            lastConnectionEvent = "Found \(identity.displayName)"

            let discoveredPeer = MyRAMDiscoveredPeer(
                peerID: peerID,
                deviceID: identity.deviceID,
                displayName: identity.displayName,
                isTrusted: trustedPeerStore.contains(peerID: identity.deviceID)
            )
            addOrUpdateAvailablePeer(discoveredPeer)

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
            clearConnectingState(for: identity.deviceID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            lastConnectionEvent = "Browsing failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}
