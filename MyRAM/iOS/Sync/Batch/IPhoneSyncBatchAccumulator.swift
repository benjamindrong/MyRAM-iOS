import Foundation
@preconcurrency import MultipeerConnectivity

actor IPhoneSyncBatchAccumulator {
    private let originDeviceID: SyncBatchDeviceID
    private let quietWindow: TimeInterval
    private let batchIDProvider: @Sendable () -> SyncBatchID
    private let batchSequenceProvider: @Sendable () -> SyncBatchSequenceReservation
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pendingBatch: PendingBatch?
    private var lastSequenceReservationIssue: SyncBatchSequenceReservation.SequenceIssue?
    private var readinessTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SyncConvergenceLocalObligation>.Continuation] = [:]

    init(
        originDeviceID: SyncBatchDeviceID,
        quietWindow: TimeInterval = MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() ? 0.25 : 3,
        batchIDProvider: @escaping @Sendable () -> SyncBatchID = { UUID() },
        batchSequenceProvider: (@Sendable () -> SyncBatchSequenceReservation)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) {
        self.originDeviceID = originDeviceID
        self.quietWindow = quietWindow
        self.batchIDProvider = batchIDProvider
        let sequenceStore = SyncBatchSequenceStore()
        self.batchSequenceProvider = batchSequenceProvider ?? {
            sequenceStore.nextSequence(for: originDeviceID)
        }
        self.sleep = sleep
    }

    func readyBatches() -> AsyncStream<SyncConvergenceLocalObligation> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SyncConvergenceLocalObligation.self)
        continuations[streamID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: streamID) }
        }
        return stream
    }

    func record(_ change: SyncBatchChange, at date: Date = .now) {
        record(SyncConvergenceCapturedLocalChange(change: change, evidence: nil), at: date)
    }

    func record(_ capturedChange: SyncConvergenceCapturedLocalChange, at date: Date = .now) {
        record([capturedChange], at: date)
    }

    func record(_ capturedChanges: [SyncConvergenceCapturedLocalChange], at date: Date = .now) {
        guard !capturedChanges.isEmpty else { return }
        appendCapturedChanges(capturedChanges, at: date)
    }

    func recordAndTakeBoundaryObligation(
        adding capturedChanges: [SyncConvergenceCapturedLocalChange],
        affecting noteID: UUID,
        at date: Date = .now
    ) -> SyncConvergenceLocalObligation? {
        appendCapturedChanges(capturedChanges, at: date)
        return extractPendingBatch { pendingBatch in
            pendingBatch.capturedChanges.contains { captured in
                guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation(captured.change) else { return false }
                return SyncConvergenceLocalEvidenceCapture.noteID(for: captured.change) == noteID
            }
        }
    }

    private func appendCapturedChanges(_ capturedChanges: [SyncConvergenceCapturedLocalChange], at date: Date) {
        guard !capturedChanges.isEmpty else { return }
        if pendingBatch == nil {
            let reservation = batchSequenceProvider()
            let batchSequence: UInt64?
            switch reservation {
            case .reserved(let sequence):
                batchSequence = sequence
                lastSequenceReservationIssue = nil
            case .sequenceLess(let issue):
                batchSequence = nil
                lastSequenceReservationIssue = issue
            }

            pendingBatch = PendingBatch(
                id: batchIDProvider(),
                createdAt: date,
                batchSequence: batchSequence,
                capturedChanges: [],
                readyAt: date.addingTimeInterval(quietWindow)
            )
        }

        pendingBatch?.capturedChanges.append(contentsOf: capturedChanges)
        pendingBatch?.readyAt = date.addingTimeInterval(quietWindow)
        scheduleReadyEmission(batchID: pendingBatch?.id, readyAt: pendingBatch?.readyAt)
    }

    func pendingBatchID() -> SyncBatchID? {
        pendingBatch?.id
    }

    func pendingReadyAt() -> Date? {
        pendingBatch?.readyAt
    }

    func takeLastSequenceReservationIssue() -> SyncBatchSequenceReservation.SequenceIssue? {
        defer { lastSequenceReservationIssue = nil }
        return lastSequenceReservationIssue
    }

    func emitReadyBatches(at date: Date = .now) {
        guard let batch = readyBatchIfAvailable(at: date) else { return }
        for continuation in continuations.values {
            continuation.yield(batch)
        }
    }

    func takeReadyBatch(at date: Date = .now) -> SyncConvergenceLocalObligation? {
        extractPendingBatch { pendingBatch in
            date >= pendingBatch.readyAt
        }
    }

    private func readyBatchIfAvailable(at date: Date) -> SyncConvergenceLocalObligation? {
        extractPendingBatch { pendingBatch in
            date >= pendingBatch.readyAt
        }
    }

    func takePendingBatchNow() -> SyncConvergenceLocalObligation? {
        extractPendingBatch { _ in true }
    }

    func containsPendingBodyChange(for noteID: UUID) -> Bool {
        pendingBatch?.capturedChanges.contains {
            guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation($0.change) else { return false }
            return SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) == noteID
        } ?? false
    }

    func takePendingObligationIfAffecting(noteID: UUID) -> SyncConvergenceLocalObligation? {
        extractPendingBatch { pendingBatch in
            pendingBatch.capturedChanges.contains {
                SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) == noteID
            }
        }
    }

    private func extractPendingBatch(when shouldExtract: (PendingBatch) -> Bool) -> SyncConvergenceLocalObligation? {
        guard let pendingBatch, shouldExtract(pendingBatch) else { return nil }
        readinessTask?.cancel()
        readinessTask = nil
        self.pendingBatch = nil
        let batch = SyncBatch(
            id: pendingBatch.id,
            originDeviceID: originDeviceID,
            createdAt: pendingBatch.createdAt,
            batchSequence: pendingBatch.batchSequence,
            changes: pendingBatch.capturedChanges.map(\.change)
        )
        return SyncConvergenceLocalObligation(batch: batch, capturedChanges: pendingBatch.capturedChanges)
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }

    private func scheduleReadyEmission(batchID: SyncBatchID?, readyAt: Date?) {
        readinessTask?.cancel()
        guard let batchID, let readyAt else { return }

        readinessTask = Task { [weak self, sleep, quietWindow] in
            await sleep(quietWindow)
            guard !Task.isCancelled else { return }
            await self?.emitReadyBatchIfStillCurrent(batchID: batchID, readyAt: readyAt)
        }
    }

    private func emitReadyBatchIfStillCurrent(batchID: SyncBatchID, readyAt: Date) {
        guard pendingBatch?.id == batchID, pendingBatch?.readyAt == readyAt else { return }
        emitReadyBatches(at: readyAt)
    }
}

