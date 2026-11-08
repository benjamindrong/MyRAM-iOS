#if os(macOS)
import Foundation
import CryptoKit
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
    private struct IncomingBatchWork {
        let batch: SyncBatch
        let peerID: MCPeerID
    }

    private struct PendingReceivedBootstrap {
        let snapshot: SyncPeerBootstrapSnapshot
        let peerID: MCPeerID
    }

    @Published private(set) var availablePeers: [MacSyncDiscoveredPeer] = []
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var lastConnectionEvent = "Browsing for nearby MyRAM devices"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var quarantinedWork: SyncConvergenceQuarantinedWork?
    @Published private(set) var authorizedCapturePeer: MacSyncDiscoveredPeer?

    weak var convergenceCoordinator: MacSyncConvergenceCoordinator?
#if DEBUG
    var onBootstrapOwnershipPreflightCompletedForTesting: (() async -> Void)?
    var onBootstrapCandidateCapturedForTesting: (() async -> Void)?
#endif

    private let runtimeConfiguration: MyRAMSyncRuntimeConfiguration
    private let exclusivePeerCaptureMode: Bool
    var requiresExclusivePeerAuthorization: Bool { exclusivePeerCaptureMode }
    nonisolated private let transportDiagnostics: MyRAMSyncTransportDiagnostics
    var applicationSyncEnabled: Bool { runtimeConfiguration.applicationSyncEnabled }

    private let serviceType = "myram-sync"
    private let peerID: MCPeerID
    private let session: MCSession
    /// Keeps batch transport observable in tests without making capability policy configurable.
    private let connectedPeersProvider: () -> [MCPeerID]
    private let sendBatchDataOperation:
        (Data, [MCPeerID], MCSessionSendDataMode) throws -> Void
    /// Narrow test seam for observing outgoing invitation context.
    private let invitePeerOperation: (MCPeerID, Data, TimeInterval) -> Void
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let accumulator: MacSyncBatchAccumulator
    private let context: ModelContext
    let conflictStore: SyncConflictStore
    private var readyBatchTask: Task<Void, Never>?
    private let unsentBatches: FileBackedSyncBatchQueue
    private var acknowledgementOutbox = SyncBatchAcknowledgementOutbox()
    private var outstandingBatchDeliveries = SyncBatchOutstandingDeliveryTracker()
    private var pendingBatchReceives = SyncBatchPendingReceiveTracker()
    private var acknowledgementPeerByRemoteBatchID: [SyncBatchID: String] = [:]
    private let legacyReceiver: MacLegacySyncReceiver
    private let startAdvertisingOperation: () -> Void
    private let startBrowsingOperation: () -> Void
    private var peerCapabilityRegistry = SyncBatchPeerCapabilityRegistry()
    private var bootstrapStateByPeerDeviceID: [String: SyncPeerBootstrapPendingState] = [:]
    private var inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID:
        [String: Set<SyncBatchNoteID>] = [:]
    private var bootstrapPreparationPeerDeviceIDs: Set<String> = []
    private var bootstrapCapabilityResolutionTasks: [String: Task<Void, Never>] = [:]
    private var bootstrapRetryTasks: [String: Task<Void, Never>] = [:]
    private var bootstrapPreflightRetryAttemptByPeerDeviceID: [String: Int] = [:]
    private let bootstrapPreflightRetryDelayNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000
    ]
    private var bootstrapRetryDelayNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        1_000_000_000
    ]
    private var localCaptureGeneration: UInt64 = 0
    private enum NetworkingLifecycle { case idle, running, stopped }
    private var networkingLifecycle = NetworkingLifecycle.idle
    private let stopAdvertisingOperation: () -> Void
    private let stopBrowsingOperation: () -> Void
    private let disconnectSessionOperation: () -> Void
    private struct PendingReplacementInvitation {
        let peerID: MCPeerID
        let context: Data?
        let retiringPeerID: MCPeerID
        let handler: (Bool, MCSession?) -> Void
    }
    // One invitation owns admission for each logical peer. A replacement cannot
    // enter the session while the preceding connection still owns membership.
    private var pendingReplacementInvitations: [String: PendingReplacementInvitation] = [:]
    private var pendingIncomingBatchWork: [IncomingBatchWork] = []
    private var isProcessingIncomingBatchWork = false
    private var pendingReceivedBootstrapByPeerDeviceID: [String: PendingReceivedBootstrap] = [:]

    init(
        context: ModelContext,
        conflictStore: SyncConflictStore,
        unsentBatchQueueFileURL: URL? = MacSyncBatchController.unsentBatchQueueFileURL(),
        unsentBatchQueue: FileBackedSyncBatchQueue? = nil,
        startsNetworking: Bool = true,
        exclusivePeerCaptureMode: Bool =
            ProcessInfo.processInfo.arguments.contains("--myram-exclusive-peer-capture"),
        configurationBundle: Bundle = .main,
        identityProvider: () -> MacSyncDeviceIdentity = {
            MacSyncDeviceIdentityProvider().currentIdentity()
        },
        legacyReceiver: MacLegacySyncReceiver? = nil,
        startAdvertisingOperation: (() -> Void)? = nil,
        startBrowsingOperation: (() -> Void)? = nil,
        stopAdvertisingOperation: (() -> Void)? = nil,
        stopBrowsingOperation: (() -> Void)? = nil,
        disconnectSessionOperation: (() -> Void)? = nil,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil,
        invitePeerOperation:
            ((MCPeerID, Data, TimeInterval) -> Void)? = nil
    ) {
        let configuration = MyRAMSyncRuntimeConfiguration.current(bundle: configurationBundle)
        // Only validated Verification identities may bind the isolated MPC service.
        let effectiveServiceType = configuration.recordsTransportDiagnostics ? "myram-verify" : serviceType
        runtimeConfiguration = configuration
        self.exclusivePeerCaptureMode = exclusivePeerCaptureMode
        transportDiagnostics = MyRAMSyncTransportDiagnostics(configuration: configuration)
        let identity = identityProvider()
        let retainedPeerID = MyRAMSyncDeviceIdentityStore.currentPeerID(displayName: identity.peerDisplayName)
        let retainedSession = MCSession(
            peer: retainedPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        let retainedAdvertiser = MCNearbyServiceAdvertiser(
            peer: retainedPeerID,
            discoveryInfo: SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            serviceType: effectiveServiceType
        )
        let retainedBrowser = MCNearbyServiceBrowser(
            peer: retainedPeerID,
            serviceType: effectiveServiceType
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
        self.invitePeerOperation =
            invitePeerOperation ?? { peerID, context, timeout in
                retainedBrowser.invitePeer(
                    peerID,
                    to: retainedSession,
                    withContext: context,
                    timeout: timeout
                )
            }
        advertiser = retainedAdvertiser
        browser = retainedBrowser
        accumulator = MacSyncBatchAccumulator(originDeviceID: identity.id)
        self.context = context
        self.conflictStore = conflictStore
        unsentBatches = unsentBatchQueue ?? FileBackedSyncBatchQueue(fileURL: unsentBatchQueueFileURL)
        self.legacyReceiver = legacyReceiver ?? MacLegacySyncReceiver(
            context: context,
            conflictStore: conflictStore
        )
        self.startAdvertisingOperation = startAdvertisingOperation
            ?? { [retainedAdvertiser] in retainedAdvertiser.startAdvertisingPeer() }
        self.startBrowsingOperation = startBrowsingOperation
            ?? { [retainedBrowser] in retainedBrowser.startBrowsingForPeers() }

        self.stopAdvertisingOperation = stopAdvertisingOperation
            ?? { retainedAdvertiser.stopAdvertisingPeer() }
        self.stopBrowsingOperation = stopBrowsingOperation
            ?? { retainedBrowser.stopBrowsingForPeers() }
        self.disconnectSessionOperation = disconnectSessionOperation
            ?? { retainedSession.disconnect() }

        super.init()
        transportDiagnostics.record("owner.created", session: session, peer: retainedPeerID, detail: "advertiser=\(ObjectIdentifier(advertiser))", owner: browser)

        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        if startsNetworking {
            startNetworkingIfNeeded()
        }

        guard applicationSyncEnabled else { return }
        readyBatchTask = Task { [weak self, accumulator] in
            let stream = await accumulator.readyLocalObligations()
            for await collection in stream {
                await self?.handlePreparedLocalObligations(collection)
            }
        }
    }

    deinit {
        readyBatchTask?.cancel()
        bootstrapRetryTasks.values.forEach { $0.cancel() }
        bootstrapCapabilityResolutionTasks.values.forEach { $0.cancel() }
        if networkingLifecycle != .stopped {
            stopAdvertisingOperation()
            stopBrowsingOperation()
            disconnectSessionOperation()
        }
    }

    var connectionSummary: String {
        connectedPeers.isEmpty ? "Disconnected" : connectedPeers.joined(separator: ", ")
    }

    var hasConnectedPeers: Bool {
        networkingLifecycle != .stopped && !connectedPeersProvider().isEmpty
            && (!exclusivePeerCaptureMode || exclusiveCaptureSessionIsReady)
    }

    private func permitsCapturePeer(_ peer: MCPeerID) -> Bool {
        !exclusivePeerCaptureMode || authorizedCapturePeer?.peerID == peer
    }

    private var exclusiveCaptureSessionIsReady: Bool {
        guard exclusivePeerCaptureMode else { return true }
        let connected = connectedPeersProvider()
        return connected.count == 1 && connected.first == authorizedCapturePeer?.peerID
    }

    /// One explicit operator selection per launch, bound to the discovered MPC identity.
    /// A different peer can only be selected after terminating this process.
    @discardableResult
    func authorizeExclusivePeerForCapture(_ peer: MacSyncDiscoveredPeer) -> Bool {
        guard exclusivePeerCaptureMode,
              authorizedCapturePeer == nil,
              networkingLifecycle != .stopped,
              connectedPeersProvider().isEmpty,
              UUID(uuidString: peer.deviceID) != nil,
              peer.deviceID == MacSyncPeerIdentity(peerID: peer.peerID).deviceID,
              availablePeers.contains(where: {
                  $0.peerID == peer.peerID && $0.deviceID == peer.deviceID
              }) else {
            return false
        }
        authorizedCapturePeer = peer
        invite(peer)
        return true
    }

    /// Captures current in-memory state only. No drain, invite, retry, queue
    /// writes, identities, note content, or transport mutations are performed.
    /// A new process cannot reconstruct the previous process's transient state.
    var readOnlySyncDiagnostics: String {
        let authorizedPeerHash = authorizedCapturePeer.map {
            Self.diagnosticHash($0.peerID.displayName)
        } ?? "none"
        var lines = [
            "schema=myram.mac.sync-diagnostics.v1",
            "networking=\(networkingLifecycle)",
            "mc_session_connected_count=\(session.connectedPeers.count)",
            "published_connected_count=\(connectedPeers.count)",
            "exclusive_capture_mode=\(exclusivePeerCaptureMode)",
            "exclusive_peer_authorized=\(authorizedCapturePeer != nil)",
            "exclusive_session_ready=\(exclusiveCaptureSessionIsReady)",
            "exclusive_authorized_peer_hash=\(authorizedPeerHash)",
            "pending_incoming_count=\(convergenceCoordinator?.pendingIncomingBatchCount ?? -1)",
            "pending_local_obligation_count=\(convergenceCoordinator?.pendingLocalObligationCount ?? -1)",
            "unsent_count=\(unsentBatches.pendingCount)",
            "pending_incoming_transport_count=\(pendingIncomingBatchWork.count)",
            "processing_incoming=\(isProcessingIncomingBatchWork)"
        ]

        let peerIDs = Set(
            session.connectedPeers.map { MacSyncPeerIdentity(peerID: $0).deviceID }
        )
        lines.append("mc_session_peer_hashes=\(peerIDs.map(Self.diagnosticHash).sorted().joined(separator: ","))")

        for (index, item) in (quarantinedWork?.items ?? []).enumerated() {
            let domain: String
            switch item.domain {
            case .incoming: domain = "incoming"
            case .localObligation: domain = "localObligation"
            case .postCommit: domain = "postCommit"
            }
            let reason: String
            switch item.reason {
            case .localEvidenceContinuityViolation: reason = "localEvidenceContinuityViolation"
            case .localEvidenceIndexMismatch: reason = "localEvidenceIndexMismatch"
            case .localEvidenceInvalidOperation: reason = "localEvidenceInvalidOperation"
            case .localEvidenceBaseHashMismatch: reason = "localEvidenceBaseHashMismatch"
            case .staleAuthoritativeState: reason = "staleAuthoritativeState"
            case .anchoredTerminalStructuralFailure(let failure):
                reason = "anchoredTerminalStructuralFailure.\(failure.code.rawValue)"
            case .anchoredBootstrapConflict(let conflict):
                reason = "anchoredBootstrapConflict.\(conflict.reason.rawValue)"
            }
            lines.append(
                "quarantine[\(index)]=domain:\(domain),reason:\(reason)," +
                "batch:\(Self.diagnosticHash(item.batchID.uuidString))," +
                "origin:\(Self.diagnosticHash(item.originDeviceID.uuidString))," +
                "affected_notes:\(item.affectedNoteIDs.count)"
            )
        }
        lines.append("quarantine_count=\(quarantinedWork?.items.count ?? 0)")

        for (index, batch) in unsentBatches.pendingBatches.enumerated() {
            lines.append(
                "unsent[\(index)]=batch:\(Self.diagnosticHash(batch.id.uuidString))," +
                "origin:\(Self.diagnosticHash(batch.originDeviceID.uuidString))"
            )
        }
        let ackOwners = acknowledgementOutbox.pendingOwnersForDiagnostics
            .map {
                "batch:\(Self.diagnosticHash($0.batchID.uuidString))," +
                "peer:\(Self.diagnosticHash($0.peerDeviceID))"
            }.sorted()
        lines.append("ack_outbox_count=\(ackOwners.count)")
        lines += ackOwners.enumerated().map { "ack_outbox[\($0.offset)]=\($0.element)" }

        let deliveryOwners = outstandingBatchDeliveries.pendingOwnersForDiagnostics
            .map {
                "batch:\(Self.diagnosticHash($0.batchID.uuidString))," +
                "peer:\(Self.diagnosticHash($0.peerDeviceID))"
            }.sorted()
        lines.append("awaiting_delivery_ack_count=\(deliveryOwners.count)")
        lines += deliveryOwners.enumerated().map { "delivery[\($0.offset)]=\($0.element)" }

        let pendingReceive = pendingBatchReceives.pendingBatchIDsForDiagnostics
            .map { Self.diagnosticHash($0.uuidString) }.sorted()
        lines.append("receiving_batch_count=\(pendingReceive.count)")
        lines.append("receiving_batch_hashes=\(pendingReceive.joined(separator: ","))")

        let remoteACKOwners = acknowledgementPeerByRemoteBatchID.map {
            "batch:\(Self.diagnosticHash($0.key.uuidString))," +
            "peer:\(Self.diagnosticHash($0.value))"
        }.sorted()
        lines.append("remote_ack_route_count=\(remoteACKOwners.count)")
        lines += remoteACKOwners.enumerated().map { "remote_ack[\($0.offset)]=\($0.element)" }

        let knownPeers = peerIDs.union(bootstrapStateByPeerDeviceID.keys)
            .union(bootstrapPreparationPeerDeviceIDs)
            .union(pendingReceivedBootstrapByPeerDeviceID.keys)
            .union(acknowledgementPeerByRemoteBatchID.values)
        for (index, deviceID) in knownPeers.sorted().enumerated() {
            let bootstrap = bootstrapStateByPeerDeviceID[deviceID]
            lines.append(
                "peer[\(index)]=id:\(Self.diagnosticHash(deviceID))," +
                "capability_resolved:\(peerCapabilityRegistry.isBootstrapCapabilityResolved(forPeerDeviceID: deviceID))," +
                "current_session_v2:\(peerCapabilityRegistry.hasExplicitCurrentSessionV2Support(forPeerDeviceID: deviceID))," +
                "bootstrap_preparing:\(bootstrapPreparationPeerDeviceIDs.contains(deviceID))," +
                "bootstrap_pending:\(bootstrap != nil)," +
                "bootstrap_ready:\(bootstrap?.ordinarySyncReady == true)," +
                "baseline_ack:\(bootstrap?.hasSequenceBaselineAcknowledgement == true)," +
                "bootstrap_retry:\(bootstrap?.retryAttempt ?? -1)," +
                "withheld_historical_batches:\(bootstrap?.withheldHistoricalBatchIDs.count ?? 0)," +
                "frozen_unsent_batches:\(bootstrap?.frozenUnsentBatchIDs.count ?? 0)," +
                "frozen_local_batches:\(bootstrap?.frozenLocalObligationBatchIDs.count ?? 0)"
            )
            guard let bootstrap else { continue }
            let expectedNoteIDs = Set(bootstrap.snapshot.notes.map(\.id))
            let missingNoteIDs = expectedNoteIDs.subtracting(
                bootstrap.sequenceBaselineCoveredNoteIDs
            )
            let missingHashes = missingNoteIDs.map { Self.diagnosticHash($0.uuidString) }
                .sorted().joined(separator: ",")
            let coverageState: String
            if !bootstrap.hasSequenceBaselineAcknowledgement {
                coverageState = "awaiting_acknowledgement"
            } else if !missingNoteIDs.isEmpty {
                coverageState = "partial_note_baseline"
            } else if !bootstrap.ordinarySyncReady {
                coverageState = "post_baseline_incomplete"
            } else {
                coverageState = "complete"
            }
            lines.append(
                "peer[\(index)]_bootstrap_coverage=state:\(coverageState)," +
                "expected_notes:\(expectedNoteIDs.count)," +
                "acknowledged_notes:\(bootstrap.sequenceBaselineCoveredNoteIDs.count)," +
                "missing_notes:\(missingNoteIDs.count)," +
                "missing_note_hashes:\(missingHashes)," +
                "manifest_batches:\(bootstrap.coveredBatchIDs.count)"
            )
            for (batchIndex, batchID) in bootstrap.withheldHistoricalBatchIDs
                .sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                let manifestEntry = bootstrap.snapshot.historyCoverage.first {
                    $0.batchID == batchID
                }
                let cause: String
                if let manifestEntry {
                    if manifestEntry.noteIDs.isEmpty {
                        cause = "empty_history"
                    } else if !manifestEntry.noteIDs.isSubset(
                        of: bootstrap.sequenceBaselineCoveredNoteIDs
                    ) {
                        cause = "missing_note_baseline"
                    } else {
                        cause = "unclassified"
                    }
                } else {
                    cause = "absent_from_manifest"
                }
                let relatedNoteHashes = manifestEntry.map {
                    $0.noteIDs.intersection(missingNoteIDs)
                        .map { Self.diagnosticHash($0.uuidString) }
                        .sorted().joined(separator: ",")
                } ?? ""
                // The frozen batch is already owned by this bootstrap. Inspect its
                // reference IDs without reading or changing either production store.
                // This distinguishes an omitted missing-note reference from an
                // empty history entry without disclosing note content or raw IDs.
                let frozenBatch = bootstrap.frozenBatch(for: batchID)
                let referencedNoteIDs = Set(frozenBatch?.changes.map(\.noteID) ?? [])
                let absentReferenceNoteIDs = referencedNoteIDs.subtracting(expectedNoteIDs)
                let absentReferenceHashes = absentReferenceNoteIDs
                    .map { Self.diagnosticHash($0.uuidString) }
                    .sorted().joined(separator: ",")
                let frozenOriginHash = frozenBatch.map {
                    Self.diagnosticHash($0.originDeviceID.uuidString)
                } ?? "unknown"
                lines.append(
                    "peer[\(index)]_withheld[\(batchIndex)]=batch:" +
                    Self.diagnosticHash(batchID.uuidString) +
                    ",cause:\(cause),missing_note_hashes:\(relatedNoteHashes)," +
                    "frozen_origin_hash:\(frozenOriginHash)," +
                    "frozen_changes:\(frozenBatch?.changes.count ?? -1)," +
                    "referenced_notes:\(referencedNoteIDs.count)," +
                    "absent_reference_count:\(absentReferenceNoteIDs.count)," +
                    "absent_note_hashes:\(absentReferenceHashes)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func diagnosticHash(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(("myram.mac.sync-diagnostics.v1:" + raw).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
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

    func recordBootstrapCapabilityForTesting(
        _ value: String?,
        forPeerDeviceID peerDeviceID: String
    ) {
        peerCapabilityRegistry.recordBootstrapDiscoveryValue(value, forPeerDeviceID: peerDeviceID)
    }

    func recordStructuralMarkCapabilityForTesting(
        _ value: String?,
        forPeerDeviceID peerDeviceID: String
    ) {
        peerCapabilityRegistry.recordStructuralMarkDiscoveryValue(
            value,
            forPeerDeviceID: peerDeviceID
        )
        peerCapabilityRegistry.bindCurrentSessionV2Support(
            forPeerDeviceID: peerDeviceID
        )
    }

    func beginBootstrapForTesting(to peerID: MCPeerID) {
        beginBootstrapAfterLocalOwnershipPreflight(to: peerID)
    }

    func beginReconnectBootstrapForTesting(to peerID: MCPeerID) async {
        await beginBootstrap(to: peerID)
    }

    func handleBootstrapAcknowledgementForTesting(
        _ acknowledgement: SyncPeerBootstrapAcknowledgement,
        from peerID: MCPeerID
    ) async {
        await handleBootstrapAcknowledgement(acknowledgement, from: peerID)
    }

    func inboundFormattingBaselineForTesting(
        peerDeviceID: String
    ) -> Set<SyncBatchNoteID> {
        inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID[peerDeviceID] ?? []
    }

    func outboundFormattingBaselineForTesting(
        peerDeviceID: String
    ) -> Set<SyncBatchNoteID> {
        bootstrapStateByPeerDeviceID[peerDeviceID]?
            .outboundAcknowledgedFormattingNoteIDs ?? []
    }

    func handleBatchAcknowledgementForTesting(
        _ acknowledgement: SyncBatchAcknowledgement,
        from peerID: MCPeerID
    ) async {
        await handleBatchAcknowledgement(acknowledgement, from: peerID)
    }

    func bootstrapStateForTesting(peerDeviceID: String) -> SyncPeerBootstrapPendingState? {
        bootstrapStateByPeerDeviceID[peerDeviceID]
    }

    func receiveBootstrapSnapshotForTesting(
        _ snapshot: SyncPeerBootstrapSnapshot,
        from peerID: MCPeerID
    ) async {
        await receiveBootstrapSnapshot(snapshot, from: peerID)
    }

    func handlePeerDisconnectForTesting(peerDeviceID: String) {
        handlePeerDisconnect(peerDeviceID: peerDeviceID)
    }

    func isBootstrapCapabilityResolvedForTesting(peerDeviceID: String) -> Bool {
        peerCapabilityRegistry.isBootstrapCapabilityResolved(forPeerDeviceID: peerDeviceID)
    }

    func handleBootstrapCapabilityAnnouncementForTesting(from peerID: MCPeerID) {
        let announcement = SyncPeerBootstrapCapabilityAnnouncement()
        guard announcement.version == SyncPeerBootstrapCapabilityAnnouncement.currentVersion else {
            return
        }
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        peerCapabilityRegistry.recordBootstrapV1Announcement(forPeerDeviceID: deviceID)
        peerCapabilityRegistry.recordBootstrapStructuralMarkSchemaVersion(
            announcement.structuralMarkSchemaVersion,
            forPeerDeviceID: deviceID
        )
        bootstrapCapabilityResolutionTasks.removeValue(forKey: deviceID)?.cancel()
        if connectedPeersProvider().contains(peerID) {
            beginBootstrapAfterLocalOwnershipPreflight(to: peerID)
        }
    }

    func resolveBootstrapCapabilityFallbackForTesting(peerID: MCPeerID) async {
        await resolveBootstrapCapabilityFallback(for: peerID)
    }

    func setBootstrapRetryDelayNanosecondsForTesting(_ values: [UInt64]) {
        bootstrapRetryDelayNanoseconds = values
    }

    func unsentBatchQueueSnapshotForTesting() -> FileBackedSyncBatchQueueSnapshot {
        unsentBatches.snapshot()
    }

    /// Starts the retained nearby-sync transports exactly once after startup migration succeeds.
    func startNetworkingIfNeeded() {
        guard networkingLifecycle == .idle else { return }
        networkingLifecycle = .running
        transportDiagnostics.record("networking.start", session: session)
        startAdvertisingOperation()
        startBrowsingOperation()
    }

    /// Terminal process shutdown; discovery cannot reopen this retained session.
    /// disconnect() requests departure but does not promise remote GCK retirement.
    func stopNetworking() {
        guard networkingLifecycle != .stopped else { return }
        transportDiagnostics.record("networking.stop", session: session)
        networkingLifecycle = .stopped
        readyBatchTask?.cancel()
        bootstrapCapabilityResolutionTasks.values.forEach { $0.cancel() }
        bootstrapRetryTasks.values.forEach { $0.cancel() }
        advertiser.delegate = nil
        browser.delegate = nil
        session.delegate = nil
        let pendingInvitations = pendingReplacementInvitations.values
        pendingReplacementInvitations.removeAll()
        pendingInvitations.forEach { $0.handler(false, nil) }
        stopAdvertisingOperation()
        stopBrowsingOperation()
        disconnectSessionOperation()
        connectedPeers = []
        availablePeers = []
    }

    private func sendTransportData(
        _ data: Data, _ peers: [MCPeerID], _ mode: MCSessionSendDataMode
    ) throws {
        try runtimeConfiguration.requireApplicationSync()
        guard networkingLifecycle != .stopped else { throw CancellationError() }
        if exclusivePeerCaptureMode {
            guard exclusiveCaptureSessionIsReady,
                  peers.count == 1,
                  peers.first == authorizedCapturePeer?.peerID else {
                throw CancellationError()
            }
        }
        transportDiagnostics.record("application.send", session: session, detail: "bytes=\(data.count)")
        try sendBatchDataOperation(data, peers, mode)
    }

    func invite(_ peer: MacSyncDiscoveredPeer) {
        guard networkingLifecycle != .stopped, permitsCapturePeer(peer.peerID) else { return }
        guard !exclusivePeerCaptureMode || connectedPeersProvider().isEmpty else { return }
        guard !connectedPeersProvider().contains(peer.peerID) else {
            lastConnectionEvent = "Connected: \(peer.displayName)"
            return
        }
        lastConnectionEvent = "Inviting \(peer.displayName)"
        transportDiagnostics.record("invitation.outgoing", session: session, peer: peer.peerID)
        invitePeerOperation(
            peer.peerID,
            SyncBatchPeerCapabilityCodec.productionInvitationContext,
            12
        )
    }

    func record(_ capturedChanges: [SyncConvergenceCapturedLocalChange], at date: Date = .now) async {
        guard applicationSyncEnabled else { return }
        if !capturedChanges.isEmpty {
            localCaptureGeneration &+= 1
        }
        await accumulator.record(capturedChanges, at: date)
        await updateSequenceReservationIssue()
    }

    func record(_ capturedChange: SyncConvergenceCapturedLocalChange, at date: Date = .now) async {
        await record([capturedChange], at: date)
    }

    func recordAndTakeBoundaryObligations(
        adding capturedChanges: [SyncConvergenceCapturedLocalChange],
        affecting noteID: UUID,
        at date: Date = .now
    ) async -> SyncPreparedLocalObligationCollection? {
        guard applicationSyncEnabled else { return nil }
        if !capturedChanges.isEmpty {
            localCaptureGeneration &+= 1
        }
        let collection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: capturedChanges,
            affecting: noteID,
            at: date
        )
        await updateSequenceReservationIssue()
        return collection
    }

    func takePendingLocalObligationsIfAffecting(
        noteID: UUID
    ) async -> SyncPreparedLocalObligationCollection? {
        guard applicationSyncEnabled else { return nil }
        return await accumulator.takePendingObligationCollectionIfAffecting(noteID: noteID)
    }

    func admitPreparedLocalObligations(
        _ collection: SyncPreparedLocalObligationCollection
    ) async -> SyncConvergenceLocalObligationCollectionAdmissionResult {
        guard let convergenceCoordinator else {
            let result: SyncConvergenceLocalObligationCollectionAdmissionResult =
                .terminal(.blocked(
                    SyncBatchDrainFailure(
                        batchID: collection.primary.id,
                        kind: .queuePersistence
                    )
                ))
            await accumulator.reportPreparedCollectionAdmissionResult(
                token: collection.token,
                result: result
            )
            return result
        }

        let result = await convergenceCoordinator.admitLocalObligations(collection)
        switch result {
        case .admitted:
            guard await accumulator.commitPreparedCollection(
                token: collection.token
            ) else {
                return .terminal(.blocked(
                    SyncBatchDrainFailure(
                        batchID: collection.primary.id,
                        kind: .queuePersistence
                    )
                ))
            }
        case .retryableCapacity, .retryablePersistenceFailure, .terminal:
            await accumulator.reportPreparedCollectionAdmissionResult(
                token: collection.token,
                result: result
            )
        }
        return result
    }

    private func handlePreparedLocalObligations(
        _ collection: SyncPreparedLocalObligationCollection
    ) async {
        guard applicationSyncEnabled, let convergenceCoordinator else { return }
        switch await admitPreparedLocalObligations(collection) {
        case .admitted:
            await convergenceCoordinator.resumePendingWork()
        case .retryableCapacity, .retryablePersistenceFailure:
            markConvergenceWaiting()
        case .terminal(let outcome):
            await convergenceCoordinator.handleTerminalLocalAdmission(
                outcome,
                sourceBatch: collection.primary.batch
            )
        }
    }

    private func updateSequenceReservationIssue() async {
        if let issue = await accumulator.takeLastSequenceReservationIssue() {
            lastErrorMessage = SyncBatchSequenceIssueDescription.message(for: issue)
        }
    }

    func flushPendingBatch() {
        guard applicationSyncEnabled else { return }
        Task {
            await accumulator.emitReadyBatches(at: .now)
            await flushUnsentBatches()
            await convergenceCoordinator?.resumePendingWork()
        }
    }

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        try runtimeConfiguration.requireApplicationSync()
        try validateDurableAdmission(batch)
        do {
            try unsentBatches.enqueueDurably(batch)
        } catch {
            lastErrorMessage = "Unable to save nearby sync changes for retry."
            throw error
        }
        await flushUnsentBatches()
    }

    private func validateDurableAdmission(_ batch: SyncBatch) throws {
        let decision = SyncBatchTransportAdmissionPlanner.durableAdmission(
            deliveryRepresentation: SyncBatchDeliveryPartitionPlanner.classification(of: batch.changes),
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled
        )

        switch decision {
        case .admitV1, .admitV2, .admitV3:
            try SyncBatchAnchoredPayloadPolicy.validateOutbound(batch)
        case .reject:
            try SyncBatchAnchoredPayloadPolicy.validateOutbound(batch)
            preconditionFailure(
                "Planner rejected a batch that the lower-level payload policy admitted"
            )
        }
    }

    private func sendQueuedBatch(
        _ batch: SyncBatch,
        connectedPeers: [MCPeerID]
    ) async -> Bool {
        guard !exclusivePeerCaptureMode || exclusiveCaptureSessionIsReady else { return false }
        let deliveryRepresentation =
            SyncBatchDeliveryPartitionPlanner.classification(of: batch.changes)
        let structuralMarkNoteID: UUID? = {
            guard deliveryRepresentation == .structuralMarkV3,
                  batch.changes.count == 1 else { return nil }
            return batch.changes[0].noteID
        }()
        let eligiblePeers = connectedPeers.filter { peerID in
            let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
            guard peerCapabilityRegistry.isBootstrapCapabilityResolved(
                forPeerDeviceID: deviceID
            ) else { return false }
            guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                forPeerDeviceID: deviceID
            ) else { return true }
            guard let state = bootstrapStateByPeerDeviceID[deviceID],
                  state.permitsOrdinarySync(for: batch) else { return false }
            if deliveryRepresentation == .structuralMarkV3 {
                guard let structuralMarkNoteID,
                      peerCapabilityRegistry.hasExplicitCurrentSessionStructuralMarkSupport(
                        forPeerDeviceID: deviceID
                      ),
                      state.outboundAcknowledgedFormattingNoteIDs.contains(structuralMarkNoteID) else {
                    return false
                }
            }
            return true
        }
        let plannerPeers = eligiblePeers.enumerated().map { index, peerID in
            let identity = MacSyncPeerIdentity(peerID: peerID)
            return SyncBatchTransportPeer(
                transportIndex: index,
                stableDeviceID: identity.deviceID,
                hasExplicitCurrentSessionV2Support:
                    peerCapabilityRegistry
                        .hasExplicitCurrentSessionV2Support(
                            forPeerDeviceID: identity.deviceID
                        ),
                hasExplicitCurrentSessionStructuralMarkSupport:
                    peerCapabilityRegistry
                        .hasExplicitCurrentSessionStructuralMarkSupport(
                            forPeerDeviceID: identity.deviceID
                        )
            )
        }
        let routing = SyncBatchTransportAdmissionPlanner.outboundRouting(
            deliveryRepresentation:
                SyncBatchDeliveryPartitionPlanner.classification(of: batch.changes),
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled,
            connectedPeers: plannerPeers
        )

        let recipients: [MCPeerID]
        switch routing {
        case .sendToAllConnectedPeers:
            recipients = eligiblePeers
        case .sendToPeer(let transportIndex):
            guard eligiblePeers.indices.contains(transportIndex) else {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendDeferred,
                    batchID: String(describing: batch.id),
                    outcome: "invalidRoutingIndex"
                )
                return false
            }
            recipients = [eligiblePeers[transportIndex]]
        case .withhold:
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchSendDeferred,
                batchID: String(describing: batch.id),
                itemCount: connectedPeers.count,
                outcome: "routingWithheld"
            )
            return false
        }

        guard !recipients.isEmpty else { return false }
        var reservations: [(peerID: MCPeerID, reservation: SyncBatchOutstandingDeliveryTracker.Reservation)] = []
        for peerID in recipients {
            let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
            if let reservation = outstandingBatchDeliveries.reserve(
                batch.id,
                forPeerDeviceID: deviceID
            ) {
                reservations.append((peerID, reservation))
            }
        }
        guard !reservations.isEmpty else {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchSendDeferred,
                batchID: String(describing: batch.id),
                itemCount: recipients.count,
                outcome: "awaitingAcknowledgement"
            )
            return true
        }

        let pendingRecipients = reservations.map(\.peerID)
        let recipientDeviceIDs = reservations.map(\.reservation.peerDeviceID)
        for deviceID in recipientDeviceIDs {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchSendStarted,
                batchID: String(describing: batch.id),
                peerDeviceID: deviceID,
                itemCount: batch.changes.count
            )
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
            try sendTransportData(data, pendingRecipients, .reliable)
            for deviceID in recipientDeviceIDs {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendSucceeded,
                    batchID: String(describing: batch.id),
                    peerDeviceID: deviceID,
                    itemCount: batch.changes.count,
                    outcome: "awaitingAcknowledgement"
                )
            }
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
            return true
        } catch {
            for entry in reservations {
                outstandingBatchDeliveries.release(entry.reservation)
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendFailed,
                    batchID: String(describing: batch.id),
                    peerDeviceID: entry.reservation.peerDeviceID,
                    itemCount: batch.changes.count,
                    outcome: "transportFailed"
                )
            }
            lastErrorMessage = "Unable to sync nearby batch changes."
            return false
        }
    }

    private func isIntentionallyWithheldBootstrapBatch(
        _ batch: SyncBatch,
        connectedPeers: [MCPeerID]
    ) -> Bool {
        guard !connectedPeers.isEmpty else { return false }
        return connectedPeers.allSatisfy { peerID in
            let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
            guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                forPeerDeviceID: deviceID
            ), let state = bootstrapStateByPeerDeviceID[deviceID] else {
                return false
            }
            return state.intentionallyWithholdsOrdinarySync(for: batch)
        }
    }

    private func isIntentionallyWithheldStructuralMarkBatch(
        _ batch: SyncBatch,
        connectedPeers: [MCPeerID]
    ) -> Bool {
        guard SyncBatchDeliveryPartitionPlanner.classification(of: batch.changes)
                == .structuralMarkV3,
              !connectedPeers.isEmpty else {
            return false
        }
        let structurallyCapablePeerCount = connectedPeers.reduce(into: 0) { count, peerID in
            let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
            if peerCapabilityRegistry.hasExplicitCurrentSessionStructuralMarkSupport(
                forPeerDeviceID: deviceID
            ) {
                count += 1
            }
        }
        return structurallyCapablePeerCount != 1
    }

    private func flushUnsentBatches() async {
        guard applicationSyncEnabled else { return }
        guard !exclusivePeerCaptureMode || exclusiveCaptureSessionIsReady else { return }
        guard !unsentBatches.isEmpty else { return }
        let connectedPeers = connectedPeersProvider()

        for batch in unsentBatches.pendingBatches {
            if await sendQueuedBatch(batch, connectedPeers: connectedPeers) {
                continue
            }
            if isIntentionallyWithheldBootstrapBatch(batch, connectedPeers: connectedPeers)
                || isIntentionallyWithheldStructuralMarkBatch(
                    batch,
                    connectedPeers: connectedPeers
                ) {
                continue
            }
            break
        }
    }

    private func handleBatchAcknowledgement(
        _ acknowledgement: SyncBatchAcknowledgement,
        from peerID: MCPeerID
    ) async {
        let peerDeviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        MyRAMSyncBenchmarkTelemetry.shared.record(
            .batchAcknowledgementReceived,
            batchID: String(describing: acknowledgement.batchID),
            peerDeviceID: peerDeviceID
        )
        let wasQueued = unsentBatches.contains(acknowledgement.batchID)
        unsentBatches.removeAll(withIDs: [acknowledgement.batchID])
        let didDequeue = wasQueued && !unsentBatches.contains(acknowledgement.batchID)
        if didDequeue {
            outstandingBatchDeliveries.release(acknowledgement.batchID)
            await convergenceCoordinator?.resumePendingWork()
            await flushUnsentBatches()
        }
    }

    private func enqueueBatchAcknowledgement(
        batchID: SyncBatchID,
        peerDeviceID: String
    ) {
        acknowledgementOutbox.enqueue(batchID, forPeerDeviceID: peerDeviceID)
        flushBatchAcknowledgements(forPeerDeviceID: peerDeviceID)
    }

    private func flushBatchAcknowledgements(forPeerDeviceID peerDeviceID: String) {
        guard !exclusivePeerCaptureMode || exclusiveCaptureSessionIsReady else { return }
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
                try sendTransportData(data, [peerID], .reliable)
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

    private func beginBootstrap(to peerID: MCPeerID) async {
        guard applicationSyncEnabled else { return }
        let identity = MacSyncPeerIdentity(peerID: peerID)
        guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
            forPeerDeviceID: identity.deviceID
        ) else {
            bootstrapRetryTasks.removeValue(forKey: identity.deviceID)?.cancel()
            bootstrapStateByPeerDeviceID.removeValue(forKey: identity.deviceID)
            return
        }
        if let state = bootstrapStateByPeerDeviceID[identity.deviceID] {
            guard !state.ordinarySyncReady else { return }
            scheduleBootstrapRetryIfNeeded(to: peerID, expectedSnapshotID: state.snapshotID)
            return
        }
        guard bootstrapPreparationPeerDeviceIDs.insert(identity.deviceID).inserted else { return }
        defer { bootstrapPreparationPeerDeviceIDs.remove(identity.deviceID) }
        guard convergenceCoordinator != nil else {
            lastErrorMessage = "Unable to prepare nearby bootstrap state."
            return
        }
        // A changing capture gets a bounded retry; it never publishes a stale generation.
        for _ in 0..<3 {
            let captureGeneration = localCaptureGeneration
            let firstPreflight = await prepareBootstrapLocalOwnership()
#if DEBUG
            await onBootstrapOwnershipPreflightCompletedForTesting?()
#endif
            switch firstPreflight {
            case .ready: break
            case .retryablePending:
                scheduleBootstrapPreflightRetry(to: peerID)
                lastErrorMessage = "Nearby bootstrap is waiting for local sync ownership."
                return
            case .terminal:
                bootstrapRetryTasks.removeValue(forKey: identity.deviceID)?.cancel()
                bootstrapPreflightRetryAttemptByPeerDeviceID[identity.deviceID] = nil
                lastErrorMessage = "Unable to prepare nearby bootstrap state."
                return
            }
            guard captureGeneration == localCaptureGeneration else { continue }
            do {
                let formattingCapable = peerCapabilityRegistry
                    .hasExplicitCurrentSessionStructuralMarkSupport(forPeerDeviceID: identity.deviceID)
                let candidateOwnership = try SyncPeerBootstrapOwnershipCandidate(
                    unsentSnapshot: unsentBatches.snapshot(),
                    localObligationSnapshot: localBootstrapOwnershipSnapshot()
                )
                let candidateBaseSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: context)
                let candidateSnapshot = (formattingCapable
                    ? candidateBaseSnapshot : candidateBaseSnapshot.withoutFormattingPayload())
                    .attachingHistoryCoverage(
                        for: candidateOwnership.canonicalBatches,
                        includeStructuralMarks: formattingCapable
                    )
#if DEBUG
                await onBootstrapCandidateCapturedForTesting?()
#else
                await Task.yield()
#endif
                let secondCaptureGeneration = localCaptureGeneration
                switch await prepareBootstrapLocalOwnership() {
                case .ready: break
                case .retryablePending:
                    scheduleBootstrapPreflightRetry(to: peerID)
                    lastErrorMessage = "Nearby bootstrap is waiting for local sync ownership."
                    return
                case .terminal:
                    bootstrapRetryTasks.removeValue(forKey: identity.deviceID)?.cancel()
                    bootstrapPreflightRetryAttemptByPeerDeviceID[identity.deviceID] = nil
                    lastErrorMessage = "Unable to prepare nearby bootstrap state."
                    return
                }
                guard secondCaptureGeneration == localCaptureGeneration else { continue }
                guard applicationSyncEnabled,
                      peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                        forPeerDeviceID: identity.deviceID
                      ), formattingCapable == peerCapabilityRegistry
                        .hasExplicitCurrentSessionStructuralMarkSupport(forPeerDeviceID: identity.deviceID)
                else { return }
                let capturedOwnership = try SyncPeerBootstrapOwnershipCandidate(
                    unsentSnapshot: unsentBatches.snapshot(),
                    localObligationSnapshot: localBootstrapOwnershipSnapshot()
                )
                let baseSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: context)
                let snapshot = (formattingCapable ? baseSnapshot : baseSnapshot.withoutFormattingPayload())
                    .attachingHistoryCoverage(
                        for: capturedOwnership.canonicalBatches,
                        includeStructuralMarks: formattingCapable
                    )
                guard candidateOwnership == capturedOwnership,
                      candidateSnapshot.folders == snapshot.folders,
                      candidateSnapshot.notes == snapshot.notes,
                      candidateSnapshot.historyCoverage == snapshot.historyCoverage else { continue }
                bootstrapPreflightRetryAttemptByPeerDeviceID[identity.deviceID] = nil
                bootstrapStateByPeerDeviceID[identity.deviceID] = SyncPeerBootstrapPendingState(
                    snapshot: snapshot, ownershipCandidate: capturedOwnership,
                    withheldHistoricalBatchIDs: [], ordinarySyncReady: false, retryAttempt: 0
                )
                attemptBootstrapSnapshotTransmission(to: peerID, expectedSnapshotID: snapshot.id)
                return
            } catch {
                lastErrorMessage = "Unable to prepare nearby bootstrap state."
                return
            }
        }
        scheduleBootstrapPreflightRetry(to: peerID)
        lastErrorMessage = "Nearby bootstrap is waiting for stable local sync ownership."
    }

    private func prepareBootstrapLocalOwnership()
        async -> SyncBootstrapLocalOwnershipPreparationResult
    {
        guard let convergenceCoordinator else {
            return .terminal(.blocked(
                SyncBatchDrainFailure(batchID: nil, kind: .queuePersistence)
            ))
        }
        let captureGeneration = localCaptureGeneration

        if let collection = await accumulator.takePendingObligationCollectionNow() {
            switch await admitPreparedLocalObligations(collection) {
            case .admitted:
                break
            case .retryableCapacity, .retryablePersistenceFailure:
                return .retryablePending
            case .terminal(let outcome):
                return .terminal(outcome)
            }
        }

        let outcome = await convergenceCoordinator.resumePendingWorkOutcome()
        switch outcome {
        case .blocked(let failure) where failure.kind == .queueCapacity:
            // Bootstrap can release unsent capacity while the complete local
            // obligation remains durable and is included in frozen ownership.
            break
        case .blocked, .quarantined:
            return .terminal(outcome)
        case .pending, .alreadyDraining:
            return .retryablePending
        case .drained, .deferred:
            break
        }

        guard captureGeneration == localCaptureGeneration,
              await accumulator.takePendingObligationCollectionNow() == nil else {
            return .retryablePending
        }
        return .ready
    }

    private func scheduleBootstrapPreflightRetry(to peerID: MCPeerID) {
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        bootstrapRetryTasks.removeValue(forKey: deviceID)?.cancel()
        guard bootstrapStateByPeerDeviceID[deviceID] == nil,
              peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                forPeerDeviceID: deviceID
              ) else {
            return
        }
        let attempt =
            bootstrapPreflightRetryAttemptByPeerDeviceID[deviceID] ?? 0
        guard attempt < bootstrapPreflightRetryDelayNanoseconds.count else {
            lastErrorMessage = "Nearby bootstrap local ownership preparation timed out."
            return
        }
        let delay = bootstrapPreflightRetryDelayNanoseconds[min(
            attempt,
            bootstrapPreflightRetryDelayNanoseconds.count - 1
        )]
        bootstrapPreflightRetryAttemptByPeerDeviceID[deviceID] = attempt + 1
        bootstrapRetryTasks[deviceID] = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.bootstrapRetryTasks.removeValue(forKey: deviceID)
            guard self.connectedPeersProvider().contains(peerID),
                  self.peerCapabilityRegistry
                    .hasExplicitCurrentSessionBootstrapV1Support(
                        forPeerDeviceID: deviceID
                    ) else {
                self.bootstrapPreflightRetryAttemptByPeerDeviceID[deviceID] = nil
                return
            }
            await self.beginBootstrap(to: peerID)
        }
    }

    private func beginBootstrapAfterLocalOwnershipPreflight(to peerID: MCPeerID) {
        guard applicationSyncEnabled else { return }
        let identity = MacSyncPeerIdentity(peerID: peerID)
        guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
            forPeerDeviceID: identity.deviceID
        ) else { return }
        if let state = bootstrapStateByPeerDeviceID[identity.deviceID] {
            guard !state.ordinarySyncReady else { return }
            scheduleBootstrapRetryIfNeeded(to: peerID, expectedSnapshotID: state.snapshotID)
            return
        }
        do {
            let formattingCapable = peerCapabilityRegistry
                .hasExplicitCurrentSessionStructuralMarkSupport(forPeerDeviceID: identity.deviceID)
            let ownership = try SyncPeerBootstrapOwnershipCandidate(
                unsentSnapshot: unsentBatches.snapshot(),
                localObligationSnapshot: localBootstrapOwnershipSnapshot()
            )
            let baseSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: context)
            let snapshot = (formattingCapable ? baseSnapshot : baseSnapshot.withoutFormattingPayload())
                .attachingHistoryCoverage(
                    for: ownership.canonicalBatches, includeStructuralMarks: formattingCapable
                )
            bootstrapStateByPeerDeviceID[identity.deviceID] = SyncPeerBootstrapPendingState(
                snapshot: snapshot, ownershipCandidate: ownership,
                withheldHistoricalBatchIDs: [], ordinarySyncReady: false, retryAttempt: 0
            )
            attemptBootstrapSnapshotTransmission(to: peerID, expectedSnapshotID: snapshot.id)
        } catch {
            lastErrorMessage = "Unable to prepare nearby bootstrap state."
        }
    }

    private func localBootstrapOwnershipSnapshot() -> FileBackedSyncBatchQueueSnapshot {
        convergenceCoordinator?.localBootstrapOwnershipSnapshot()
            ?? FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
    }

    private func attemptBootstrapSnapshotTransmission(
        to peerID: MCPeerID,
        expectedSnapshotID: UUID
    ) {
        let identity = MacSyncPeerIdentity(peerID: peerID)
        guard connectedPeersProvider().contains(peerID),
              peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                forPeerDeviceID: identity.deviceID
              ),
              var state = bootstrapStateByPeerDeviceID[identity.deviceID],
              state.snapshotID == expectedSnapshotID,
              !state.ordinarySyncReady else {
            return
        }

        let maximumAttempts = bootstrapRetryDelayNanoseconds.count + 1
        guard state.retryAttempt < maximumAttempts else {
            bootstrapRetryTasks.removeValue(forKey: identity.deviceID)?.cancel()
            lastErrorMessage = "Nearby bootstrap acknowledgement timed out."
            return
        }

        state.retryAttempt += 1
        bootstrapStateByPeerDeviceID[identity.deviceID] = state

        do {
            let payload = try JSONEncoder().encode(state.snapshot)
            let data = try MultipeerSyncMessageCoding.encode(
                kind: .bootstrapSnapshot,
                payload: payload
            )
            try sendTransportData(data, [peerID], .reliable)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Unable to send nearby bootstrap state."
        }

        scheduleBootstrapRetryIfNeeded(
            to: peerID,
            expectedSnapshotID: expectedSnapshotID
        )
    }

    private func scheduleBootstrapRetryIfNeeded(
        to peerID: MCPeerID,
        expectedSnapshotID: UUID
    ) {
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        bootstrapRetryTasks.removeValue(forKey: deviceID)?.cancel()
        guard let state = bootstrapStateByPeerDeviceID[deviceID],
              state.snapshotID == expectedSnapshotID,
              !state.ordinarySyncReady else {
            return
        }
        guard state.retryAttempt > 0,
              state.retryAttempt <= bootstrapRetryDelayNanoseconds.count else {
            lastErrorMessage = "Nearby bootstrap acknowledgement timed out."
            return
        }

        let delay = bootstrapRetryDelayNanoseconds[state.retryAttempt - 1]
        bootstrapRetryTasks[deviceID] = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.bootstrapRetryTasks.removeValue(forKey: deviceID)
            self.attemptBootstrapSnapshotTransmission(
                to: peerID,
                expectedSnapshotID: expectedSnapshotID
            )
        }
    }

    private func receiveBootstrapSnapshot(
        _ snapshot: SyncPeerBootstrapSnapshot,
        from peerID: MCPeerID
    ) async {
        guard applicationSyncEnabled else { return }
        let peerDeviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        let deviceID = peerDeviceID
        let formattingCapable = peerCapabilityRegistry
            .hasExplicitCurrentSessionStructuralMarkSupport(forPeerDeviceID: deviceID)
        if let retained = pendingReceivedBootstrapByPeerDeviceID[peerDeviceID],
           retained.snapshot.id != snapshot.id {
            pendingReceivedBootstrapByPeerDeviceID.removeValue(forKey: peerDeviceID)
        }
        let disposition: SyncPeerBootstrapApplyDisposition
        do {
            guard let convergenceCoordinator else {
                lastErrorMessage = "Unable to apply nearby bootstrap state."
                return
            }
            disposition = try convergenceCoordinator.applyBootstrapSnapshot(snapshot, to: context)
        } catch {
            lastErrorMessage = "Unable to apply nearby bootstrap state."
            return
        }

        if disposition.presentationRefreshRequired {
            convergenceCoordinator?.refreshAfterBootstrap()
        }
        if formattingCapable {
            inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID[deviceID] =
                disposition.coveredFormattingNoteIDs
        } else {
            inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID[deviceID] = nil
        }
        let acknowledgement = SyncPeerBootstrapAcknowledgement(
            snapshotID: snapshot.id,
            coveredBatchIDs: disposition.coveredBatchIDs,
            coveredNoteIDs: disposition.coveredNoteIDs,
            coveredFormattingNoteIDs:
                formattingCapable
                    ? disposition.coveredFormattingNoteIDs
                    : nil,
            coveredFormattingBatchIDs:
                formattingCapable
                    ? disposition.coveredFormattingBatchIDs
                    : nil
        )

        let requiredNoteIDs = Set(snapshot.notes.map(\.id))
        if requiredNoteIDs.isSubset(of: disposition.coveredNoteIDs) {
            pendingReceivedBootstrapByPeerDeviceID.removeValue(forKey: peerDeviceID)
        } else {
            pendingReceivedBootstrapByPeerDeviceID[peerDeviceID] = PendingReceivedBootstrap(
                snapshot: snapshot,
                peerID: peerID
            )
        }

        do {
            let payload = try JSONEncoder().encode(acknowledgement)
            let data = try MultipeerSyncMessageCoding.encode(
                kind: .bootstrapAcknowledgement,
                payload: payload
            )
            try sendTransportData(data, [peerID], .reliable)
        } catch {
            lastErrorMessage = "Unable to confirm nearby bootstrap state."
            return
        }
        for batchID in acknowledgement.coveredBatchIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchAcknowledgementSent, batchID: batchID.uuidString,
                peerDeviceID: peerDeviceID, outcome: "bootstrapCoverage",
                detail: acknowledgement.benchmarkDetail
            )
        }
        var persistedIncomingBatchIDsFromPeer: Set<SyncBatchID> = []
        if let originDeviceID = UUID(uuidString: peerDeviceID),
           let convergenceCoordinator {
            // Pending incoming work survives relaunch, but its transient ACK peer map does not.
            // Rebind only batches whose durable origin matches this authenticated peer before redrive.
            persistedIncomingBatchIDsFromPeer = convergenceCoordinator.pendingIncomingBatchIDs(
                forOriginDeviceID: originDeviceID
            )
            for batchID in persistedIncomingBatchIDsFromPeer
                where acknowledgementPeerByRemoteBatchID[batchID] == nil
            {
                acknowledgementPeerByRemoteBatchID[batchID] = peerDeviceID
            }
        }

        lastErrorMessage = nil
        if let convergenceCoordinator {
            let completion = await convergenceCoordinator.resumePendingWorkAwaitingDrainOwnership()
            await retainCompletedRemoteBatchAcknowledgements(
                completion.successfullyCompletedBatchIDs
                    .intersection(persistedIncomingBatchIDsFromPeer)
            )
        }
    }

    private func handleBootstrapAcknowledgement(
        _ acknowledgement: SyncPeerBootstrapAcknowledgement,
        from peerID: MCPeerID
    ) async {
        guard applicationSyncEnabled else { return }
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
            forPeerDeviceID: deviceID
        ), var state = bootstrapStateByPeerDeviceID[deviceID],
              state.snapshotID == acknowledgement.snapshotID else { return }

        let formattingCapable = peerCapabilityRegistry
            .hasExplicitCurrentSessionStructuralMarkSupport(forPeerDeviceID: deviceID)
        let requiredNoteIDs = Set(state.snapshot.notes.map(\.id))
        let coveredNoteIDs = acknowledgement.coveredNoteIDs ?? []
        let formattingNoteIDs = acknowledgement.coveredFormattingNoteIDs ?? []
        let formattingBatchIDs = acknowledgement.coveredFormattingBatchIDs ?? []
        guard acknowledgement.coveredBatchIDs.isSubset(of: state.coveredBatchIDs),
              formattingBatchIDs.isSubset(of: state.coveredFormattingBatchIDs),
              coveredNoteIDs.isSubset(of: requiredNoteIDs),
              formattingNoteIDs.isSubset(of: coveredNoteIDs),
              formattingCapable || (formattingNoteIDs.isEmpty && formattingBatchIDs.isEmpty) else {
            return
        }

        // Each dimension releases only its own represented, dependency-safe history.
        let compatibleBatchIDs = acknowledgement.coveredBatchIDs.intersection(state.coveredBatchIDs)
        let coveredBatchIDs = compatibleBatchIDs.union(
            formattingBatchIDs.intersection(state.coveredFormattingBatchIDs)
        )
        let acknowledgedCoverage = state.snapshot.historyCoverage.filter {
            coveredBatchIDs.contains($0.batchID)
        }
        guard acknowledgedCoverage.allSatisfy({ coverage in
            coverage.noteIDs.isSubset(of: coveredNoteIDs)
                && (coverage.structuralMarkOnly != true
                    || coverage.noteIDs.isSubset(of: formattingNoteIDs))
        }) else {
            lastErrorMessage = "Nearby bootstrap did not establish the acknowledged baseline."
            return
        }

        do {
            let currentOwnership = try SyncPeerBootstrapOwnershipCandidate(
                unsentSnapshot: unsentBatches.snapshot(),
                localObligationSnapshot: localBootstrapOwnershipSnapshot()
            )
            for batchID in coveredBatchIDs {
                guard state.frozenBatch(for: batchID) != nil else {
                    lastErrorMessage = "Nearby bootstrap acknowledgement did not match frozen local ownership."
                    return
                }
            }
            for batch in currentOwnership.canonicalBatches where coveredBatchIDs.contains(batch.id) {
                guard state.frozenBatch(for: batch.id) == batch else {
                    lastErrorMessage = "Nearby bootstrap acknowledgement did not match frozen local ownership."
                    return
                }
            }
            try unsentBatches.removeBatchesForBootstrapAcknowledgement(withIDs: coveredBatchIDs)
            if !coveredBatchIDs.isDisjoint(with: state.frozenLocalObligationBatchIDs.union(
                currentOwnership.localObligationBatchIDs
            )) {
                guard let convergenceCoordinator else {
                    lastErrorMessage = "Unable to update pending local sync queue."
                    return
                }
                try convergenceCoordinator.removeLocalBootstrapOwnership(withIDs: coveredBatchIDs)
            }
            let remainingOwnership = try SyncPeerBootstrapOwnershipCandidate(
                unsentSnapshot: unsentBatches.snapshot(),
                localObligationSnapshot: localBootstrapOwnershipSnapshot()
            )
            guard remainingOwnership.batchIDs.isDisjoint(with: coveredBatchIDs) else {
                lastErrorMessage = "Unable to update pending local sync queue."
                return
            }
            outstandingBatchDeliveries.release(coveredBatchIDs)
        } catch {
            lastErrorMessage = "Unable to update pending sync queues."
            return
        }

        state.recordSequenceBaselineCoverage(coveredNoteIDs)
        state.recordAcknowledgement(
            compatibleBatchIDs: compatibleBatchIDs,
            formattingBatchIDs: formattingBatchIDs,
            formattingNoteIDs: formattingNoteIDs
        )
        for batchID in coveredBatchIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchAcknowledgementReceived, batchID: batchID.uuidString,
                peerDeviceID: deviceID, outcome: "bootstrapOwnershipReleased",
                detail: acknowledgement.benchmarkDetail
            )
        }
        state.ordinarySyncReady = requiredNoteIDs.isSubset(of: state.sequenceBaselineCoveredNoteIDs)
            && (!formattingCapable
                || requiredNoteIDs.isSubset(of: state.outboundAcknowledgedFormattingNoteIDs))
        if state.ordinarySyncReady {
            bootstrapRetryTasks.removeValue(forKey: deviceID)?.cancel()
            lastErrorMessage = nil
        } else {
            lastErrorMessage = "Nearby bootstrap has not established every note baseline."
        }
        bootstrapStateByPeerDeviceID[deviceID] = state
        await flushUnsentBatches()
        await convergenceCoordinator?.resumePendingWork()
    }

    private func sendBootstrapCapabilityAnnouncement(to peerID: MCPeerID) {
        guard applicationSyncEnabled else { return }
        do {
            let payload = try JSONEncoder().encode(SyncPeerBootstrapCapabilityAnnouncement())
            let data = try MultipeerSyncMessageCoding.encode(
                kind: .bootstrapCapability,
                payload: payload
            )
            try sendTransportData(data, [peerID], .reliable)
        } catch {
            lastErrorMessage = "Unable to announce nearby bootstrap capability."
        }
    }

    func resumeBootstrapAfterConflictResolution() async {
        guard applicationSyncEnabled else { return }
        let connectedDeviceIDs = Set(
            connectedPeersProvider().map { MacSyncPeerIdentity(peerID: $0).deviceID }
        )
        let pending = pendingReceivedBootstrapByPeerDeviceID
            .filter { connectedDeviceIDs.contains($0.key) }
            .map(\.value)

        for entry in pending {
            await receiveBootstrapSnapshot(entry.snapshot, from: entry.peerID)
        }
    }

    private func handlePeerDisconnect(peerDeviceID: String) {
        bootstrapCapabilityResolutionTasks.removeValue(forKey: peerDeviceID)?.cancel()
        bootstrapRetryTasks.removeValue(forKey: peerDeviceID)?.cancel()
        bootstrapPreflightRetryAttemptByPeerDeviceID[peerDeviceID] = nil
        outstandingBatchDeliveries.invalidateSession(forPeerDeviceID: peerDeviceID)
        peerCapabilityRegistry.clearCurrentSessionEvidence(forPeerDeviceID: peerDeviceID)
        bootstrapStateByPeerDeviceID.removeValue(forKey: peerDeviceID)
        inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID[peerDeviceID] = nil
        pendingReceivedBootstrapByPeerDeviceID.removeValue(forKey: peerDeviceID)
    }

    private func handleBootstrapCapabilityAnnouncement(
        _ announcement: SyncPeerBootstrapCapabilityAnnouncement,
        from peerID: MCPeerID
    ) async {
        guard announcement.version == SyncPeerBootstrapCapabilityAnnouncement.currentVersion else {
            return
        }
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        peerCapabilityRegistry.recordBootstrapV1Announcement(forPeerDeviceID: deviceID)
        peerCapabilityRegistry.recordBootstrapStructuralMarkSchemaVersion(
            announcement.structuralMarkSchemaVersion,
            forPeerDeviceID: deviceID
        )
        bootstrapCapabilityResolutionTasks.removeValue(forKey: deviceID)?.cancel()
        if connectedPeersProvider().contains(peerID) {
            await beginBootstrap(to: peerID)
        }
    }

    private func startBootstrapCapabilityResolution(for peerID: MCPeerID) {
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        guard !peerCapabilityRegistry.isBootstrapCapabilityResolved(forPeerDeviceID: deviceID),
              bootstrapCapabilityResolutionTasks[deviceID] == nil else { return }
        bootstrapCapabilityResolutionTasks[deviceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.resolveBootstrapCapabilityFallback(for: peerID)
        }
    }

    private func resolveBootstrapCapabilityFallback(for peerID: MCPeerID) async {
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        bootstrapCapabilityResolutionTasks.removeValue(forKey: deviceID)
        guard connectedPeersProvider().contains(peerID),
              !peerCapabilityRegistry.isBootstrapCapabilityResolved(forPeerDeviceID: deviceID) else {
            return
        }
        peerCapabilityRegistry.recordBootstrapSessionFallbackUnsupported(
            forPeerDeviceID: deviceID
        )
        await flushUnsentBatches()
    }

    func receive(_ batch: MacSyncBatch) {
        guard applicationSyncEnabled else { return }
        Task { _ = await processReceivedBatch(batch) }
    }

    private func processReceivedBatch(
        _ batch: MacSyncBatch
    ) async -> SyncConvergenceRemoteBatchDisposition {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(batch)) != nil else {
            return .acknowledgementPermitted
        }
        return await convergenceCoordinator?.submitRemoteBatch(batch) ?? .acknowledgementPermitted
    }

    private func enqueueIncomingBatch(_ batch: SyncBatch, from peerID: MCPeerID) {
        let peerDeviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        let existingAcknowledgementPeerDeviceID = acknowledgementPeerByRemoteBatchID[batch.id]
        if let existingAcknowledgementPeerDeviceID,
           existingAcknowledgementPeerDeviceID != peerDeviceID {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchCaptureCompleted,
                batchID: String(describing: batch.id),
                peerDeviceID: peerDeviceID,
                outcome: "duplicateAlreadyDurablePeerMismatch"
            )
            return
        }
        guard pendingBatchReceives.begin(batch.id) else {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchCaptureCompleted,
                batchID: String(describing: batch.id),
                peerDeviceID: peerDeviceID,
                outcome: "duplicatePendingReceive"
            )
            return
        }
        if existingAcknowledgementPeerDeviceID != nil {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchCaptureCompleted,
                batchID: String(describing: batch.id),
                peerDeviceID: peerDeviceID,
                outcome: "duplicateAlreadyDurableRetry"
            )
        }

        pendingIncomingBatchWork.append(IncomingBatchWork(batch: batch, peerID: peerID))
        guard !isProcessingIncomingBatchWork else { return }

        isProcessingIncomingBatchWork = true
        Task { @MainActor [weak self] in
            await self?.processIncomingBatchWork()
        }
    }

    private func processIncomingBatchWork() async {
        while !pendingIncomingBatchWork.isEmpty {
            let work = pendingIncomingBatchWork.removeFirst()
            let peerDeviceID = MacSyncPeerIdentity(peerID: work.peerID).deviceID
            let captured = convergenceCoordinator?.durablyCaptureIncomingBatch(work.batch) ?? false
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchCaptureCompleted,
                batchID: String(describing: work.batch.id),
                peerDeviceID: peerDeviceID,
                outcome: captured ? "captured" : "notCaptured"
            )
            if captured {
                acknowledgementPeerByRemoteBatchID[work.batch.id] = peerDeviceID
                let disposition = await processReceivedBatch(work.batch)
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchConvergenceCompleted,
                    batchID: String(describing: work.batch.id),
                    peerDeviceID: peerDeviceID,
                    outcome: String(describing: disposition)
                )
                if disposition == .acknowledgementPermitted {
                    await retainCompletedRemoteBatchAcknowledgements([work.batch.id])
                }
            }

            pendingBatchReceives.finish(work.batch.id)
            remember(work.peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: work.peerID))"
        }

        isProcessingIncomingBatchWork = false
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

    private func receiveLegacyEnvelope(_ envelope: SyncEnvelope, from peerID: MCPeerID) async {
        do {
            let result = try legacyReceiver.receive(envelope)
            let terminalChangeIDs = Set(
                result.applyResult.outcomes
                    .filter(\.shouldAcknowledge)
                    .map(\.changeID)
            )
            let didApplyFolder = envelope.changes.contains { change in
                terminalChangeIDs.contains(change.id)
                    && change.entityType == .collection
                    && change.operation != .delete
            }
            if didApplyFolder {
                await convergenceCoordinator?.resumePendingWork()
            }

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
        try sendTransportData(data, [peerID], .reliable)
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

extension MacSyncBatchController: SyncConvergenceRemoteAcknowledgementRetaining {
    func retainCompletedRemoteBatchAcknowledgements(_ batchIDs: Set<SyncBatchID>) async {
        for batchID in batchIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let peerDeviceID = acknowledgementPeerByRemoteBatchID.removeValue(forKey: batchID) else {
                continue
            }
            enqueueBatchAcknowledgement(
                batchID: batchID,
                peerDeviceID: peerDeviceID
            )
        }
    }
}

extension MacSyncBatchController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        transportDiagnostics.record("session.callback", session: session, peer: peerID, detail: "state=\(state.rawValue)")
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
            if exclusivePeerCaptureMode &&
                (!permitsCapturePeer(peerID) ||
                    (state == .connected && !exclusiveCaptureSessionIsReady)) {
                lastErrorMessage = "Exclusive peer capture encountered an unexpected connection."
                stopNetworking()
                return
            }
            let identity = MacSyncPeerIdentity(peerID: peerID)
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .peerConnectionState,
                peerDeviceID: identity.deviceID,
                outcome: state.benchmarkLabel
            )
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
            lastConnectionEvent = "\(state.syncDescription): \(displayName(for: peerID))"
            transportDiagnostics.record("session.state", session: session, peer: peerID, detail: "state=\(state.rawValue)")
            if state == .notConnected {
                if applicationSyncEnabled { handlePeerDisconnect(peerDeviceID: identity.deviceID) }
                if let pending = pendingReplacementInvitations[identity.deviceID],
                   pending.retiringPeerID == peerID,
                   !connectedPeersProvider().contains(where: {
                       MacSyncPeerIdentity(peerID: $0).deviceID == identity.deviceID
                   }) {
                    pendingReplacementInvitations.removeValue(forKey: identity.deviceID)
                    acceptInvitation(from: pending.peerID, context: pending.context, handler: pending.handler)
                }
            }

            if state == .connected, !applicationSyncEnabled {
                remember(peerID)
                return
            }

            if state == .connected {
                peerCapabilityRegistry.bindCurrentSessionV2Support(
                    forPeerDeviceID: identity.deviceID
                )
                remember(peerID)
                flushBatchAcknowledgements(forPeerDeviceID: identity.deviceID)
                sendBootstrapCapabilityAnnouncement(to: peerID)
                await beginBootstrap(to: peerID)
                startBootstrapCapabilityResolution(for: peerID)
                await flushUnsentBatches()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
            guard !exclusivePeerCaptureMode ||
                    (exclusiveCaptureSessionIsReady && permitsCapturePeer(peerID)) else {
                return
            }
            transportDiagnostics.record("application.received", session: session, peer: peerID, detail: "bytes=\(data.count)")
            guard applicationSyncEnabled else { return }
            guard let message = try? MultipeerSyncMessageCoding.decodeMessage(from: data),
                  message.schemaVersion == MultipeerSyncMessageEnvelope.currentSchemaVersion else {
                return
            }

            switch message.kind {
            case .batchSync:
                guard let envelope = try? MultipeerSyncMessageCoding.decodeBatchPayload(
                    message.payload
                ) else { return }
                let identity = MacSyncPeerIdentity(peerID: peerID)
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchReceived,
                    batchID: String(describing: envelope.batch.id),
                    peerDeviceID: identity.deviceID,
                    itemCount: envelope.batch.changes.count
                )
                let admission = SyncBatchTransportAdmissionPlanner.inboundAdmission(
                    schemaVersion: envelope.schemaVersion,
                    activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled,
                    hasExplicitCurrentSessionV2Support:
                        peerCapabilityRegistry
                            .hasExplicitCurrentSessionV2Support(
                                forPeerDeviceID: identity.deviceID
                            ),
                    hasExplicitCurrentSessionStructuralMarkSupport:
                        peerCapabilityRegistry
                            .hasExplicitCurrentSessionStructuralMarkSupport(
                                forPeerDeviceID: identity.deviceID
                            )
                )
                guard admission == .admitV1
                        || admission == .admitV2
                        || admission == .admitV3 else {
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchCaptureCompleted,
                        batchID: String(describing: envelope.batch.id),
                        peerDeviceID: identity.deviceID,
                        outcome: "rejectedByAdmission"
                    )
                    return
                }
                if admission == .admitV3 {
                    let coveredNoteIDs =
                        inboundFormattingBaselineCoveredNoteIDsByPeerDeviceID[
                            identity.deviceID
                        ] ?? []
                    guard envelope.batch.changes.count == 1,
                          case .noteStructuralMarksChanged(let marks) =
                            envelope.batch.changes[0],
                          coveredNoteIDs.contains(marks.noteID) else {
                        MyRAMSyncBenchmarkTelemetry.shared.record(
                            .batchCaptureCompleted,
                            batchID: String(describing: envelope.batch.id),
                            peerDeviceID: identity.deviceID,
                            outcome: "rejectedMissingInboundFormattingBaseline"
                        )
                        return
                    }
                }
                guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(envelope.batch)) != nil else {
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchCaptureCompleted,
                        batchID: String(describing: envelope.batch.id),
                        peerDeviceID: identity.deviceID,
                        outcome: "rejectedByPayloadPolicy"
                    )
                    return
                }
                enqueueIncomingBatch(envelope.batch, from: peerID)
                return
            case .legacySyncEnvelope:
                guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: message.payload) else { return }
                await receiveLegacyEnvelope(envelope, from: peerID)
            case .batchAcknowledgement:
                guard let acknowledgement = try? JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload) else { return }
                await handleBatchAcknowledgement(acknowledgement, from: peerID)
            case .bootstrapCapability:
                guard let announcement = try? JSONDecoder().decode(
                    SyncPeerBootstrapCapabilityAnnouncement.self,
                    from: message.payload
                ) else { return }
                await handleBootstrapCapabilityAnnouncement(announcement, from: peerID)
            case .bootstrapSnapshot:
                guard let snapshot = try? JSONDecoder().decode(
                    SyncPeerBootstrapSnapshot.self,
                    from: message.payload
                ) else { return }
                await receiveBootstrapSnapshot(snapshot, from: peerID)
            case .bootstrapAcknowledgement:
                guard let acknowledgement = try? JSONDecoder().decode(
                    SyncPeerBootstrapAcknowledgement.self,
                    from: message.payload
                ) else { return }
                await handleBootstrapAcknowledgement(acknowledgement, from: peerID)
            }

            remember(peerID)
            lastConnectionEvent = "Received sync from \(displayName(for: peerID))"
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MacSyncBatchController {
    private func acceptInvitation(
        from peerID: MCPeerID, context: Data?, handler: (Bool, MCSession?) -> Void
    ) {
        guard permitsCapturePeer(peerID),
              !exclusivePeerCaptureMode || connectedPeersProvider().allSatisfy({
                  $0 == peerID
              }) else {
            handler(false, nil)
            return
        }
        let identity = MacSyncPeerIdentity(peerID: peerID)
        pendingReplacementInvitations.removeValue(forKey: identity.deviceID)?.handler(false, nil)
        peerCapabilityRegistry.recordInvitationContext(context, forPeerDeviceID: identity.deviceID)
        remember(peerID)
        lastConnectionEvent = "Invitation from \(displayName(for: peerID))"
        transportDiagnostics.record("invitation.incoming.accepted", session: session, peer: peerID, owner: advertiser, context: context)
        handler(true, session)
        transportDiagnostics.record("invitation.incoming.handlerReturned", session: session, peer: peerID, owner: advertiser, context: context)
    }
}

