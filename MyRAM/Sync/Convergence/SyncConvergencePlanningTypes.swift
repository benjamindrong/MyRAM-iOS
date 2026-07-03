import Foundation

enum SyncConvergencePlanningOutcome: Equatable {
    case planned(ValidatedSyncConvergenceIncorporationInput)
    case alreadyIncorporated(SyncConvergenceCleanupPlan)
    case deferred(SyncConvergenceDeferredReason)
    case failedBeforeCommit(SyncConvergenceTransactionFailure)
}

struct ValidatedSyncConvergenceIncorporationInput: Equatable {
    let plan: SyncConvergenceBatchPlan
    let sourceBatch: SyncBatch
    let sourceSchemaVersion: Int
    let projectedFullIncorporationEvidenceBytes: Int

    var sourceBatchID: UUID { sourceBatch.id }
    var sourceOriginDeviceID: UUID { sourceBatch.originDeviceID }
    var sourceCreatedAt: Date { sourceBatch.createdAt }
    var sourceBatchSequence: UInt64? { sourceBatch.batchSequence }

    init(
        validatedPlanToken: SyncConvergenceValidatedPlanToken,
        plan: SyncConvergenceBatchPlan,
        sourceBatch: SyncBatch,
        sourceSchemaVersion: Int,
        projectedFullIncorporationEvidenceBytes: Int
    ) {
        _ = validatedPlanToken
        self.plan = plan
        self.sourceBatch = sourceBatch
        self.sourceSchemaVersion = sourceSchemaVersion
        self.projectedFullIncorporationEvidenceBytes = projectedFullIncorporationEvidenceBytes
    }
}

enum SyncConvergenceIncorporationOutcome: Equatable {
    case incorporated(SyncConvergenceIncorporationResult)
    case alreadyIncorporated(SyncConvergenceIncorporationResult)
    case failedBeforeCommit(SyncConvergenceTransactionFailure)
    case failedAndRolledBack(SyncConvergenceTransactionFailure)
}

struct SyncConvergenceIncorporationResult: Equatable {
    let batchID: UUID
    let affectedNoteIDs: Set<UUID>
    let cleanupPlan: SyncConvergenceCleanupPlan
    let presentationPlan: SyncConvergencePresentationPlan
    let persistedIncorporationIdentity: SyncConvergencePersistedIncorporationIdentity
}

struct SyncConvergencePersistedIncorporationIdentity: Equatable {
    let batchID: UUID
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
}

struct SyncConvergencePlanningInput: Equatable {
    let incomingBatch: SyncBatch
    let currentNotes: [SyncConvergenceProjectedNote]
    let retainedSnapshots: [SyncConvergenceRetainedSnapshot]
    let retainedLocalOperations: [SyncConvergenceRetainedOperation]
    let retainedRemoteOperations: [SyncConvergenceRetainedOperation]
    let queuedBatches: [SyncConvergenceQueuedBatch]
    let persistedTitleWinners: [SyncConvergenceTitleWinnerProjection]
    let incorporatedBatches: [SyncConvergenceIncorporatedBatchProjection]
    let incorporatedTombstones: [SyncConvergenceIncorporatedBatchProjection]
    let historyStates: [SyncConvergenceHistoryAccountingProjection]
    let supportedDigestFormatVersions: Set<Int>
    // nil means the candidate is a live newest arrival that follows every durable queue entry;
    // a queued-drain caller must pass the candidate's durable queue position explicitly.
    let candidateQueuePosition: Int?