private struct PendingBatch {
    let id: SyncBatchID
    let createdAt: Date
    let batchSequence: UInt64?
    var capturedChanges: [SyncConvergenceCapturedLocalChange]
    var readyAt: Date
}

#if DEBUG && os(iOS)
enum MyRAMSyncBenchmarkEnduranceIOSRoutingGate {
    static func isReady(
        connectedPeerDeviceIDs: [String],
        ordinarySyncReady: (String) -> Bool
    ) -> Bool {
        connectedPeerDeviceIDs.contains(where: ordinarySyncReady)
    }
}

@MainActor
final class MyRAMSyncBenchmarkEnduranceRoutingGatedIOSDriver {
    static let shared = MyRAMSyncBenchmarkEnduranceRoutingGatedIOSDriver()

    private static let syntheticQueueHighWatermark = 80
    private static let initialSeedDrainSeconds = 45
    private var task: Task<Void, Never>?

    private init() {}

    func startIfNeeded(state: NotesListState) {
        guard task == nil,
              MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() else { return }
        task = Task { @MainActor in
            await run(state: state)
        }
    }

    private func run(state: NotesListState) async {
        switch MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() {
        case .notRequested:
            return
        case .invalid(let message):
            print("[MyRAM Sync Endurance] rejected iOS launch: \(message)")
            return
        case .valid(let launch):
            await run(state: state, launch: launch)
        }
    }

    private func run(
        state: NotesListState,
        launch: MyRAMSyncBenchmarkEnduranceLaunch
    ) async {
        let recorder = MyRAMSyncBenchmarkEnduranceRecorder(runID: launch.runID, platform: .iOS)
        let startedAt = Date()
        recorder.record(.launch, outcome: "accepted", detail: "durationSeconds=\(launch.durationSeconds);routingGate=v3")

        guard await waitForBootstrapAndRoutingReady(state: state, timeoutSeconds: 60) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: 0,
                committed: 0,
                failed: 0,
                state: state,
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
            guard let note = state.vm.createNewNote() else {
                failed += 1
                continue
            }
            attempted += 1
            let title = MyRAMSyncBenchmarkEnduranceWorkload.noteTitle(
                runID: launch.runID,
                platform: .iOS,
                index: index
            )
            let body = MyRAMSyncBenchmarkEnduranceWorkload.initialBody(
                runID: launch.runID,
                platform: .iOS,
                index: index
            )
            if await state.vm.commitNoteEditForProduction(note, title: title, content: body) {
                committed += 1
                noteIDs.append(note.id)
            } else {
                failed += 1
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
                state: state,
                detail: "unable to create the complete synthetic iOS note set"
            )
            return
        }

