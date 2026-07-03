import Foundation

enum SyncConvergencePlanningOutcome: Equatable {
    case planned(SyncConvergenceBatchPlan)
    case alreadyIncorporated(SyncConvergenceCleanupPlan)
    case deferred(SyncConvergenceDeferredReason)
    case failedBeforeCommit(SyncConvergenceTransactionFailure)
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
    let presentationPlan: SyncConvergencePresentationPlan
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

struct SyncConvergenceResultEvidence: Equatable {
    enum Kind: String, Equatable {
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