    init(
        incomingBatch: SyncBatch,
        currentNotes: [SyncConvergenceProjectedNote] = [],
        retainedSnapshots: [SyncConvergenceRetainedSnapshot] = [],
        retainedLocalOperations: [SyncConvergenceRetainedOperation] = [],
        retainedRemoteOperations: [SyncConvergenceRetainedOperation] = [],
        queuedBatches: [SyncConvergenceQueuedBatch] = [],
        persistedTitleWinners: [SyncConvergenceTitleWinnerProjection] = [],
        incorporatedBatches: [SyncConvergenceIncorporatedBatchProjection] = [],
        incorporatedTombstones: [SyncConvergenceIncorporatedBatchProjection] = [],
        historyStates: [SyncConvergenceHistoryAccountingProjection] = [],
        supportedDigestFormatVersions: Set<Int> = [SyncConvergenceCanonicalBatchDigest.supportedFormatVersion],
        candidateQueuePosition: Int? = nil
    ) {
        self.incomingBatch = incomingBatch
        self.currentNotes = currentNotes
        self.retainedSnapshots = retainedSnapshots
        self.retainedLocalOperations = retainedLocalOperations
        self.retainedRemoteOperations = retainedRemoteOperations
        self.queuedBatches = queuedBatches
        self.persistedTitleWinners = persistedTitleWinners
        self.incorporatedBatches = incorporatedBatches
        self.incorporatedTombstones = incorporatedTombstones
        self.historyStates = historyStates
        self.supportedDigestFormatVersions = supportedDigestFormatVersions
        self.candidateQueuePosition = candidateQueuePosition
    }
}

struct SyncConvergenceBatchPlan: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let affectedNotePlans: [SyncConvergenceNotePlan]
    let incorporationEvidence: SyncConvergenceIncorporationPlan
    let historyPlan: SyncConvergenceHistoryPlan
    let cleanupPlan: SyncConvergenceCleanupPlan
    let presentationPlan: SyncConvergencePresentationPlan

    init(
        batchID: UUID,
        originDeviceID: UUID,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        affectedNotePlans: [SyncConvergenceNotePlan],
        incorporationEvidence: SyncConvergenceIncorporationPlan,
        historyPlan: SyncConvergenceHistoryPlan,
        cleanupPlan: SyncConvergenceCleanupPlan,
        presentationPlan: SyncConvergencePresentationPlan
    ) {
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.affectedNotePlans = affectedNotePlans
        self.incorporationEvidence = incorporationEvidence
        self.historyPlan = historyPlan
        self.cleanupPlan = cleanupPlan
        self.presentationPlan = presentationPlan
    }
}

struct SyncConvergenceNotePlan: Equatable {
    let noteID: UUID
    let creationEffect: SyncConvergenceCreationEffect?
    let bodyEffect: SyncConvergenceBodyEffect?
    let titleEffect: SyncConvergenceTitleEffect?
}

struct SyncConvergenceCreationEffect: Equatable {
    enum Verdict: Equatable {
        case create
        case idempotent
    }

    let verdict: Verdict
    let noteID: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let createdAt: Date
    let modifiedAt: Date
    let initialBodyHash: String
    let operationIdentity: OperationIdentityPayload
    let resultEvidence: SyncConvergenceResultEvidence
}

enum SyncConvergenceBodyEffect: Equatable {
    case matchingBaseIncremental(MatchingBaseBodyPlan)
    case reconstructedConflict(ReconstructedConflictBodyPlan)
    case legacyPositional(LegacyBodyPlan)
    case compatibilityNoopMissingNote(MissingNoteBodyNoopPlan)
}

struct MatchingBaseBodyPlan: Equatable {
    let noteID: UUID
    let initialBody: String
    let initialBodyHash: String
    let operations: [SyncConvergencePlannedBodyOperation]
    let finalBody: String
    let finalBodyHash: String
    let resultEvidence: SyncConvergenceResultEvidence
}

struct ReconstructedConflictBodyPlan: Equatable {
    let noteID: UUID
    let reconstructedBaseBody: String
    let reconstructedBaseHash: String
    let projectedPreMergeCurrentBody: String
    let projectedPreMergeCurrentHash: String
    let orderedOperationIdentities: [OperationIdentityPayload]
    let finalBody: String
    let finalBodyHash: String
    let retainedOperationAdditions: [SyncConvergencePlannedBodyOperation]
    let snapshotAdditions: [SyncConvergenceSnapshotAddition]
    let resultEvidence: SyncConvergenceResultEvidence
    let presentationRouting: SyncConvergencePresentationRouting
}

