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
    func invite(
        _ peerID: MCPeerID,
        context: Data,
        timeout: TimeInterval
    )
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

    func invite(
        _ peerID: MCPeerID,
        context: Data,
        timeout: TimeInterval
    ) {
        queue.async { [browser, session] in
            browser.invitePeer(
                peerID,
                to: session,
                withContext: context,
                timeout: timeout
            )
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
    var onChangesReceived: (([SyncChange]) async -> [LegacyIncomingChangeResult])? { get set }
    var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)? { get set }
    var onBatchReceived: ((SyncBatch) async -> SyncConvergenceRemoteBatchDisposition)? { get set }
    /// Durably persists an incoming batch before convergence processing. A true
    /// result is necessary but not sufficient for transport acknowledgement; the
    /// convergence disposition must also permit acknowledgement.
    var onDurablyCaptureIncomingBatch: ((SyncBatch) async -> Bool)? { get set }

    func recordLocalChange(
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation,
        payload: Data,
        updatedAt: Date
    )

    func acceptLocalBatch(_ batch: SyncBatch) async throws
}

enum LegacyIncomingCandidateDisposition: Equatable, Sendable {
    case applied
    case retryRequired
    case quarantined
}

struct LegacyIncomingChangeResult: Equatable, Sendable {
    let changeID: UUID
    let disposition: LegacyIncomingCandidateDisposition
}

@MainActor
protocol MyRAMSyncConvergenceStatusConfiguring: AnyObject {
    var onFlushLocalConvergenceRequested: (() async -> Void)? { get set }
    var localConvergencePendingCountProvider: (() -> Int)? { get set }

    func refreshPendingSyncStatus() async
}

@MainActor
protocol PendingSyncQueueAdministrating: AnyObject {
    func suspendOutboundForRecovery()
    func resumeOutboundAfterRecovery()

    func legacyQueueSnapshot() async -> SyncQueueSnapshot
    func legacyQueueHealth() async -> SyncQueuePersistenceHealth
    func replaceLegacyQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws

