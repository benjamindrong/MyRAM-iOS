import Foundation

struct SyncConvergencePostCommitRequest: Equatable, Sendable {
    let sourceBatchID: UUID
    let affectedNoteIDs: Set<UUID>
    let cleanupPlan: SyncConvergenceCleanupPlan
    let presentationPlan: SyncConvergencePresentationPlan
    let persistedIncorporationIdentity: SyncConvergencePersistedIncorporationIdentity

    init(result: SyncConvergenceIncorporationResult) {
        self.sourceBatchID = result.batchID
        self.affectedNoteIDs = result.affectedNoteIDs
        self.cleanupPlan = result.cleanupPlan
        self.presentationPlan = result.presentationPlan
        self.persistedIncorporationIdentity = result.persistedIncorporationIdentity
    }

    init(
        sourceBatchID: UUID,
        affectedNoteIDs: Set<UUID>,
        cleanupPlan: SyncConvergenceCleanupPlan,
        presentationPlan: SyncConvergencePresentationPlan,
        persistedIncorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    ) {
        self.sourceBatchID = sourceBatchID
        self.affectedNoteIDs = affectedNoteIDs
        self.cleanupPlan = cleanupPlan
        self.presentationPlan = presentationPlan
        self.persistedIncorporationIdentity = persistedIncorporationIdentity
    }
}

enum SyncConvergencePostCommitOutcome: Equatable, Sendable {
    case complete
    case pending(Set<SyncConvergencePostCommitPendingWork>)
    case failedBeforeWork(SyncConvergencePostCommitFailure)
}

enum SyncConvergencePostCommitPendingWork: Hashable, Sendable {
    case queueCleanup
    case legacyCleanup
    case presentationRefresh
    case postCommitStatePersistence
}

enum SyncConvergencePostCommitFailure: Error, Equatable, Sendable {
    case missingAuthoritativeIncorporation(batchID: UUID)
    case inconsistentIncorporationIdentity(batchID: UUID)
    case malformedPostCommitState(batchID: UUID)
    case missingLegacyCleanupAdapter(batchID: UUID)
    case persistence
    case unexpected
}

enum SyncConvergencePostCommitAdapterResult: Equatable, Sendable {
    case verifiedComplete
    case stillPending
    case failed
}

struct SyncConvergencePresentationRequest: Equatable, Sendable {
    let incorporationIdentity: SyncConvergencePersistedIncorporationIdentity
    let noteID: UUID
    let routing: SyncConvergencePresentationRouting
    let committedNote: SyncConvergenceMutableNoteRecord
    let committedBodyHash: String
    let committedTitle: String
}

enum SyncConvergencePostCommitLoadedState: Equatable {
    case fullRoot(SyncConvergencePostCommitFullRootState)
    case tombstone(SyncConvergenceIncorporatedTombstoneProjection)
    case missing
    case inconsistent
}

struct SyncConvergencePostCommitFullRootState: Equatable {
    let root: SyncConvergenceIncorporatedRootProjection
    let postCommitState: SyncConvergencePostCommitState
    let postCommitStatePayloadData: Data
}

protocol SyncConvergencePostCommitStateStore {
    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord?

    func compareAndSetPostCommitState(
        identity: SyncConvergencePersistedIncorporationIdentity,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState
}

protocol SyncConvergenceQueueCleanupAdapter {
    func removeBatches(withIDs ids: Set<SyncBatchID>) throws
    func containsBatch(withID id: SyncBatchID) throws -> Bool
}

protocol SyncConvergenceLegacyCleanupAdapter {
    func performLegacyCleanup(for request: SyncConvergencePostCommitRequest) async -> SyncConvergencePostCommitAdapterResult
}

protocol SyncConvergencePresentationAdapter {
    func refreshPresentation(for request: SyncConvergencePresentationRequest) async -> SyncConvergencePostCommitAdapterResult
}

extension SyncConvergencePostCommitState {
    var pendingWork: Set<SyncConvergencePostCommitPendingWork> {
        var work: Set<SyncConvergencePostCommitPendingWork> = []
        if queueCleanupPending {
            work.insert(.queueCleanup)
        }
        if legacyCleanupPending {
            work.insert(.legacyCleanup)
        }
        if presentationRefreshPending {
            work.insert(.presentationRefresh)
        }
        return work
    }
}
