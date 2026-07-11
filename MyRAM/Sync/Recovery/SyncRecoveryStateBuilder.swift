import Foundation
import NearbySyncCore

struct SyncRecoveryReplacementState {
    let legacySnapshot: SyncQueueSnapshot
    let unsentBatches: [SyncBatch]
    let localConvergenceBatches: [SyncBatch]
    let replacedLegacyCount: Int
    let replacedUnsentBatchCount: Int
    let replacedLocalObligationCount: Int
}

enum SyncRecoveryStateBuilder {
    static func affectedNoteIDs(in batches: [SyncBatch]) -> Set<UUID> {
        Set(batches.flatMap { batch in
            batch.changes.map(\.noteID)
        })
    }
}

private extension SyncBatchChange {
    var noteID: UUID {
        switch self {
        case .noteCreated(let change):
            change.noteID
        case .noteTitleChanged(let change):
            change.noteID
        case .noteBodyTextInserted(let change):
            change.noteID
        case .noteBodyTextDeleted(let change):
            change.noteID
        case .noteBodyReconciled(let change):
            change.noteID
        }
    }
}
