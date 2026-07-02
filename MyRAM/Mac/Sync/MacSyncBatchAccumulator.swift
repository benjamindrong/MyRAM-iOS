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

    func record(_ change: MacSyncChange, at date: Date = .now) {
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
                changes: [],
                readyAt: date.addingTimeInterval(quietWindow)
            )
        }

        pendingBatch?.changes.append(change)
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
        guard let batch = readyBatchIfAvailable(at: date) else { return }
        for continuation in continuations.values {
            continuation.yield(batch)
        }
    }

    func takeReadyBatch(at date: Date = .now) -> MacSyncBatch? {
        readyBatchIfAvailable(at: date)
    }

    private func readyBatchIfAvailable(at date: Date) -> MacSyncBatch? {
        guard let pendingBatch, date >= pendingBatch.readyAt else {
            return nil
        }

        readinessTask?.cancel()
        readinessTask = nil
        self.pendingBatch = nil
        return MacSyncBatch(
            id: pendingBatch.id,
            originDeviceID: originDeviceID,
            createdAt: pendingBatch.createdAt,
            batchSequence: pendingBatch.batchSequence,
            changes: pendingBatch.changes
        )
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
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
    var changes: [MacSyncChange]
    var readyAt: Date
}
#endif
