#if os(macOS)
import Foundation
@preconcurrency import MultipeerConnectivity

typealias MacSyncSeenBatchStore = SyncBatchSeenBatchStore

#if DEBUG
extension MacSyncBatchController {
    /// BEN-36-only network cycling seam. It is unavailable unless the launch has passed the
    /// endurance safety gate, and it operates only on the controller's retained production
    /// MultipeerConnectivity objects so the workload exercises the real transport path.
    @discardableResult
    func setBenchmarkEnduranceNetworkingEnabled(_ enabled: Bool) -> Bool {
        guard case .valid = MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() else {
            return false
        }

        let children = Mirror(reflecting: self).children
        guard let session = children.first(where: { $0.label == "session" })?.value as? MCSession,
              let advertiser = children.first(where: { $0.label == "advertiser" })?.value as? MCNearbyServiceAdvertiser,
              let browser = children.first(where: { $0.label == "browser" })?.value as? MCNearbyServiceBrowser else {
            MyRAMSyncBenchmarkTelemetry.shared.record(
                .peerObserved,
                outcome: "enduranceNetworkControlUnavailable"
            )
            return false
        }

        if enabled {
            advertiser.startAdvertisingPeer()
            browser.startBrowsingForPeers()
        } else {
            advertiser.stopAdvertisingPeer()
            browser.stopBrowsingForPeers()
            session.disconnect()
        }
        return true
    }
}

enum MyRAMSyncBenchmarkEnduranceMacRoutingGate {
    static func isReady(
        connectedPeerDeviceIDs: [String],
        ordinarySyncReady: (String) -> Bool
    ) -> Bool {
        connectedPeerDeviceIDs.contains(where: ordinarySyncReady)
    }
}

@MainActor
final class MyRAMSyncBenchmarkEnduranceRoutingGatedMacDriver {
    static let shared = MyRAMSyncBenchmarkEnduranceRoutingGatedMacDriver()

    private static let invitationRetryInterval: TimeInterval = 12
    private static let syntheticQueueHighWatermark = 80
    private static let initialSeedDrainSeconds = 45

    private var task: Task<Void, Never>?
    private var convergenceCoordinator: MacSyncConvergenceCoordinator?
    private var lastInvitationAt: Date?

    private init() {}

    func startIfNeeded() {
        guard task == nil,
              MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() else { return }
        task = Task { @MainActor in
            await run()
        }
    }

    private func run() async {
        switch MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() {
        case .notRequested:
            return
        case .invalid(let message):
            print("[MyRAM Sync Endurance] rejected macOS launch: \(message)")
            return
        case .valid(let launch):
            await run(launch: launch)
        }
    }