        let seedQueueDepth = await waitForIOSDrain(
            state: state,
            timeoutSeconds: Self.initialSeedDrainSeconds
        )
        guard seedQueueDepth == 0, ordinaryRoutingReady(state: state) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                state: state,
                detail: "seed traffic did not drain through an ordinary-sync-ready route"
            )
            return
        }
        recorder.record(.phase, phase: "seedDrain", queueDepth: 0, outcome: "completed")

        let workloadEnd = startedAt.addingTimeInterval(
            TimeInterval(max(1, launch.durationSeconds - MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds))
        )
        recorder.record(.phase, phase: "workload", outcome: "started")
        var operation = 0
        var waitingForReconnectRouting = false
        var highWatermarkRecorded = false

        while Date() < workloadEnd, !Task.isCancelled {
            let connected = state.syncController.hasConnectedPeers
            let queueDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count

            if !connected {
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
                if let peer = state.syncController.availablePeers.first {
                    state.syncController.invite(peer)
                }
            } else if waitingForReconnectRouting {
                guard ordinaryRoutingReady(state: state) else {
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
            } else if !ordinaryRoutingReady(state: state) {
                // A connected MCSession is not enough. Do not create more synthetic traffic
                // while MyRAM is deliberately withholding ordinary batches for bootstrap.
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
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
            if let note = state.vm.refreshedNote(withID: noteID) {
                let nextBody = note.content + MyRAMSyncBenchmarkEnduranceWorkload.mutationToken(
                    platform: .iOS,
                    operation: operation
                )
                if await state.vm.commitNoteEditForProduction(
                    note,
                    title: note.title,
                    content: nextBody
                ) {
                    committed += 1
                } else {
                    failed += 1
                    recorder.record(
                        .localMutationFailure,
                        phase: "workload",
                        operationCount: operation,
                        outcome: "commitRejected"
                    )
                }
            } else {
                failed += 1
                recorder.record(
                    .localMutationFailure,
                    phase: "workload",
                    operationCount: operation,
                    outcome: "noteMissing"
                )
            }

            operation += 1
            if operation % 50 == 0 {
                recorder.record(
                    .checkpoint,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: state.syncController.unsentBatchQueueSnapshot().pendingBatches.count,
                    outcome: state.syncController.hasConnectedPeers ? "connected" : "disconnected"
                )
            }
            try? await Task.sleep(nanoseconds: MyRAMSyncBenchmarkEnduranceWorkload.mutationIntervalNanoseconds)
        }

        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForIOSDrain(
            state: state,
            timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let notes = state.vm.fetchSearchableNotes()
        let digests = benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = expectedTitlesObserved(digests, runID: launch.runID)
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && state.syncController.hasConnectedPeers
            && ordinaryRoutingReady(state: state)
            && hasExpectedNotes

        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .iOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: locallyComplete ? "locallyComplete" : "incomplete",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: finalQueueDepth,
            connectedAtFinish: state.syncController.hasConnectedPeers,
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
            detail: "observedBenchmarkNotes=\(digests.count);routingReady=\(ordinaryRoutingReady(state: state))"
        )
        recorder.writeResult(result)
        recorder.record(.completed, outcome: result.outcome)
    }

    private func waitForBootstrapAndRoutingReady(
        state: NotesListState,
        timeoutSeconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline, !Task.isCancelled {
            if state.bootstrapState == .ready,
               state.syncController.hasConnectedPeers,
               ordinaryRoutingReady(state: state) {
                return true
            }
            if state.bootstrapState == .ready,
               !state.syncController.hasConnectedPeers,
               let peer = state.syncController.availablePeers.first {
                state.syncController.invite(peer)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func waitForIOSDrain(
        state: NotesListState,
        timeoutSeconds: Int
    ) async -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var stableZeroSamples = 0
        var lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
        while Date() < deadline, !Task.isCancelled {
            if !state.syncController.hasConnectedPeers,
               let peer = state.syncController.availablePeers.first {
                state.syncController.invite(peer)
            }
            lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
            if lastDepth == 0,
               state.syncController.hasConnectedPeers,
               ordinaryRoutingReady(state: state) {
                stableZeroSamples += 1
                if stableZeroSamples >= 5 { return 0 }
            } else {
                stableZeroSamples = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return lastDepth
    }

    private func ordinaryRoutingReady(state: NotesListState) -> Bool {
        let children = Mirror(reflecting: state.syncController).children
        guard let session = children.first(where: { $0.label == "session" })?.value as? MCSession else {
            return false
        }
        let connectedPeerDeviceIDs = session.connectedPeers.map {
            MyRAMPeerIdentity(peerID: $0).deviceID
        }
        return MyRAMSyncBenchmarkEnduranceIOSRoutingGate.isReady(
            connectedPeerDeviceIDs: connectedPeerDeviceIDs,
            ordinarySyncReady: { peerDeviceID in
                state.syncController.isOrdinarySyncReadyForTesting(peerDeviceID: peerDeviceID)
            }
        )
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
        state: NotesListState,
        detail: String
    ) {
        let digests = benchmarkDigests(
            notes: state.vm.fetchSearchableNotes(),
            runID: launch.runID
        )
        let queueDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .iOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: "failed",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: queueDepth,
            connectedAtFinish: state.syncController.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: detail
        )
        recorder.writeResult(result)
        recorder.record(.failed, queueDepth: queueDepth, outcome: "failed", detail: detail)
    }
}
#endif
