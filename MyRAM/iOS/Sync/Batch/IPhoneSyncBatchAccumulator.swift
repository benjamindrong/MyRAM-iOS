import Foundation

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
        quietWindow: TimeInterval = 3,
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

        pendingBatch?.capturedChanges.append(capturedChange)
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