    private func run(launch: MyRAMSyncBenchmarkEnduranceLaunch) async {
        let controller = MyRAMMacProcessSyncCompositionRoot.syncController
        configureConvergenceIfNeeded(controller: controller)
        controller.startNetworkingIfNeeded()

        let recorder = MyRAMSyncBenchmarkEnduranceRecorder(runID: launch.runID, platform: .macOS)
        let adapter = MacNotePersistenceAdapter()
        let startedAt = Date()
        recorder.record(
            .launch,
            outcome: "accepted",
            detail: "durationSeconds=\(launch.durationSeconds);routingGate=v3"
        )

        guard await waitForMacRoutingReady(controller: controller, timeoutSeconds: 60) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: 0,
                committed: 0,
                failed: 0,
                controller: controller,
                adapter: adapter,
                detail: "initial peer bootstrap/routing did not become ready"
            )
            return
        }
        recorder.record(.phase, phase: "initialRoutingReady", outcome: "completed")

        recorder.record(.phase, phase: "seed", outcome: "started")
        var noteIDs: [UUID] = []
        var attempted = 0
        var committed = 0
        var failed = 0

        for index in 1...MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform {
            attempted += 1
            do {
                let note = try adapter.createNote(
                    title: MyRAMSyncBenchmarkEnduranceWorkload.noteTitle(
                        runID: launch.runID,
                        platform: .macOS,
                        index: index
                    ),
                    body: MyRAMSyncBenchmarkEnduranceWorkload.initialBody(
                        runID: launch.runID,
                        platform: .macOS,
                        index: index
                    )
                )
                let capturedCreate = SyncConvergenceCapturedLocalChange(
                    change: SyncBatchNoteChangeCapture.noteCreated(
                        noteID: note.id,
                        title: note.title,
                        body: note.content,
                        folderID: note.folder?.id,
                        createdAt: note.createdAt,
                        modifiedAt: note.modifiedAt
                    ),
                    evidence: nil
                )
                await controller.record(capturedCreate, at: note.modifiedAt)
                noteIDs.append(note.id)
                committed += 1
            } catch {
                failed += 1
                recorder.record(
                    .localMutationFailure,
                    phase: "seed",
                    outcome: "createFailed",
                    detail: error.localizedDescription
                )
            }
        }
        recorder.record(.phase, phase: "seed", operationCount: attempted, outcome: "completed")

        guard noteIDs.count == MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                controller: controller,
                adapter: adapter,
                detail: "unable to create the complete synthetic macOS note set"
            )
            return
        }

        let seedQueueDepth = await waitForMacDrain(
            controller: controller,
            timeoutSeconds: Self.initialSeedDrainSeconds
        )
        guard seedQueueDepth == 0, ordinaryRoutingReady(controller: controller) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                controller: controller,
                adapter: adapter,
                detail: "seed traffic did not drain through an ordinary-sync-ready route"
            )
            return
        }
        recorder.record(.phase, phase: "seedDrain", queueDepth: 0, outcome: "completed")

        let workloadSeconds = max(
            1,
            launch.durationSeconds - MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let workloadEnd = startedAt.addingTimeInterval(TimeInterval(workloadSeconds))
        let outageWindows = MyRAMSyncBenchmarkEnduranceWorkload.outageWindows(
            totalDurationSeconds: launch.durationSeconds
        )
        var networkEnabled = true
        var waitingForReconnectRouting = false
        var highWatermarkRecorded = false
        var operation = 0
        recorder.record(.phase, phase: "workload", outcome: "started")

        while Date() < workloadEnd, !Task.isCancelled {
            let elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            let shouldNetworkBeEnabled = !outageWindows.contains { $0.contains(elapsedSeconds) }
            if shouldNetworkBeEnabled != networkEnabled {
                networkEnabled = shouldNetworkBeEnabled
                if networkEnabled {
                    waitingForReconnectRouting = true
                    lastInvitationAt = nil
                } else {
                    waitingForReconnectRouting = false
                }
                controller.setBenchmarkEnduranceNetworkingEnabled(networkEnabled)
                recorder.record(
                    .network,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count,
                    outcome: networkEnabled ? "resumed" : "suspended",
                    detail: "elapsedSeconds=\(elapsedSeconds)"
                )
            }

            let queueDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count

            if networkEnabled {
                if !controller.hasConnectedPeers {
                    if !waitingForReconnectRouting {
                        waitingForReconnectRouting = true
                        recorder.record(
                            .phase,
                            phase: "reconnectRoutingWait",
                            operationCount: operation,
                            queueDepth: queueDepth,
                            outcome: "disconnected"
                        )
                    }
                    inviteMacPeerIfDue(controller: controller)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                if waitingForReconnectRouting || !ordinaryRoutingReady(controller: controller) {
                    guard ordinaryRoutingReady(controller: controller) else {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }
                    waitingForReconnectRouting = false
                    highWatermarkRecorded = false
                    recorder.record(
                        .phase,
                        phase: "reconnectRoutingWait",
                        operationCount: operation,
                        queueDepth: queueDepth,
                        outcome: "routingReady"
                    )
                }
            }

            if queueDepth >= Self.syntheticQueueHighWatermark {
                if !highWatermarkRecorded {
                    highWatermarkRecorded = true
                    recorder.record(
                        .checkpoint,
                        phase: "queueBackpressure",
                        operationCount: operation,
                        queueDepth: queueDepth,
                        outcome: "paused"
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            highWatermarkRecorded = false

            let noteID = noteIDs[operation % noteIDs.count]
            attempted += 1
            do {
                guard let note = try adapter.loadNote(id: noteID) else {
                    throw MyRAMSyncBenchmarkEnduranceRoutingGatedMacError.noteMissing
                }
                let nextBody = note.content + MyRAMSyncBenchmarkEnduranceWorkload.mutationToken(
                    platform: .macOS,
                    operation: operation
                )
                let prepared = try await adapter.prepareProductionLocalNoteEdit(
                    noteID: noteID,
                    proposedAttributedContent: NSAttributedString(string: nextBody)
                )
                try adapter.persistPreparedLocalNoteEdit(prepared)
                await controller.record(prepared.capturedChanges, at: prepared.modifiedAt)
                committed += 1
            } catch {
                failed += 1
                recorder.record(
                    .localMutationFailure,
                    phase: "workload",
                    operationCount: operation,
                    outcome: "commitFailed",
                    detail: error.localizedDescription
                )
            }

            operation += 1
            if operation % 50 == 0 {
                recorder.record(
                    .checkpoint,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count,
                    outcome: controller.hasConnectedPeers ? "connected" : "disconnected"
                )
            }
            try? await Task.sleep(
                nanoseconds: MyRAMSyncBenchmarkEnduranceWorkload.mutationIntervalNanoseconds
            )
        }

        if !networkEnabled {
            lastInvitationAt = nil
            controller.setBenchmarkEnduranceNetworkingEnabled(true)
            recorder.record(.network, phase: "finalDrain", operationCount: operation, outcome: "resumed")
        }

        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForMacDrain(
            controller: controller,
            timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let notes = (try? adapter.loadNotes()) ?? []
        let digests = benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = expectedTitlesObserved(digests, runID: launch.runID)
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && controller.hasConnectedPeers
            && ordinaryRoutingReady(controller: controller)
            && hasExpectedNotes

        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .macOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: locallyComplete ? "locallyComplete" : "incomplete",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: finalQueueDepth,
            connectedAtFinish: controller.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: hasExpectedNotes ? nil : "one or more cross-device synthetic notes were absent at final verification"
        )
        recorder.record(
            .verification,
            phase: "finalDrain",
            operationCount: operation,
            queueDepth: finalQueueDepth,
            outcome: result.outcome,
            detail: "observedBenchmarkNotes=\(digests.count);routingReady=\(ordinaryRoutingReady(controller: controller))"
        )
        recorder.writeResult(result)
        recorder.record(.completed, outcome: result.outcome)
    }

    private func configureConvergenceIfNeeded(controller: MacSyncBatchController) {
        guard convergenceCoordinator == nil else { return }

        let presentationSurface = MacSyncConvergencePresentationSurface(
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
            reloadSelectedEditor: { _, _ in true },
            currentEditorBody: { nil }
        )
        let boundarySurface = MacSyncIncomingLocalBoundarySurface(
            prepareForIncomingBodyMutation: { noteIDs in
                for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    if let obligation = await controller.takePendingLocalObligationIfAffecting(
                        noteID: noteID
                    ) {
                        return .localObligation(obligation)
                    }
                }
                return .ready
            }
        )
        convergenceCoordinator = MacSyncConvergenceCoordinator(
            context: PersistenceManager.shared.context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: presentationSurface,
            incomingBoundarySurface: boundarySurface
        )
    }

    private func waitForMacRoutingReady(
        controller: MacSyncBatchController,
        timeoutSeconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline, !Task.isCancelled {
            if controller.hasConnectedPeers,
               ordinaryRoutingReady(controller: controller) {
                return true
            }
            if !controller.hasConnectedPeers {
                inviteMacPeerIfDue(controller: controller)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func waitForMacDrain(
        controller: MacSyncBatchController,
        timeoutSeconds: Int
    ) async -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var stableZeroSamples = 0
        var lastDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
        while Date() < deadline, !Task.isCancelled {
            if !controller.hasConnectedPeers {
                inviteMacPeerIfDue(controller: controller)
            }
            lastDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
            if lastDepth == 0,
               controller.hasConnectedPeers,
               ordinaryRoutingReady(controller: controller) {
                stableZeroSamples += 1
                if stableZeroSamples >= 5 { return 0 }
            } else {
                stableZeroSamples = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return lastDepth
    }

    private func ordinaryRoutingReady(controller: MacSyncBatchController) -> Bool {
        let children = Mirror(reflecting: controller).children
        guard let session = children.first(where: { $0.label == "session" })?.value as? MCSession else {
            return false
        }
        let connectedPeerDeviceIDs = session.connectedPeers.map {
            MacSyncPeerIdentity(peerID: $0).deviceID
        }
        return MyRAMSyncBenchmarkEnduranceMacRoutingGate.isReady(
            connectedPeerDeviceIDs: connectedPeerDeviceIDs,
            ordinarySyncReady: { peerDeviceID in
                controller.bootstrapStateForTesting(peerDeviceID: peerDeviceID)?.ordinarySyncReady == true
            }
        )
    }

    private func inviteMacPeerIfDue(controller: MacSyncBatchController) {
        let now = Date()
        if let lastInvitationAt,
           now.timeIntervalSince(lastInvitationAt) < Self.invitationRetryInterval {
            return
        }
        guard let peer = controller.availablePeers.first else { return }
        lastInvitationAt = now
        controller.invite(peer)
    }

    private func benchmarkDigests(
        notes: [Note],
        runID: String
    ) -> [MyRAMSyncBenchmarkEnduranceNoteDigest] {
        let prefix = "BEN36-\(runID)-"
        return notes
            .filter { $0.deletedAt == nil && $0.title.hasPrefix(prefix) }
            .map {
                MyRAMSyncBenchmarkEnduranceNoteDigest(
                    title: $0.title,
                    bodySHA256: SyncBatchContentHash.sha256Hex(for: $0.content)
                )
            }
            .sorted { $0.title < $1.title }
    }

    private func expectedTitlesObserved(
        _ digests: [MyRAMSyncBenchmarkEnduranceNoteDigest],
        runID: String
    ) -> Bool {
        let observed = Set(digests.map(\.title))
        return Set(MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: runID)).isSubset(of: observed)
    }

    private func finishFailure(
        recorder: MyRAMSyncBenchmarkEnduranceRecorder,
        launch: MyRAMSyncBenchmarkEnduranceLaunch,
        startedAt: Date,
        attempted: Int,
        committed: Int,
        failed: Int,
        controller: MacSyncBatchController,
        adapter: MacNotePersistenceAdapter,
        detail: String
    ) {
        let digests = benchmarkDigests(
            notes: (try? adapter.loadNotes()) ?? [],
            runID: launch.runID
        )
        let queueDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .macOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: "failed",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: queueDepth,
            connectedAtFinish: controller.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: detail
        )
        recorder.writeResult(result)
        recorder.record(.failed, queueDepth: queueDepth, outcome: "failed", detail: detail)
    }
}

private enum MyRAMSyncBenchmarkEnduranceRoutingGatedMacError: LocalizedError {
    case noteMissing

    var errorDescription: String? {
        "Synthetic benchmark note disappeared before the next mutation."
    }
}
#endif
#endif