struct LegacyBodyPlan: Equatable {
    let noteID: UUID
    let initialBody: String
    let operations: [SyncConvergencePlannedBodyOperation]
    let finalBody: String
    let finalBodyHash: String
    let resultEvidence: SyncConvergenceResultEvidence
}

struct MissingNoteBodyNoopPlan: Equatable {
    let noteID: UUID
    let operationIdentities: [OperationIdentityPayload]
    let resultEvidence: SyncConvergenceResultEvidence
}

struct SyncConvergenceTitleEffect: Equatable {
    let priorTitle: String
    let priorWinningKey: CanonicalReplayKeyPayload?
    let candidateTitle: String
    let candidateOperationIdentity: OperationIdentityPayload
    let candidateCanonicalKey: CanonicalReplayKeyPayload
    let verdict: SyncConvergenceTitleVerdict
    let resultingTitle: String
    let resultingWinningKey: CanonicalReplayKeyPayload?
    let resultEvidence: SyncConvergenceResultEvidence
}

enum SyncConvergenceTitleVerdict: Equatable {
    case apply
    case ignoreOlder
    case idempotent
    case compatibilityNoopMissingNote
}

struct SyncConvergenceIncorporationPlan: Equatable {
    let operationIdentities: [OperationIdentityPayload]
    let resultEvidence: [SyncConvergenceResultEvidence]
}

struct SyncConvergenceHistoryPlan: Equatable {
    let retainedOperationAdditions: [SyncConvergencePlannedBodyOperation]
    let snapshotAdditions: [SyncConvergenceSnapshotAddition]
    let pressureNotes: Set<UUID>
}

struct SyncConvergencePresentationPlan: Equatable {
    let noteRoutings: [UUID: SyncConvergencePresentationRouting]
}

enum SyncConvergencePresentationRouting: Equatable {
    case incremental
    case wholeNoteFallback
    case none
}

struct SyncConvergenceResultEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case body
        case title
        case creation
    }

    let batchID: UUID
    let noteID: UUID
    let kind: Kind
    let preHash: String?
    let postHash: String?
    let canonicalReplayKey: CanonicalReplayKeyPayload?
}

struct SyncConvergencePlannedBodyOperation: Equatable {
    enum Kind: String, Equatable {
        case insert
        case delete
    }

    let noteID: UUID
    let kind: Kind
    let utf16Offset: Int
    let utf16Length: Int?
    let text: String?
    let expectedText: String?
    let baseContentHash: String?
    let resultContentHash: String
    let operationIdentity: OperationIdentityPayload
}

struct SyncConvergenceSnapshotAddition: Equatable {
    let noteID: UUID
    let contentHash: String
    let body: String
    let generation: Int
}

struct SyncConvergenceProjectedNote: Equatable {
    let noteID: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let createdAt: Date
    let modifiedAt: Date
}

struct SyncConvergenceMutableNoteRecord: Equatable {
    let noteID: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let createdAt: Date
    let modifiedAt: Date
}

struct SyncConvergenceNewNoteRecord: Equatable {
    let noteID: UUID
    let folderID: UUID?
    let title: String
    let body: String
    let createdAt: Date
    let modifiedAt: Date
}

struct SyncConvergenceUpdatedNoteRecord: Equatable {
    let noteID: UUID
    let title: String
    let body: String
    let modifiedAt: Date
}

struct SyncConvergenceRetainedSnapshot: Equatable {
    let noteID: UUID
    let contentHash: String
    let body: String
    let generation: Int
}

