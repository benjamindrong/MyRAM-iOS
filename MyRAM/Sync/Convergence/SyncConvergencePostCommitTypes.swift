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
    case missingPostCommitWorkPayload(batchID: UUID)
    case malformedPostCommitWorkPayload(batchID: UUID)
    case contradictoryPostCommitWorkPayload(batchID: UUID)
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
    let expectedPreBodyHash: String
    let committedPostBodyHash: String
    let incrementalOperations: [SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload]
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
    let postCommitWorkPayload: SyncConvergencePostCommitWorkPayloadV1?
    let postCommitWorkPayloadData: Data?
}

protocol SyncConvergencePostCommitStateStore {
    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord?

    func compareAndSetPostCommitState(
        expectedRoot: SyncConvergencePostCommitRootSnapshot,
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

struct SyncConvergencePostCommitRootSnapshot: Equatable, Sendable {
    let root: SyncConvergenceIncorporatedRootProjection
}

struct SyncConvergencePostCommitWorkPayloadV1: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 1

    let formatVersion: Int
    let queueCleanupBatchIDs: [UUID]
    let legacyCleanupRequired: Bool
    let presentationEntries: [PresentationEntry]

    init(
        queueCleanupBatchIDs: Set<UUID>,
        legacyCleanupRequired: Bool,
        presentationEntries: [PresentationEntry]
    ) {
        self.formatVersion = Self.supportedFormatVersion
        self.queueCleanupBatchIDs = queueCleanupBatchIDs.sortedByUUIDString()
        self.legacyCleanupRequired = legacyCleanupRequired
        self.presentationEntries = presentationEntries.sorted { $0.noteID.uuidString < $1.noteID.uuidString }
    }

    func encodedPayloadData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodePayloadData(_ data: Data) throws -> Self {
        let payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        try payload.validate()
        return payload
    }

    func derivedState() -> SyncConvergencePostCommitState {
        SyncConvergencePostCommitState(
            queueCleanupPending: !queueCleanupBatchIDs.isEmpty,
            legacyCleanupPending: legacyCleanupRequired,
            presentationRefreshPending: !presentationEntries.isEmpty
        )
    }

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw SyncConvergencePostCommitWorkPayloadError.unsupportedVersion
        }
        guard queueCleanupBatchIDs == Set(queueCleanupBatchIDs).sortedByUUIDString() else {
            throw SyncConvergencePostCommitWorkPayloadError.duplicateCleanupIDs
        }
        let noteIDs = presentationEntries.map(\.noteID)
        guard noteIDs == Set(noteIDs).sortedByUUIDString() else {
            throw SyncConvergencePostCommitWorkPayloadError.duplicatePresentationNoteIDs
        }
        for entry in presentationEntries {
            try entry.validate()
        }
    }

    struct PresentationEntry: Codable, Equatable, Sendable {
        let noteID: UUID
        let routing: SyncConvergencePostCommitPresentationRoutingPayload
        let expectedPreBodyHash: String
        let committedPostBodyHash: String
        let incrementalOperations: [IncrementalOperationPayload]

        func validate() throws {
            switch routing {
            case .incremental:
                break
            case .wholeNoteFallback:
                guard incrementalOperations.isEmpty else {
                    throw SyncConvergencePostCommitWorkPayloadError.contradictoryPresentationEntry
                }
            }
        }
    }

    struct IncrementalOperationPayload: Codable, Equatable, Sendable {
        let operationIndex: Int
        let operationIdentity: OperationIdentityPayload
    }
}

enum SyncConvergencePostCommitPresentationRoutingPayload: String, Codable, Equatable, Sendable {
    case incremental
    case wholeNoteFallback

    var routing: SyncConvergencePresentationRouting {
        switch self {
        case .incremental:
            return .incremental
        case .wholeNoteFallback:
            return .wholeNoteFallback
        }
    }

    init?(_ routing: SyncConvergencePresentationRouting) {
        switch routing {
        case .incremental:
            self = .incremental
        case .wholeNoteFallback:
            self = .wholeNoteFallback
        case .none:
            return nil
        }
    }
}

enum SyncConvergencePostCommitWorkPayloadError: Error, Equatable {
    case unsupportedVersion
    case duplicateCleanupIDs
    case duplicatePresentationNoteIDs
    case contradictoryPresentationEntry
}

private extension Set where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
