#if os(macOS)
import Foundation

actor MacSyncBatchAccumulator {
    private let originDeviceID: MacSyncDeviceID
    private let quietWindow: TimeInterval
    private let batchIDProvider: @Sendable () -> MacSyncBatchID
    private let batchSequenceProvider: @Sendable () -> SyncBatchSequenceReservation
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pendingBatch: PendingBatch?
    private var lastSequenceReservationIssue: SyncBatchSequenceReservation.SequenceIssue?
    private var readinessTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<MacSyncBatch>.Continuation] = [:]
    private var obligationContinuations: [UUID: AsyncStream<SyncConvergenceLocalObligation>.Continuation] = [:]

    init(
        originDeviceID: MacSyncDeviceID,
        quietWindow: TimeInterval = 3,
        batchIDProvider: @escaping @Sendable () -> MacSyncBatchID = { UUID() },
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

    func readyBatches() -> AsyncStream<MacSyncBatch> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: MacSyncBatch.self)
        continuations[streamID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: streamID) }
        }
        return stream
    }

    func readyLocalObligations() -> AsyncStream<SyncConvergenceLocalObligation> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SyncConvergenceLocalObligation.self)
        obligationContinuations[streamID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObligationContinuation(id: streamID) }
        }
        return stream
    }

    func record(_ change: MacSyncChange, at date: Date = .now) {
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

    func pendingBatchID() -> MacSyncBatchID? {
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
        guard let obligation = readyObligationIfAvailable(at: date) else { return }
        for continuation in continuations.values {
            continuation.yield(obligation.batch)
        }
        for continuation in obligationContinuations.values {
            continuation.yield(obligation)
        }
    }

    func takeReadyBatch(at date: Date = .now) -> MacSyncBatch? {
        readyObligationIfAvailable(at: date)?.batch
    }

    func takePendingObligationIfAffecting(noteID: UUID) -> SyncConvergenceLocalObligation? {
        extractPendingBatch { pendingBatch in
            pendingBatch.capturedChanges.contains {
                SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) == noteID
            }
        }
    }

    func containsPendingBodyChange(for noteID: UUID) -> Bool {
        pendingBatch?.capturedChanges.contains { captured in
            guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation(captured.change) else { return false }
            return SyncConvergenceLocalEvidenceCapture.noteID(for: captured.change) == noteID
        } ?? false
    }

    private func readyObligationIfAvailable(at date: Date) -> SyncConvergenceLocalObligation? {
        extractPendingBatch { pendingBatch in
            date >= pendingBatch.readyAt
        }
    }

    private func extractPendingBatch(when shouldExtract: (PendingBatch) -> Bool) -> SyncConvergenceLocalObligation? {
        guard let pendingBatch, shouldExtract(pendingBatch) else { return nil }
        readinessTask?.cancel()
        readinessTask = nil
        self.pendingBatch = nil
        return obligation(for: pendingBatch)
    }

    private func obligation(for pendingBatch: PendingBatch) -> SyncConvergenceLocalObligation {
        SyncConvergenceLocalObligation(
            batch: MacSyncBatch(
                id: pendingBatch.id,
                originDeviceID: originDeviceID,
                createdAt: pendingBatch.createdAt,
                batchSequence: pendingBatch.batchSequence,
                changes: pendingBatch.capturedChanges.map(\.change)
            ),
            capturedChanges: pendingBatch.capturedChanges
        )
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }

    private func removeObligationContinuation(id: UUID) {
        obligationContinuations[id] = nil
    }

    private func scheduleReadyEmission(batchID: MacSyncBatchID?, readyAt: Date?) {
        readinessTask?.cancel()
        guard let batchID, let readyAt else { return }

        readinessTask = Task { [weak self, sleep, quietWindow] in
            await sleep(quietWindow)
            guard !Task.isCancelled else { return }
            await self?.emitReadyBatchIfStillCurrent(batchID: batchID, readyAt: readyAt)
        }
    }

    private func emitReadyBatchIfStillCurrent(batchID: MacSyncBatchID, readyAt: Date) {
        guard pendingBatch?.id == batchID, pendingBatch?.readyAt == readyAt else { return }
        emitReadyBatches(at: readyAt)
    }
}

private struct PendingBatch {
    let id: MacSyncBatchID
    let createdAt: Date
    let batchSequence: UInt64?
    var capturedChanges: [SyncConvergenceCapturedLocalChange]

    var affectedNoteIDs: Set<UUID> {
        Set(capturedChanges.map { SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) })
    }
    var readyAt: Date
}
#endif
