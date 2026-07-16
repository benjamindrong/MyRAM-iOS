import Foundation

actor SyncConvergencePostCommitExecutor {
    private let store: SyncConvergencePostCommitStateStore & SyncConvergencePendingPostCommitSource
    private let queueCleanupAdapter: SyncConvergenceQueueCleanupAdapter
    private let legacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter?
    private let presentationAdapter: SyncConvergencePresentationAdapter
    private var activeRun: (id: UUID, task: Task<SyncConvergencePostCommitOutcome, Never>)?
    private var acknowledgedPresentations: Set<AcknowledgedPresentation> = []

    init(
        store: SyncConvergencePostCommitStateStore & SyncConvergencePendingPostCommitSource,
        queueCleanupAdapter: SyncConvergenceQueueCleanupAdapter,
        legacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter? = nil,
        presentationAdapter: SyncConvergencePresentationAdapter
    ) {
        self.store = store
        self.queueCleanupAdapter = queueCleanupAdapter
        self.legacyCleanupAdapter = legacyCleanupAdapter
        self.presentationAdapter = presentationAdapter
    }

    func execute(_ request: SyncConvergencePostCommitRequest) async -> SyncConvergencePostCommitOutcome {
        let predecessor = activeRun?.task
        let runID = UUID()
        let run = Task { [self] in
            if let predecessor {
                _ = await predecessor.value
            }
            return await executeSerialized(request)
        }
        activeRun = (runID, run)
        let outcome = await run.value
        if activeRun?.id == runID {
            activeRun = nil
        }
        return outcome
    }

    private func executeSerialized(_ request: SyncConvergencePostCommitRequest) async -> SyncConvergencePostCommitOutcome {
        do {
            switch try store.loadState(matching: request.persistedIncorporationIdentity) {
            case .fullRoot(let loaded):
                return await executeFullRoot(request, loaded: loaded)
            case .tombstone:
                return executeTombstone(request)
            case .missing:
                return .failedBeforeWork(.missingAuthoritativeIncorporation(batchID: request.sourceBatchID))
            case .inconsistent:
                return .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: request.sourceBatchID))
            }
        } catch let failure as SyncConvergencePostCommitFailure {
            return .failedBeforeWork(failure)
        } catch {
            return .failedBeforeWork(.unexpected)
        }
    }

    private func executeFullRoot(
        _ request: SyncConvergencePostCommitRequest,
        loaded: SyncConvergencePostCommitFullRootState
    ) async -> SyncConvergencePostCommitOutcome {
        var current = loaded
        guard current.postCommitState != .none else { return .complete }
        guard let workPayload = current.postCommitWorkPayload else {
            return .failedBeforeWork(.missingPostCommitWorkPayload(batchID: request.sourceBatchID))
        }

        if current.postCommitState.presentationRefreshPending {
            let outcome = await executePresentationIfNeeded(request, loaded: current, workPayload: workPayload)
            switch outcome {
            case .complete:
                guard case .fullRoot(let reloaded) = reloadState(for: request) else {
                    return .failedBeforeWork(.missingAuthoritativeIncorporation(batchID: request.sourceBatchID))
                }
                current = reloaded
            case .pending, .failedBeforeWork:
                return outcome
            }
        }

        if current.postCommitState.legacyCleanupPending {
            let outcome = await executeLegacyCleanupIfNeeded(request, loaded: current)
            switch outcome {
            case .complete:
                guard case .fullRoot(let reloaded) = reloadState(for: request) else {
                    return .failedBeforeWork(.missingAuthoritativeIncorporation(batchID: request.sourceBatchID))
                }
                current = reloaded
            case .pending, .failedBeforeWork:
                return outcome
            }
        }

        if current.postCommitState.queueCleanupPending {
            let outcome = executeQueueCleanupIfNeeded(request, loaded: current, workPayload: workPayload)
            switch outcome {
            case .complete:
                guard case .fullRoot(let reloaded) = reloadState(for: request) else {
                    return .failedBeforeWork(.missingAuthoritativeIncorporation(batchID: request.sourceBatchID))
                }
                current = reloaded
            case .pending, .failedBeforeWork:
                return outcome
            }
        }

        return .complete
    }

    private func executePresentationIfNeeded(
        _ request: SyncConvergencePostCommitRequest,
        loaded: SyncConvergencePostCommitFullRootState,
        workPayload: SyncConvergencePostCommitWorkPayloadV1
    ) async -> SyncConvergencePostCommitOutcome {
        let acknowledged = acknowledgedPresentationIdentities(request, entries: workPayload.presentationEntries)
        let result: SyncConvergencePostCommitAdapterResult
        if acknowledged.isSubset(of: acknowledgedPresentations) {
            result = .verifiedComplete
        } else {
            result = await performPresentationRefresh(request, entries: workPayload.presentationEntries)
        }

        switch result {
        case .verifiedComplete:
            acknowledgedPresentations.formUnion(acknowledged)
            return persistCompletedWork(.presentationRefresh, request: request, loaded: loaded)
        case .stillPending:
            return pendingOutcome(blocking: .presentationRefresh, for: loaded.postCommitState)
        case .failed:
            return .failedBeforeWork(.persistence)
        }
    }

    private func executeLegacyCleanupIfNeeded(
        _ request: SyncConvergencePostCommitRequest,
        loaded: SyncConvergencePostCommitFullRootState
    ) async -> SyncConvergencePostCommitOutcome {
        guard let legacyCleanupAdapter else {
            return pendingOutcome(blocking: .legacyCleanup, for: loaded.postCommitState)
        }
        guard await legacyCleanupAdapter.performLegacyCleanup(for: request) == .verifiedComplete else {
            return pendingOutcome(blocking: .legacyCleanup, for: loaded.postCommitState)
        }
        return persistCompletedWork(.legacyCleanup, request: request, loaded: loaded)
    }

    private func executeQueueCleanupIfNeeded(
        _ request: SyncConvergencePostCommitRequest,
        loaded: SyncConvergencePostCommitFullRootState,
        workPayload: SyncConvergencePostCommitWorkPayloadV1
    ) -> SyncConvergencePostCommitOutcome {
        do {
            guard try performQueueCleanup(batchIDs: Set(workPayload.queueCleanupBatchIDs)) else {
                return pendingOutcome(blocking: .queueCleanup, for: loaded.postCommitState)
            }
        } catch {
            return pendingOutcome(blocking: .queueCleanup, for: loaded.postCommitState)
        }
        return persistCompletedWork(.queueCleanup, request: request, loaded: loaded)
    }

    private func persistCompletedWork(
        _ work: SyncConvergencePostCommitPendingWork,
        request: SyncConvergencePostCommitRequest,
        loaded: SyncConvergencePostCommitFullRootState
    ) -> SyncConvergencePostCommitOutcome {
        let original = loaded.postCommitState
        let updated = SyncConvergencePostCommitState(
            queueCleanupPending: work == .queueCleanup ? false : original.queueCleanupPending,
            legacyCleanupPending: work == .legacyCleanup ? false : original.legacyCleanupPending,
            presentationRefreshPending: work == .presentationRefresh ? false : original.presentationRefreshPending
        )

        do {
            let persisted = try store.compareAndSetPostCommitState(
                expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loaded.root),
                expectedPayloadData: loaded.postCommitStatePayloadData,
                newState: updated
            )
            if !persisted.postCommitState.presentationRefreshPending {
                clearAcknowledgedPresentations(for: request)
            }
            return .complete
        } catch {
            if work == .presentationRefresh,
               case .fullRoot(let reloaded) = reloadState(for: request),
               !reloaded.postCommitState.presentationRefreshPending {
                clearAcknowledgedPresentations(for: request)
                return .complete
            }
            var pending = original.pendingWork
            pending.insert(.postCommitStatePersistence)
            return .pending(blocking: .postCommitStatePersistence, outstanding: pending)
        }
    }

    private func reloadState(for request: SyncConvergencePostCommitRequest) -> SyncConvergencePostCommitLoadedState {
        do {
            return try store.loadState(matching: request.persistedIncorporationIdentity)
        } catch {
            return .missing
        }
    }

    private func executeTombstone(_ request: SyncConvergencePostCommitRequest) -> SyncConvergencePostCommitOutcome {
        guard request.sourceBatchID == request.persistedIncorporationIdentity.batchID else {
            return .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: request.sourceBatchID))
        }
        let queueCleanupComplete: Bool
        do {
            queueCleanupComplete = try performQueueCleanup(batchIDs: [request.sourceBatchID])
        } catch {
            return .pending(blocking: .queueCleanup, outstanding: [.queueCleanup])
        }
        guard queueCleanupComplete else {
            return .pending(blocking: .queueCleanup, outstanding: [.queueCleanup])
        }
        return .complete
    }

    private func performQueueCleanup(batchIDs: Set<SyncBatchID>) throws -> Bool {
        guard !batchIDs.isEmpty else { return true }
        try queueCleanupAdapter.removeBatches(withIDs: batchIDs)
        for batchID in batchIDs {
            if try queueCleanupAdapter.containsBatch(withID: batchID) {
                return false
            }
        }
        return true
    }

    private func performPresentationRefresh(
        _ request: SyncConvergencePostCommitRequest,
        entries: [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry]
    ) async -> SyncConvergencePostCommitAdapterResult {
        guard !entries.isEmpty else { return .failed }
        do {
            let pendingRequests = try store.loadPendingPostCommitRequests()
            let laterPendingPresentationNoteIDs = pendingPresentationNoteIDs(
                after: request,
                in: pendingRequests
            )
            for entry in entries.sorted(by: { $0.noteID.uuidString < $1.noteID.uuidString }) {
                // A later pending request for this note owns the current presentation state. Its
                // own entry will catch the UI up, so the older entry is already satisfied.
                if laterPendingPresentationNoteIDs.contains(entry.noteID) {
                    continue
                }
                // The note may be gone by the time presentation catches up (deleted, or never
                // locally present). There's nothing left to refresh for it, so treat it as satisfied
                // rather than failing the whole batch.
                guard let note = try store.loadCommittedNote(id: entry.noteID) else {
                    continue
                }
                let presentationRequest = SyncConvergencePresentationRequest(
                    incorporationIdentity: request.persistedIncorporationIdentity,
                    noteID: entry.noteID,
                    routing: entry.routing.routing,
                    expectedPreBodyHash: entry.expectedPreBodyHash,
                    committedPostBodyHash: entry.committedPostBodyHash,
                    incrementalOperations: entry.incrementalOperations,
                    rewriteSafetyReceipt: entry.rewriteSafetyReceipt,
                    committedNote: note,
                    committedBodyHash: SyncBatchContentHash.sha256Hex(for: note.body),
                    committedTitle: note.title
                )
                let result = await presentationAdapter.refreshPresentation(for: presentationRequest)
                guard result == .verifiedComplete else {
                    return result
                }
            }
        } catch {
            return .failed
        }
        return .verifiedComplete
    }

    private func pendingPresentationNoteIDs(
        after request: SyncConvergencePostCommitRequest,
        in pendingRequests: [SyncConvergencePostCommitRequest]
    ) -> Set<UUID> {
        guard let requestIndex = pendingRequests.firstIndex(where: {
            $0.persistedIncorporationIdentity == request.persistedIncorporationIdentity
        }), requestIndex < pendingRequests.index(before: pendingRequests.endIndex) else {
            return []
        }
        return pendingRequests[(requestIndex + 1)...].reduce(into: Set()) { noteIDs, pendingRequest in
            guard pendingRequest.cleanupPlan.retryPresentationRefresh else { return }
            // Only a routing that actually re-establishes editor content (or closes the editor
            // entirely) can be relied on to catch the UI up. A later .none entry only refreshes
            // list metadata, so it can't stand in for an older incremental/whole-note refresh.
            for noteID in pendingRequest.affectedNoteIDs {
                guard let routing = pendingRequest.presentationPlan.noteRoutings[noteID], routing != .none else { continue }
                noteIDs.insert(noteID)
            }
        }
    }

    private func pendingOutcome(
        blocking: SyncConvergencePostCommitPendingWork,
        for state: SyncConvergencePostCommitState
    ) -> SyncConvergencePostCommitOutcome {
        let outstanding = state.pendingWork
        return outstanding.isEmpty ? .complete : .pending(blocking: blocking, outstanding: outstanding)
    }

    private func acknowledgedPresentationIdentities(
        _ request: SyncConvergencePostCommitRequest,
        entries: [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry]
    ) -> Set<AcknowledgedPresentation> {
        Set(entries.map {
            AcknowledgedPresentation(
                incorporationBatchID: request.persistedIncorporationIdentity.batchID,
                noteID: $0.noteID,
                committedPostBodyHash: $0.committedPostBodyHash,
                result: .verifiedComplete
            )
        })
    }

    private func clearAcknowledgedPresentations(for request: SyncConvergencePostCommitRequest) {
        acknowledgedPresentations = acknowledgedPresentations.filter {
            $0.incorporationBatchID != request.persistedIncorporationIdentity.batchID
        }
    }
}

private struct AcknowledgedPresentation: Hashable {
    let incorporationBatchID: UUID
    let noteID: UUID
    let committedPostBodyHash: String
    let result: SyncConvergencePostCommitAdapterResult
}

extension FileBackedSyncBatchQueue: SyncConvergenceQueueCleanupAdapter {
    func containsBatch(withID id: SyncBatchID) throws -> Bool {
        contains(id)
    }
}
