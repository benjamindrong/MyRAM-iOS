import Foundation

actor IPhoneSyncBatchAccumulator {
    private let originDeviceID: SyncBatchDeviceID
    private let quietWindow: TimeInterval
    private let batchIDProvider: @Sendable () -> SyncBatchID
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pendingBatch: PendingBatch?
    private var readinessTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SyncBatch>.Continuation] = [:]

    init(
        originDeviceID: SyncBatchDeviceID,
        quietWindow: TimeInterval = 3,
        batchIDProvider: @escaping @Sendable () -> SyncBatchID = { UUID() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    ) {
        self.originDeviceID = originDeviceID
        self.quietWindow = quietWindow
        self.batchIDProvider = batchIDProvider
        self.sleep = sleep
    }

    func readyBatches() -> AsyncStream<SyncBatch> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SyncBatch.self)
        continuations[streamID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: streamID) }
        }
        return stream
    }

    func record(_ change: SyncBatchChange, at date: Date = .now) {
        if pendingBatch == nil {
            pendingBatch = PendingBatch(
                id: batchIDProvider(),
                createdAt: date,
                changes: [],
                readyAt: date.addingTimeInterval(quietWindow)
            )
        }

        pendingBatch?.changes.append(change)
        pendingBatch?.readyAt = date.addingTimeInterval(quietWindow)
        scheduleReadyEmission(batchID: pendingBatch?.id, readyAt: pendingBatch?.readyAt)
    }

    func pendingBatchID() -> SyncBatchID? {
        pendingBatch?.id
    }

    func pendingReadyAt() -> Date? {
        pendingBatch?.readyAt
    }

    func emitReadyBatches(at date: Date = .now) {
        guard let batch = readyBatchIfAvailable(at: date) else { return }
        for continuation in continuations.values {
            continuation.yield(batch)
        }
    }

    func takeReadyBatch(at date: Date = .now) -> SyncBatch? {
        readyBatchIfAvailable(at: date)
    }

    private func readyBatchIfAvailable(at date: Date) -> SyncBatch? {
        guard let pendingBatch, date >= pendingBatch.readyAt else {
            return nil
        }

        readinessTask?.cancel()
        readinessTask = nil
        self.pendingBatch = nil
        return SyncBatch(
            id: pendingBatch.id,
            originDeviceID: originDeviceID,
            createdAt: pendingBatch.createdAt,
            changes: pendingBatch.changes
        )
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
    var changes: [SyncBatchChange]
    var readyAt: Date
}
