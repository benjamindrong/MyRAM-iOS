import Foundation

actor IPhoneSyncBatchAccumulator {
    private let originDeviceID: SyncBatchDeviceID
    private let quietWindow: TimeInterval
    private let batchIDProvider: @Sendable () -> SyncBatchID
    private let batchSequenceProvider: @Sendable () -> SyncBatchSequenceReservation
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pendingBatch: PendingBatch?
    private var preparedCollection: SyncPreparedLocalObligationCollection?
    private var lastSequenceReservationIssue: SyncBatchSequenceReservation.SequenceIssue?
    private var readinessTask: Task<Void, Never>?
    private var preparedRetryTask: Task<Void, Never>?
    private var preparedRetryAttempt = 0
    private let preparedRetryDelays: [TimeInterval]
    private var continuations: [UUID: AsyncStream<SyncPreparedLocalObligationCollection>.Continuation] = [:]

    init(
        originDeviceID: SyncBatchDeviceID,
        quietWindow: TimeInterval = 3,
        batchIDProvider: @escaping @Sendable () -> SyncBatchID = { UUID() },
        batchSequenceProvider: (@Sendable () -> SyncBatchSequenceReservation)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        preparedRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]
    ) {
        self.originDeviceID = originDeviceID
        self.quietWindow = quietWindow
        self.batchIDProvider = batchIDProvider
        let sequenceStore = SyncBatchSequenceStore()
        self.batchSequenceProvider = batchSequenceProvider ?? {
            sequenceStore.nextSequence(for: originDeviceID)
        }
        self.sleep = sleep
        self.preparedRetryDelays = preparedRetryDelays.isEmpty
            ? [2]
            : preparedRetryDelays
    }

    deinit {
        readinessTask?.cancel()
        preparedRetryTask?.cancel()
    }

    func readyBatches() -> AsyncStream<SyncPreparedLocalObligationCollection> {
        let streamID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SyncPreparedLocalObligationCollection.self)
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
        recordAndTakeBoundaryObligations(
            adding: capturedChanges,
            affecting: noteID,
            at: date
        ).first
    }

    func recordAndTakeBoundaryObligations(
        adding capturedChanges: [SyncConvergenceCapturedLocalChange],
        affecting noteID: UUID,
        at date: Date = .now
    ) -> [SyncConvergenceLocalObligation] {
        appendCapturedChanges(capturedChanges, at: date)
        return extractPendingBatches { pendingBatch in
            pendingBatch.capturedChanges.contains { captured in
                guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation(captured.change) else { return false }
                return SyncConvergenceLocalEvidenceCapture.noteID(for: captured.change) == noteID
            }
        }
    }

    private func appendCapturedChanges(_ capturedChanges: [SyncConvergenceCapturedLocalChange], at date: Date) {
        guard !capturedChanges.isEmpty else { return }
        if pendingBatch == nil {
            pendingBatch = PendingBatch(
                id: batchIDProvider(),
                createdAt: date,
                batchSequence: reserveBatchSequence(),
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
        guard let collection = readyCollectionIfAvailable(at: date) else { return }
        for continuation in continuations.values {
            continuation.yield(collection)
        }
    }

    func takeReadyBatch(at date: Date = .now) -> SyncConvergenceLocalObligation? {
        takeReadyBatches(at: date).first
    }

    func takeReadyBatches(at date: Date = .now) -> [SyncConvergenceLocalObligation] {
        takeReadyCollection(at: date)?.obligations ?? []
    }

    func takeReadyCollection(at date: Date = .now) -> SyncPreparedLocalObligationCollection? {
        prepareCollection { pendingBatch in
            date >= pendingBatch.readyAt
        }
    }

    private func readyCollectionIfAvailable(at date: Date) -> SyncPreparedLocalObligationCollection? {
        takeReadyCollection(at: date)
    }

    func takePendingBatchNow() -> SyncConvergenceLocalObligation? {
        takePendingBatchesNow().first
    }

    func takePendingBatchesNow() -> [SyncConvergenceLocalObligation] {
        takePendingCollectionNow()?.obligations ?? []
    }

    func takePendingCollectionNow() -> SyncPreparedLocalObligationCollection? {
        prepareCollection { _ in true }
    }

    func containsPendingBodyChange(for noteID: UUID) -> Bool {
        pendingBatch?.capturedChanges.contains {
            guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation($0.change) else { return false }
            return SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) == noteID
        } ?? false
    }

    func takePendingObligationIfAffecting(noteID: UUID) -> SyncConvergenceLocalObligation? {
        takePendingObligationsIfAffecting(noteID: noteID).first
    }

    func takePendingObligationsIfAffecting(
        noteID: UUID
    ) -> [SyncConvergenceLocalObligation] {
        takePendingCollectionIfAffecting(noteID: noteID)?.obligations ?? []
    }

    func takePendingCollectionIfAffecting(
        noteID: UUID
    ) -> SyncPreparedLocalObligationCollection? {
        prepareCollection { pendingBatch in
            pendingBatch.capturedChanges.contains {
                SyncConvergenceLocalEvidenceCapture.noteID(for: $0.change) == noteID
            }
        }
    }

    private func extractPendingBatches(
        when shouldExtract: (PendingBatch) -> Bool
    ) -> [SyncConvergenceLocalObligation] {
        prepareCollection(when: shouldExtract)?.obligations ?? []
    }

    private func prepareCollection(
        when shouldPrepare: (PendingBatch) -> Bool
    ) -> SyncPreparedLocalObligationCollection? {
        if let preparedCollection {
            return preparedCollection
        }
        guard let pendingBatch, shouldPrepare(pendingBatch),
              let collection = try? makePreparedCollection(for: pendingBatch) else {
            return nil
        }
        readinessTask?.cancel()
        readinessTask = nil
        self.pendingBatch = nil
        preparedCollection = collection
        preparedRetryAttempt = 0
        return collection
    }

    private func makePreparedCollection(
        for pendingBatch: PendingBatch
    ) throws -> SyncPreparedLocalObligationCollection? {
        SyncPreparedLocalObligationCollection(
            try obligations(for: pendingBatch)
        )
    }

    func commitPreparedCollection(token: UUID) -> Bool {
        guard preparedCollection?.token == token else { return false }
        preparedCollection = nil
        preparedRetryTask?.cancel()
        preparedRetryTask = nil
        preparedRetryAttempt = 0
        return true
    }

    func reportPreparedCollectionAdmissionResult(
        token: UUID,
        result: SyncConvergenceLocalObligationCollectionAdmissionResult
    ) {
        guard preparedCollection?.token == token else { return }
        switch result {
        case .admitted:
            return
        case .retryableCapacity, .retryablePersistenceFailure:
            schedulePreparedRetry(token: token)
        case .terminal:
            preparedRetryTask?.cancel()
            preparedRetryTask = nil
            preparedRetryAttempt = 0
        }
    }

    private func schedulePreparedRetry(token: UUID) {
        preparedRetryTask?.cancel()
        let delay = preparedRetryDelays[min(
            preparedRetryAttempt,
            preparedRetryDelays.count - 1
        )]
        preparedRetryAttempt += 1
        preparedRetryTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.emitPreparedRetryIfCurrent(token: token)
        }
    }

    private func emitPreparedRetryIfCurrent(token: UUID) {
        preparedRetryTask = nil
        guard let collection = preparedCollection,
              collection.token == token else {
            return
        }
        for continuation in continuations.values {
            continuation.yield(collection)
        }
    }

    private func obligations(
        for pendingBatch: PendingBatch
    ) throws -> [SyncConvergenceLocalObligation] {
        let partitions = try SyncBatchDeliveryPartitionPlanner.durablePartitions(
            pendingBatch.capturedChanges
        )
        return partitions.enumerated().map { index, capturedChanges in
            let batch = makeBatch(
                id: index == 0 ? pendingBatch.id : batchIDProvider(),
                createdAt: pendingBatch.createdAt,
                batchSequence: index == 0 ? pendingBatch.batchSequence : reserveBatchSequence(),
                capturedChanges: capturedChanges
            )
            return SyncConvergenceLocalObligation(
                batch: batch,
                capturedChanges: capturedChanges
            )
        }
    }

    private func makeBatch(
        id: SyncBatchID,
        createdAt: Date,
        batchSequence: UInt64?,
        capturedChanges: [SyncConvergenceCapturedLocalChange]
    ) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            batchSequence: batchSequence,
            changes: capturedChanges.map(\.change)
        )
    }

    private func reserveBatchSequence() -> UInt64? {
        switch batchSequenceProvider() {
        case .reserved(let sequence):
            lastSequenceReservationIssue = nil
            return sequence
        case .sequenceLess(let issue):
            lastSequenceReservationIssue = issue
            return nil
        }
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
