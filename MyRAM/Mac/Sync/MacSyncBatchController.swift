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
    /// Narrow test seam for observing outgoing invitation context.
    private let invitePeerOperation: (MCPeerID, Data, TimeInterval) -> Void
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let accumulator: MacSyncBatchAccumulator
    private let context: ModelContext
    private var readyBatchTask: Task<Void, Never>?
    private let unsentBatches: FileBackedSyncBatchQueue
    private let legacyReceiver: MacLegacySyncReceiver
    private let startAdvertisingOperation: () -> Void
    private let startBrowsingOperation: () -> Void
    private var peerCapabilityRegistry = SyncBatchPeerCapabilityRegistry()
    private var bootstrapStateByPeerDeviceID: [String: SyncPeerBootstrapPendingState] = [:]
    private var bootstrapCapabilityResolutionTasks: [String: Task<Void, Never>] = [:]
    private var bootstrapRetryTasks: [String: Task<Void, Never>] = [:]
    private var bootstrapRetryDelayNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        1_000_000_000
    ]
    private var hasStartedNetworking = false

    init(
        context: ModelContext,
        unsentBatchQueueFileURL: URL? = MacSyncBatchController.unsentBatchQueueFileURL(),
        unsentBatchQueue: FileBackedSyncBatchQueue? = nil,
        startsNetworking: Bool = true,
        identityProvider: () -> MacSyncDeviceIdentity = {
            MacSyncDeviceIdentityProvider().currentIdentity()
        },
        legacyReceiver: MacLegacySyncReceiver? = nil,
        startAdvertisingOperation: (() -> Void)? = nil,
        startBrowsingOperation: (() -> Void)? = nil,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation:
            ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil,
        invitePeerOperation:
            ((MCPeerID, Data, TimeInterval) -> Void)? = nil
    ) {
        let identity = identityProvider()
        let retainedPeerID = MCPeerID(displayName: identity.peerDisplayName)
        let retainedSession = MCSession(
            peer: retainedPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        let retainedAdvertiser = MCNearbyServiceAdvertiser(
            peer: retainedPeerID,
            discoveryInfo: SyncBatchPeerCapabilityCodec.productionDiscoveryInfo,
            serviceType: serviceType
        )
        let retainedBrowser = MCNearbyServiceBrowser(
            peer: retainedPeerID,
            serviceType: serviceType
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
        unsentBatches = unsentBatchQueue ?? FileBackedSyncBatchQueue(fileURL: unsentBatchQueueFileURL)
        self.legacyReceiver = legacyReceiver ?? MacLegacySyncReceiver(context: context)
        self.startAdvertisingOperation = startAdvertisingOperation
            ?? { [retainedAdvertiser] in retainedAdvertiser.startAdvertisingPeer() }
        self.startBrowsingOperation = startBrowsingOperation
            ?? { [retainedBrowser] in retainedBrowser.startBrowsingForPeers() }

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

    func beginBootstrapForTesting(to peerID: MCPeerID) {
        beginBootstrap(to: peerID)
    }

    func handleBootstrapAcknowledgementForTesting(
        _ acknowledgement: SyncPeerBootstrapAcknowledgement,
        from peerID: MCPeerID
    ) async {
        await handleBootstrapAcknowledgement(acknowledgement, from: peerID)
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
        handleBootstrapCapabilityAnnouncement(
            SyncPeerBootstrapCapabilityAnnouncement(),
            from: peerID
        )
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
        guard !hasStartedNetworking else { return }
        hasStartedNetworking = true
        startAdvertisingOperation()
        startBrowsingOperation()
    }

    func invite(_ peer: MacSyncDiscoveredPeer) {
        lastConnectionEvent = "Inviting \(peer.displayName)"
        invitePeerOperation(
            peer.peerID,
            SyncBatchPeerCapabilityCodec.productionInvitationContext,
            12
        )
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
        try validateDurableAdmission(batch)
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
        let connectedPeers = connectedPeersProvider()
        _ = await sendQueuedBatch(batch, connectedPeers: connectedPeers)
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

    private func sendQueuedBatch(
        _ batch: SyncBatch,
        connectedPeers: [MCPeerID]
    ) async -> Bool {
        let eligiblePeers = connectedPeers.filter { peerID in
            let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
            guard peerCapabilityRegistry.isBootstrapCapabilityResolved(
                forPeerDeviceID: deviceID
            ) else { return false }
            guard peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                forPeerDeviceID: deviceID
            ) else { return true }
            guard let state = bootstrapStateByPeerDeviceID[deviceID],
                  state.ordinarySyncReady else { return false }
            return !state.withheldHistoricalBatchIDs.contains(batch.id)
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

        let recipientDeviceIDs = recipients.map { MacSyncPeerIdentity(peerID: $0).deviceID }
        if recipientDeviceIDs.isEmpty {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchSendStarted,
                batchID: String(describing: batch.id),
                itemCount: 0,
                outcome: "noRecipients"
            )
        } else {
            for deviceID in recipientDeviceIDs {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendStarted,
                    batchID: String(describing: batch.id),
                    peerDeviceID: deviceID,
                    itemCount: batch.changes.count
                )
            }
        }

        do {
            let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
            try sendBatchDataOperation(data, recipients, .reliable)
            if recipientDeviceIDs.isEmpty {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendSucceeded,
                    batchID: String(describing: batch.id),
                    itemCount: 0,
                    outcome: "transportAcceptedNoRecipients"
                )
            } else {
                for deviceID in recipientDeviceIDs {
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchSendSucceeded,
                        batchID: String(describing: batch.id),
                        peerDeviceID: deviceID,
                        itemCount: batch.changes.count
                    )
                }
            }
            lastSyncAt = batch.createdAt
            lastErrorMessage = nil
            return true
        } catch {
            if recipientDeviceIDs.isEmpty {
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchSendFailed,
                    batchID: String(describing: batch.id),
                    itemCount: 0,
                    outcome: "transportFailed"
                )
            } else {
                for deviceID in recipientDeviceIDs {
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchSendFailed,
                        batchID: String(describing: batch.id),
                        peerDeviceID: deviceID,
                        itemCount: batch.changes.count,
                        outcome: "transportFailed"
                    )
                }
            }
            lastErrorMessage = "Unable to sync nearby batch changes."
            return false
        }
    }

    private func flushUnsentBatches() async {
        guard !unsentBatches.isEmpty else { return }
        let connectedPeers = connectedPeersProvider()

        for batch in unsentBatches.pendingBatches {
            _ = await sendQueuedBatch(batch, connectedPeers: connectedPeers)
        }
    }

    private func handleBatchAcknowledgement(
        _ acknowledgement: SyncBatchAcknowledgement,
        from peerID: MCPeerID
    ) {
        let peerDeviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        MyRAMSyncBenchmarkTelemetry.shared.record(
            .batchAcknowledgementReceived,
            batchID: String(describing: acknowledgement.batchID),
            peerDeviceID: peerDeviceID
        )
        unsentBatches.removeAll(withIDs: [acknowledgement.batchID])
    }

    private func sendBatchAcknowledgement(batchID: SyncBatchID, to peerID: MCPeerID) throws {
        let peerDeviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        do {
            let payload = try JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batchID))
            let data = try MultipeerSyncMessageCoding.encode(kind: .batchAcknowledgement, payload: payload)
            try sendBatchDataOperation(data, [peerID], .reliable)
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchAcknowledgementSent,
                batchID: String(describing: batchID),
                peerDeviceID: peerDeviceID
            )
        } catch {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .batchAcknowledgementSendFailed,
                batchID: String(describing: batchID),
                peerDeviceID: peerDeviceID,
                outcome: "transportFailed"
            )
            throw error
        }
    }

    private func beginBootstrap(to peerID: MCPeerID) {
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
            scheduleBootstrapRetryIfNeeded(
                to: peerID,
                expectedSnapshotID: state.snapshotID
            )
            return
        }

        do {
            let capturedBatches = unsentBatches.pendingBatches
            let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: context)
                .attachingHistoryCoverage(for: capturedBatches)
            bootstrapStateByPeerDeviceID[identity.deviceID] = SyncPeerBootstrapPendingState(
                snapshot: snapshot,
                coveredBatchIDs: Set(capturedBatches.map(\.id)),
                withheldHistoricalBatchIDs: [],
                ordinarySyncReady: false,
                retryAttempt: 0
            )
            attemptBootstrapSnapshotTransmission(
                to: peerID,
                expectedSnapshotID: snapshot.id
            )
        } catch {
            lastErrorMessage = "Unable to prepare nearby bootstrap state."
        }
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
            try sendBatchDataOperation(data, [peerID], .reliable)
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
        let disposition: SyncPeerBootstrapApplyDisposition
        do {
            disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)
        } catch {
            lastErrorMessage = "Unable to apply nearby bootstrap state."
            return
        }

        if disposition.presentationRefreshRequired {
            convergenceCoordinator?.refreshAfterBootstrap()
        }
        let acknowledgement = SyncPeerBootstrapAcknowledgement(
            snapshotID: snapshot.id,
            coveredBatchIDs: disposition.coveredBatchIDs
        )

        do {
            let payload = try JSONEncoder().encode(acknowledgement)
            let data = try MultipeerSyncMessageCoding.encode(
                kind: .bootstrapAcknowledgement,
                payload: payload
            )
            try sendBatchDataOperation(data, [peerID], .reliable)
        } catch {
            lastErrorMessage = "Unable to confirm nearby bootstrap state."
            return
        }

        lastErrorMessage = nil
        await convergenceCoordinator?.resumePendingWork()
    }

    private func handleBootstrapAcknowledgement(
        _ acknowledgement: SyncPeerBootstrapAcknowledgement,
        from peerID: MCPeerID
    ) async {
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        guard var state = bootstrapStateByPeerDeviceID[deviceID],
              state.snapshotID == acknowledgement.snapshotID,
              acknowledgement.coveredBatchIDs.isSubset(of: state.coveredBatchIDs) else { return }
        do {
            try unsentBatches.removeBatches(withIDs: acknowledgement.coveredBatchIDs)
        } catch {
            lastErrorMessage = "Unable to update the unsent batch queue."
            return
        }
        state.withheldHistoricalBatchIDs = state.coveredBatchIDs
            .subtracting(acknowledgement.coveredBatchIDs)
        state.ordinarySyncReady = true
        bootstrapStateByPeerDeviceID[deviceID] = state
        bootstrapRetryTasks.removeValue(forKey: deviceID)?.cancel()
        lastErrorMessage = nil
        await flushUnsentBatches()
    }

    private func sendBootstrapCapabilityAnnouncement(to peerID: MCPeerID) {
        do {
            let payload = try JSONEncoder().encode(SyncPeerBootstrapCapabilityAnnouncement())
            let data = try MultipeerSyncMessageCoding.encode(
                kind: .bootstrapCapability,
                payload: payload
            )
            try sendBatchDataOperation(data, [peerID], .reliable)
        } catch {
            lastErrorMessage = "Unable to announce nearby bootstrap capability."
        }
    }

    private func handlePeerDisconnect(peerDeviceID: String) {
        bootstrapCapabilityResolutionTasks.removeValue(forKey: peerDeviceID)?.cancel()
        bootstrapRetryTasks.removeValue(forKey: peerDeviceID)?.cancel()
        peerCapabilityRegistry.clearEvidence(forPeerDeviceID: peerDeviceID)
        bootstrapStateByPeerDeviceID.removeValue(forKey: peerDeviceID)
    }

    private func handleBootstrapCapabilityAnnouncement(
        _ announcement: SyncPeerBootstrapCapabilityAnnouncement,
        from peerID: MCPeerID
    ) {
        guard announcement.version == SyncPeerBootstrapCapabilityAnnouncement.currentVersion else {
            return
        }
        let deviceID = MacSyncPeerIdentity(peerID: peerID).deviceID
        peerCapabilityRegistry.recordBootstrapV1Announcement(forPeerDeviceID: deviceID)
        bootstrapCapabilityResolutionTasks.removeValue(forKey: deviceID)?.cancel()
        if connectedPeersProvider().contains(peerID) {
            beginBootstrap(to: peerID)
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
            let identity = MacSyncPeerIdentity(peerID: peerID)
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .peerConnectionState,
                peerDeviceID: identity.deviceID,
                outcome: state.benchmarkLabel
            )
            connectedPeers = session.connectedPeers.map { displayName(for: $0) }
            lastConnectionEvent = "\(state.syncDescription): \(displayName(for: peerID))"
            if state == .notConnected {
                handlePeerDisconnect(peerDeviceID: identity.deviceID)
            }
            if state == .connected {
                remember(peerID)
                sendBootstrapCapabilityAnnouncement(to: peerID)
                beginBootstrap(to: peerID)
                startBootstrapCapabilityResolution(for: peerID)
                await flushUnsentBatches()
                await convergenceCoordinator?.resumePendingWork()
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
                            )
                )
                guard admission == .admitV1 || admission == .admitV2 else {
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchCaptureCompleted,
                        batchID: String(describing: envelope.batch.id),
                        peerDeviceID: identity.deviceID,
                        outcome: "rejectedByAdmission"
                    )
                    return
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
                let captured = convergenceCoordinator?.durablyCaptureIncomingBatch(envelope.batch) ?? false
                MyRAMSyncBenchmarkTelemetry.shared.record(
                    .batchCaptureCompleted,
                    batchID: String(describing: envelope.batch.id),
                    peerDeviceID: identity.deviceID,
                    outcome: captured ? "captured" : "notCaptured"
                )
                if captured {
                    let disposition = await processReceivedBatch(envelope.batch)
                    MyRAMSyncBenchmarkTelemetry.shared.record(
                        .batchConvergenceCompleted,
                        batchID: String(describing: envelope.batch.id),
                        peerDeviceID: identity.deviceID,
                        outcome: String(describing: disposition)
                    )
                    if disposition == .acknowledgementPermitted {
                        try? sendBatchAcknowledgement(batchID: envelope.batch.id, to: peerID)
                    }
                }
            case .legacySyncEnvelope:
                guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: message.payload) else { return }
                receiveLegacyEnvelope(envelope, from: peerID)
            case .batchAcknowledgement:
                guard let acknowledgement = try? JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload) else { return }
                handleBatchAcknowledgement(acknowledgement, from: peerID)
            case .bootstrapCapability:
                guard let announcement = try? JSONDecoder().decode(
                    SyncPeerBootstrapCapabilityAnnouncement.self,
                    from: message.payload
                ) else { return }
                handleBootstrapCapabilityAnnouncement(announcement, from: peerID)
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

extension MacSyncBatchController: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            let identity = MacSyncPeerIdentity(peerID: peerID)
            peerCapabilityRegistry.recordInvitationContext(
                context,
                forPeerDeviceID: identity.deviceID
            )
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
            let identity = MacSyncPeerIdentity(peerID: peerID)
            peerCapabilityRegistry.recordDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.discoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
            peerCapabilityRegistry.recordBootstrapDiscoveryValue(
                info?[SyncBatchPeerCapabilityCodec.bootstrapDiscoveryInfoKey],
                forPeerDeviceID: identity.deviceID
            )
            if peerCapabilityRegistry.isBootstrapCapabilityResolved(
                forPeerDeviceID: identity.deviceID
            ) {
                bootstrapCapabilityResolutionTasks.removeValue(forKey: identity.deviceID)?.cancel()
            }
            if connectedPeersProvider().contains(peerID) {
                if peerCapabilityRegistry.hasExplicitCurrentSessionBootstrapV1Support(
                    forPeerDeviceID: identity.deviceID
                ) {
                    beginBootstrap(to: peerID)
                } else {
                    await flushUnsentBatches()
                }
            }
            remember(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
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