extension MacSyncBatchController: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        transportDiagnostics.record("invitation.incoming.callback", peer: peerID, owner: advertiser, context: context)
        Task { @MainActor in
            guard networkingLifecycle != .stopped,
                  permitsCapturePeer(peerID),
                  !exclusivePeerCaptureMode || connectedPeersProvider().allSatisfy({
                      $0 == peerID
                  }) else {
                invitationHandler(false, nil)
                return
            }
            let identity = MacSyncPeerIdentity(peerID: peerID)
            if let retiringPeer = connectedPeersProvider().first(where: {
                MacSyncPeerIdentity(peerID: $0).deviceID == identity.deviceID
            }) {
                let superseded = pendingReplacementInvitations.updateValue(
                    PendingReplacementInvitation(
                        peerID: peerID, context: context,
                        retiringPeerID: retiringPeer, handler: invitationHandler
                    ),
                    forKey: identity.deviceID
                )
                superseded?.handler(false, nil)
                transportDiagnostics.record("invitation.incoming.awaitingRetirement", session: session, peer: peerID)
                return
            }
            acceptInvitation(from: peerID, context: context, handler: invitationHandler)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
            lastConnectionEvent = "Advertising failed"
            lastErrorMessage = error.localizedDescription
        }
    }
}

extension MacSyncBatchController: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
            let identity = MacSyncPeerIdentity(peerID: peerID)
            peerCapabilityRegistry.recordDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.discoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
            peerCapabilityRegistry.recordBootstrapDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
            peerCapabilityRegistry.recordStructuralMarkDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.structuralMarkDiscoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
            if peerCapabilityRegistry.isBootstrapCapabilityResolved(
                forPeerDeviceID: identity.deviceID
            ) {
                bootstrapCapabilityResolutionTasks.removeValue(forKey: identity.deviceID)?.cancel()
            }
            transportDiagnostics.record("discovery.found", session: session, peer: peerID)
            if applicationSyncEnabled, connectedPeersProvider().contains(peerID),
               (!exclusivePeerCaptureMode ||
                   (exclusiveCaptureSessionIsReady && permitsCapturePeer(peerID))) {
                if peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                    forPeerDeviceID: identity.deviceID
                ) {
                    await beginBootstrap(to: peerID)
                } else {
                    await flushUnsentBatches()
                }
            }
            remember(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
            let identity = MacSyncPeerIdentity(peerID: peerID)
            peerCapabilityRegistry.clearDiscoveryEvidence(
                forPeerDeviceID: identity.deviceID
            )
            availablePeers.removeAll { $0.deviceID == identity.deviceID }
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            guard networkingLifecycle != .stopped else { return }
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

    var benchmarkLabel: String {
        switch self {
        case .notConnected: "notConnected"
        case .connecting: "connecting"
        case .connected: "connected"
        @unknown default: "unknown"
        }
    }
}
#endif
