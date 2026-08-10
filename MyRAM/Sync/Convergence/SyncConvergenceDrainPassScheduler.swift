import AnchoredSequenceCore
import Foundation

struct SyncConvergenceQueueCandidate: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let affectedNoteIDs: Set<UUID>
    let queuePosition: Int
    let anchoredOperationIDs: Set<SyncOperationID>

    init(
        batchID: UUID,
        originDeviceID: UUID,
        affectedNoteIDs: Set<UUID>,
        queuePosition: Int,
        anchoredOperationIDs: Set<SyncOperationID> = []
    ) {
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.affectedNoteIDs = affectedNoteIDs
        self.queuePosition = queuePosition
        self.anchoredOperationIDs = anchoredOperationIDs
    }
}

struct SyncConvergenceDrainPassScheduler {
    static func nextEligibleIndex(
        candidates: [SyncConvergenceQueueCandidate],
        attemptedBatchIDs: Set<UUID>,
        blockedNoteIDs: Set<UUID>,
        blockedOrigins: Set<UUID>,
        anchoredDependenciesByNoteID: [UUID: Set<SyncOperationID>] = [:]
    ) -> Int? {
        candidates.firstIndex { candidate in
            guard !attemptedBatchIDs.contains(candidate.batchID) else {
                return false
            }

            let blockedNotes = candidate.affectedNoteIDs.intersection(blockedNoteIDs)
            let originIsBlocked = blockedOrigins.contains(candidate.originDeviceID)
            guard !blockedNotes.isEmpty || originIsBlocked else {
                return true
            }

            guard !blockedNotes.isEmpty,
                  blockedNotes.allSatisfy({ noteID in
                      guard let dependencies = anchoredDependenciesByNoteID[noteID],
                            !dependencies.isEmpty else {
                          return false
                      }
                      return !candidate.anchoredOperationIDs.isDisjoint(with: dependencies)
                  }) else {
                return false
            }

            return true
        }
    }
}

struct SyncConvergenceDeferredWork: Equatable {
    let incoming: [SyncConvergenceDeferredItem]
    let localObligations: [SyncConvergenceDeferredItem]
    let postCommit: [SyncConvergenceDeferredItem]

    var isEmpty: Bool {
        incoming.isEmpty && localObligations.isEmpty && postCommit.isEmpty
    }
}

struct SyncConvergenceQuarantinedWork: Equatable {
    let items: [SyncConvergenceQuarantinedItem]

    var isEmpty: Bool {
        items.isEmpty
    }
}

struct SyncConvergenceQuarantinedItem: Equatable {
    let domain: SyncConvergenceDeferredItem.Domain
    let batchID: UUID
    let affectedNoteIDs: Set<UUID>
    let originDeviceID: UUID
    let reason: SyncConvergenceQuarantineReason
}

enum SyncConvergenceQuarantineReason: Equatable {
    case localEvidenceContinuityViolation
    case localEvidenceIndexMismatch
    case localEvidenceInvalidOperation
    case localEvidenceBaseHashMismatch
    case anchoredTerminalStructuralFailure(SyncBatchAnchoredStructuralFailure)
    case anchoredBootstrapConflict(SyncBatchAnchoredBootstrapConflict)
}

struct SyncConvergenceDeferredItem: Equatable {
    enum Domain: Equatable {
        case incoming
        case localObligation
        case postCommit
    }

    let domain: Domain
    let batchID: UUID
    let affectedNoteIDs: Set<UUID>
    let reason: SyncConvergenceRuntimeDeferredReason
}

enum SyncConvergenceRuntimeDeferredReason: Equatable {
    case planning(SyncConvergenceDeferredReason)
    case anchoredDependency(SyncBatchAnchoredMissingDependency)
    case legacyLocalEvidenceStale
    case transportUnavailable
    case postCommitPending(Set<SyncConvergencePostCommitPendingWork>)
}