    func unsentBatchQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot
    func replaceUnsentBatches(_ batches: [SyncBatch]) async throws

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
    var onChangesReceived: (([SyncChange]) async -> [LegacyIncomingChangeResult])?
    var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)?
    var onBatchReceived: ((SyncBatch) async -> SyncConvergenceRemoteBatchDisposition)?
    var onDurablyCaptureIncomingBatch: ((SyncBatch) async -> Bool)?
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
    private var peerCapabilityRegistry = SyncBatchPeerCapabilityRegistry()
    private lazy var debouncedSender = DebouncedChangeSender { [weak self] in
        await self?.requestLegacyFlush()
    }
    private let unsentBatches: FileBackedSyncBatchQueue
    private var isFlushingLegacy = false
    private var pendingLegacyFlushAfterActiveSend = false
    private var outboundFlushRequestedWhileRecoverySuspended = false
    private var isOutboundSuspendedForRecovery = false
    private var hasStartedNetworking = false

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
        advertiser = MCNearbyServiceAdvertiser(
            peer: peer,
            discoveryInfo: SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            serviceType: serviceType
        )
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)
        unsentBatches = FileBackedSyncBatchQueue(fileURL: unsentBatchQueueFileURL)
        self.transport = transport ?? MyRAMMultipeerTransport(browser: browser, session: session)

        super.init()

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self

        if startsNetworking {
            startNetworkingIfNeeded()
        }
    }

    func startNetworkingIfNeeded() {
        guard !hasStartedNetworking else { return }
        hasStartedNetworking = true
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

    var advertisedBatchSchemaDiscoveryInfo: [String: String] {
        SyncBatchPeerCapabilityCodec.productionDiscoveryInfo
    }

    func effectivePeerCapability(
        forPeerDeviceID peerDeviceID: String
    ) -> SyncBatchPeerCapability {
        peerCapabilityRegistry.effectiveCapability(
            forPeerDeviceID: peerDeviceID
        )
    }

    func hasExplicitPeerV2Support(
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        peerCapabilityRegistry.hasExplicitCurrentSessionV2Support(
            forPeerDeviceID: peerDeviceID
        )
    }

    func invite(_ peer: MyRAMDiscoveredPeer) {
        guard let attempt = reconnectTracker.beginConnecting(to: peer.deviceID) else { return }

        lastConnectionEvent = "Inviting \(peer.displayName)"
        let timeout: TimeInterval = 12
        transport.invite(
            peer.peerID,
            context: SyncBatchPeerCapabilityCodec.productionInvitationContext,
            timeout: timeout
        )
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
            // debouncedSender.flushNow() cancels any scheduled debounce and fires
            // its send closure (requestLegacyFlush()) via its own Task. Calling
            // requestLegacyFlush() again here as well would race that fire-and-forget
            // call: the loser would see isFlushingLegacy already true and schedule an
            // immediate follow-up flush of the same not-yet-acknowledged page, instead
            // of the acknowledgement-driven continuation in receiveLegacyEnvelope(_:from:).
            await debouncedSender.flushNow()
            await onFlushLocalConvergenceRequested?()
            await flushUnsentBatches()
            await updatePendingCount()
        }
    }

    private func requestLegacyFlush() async {
        if isOutboundSuspendedForRecovery {
            outboundFlushRequestedWhileRecoverySuspended = true
            await updatePendingCount()
            return
        }

        if isFlushingLegacy {
            pendingLegacyFlushAfterActiveSend = true
            return
        }

        isFlushingLegacy = true
        pendingLegacyFlushAfterActiveSend = false

        let peers = await transport.connectedPeers()
        guard !peers.isEmpty else {
            await updatePendingCount()
            finishLegacyFlushAndSchedulePendingIfNeeded()
            return
        }

        guard let envelope = await syncEngine.nextEnvelope() else {
            await updatePendingCount()
            finishLegacyFlushAndSchedulePendingIfNeeded()
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
        finishLegacyFlushAndSchedulePendingIfNeeded()
    }

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        try validateDurableAdmission(batch)
        try await sendBatch(batch)
    }

    private func validateDurableAdmission(_ batch: SyncBatch) throws {
        let decision = SyncBatchTransportAdmissionPlanner.durableAdmission(
            representation: batch.bodyOperationRepresentation,
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled
        )

        switch decision {
        case .admitV1, .admitV2:
            try SyncBatchAnchoredPayloadPolicy.validateOutbound(batch)
        case .reject:
            try SyncBatchAnchoredPayloadPolicy.validateOutbound(batch)
            preconditionFailure(
                "Planner rejected a batch that the lower-level payload policy admitted"
            )
        }
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
        case .unsupportedAnchoredPayload:
            issues.append(PendingSyncHealthIssue(
                domain: .unsentBatches,
                description: "Unsent batch queue contains unsupported anchored payloads."
            ))
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

    private func sendAcknowledgement(forChangeIDs changeIDs: Set<UUID>, to peerID: MCPeerID) async {
        guard !changeIDs.isEmpty else { return }

        let envelope = SyncEnvelope(
            senderDeviceID: syncEngine.deviceID,
            changes: [],
            acknowledgedChangeIDs: changeIDs.sorted { $0.uuidString < $1.uuidString }
        )

        do {
            let payload = try JSONEncoder().encode(envelope)
            let data = try MultipeerSyncMessageCoding.encode(kind: .legacySyncEnvelope, payload: payload)
            try await transport.send(data, toPeers: [peerID], mode: .reliable)
            await syncEngine.markAcknowledgementSent(changeIDs.sorted { $0.uuidString < $1.uuidString })
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to confirm nearby sync."
        }
    }

    private func sendBatch(_ batch: SyncBatch) async throws {
        // Durability comes first: a peer accepting a `send()` call only means the
        // data was handed to the transport, not that it survived to the other side.
        // Removal from this queue happens only once the peer acknowledges receipt
        // (see handleBatchAcknowledgement), so termination right after a send can
        // never silently drop the batch.
        do {
            try enqueueUnsentBatchDurably(batch)
            await updatePendingCount()
        } catch {
            await updatePendingCount()
            throw error
        }

        if isOutboundSuspendedForRecovery {
            outboundFlushRequestedWhileRecoverySuspended = true
            return
        }

        let connectedPeers = await transport.connectedPeers()
        _ = await sendQueuedBatch(batch, connectedPeers: connectedPeers)
    }

    private func sendQueuedBatch(
        _ batch: SyncBatch,
        connectedPeers: [MCPeerID]
    ) async -> Bool {
        let plannerPeers = connectedPeers.enumerated().map { index, peerID in
            let identity = MyRAMPeerIdentity(peerID: peerID)
            return SyncBatchTransportPeer(
                transportIndex: index,
                stableDeviceID: identity.deviceID,
                hasExplicitCurrentSessionV2Support:
                    peerCapabilityRegistry
                        .hasExplicitCurrentSessionV2Support(
                            forPeerDeviceID: identity.deviceID
                        )
            )
        }
        let routing = SyncBatchTransportAdmissionPlanner.outboundRouting(
            representation: batch.bodyOperationRepresentation,
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled,
            connectedPeers: plannerPeers
        )

        let recipients: [MCPeerID]
        switch routing {
        case .sendToAllConnectedPeers:
            recipients = connectedPeers
        case .sendToPeer(let transportIndex):
            guard connectedPeers.indices.contains(transportIndex) else {
                return false
            }
            recipients = [connectedPeers[transportIndex]]
        case .withhold:
            return false
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
            try await transport.send(data, toPeers: recipients, mode: .reliable)
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
            outboundFlushRequestedWhileRecoverySuspended = true
            await updatePendingCount()
            return
        }

        guard !unsentBatches.isEmpty else { return }
        let connectedPeers = await transport.connectedPeers()

        for batch in unsentBatches.pendingBatches {
            _ = await sendQueuedBatch(batch, connectedPeers: connectedPeers)
        }
    }

    private func enqueueUnsentBatchDurably(_ batch: SyncBatch) throws {
        do {
            try unsentBatches.enqueueDurably(batch)
        } catch {
            lastErrorMessage = "Unable to update the unsent batch queue."
            throw error
        }
    }

    private func handleBatchAcknowledgement(_ acknowledgement: SyncBatchAcknowledgement) async {
        do {
            try unsentBatches.removeBatches(withIDs: [acknowledgement.batchID])
            await updatePendingCount()
        } catch {
            lastErrorMessage = "Unable to update the unsent batch queue."
            await updatePendingCount()
        }
    }

    private func sendBatchAcknowledgement(batchID: SyncBatchID, to peerID: MCPeerID) async {
        do {
            let payload = try JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
            let data = try MultipeerSyncMessageCoding.encode(kind: .batchAcknowledgement, payload: payload)
            try await transport.send(data, toPeers: [peerID], mode: .reliable)
        } catch {
            // Best effort: if the ack itself is lost, the sender simply retries
            // redelivery on its next reconnect, which the receiver already dedupes.
        }
    }

    private func finishLegacyFlushAndSchedulePendingIfNeeded() {
        isFlushingLegacy = false
        let shouldFlushLegacyAgain = pendingLegacyFlushAfterActiveSend
        pendingLegacyFlushAfterActiveSend = false

        guard shouldFlushLegacyAgain else { return }
        if isOutboundSuspendedForRecovery {
            outboundFlushRequestedWhileRecoverySuspended = true
        } else {
            Task { [weak self] in
                await self?.requestLegacyFlush()
            }
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
        let shouldFlush = outboundFlushRequestedWhileRecoverySuspended
        isOutboundSuspendedForRecovery = false
        outboundFlushRequestedWhileRecoverySuspended = false
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

    func replaceUnsentBatches(_ batches: [SyncBatch]) async throws {
        for batch in batches {
            try validateDurableAdmission(batch)
        }
        try unsentBatches.replacePendingBatches(batches)
        await updatePendingCount()
    }

    func refreshPendingSyncStatus() async {
        await updatePendingCount()
    }

#if DEBUG
    func injectUnsentBatchPersistenceFailureForNextWrite() {
        unsentBatches.injectPersistenceFailureForNextWrite()
    }
#endif
}

extension MyRAMSyncController: SyncConvergenceLocalBatchTransportAdapter {}

extension MyRAMSyncController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            let identity = MyRAMPeerIdentity(peerID: peerID)
            connectedPeers = session.connectedPeers.map { MyRAMPeerIdentity(peerID: $0).displayName }
            lastConnectionEvent = "\(description(for: state)): \(displayName(for: peerID))"

            if state == .connected || state == .notConnected {
                clearConnectingState(for: identity.deviceID)
            }

            if state == .notConnected {
                peerCapabilityRegistry.clearEvidence(
                    forPeerDeviceID: identity.deviceID
                )
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
                  message.schemaVersion == MultipeerSyncMessageEnvelope.currentSchemaVersion else {
                return
            }

            switch message.kind {
            case .legacySyncEnvelope:
                guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: message.payload) else { return }
                await receiveLegacyEnvelope(envelope, from: peerID)

            case .batchSync:
                guard let envelope = try? MultipeerSyncMessageCoding.decodeBatchPayload(
                    message.payload
                ) else { return }
                let identity = MyRAMPeerIdentity(peerID: peerID)
                let admission = SyncBatchTransportAdmissionPlanner.inboundAdmission(
                    schemaVersion: envelope.schemaVersion,
                    activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled,
                    hasExplicitCurrentSessionV2Support:
                        peerCapabilityRegistry
                            .hasExplicitCurrentSessionV2Support(
                                forPeerDeviceID: identity.deviceID
                            )
                )
                guard admission == .admitV1 || admission == .admitV2 else {
                    return
                }
                guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(envelope.batch)) != nil else {
                    return
                }
                let captured = await onDurablyCaptureIncomingBatch?(envelope.batch) ?? false
                if captured {
                    let disposition = await onBatchReceived?(envelope.batch) ?? .acknowledgementPermitted
                    lastSyncAt = envelope.batch.createdAt
                    if disposition == .acknowledgementPermitted {
                        await sendBatchAcknowledgement(batchID: envelope.batch.id, to: peerID)
                    }
                }

            case .batchAcknowledgement:
                guard let acknowledgement = try? JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload) else { return }
                await handleBatchAcknowledgement(acknowledgement)
            }

            rememberTrustedPeer(peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: peerID))"
            await updatePendingCount()
        }
    }

    private func receiveLegacyEnvelope(_ envelope: SyncEnvelope, from peerID: MCPeerID) async {
        let preparation = await syncEngine.prepareIncomingEnvelope(envelope)
        if !preparation.acknowledgedLocalChanges.isEmpty {
            await onLocalChangesAcknowledged?(preparation.acknowledgedLocalChanges)
        }

        let candidateChanges = preparation.candidateChanges
        let callbackResults = await onChangesReceived?(candidateChanges) ?? []
        let dispositions = Self.validatedDispositions(
            callbackResults,
            candidateChanges: candidateChanges
        )
        let appliedIDs = Set(dispositions.compactMap { element in
            element.value == .applied ? element.key : nil
        })
        do {
            try await syncEngine.commitHandledIncomingChanges(appliedIDs)
        } catch {
            lastErrorMessage = "Unable to confirm nearby sync."
            await updatePendingCount()
            return
        }
        await sendAcknowledgement(
            forChangeIDs: appliedIDs.union(preparation.alreadyHandledChangeIDs),
            to: peerID
        )
        lastSyncAt = envelope.sentAt
        await updatePendingCount()
        if !isOutboundSuspendedForRecovery,
           !(await transport.connectedPeers()).isEmpty,
           await syncEngine.pendingChangeCount() > 0 {
            await requestLegacyFlush()
        }
    }

    private static func validatedDispositions(
        _ results: [LegacyIncomingChangeResult],
        candidateChanges: [SyncChange]
    ) -> [UUID: LegacyIncomingCandidateDisposition] {
        let candidateIDs = Set(candidateChanges.map(\.id))
        var dispositions = Dictionary(
            uniqueKeysWithValues: candidateIDs.map { ($0, LegacyIncomingCandidateDisposition.retryRequired) }
        )
        var seenResultIDs: Set<UUID> = []
        for result in results {
            guard candidateIDs.contains(result.changeID),
                  seenResultIDs.insert(result.changeID).inserted else {
                continue
            }
            dispositions[result.changeID] = result.disposition
        }
        return dispositions
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
            let identity = MyRAMPeerIdentity(peerID: peerID)
            peerCapabilityRegistry.recordInvitationContext(
                context,
                forPeerDeviceID: identity.deviceID
            )
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
            peerCapabilityRegistry.recordDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.discoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
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
            peerCapabilityRegistry.clearEvidence(
                forPeerDeviceID: identity.deviceID
            )
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
