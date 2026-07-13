import Foundation

struct SyncConvergenceQueueCandidate: Equatable {
    let batchID: UUID
    let originDeviceID: UUID
    let affectedNoteIDs: Set<UUID>
    let queuePosition: Int
}

struct SyncConvergenceDrainPassScheduler {
    static func nextEligibleIndex(
        candidates: [SyncConvergenceQueueCandidate],
        attemptedBatchIDs: Set<UUID>,
        blockedNoteIDs: Set<UUID>,
        blockedOrigins: Set<UUID>
    ) -> Int? {
        candidates.firstIndex { candidate in
            guard !attemptedBatchIDs.contains(candidate.batchID),
                  candidate.affectedNoteIDs.isDisjoint(with: blockedNoteIDs),
                  !blockedOrigins.contains(candidate.originDeviceID) else {
                return false
            }
            return true
        }
    }
}

struct SyncConvergenceDeferredWork: Equatable {
    let incoming: [SyncConvergenceDeferredItem]
    let localObligations: [SyncConvergenceDeferredItem]

    var isEmpty: Bool {
        incoming.isEmpty && localObligations.isEmpty
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
}

struct SyncConvergenceDeferredItem: Equatable {
    enum Domain: Equatable {
        case incoming
        case localObligation
    }

    let domain: Domain
    let batchID: UUID
    let affectedNoteIDs: Set<UUID>
    let reason: SyncConvergenceRuntimeDeferredReason
}

enum SyncConvergenceRuntimeDeferredReason: Equatable {
    case planning(SyncConvergenceDeferredReason)
    case legacyLocalEvidenceStale
    case transportUnavailable
}