struct SyncConvergenceRetainedOperation: Equatable {
    let noteID: UUID
    let batchID: UUID
    let originDeviceID: UUID
    let operationIndex: Int
    let operationKind: SyncConvergencePlannedBodyOperation.Kind
    let utf16Offset: Int
    let utf16Length: Int?
    let text: String?
    let expectedText: String?
    let baseContentHash: String?
    let resultContentHash: String?
    let canonicalReplayKey: CanonicalReplayKeyPayload
}

struct SyncConvergenceQueuedBatch: Equatable {
    let batch: SyncBatch
    let queuePosition: Int
}

struct SyncConvergenceQueueSelection: Equatable {
    let candidateBatch: SyncConvergenceQueuedBatch
    let eligibleEvidenceBatches: [SyncConvergenceQueuedBatch]
    let eligibleDisjointBatches: [SyncConvergenceQueuedBatch]
    let blockedBatches: [SyncConvergenceQueuedBatch]
    let blockedNoteIDs: Set<UUID>
}

struct SyncConvergenceTitleWinnerProjection: Equatable {
    let noteID: UUID
    let title: String
    let canonicalReplayKey: CanonicalReplayKeyPayload
    let operationIdentity: OperationIdentityPayload
}

struct SyncConvergenceIncorporatedBatchProjection: Equatable {
    let batchID: UUID
    let noteID: UUID?
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let cleanupPlan: SyncConvergenceCleanupPlan
}

struct SyncConvergenceIncorporatedRootProjection: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let createdAt: Date
    let batchSequence: UInt64?
    let schemaVersion: Int
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let committedAtOrderingPayloadData: Data
    let affectedNotesPayloadData: Data
    let authoritativeChildCount: Int
    let authoritativeChildBytes: Int
    let authoritativeChildrenDigest: String
    let postCommitStatePayloadData: Data
}

struct SyncConvergenceIncorporatedTombstoneProjection: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let schemaVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let committedAtOrderingPayloadData: Data
    let tombstoneFormatVersion: Int
}

struct SyncConvergenceIncorporatedChildrenProjection: Equatable {
    let operationIdentities: [SyncConvergenceOperationIdentityRecord]
    let noteEffects: [SyncConvergenceNoteEffectRecord]
    let resultEvidence: [SyncConvergenceResultEvidenceRecord]

    static let empty = SyncConvergenceIncorporatedChildrenProjection(
        operationIdentities: [],
        noteEffects: [],
        resultEvidence: []
    )
}

struct SyncConvergenceTitleWinnerRecord: Equatable {
    let noteID: UUID
    let title: String
    let canonicalReplayKey: CanonicalReplayKeyPayload
    let operationIdentity: OperationIdentityPayload
    let updatedAt: Date
}

struct SyncConvergenceIncorporatedBatchRecord: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let createdAt: Date
    let batchSequence: UInt64?
    let schemaVersion: Int
    let committedAt: Date
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let affectedNotesPayloadData: Data
    let authoritativeChildCount: Int
    let authoritativeChildBytes: Int
    let authoritativeChildrenDigest: String
    let postCommitStatePayloadData: Data
}

struct SyncConvergenceOperationIdentityRecord: Equatable {
    let batchID: UUID
    let noteID: UUID
    let operationIndex: Int
    let operationIdentity: OperationIdentityPayload
}

struct SyncConvergenceNoteEffectRecord: Equatable {
    let batchID: UUID
    let noteID: UUID
    let preBodyHash: String?
    let postBodyHash: String?
    let preTitleKey: CanonicalReplayKeyPayload?
    let postTitleKey: CanonicalReplayKeyPayload?
}

struct SyncConvergenceResultEvidenceRecord: Equatable {
    let evidence: SyncConvergenceResultEvidence
}

struct SyncConvergenceRetainedOperationIdentity: Equatable, Hashable {
    let batchID: UUID
    let operationIndex: Int
}

struct SyncConvergenceRetainedOperationProjection: Equatable {
    let operation: SyncConvergenceRetainedOperationRecord
    let source: SyncConvergenceRetainedOperationSource
}

enum SyncConvergenceRetainedOperationSource: String, Equatable {
    case local
    case remote
}

