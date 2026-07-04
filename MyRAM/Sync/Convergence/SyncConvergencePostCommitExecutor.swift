import Foundation

actor SyncConvergencePostCommitExecutor {
    private let store: SyncConvergencePostCommitStateStore
    private let queueCleanupAdapter: SyncConvergenceQueueCleanupAdapter
    private let legacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter?
    private let presentationAdapter: SyncConvergencePresentationAdapter
    private var activeRun: (id: UUID, task: Task<SyncConvergencePostCommitOutcome, Never>)?

    init(
        store: SyncConvergencePostCommitStateStore,
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
        let originalState = loaded.postCommitState
        guard originalState != .none else {
            return .complete
        }

        let effectiveCleanupPlan = request.cleanupPlan.gated(by: originalState)
        let effectivePresentationPlan = request.presentationPlan.gated(by: originalState)
        var completed: Set<SyncConvergencePostCommitPendingWork> = []

        if originalState.queueCleanupPending {
            if (try? performQueueCleanup(batchIDs: effectiveCleanupPlan.batchIDs)) == true {
                completed.insert(.queueCleanup)
            }
        }

        if originalState.legacyCleanupPending {
            if let legacyCleanupAdapter {
                let result = await legacyCleanupAdapter.performLegacyCleanup(for: request)
                if result == .verifiedComplete {
                    completed.insert(.legacyCleanup)
                }
            }
        }

        if originalState.presentationRefreshPending {
            if await performPresentationRefresh(
                request,
                plan: effectivePresentationPlan
            ) == .verifiedComplete {
                completed.insert(.presentationRefresh)
            }
        }

        let updatedState = SyncConvergencePostCommitState(
            queueCleanupPending: originalState.queueCleanupPending && !completed.contains(.queueCleanup),
            legacyCleanupPending: originalState.legacyCleanupPending && !completed.contains(.legacyCleanup),
            presentationRefreshPending: originalState.presentationRefreshPending && !completed.contains(.presentationRefresh)
        )

        guard updatedState != originalState else {
            return pendingOutcome(for: updatedState)
        }

        do {
            let persisted = try store.compareAndSetPostCommitState(
                identity: request.persistedIncorporationIdentity,
                expectedPayloadData: loaded.postCommitStatePayloadData,
                newState: updatedState
            )
            return pendingOutcome(for: persisted.postCommitState)
        } catch {
            var pending = originalState.pendingWork
            pending.insert(.postCommitStatePersistence)
            return .pending(pending)
        }
    }

    private func executeTombstone(_ request: SyncConvergencePostCommitRequest) -> SyncConvergencePostCommitOutcome {
        guard request.sourceBatchID == request.persistedIncorporationIdentity.batchID else {
            return .failedBeforeWork(.inconsistentIncorporationIdentity(batchID: request.sourceBatchID))
        }
        guard request.cleanupPlan.retryQueueCleanup else {
            return .complete
        }
        guard (try? performQueueCleanup(batchIDs: [request.sourceBatchID])) == true else {
            return .pending([.queueCleanup])
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
        plan: SyncConvergencePresentationPlan
    ) async -> SyncConvergencePostCommitAdapterResult {
        for noteID in plan.noteRoutings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let routing = plan.noteRoutings[noteID], routing != .none else {
                continue
            }
            do {
                guard let note = try store.loadCommittedNote(id: noteID) else {
                    return .failed
                }
                let presentationRequest = SyncConvergencePresentationRequest(
                    incorporationIdentity: request.persistedIncorporationIdentity,
                    noteID: noteID,
                    routing: routing,
                    committedNote: note,
                    committedBodyHash: SyncBatchContentHash.sha256Hex(for: note.body),
                    committedTitle: note.title
                )
                let result = await presentationAdapter.refreshPresentation(for: presentationRequest)
                guard result == .verifiedComplete else {
                    return result
                }
            } catch {
                return .failed
            }
        }
        return .verifiedComplete
    }

    private func pendingOutcome(for state: SyncConvergencePostCommitState) -> SyncConvergencePostCommitOutcome {
        let pending = state.pendingWork
        return pending.isEmpty ? .complete : .pending(pending)
    }
}

extension FileBackedSyncBatchQueue: SyncConvergenceQueueCleanupAdapter {
    func containsBatch(withID id: SyncBatchID) throws -> Bool {
        contains(id)
    }
}