struct SyncConvergenceRetainedOperationRecord: Equatable {
    let noteID: UUID
    let batchID: UUID
    let originDeviceID: UUID
    let operationIndex: Int
    let operationKind: SyncConvergencePlannedBodyOperation.Kind
    let utf16Offset: Int
    let utf16Length: Int?
    let text: String?
    let expectedText: String?
    let baseContentHash: String?
    let resultContentHash: String?
    let canonicalReplayKey: CanonicalReplayKeyPayload
    let modifiedAt: Date
}

struct SyncConvergenceSnapshotProjection: Equatable {
    let snapshot: SyncConvergenceSnapshotRecord
}

struct SyncConvergenceSnapshotRecord: Equatable {
    let noteID: UUID
    let contentHash: String
    let body: String
    let generation: Int
    let createdAt: Date
}

protocol SyncConvergencePersistenceTransaction {
    func loadNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord?
    func insertNote(_ record: SyncConvergenceNewNoteRecord) throws
    func updateNote(_ record: SyncConvergenceUpdatedNoteRecord) throws
    func loadTitleWinner(noteID: UUID) throws -> SyncConvergenceTitleWinnerProjection?
    func insertOrUpdateTitleWinner(_ record: SyncConvergenceTitleWinnerRecord) throws
    func loadIncorporatedBatch(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection?
    func loadIncorporatedBatchChildren(batchID: UUID) throws -> SyncConvergenceIncorporatedChildrenProjection
    func loadTombstone(batchID: UUID) throws -> SyncConvergenceIncorporatedTombstoneProjection?
    func insertIncorporatedBatch(_ record: SyncConvergenceIncorporatedBatchRecord) throws
    func insertOperationIdentity(_ record: SyncConvergenceOperationIdentityRecord) throws
    func insertNoteEffect(_ record: SyncConvergenceNoteEffectRecord) throws
    func insertResultEvidence(_ record: SyncConvergenceResultEvidenceRecord) throws
    func loadRetainedOperation(identity: SyncConvergenceRetainedOperationIdentity) throws -> SyncConvergenceRetainedOperationProjection?
    func insertRetainedOperation(_ record: SyncConvergenceRetainedOperationRecord) throws
    func loadSnapshot(noteID: UUID, generation: Int) throws -> SyncConvergenceSnapshotProjection?
    func loadHighestSnapshotGeneration(noteID: UUID) throws -> Int?
    func insertSnapshot(_ record: SyncConvergenceSnapshotRecord) throws
    func save() throws
    func rollback()
}

struct SyncConvergenceHistoryAccountingProjection: Equatable {
    let noteID: UUID
    let snapshotCount: Int
    let retainedOperationCount: Int
    let snapshotBytes: Int
    let retainedOperationBytes: Int
    let fullIncorporationEvidenceBytes: Int
    let diagnosticEvidenceBytes: Int
    let cleanupEvidenceBytes: Int
    let completedReconciliationEpisodeCount: Int
    let activeReconciliationEpisodeCount: Int
    let reconciliationEvidenceBytes: Int

    static func empty(noteID: UUID) -> Self {
        Self(
            noteID: noteID,
            snapshotCount: 0,
            retainedOperationCount: 0,
            snapshotBytes: 0,
            retainedOperationBytes: 0,
            fullIncorporationEvidenceBytes: 0,
            diagnosticEvidenceBytes: 0,
            cleanupEvidenceBytes: 0,
            completedReconciliationEpisodeCount: 0,
            activeReconciliationEpisodeCount: 0,
            reconciliationEvidenceBytes: 0
        )
    }
}

struct SyncConvergenceEvidenceRequest: Equatable {
    let batchID: UUID
    let affectedNoteIDs: Set<UUID>
    let requiredBaseHashes: Set<String>
    let includeQueuedSuccessors: Bool
    let includeOutgoingProtectionEvidence: Bool
}
