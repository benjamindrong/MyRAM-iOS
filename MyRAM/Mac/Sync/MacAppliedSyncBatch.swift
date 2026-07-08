#if os(macOS)
import Foundation

struct MacAppliedSyncBatch: Equatable {
    let batchID: UUID
    let changes: [MacAppliedSyncChange]
}

enum MacAppliedSyncChange: Equatable {
    case noteCreated(MacAppliedNoteCreated)
    case titleChanged(MacAppliedTitleChanged)
    case bodyInserted(AppliedEditorBodyInsertion)
    case bodyDeleted(AppliedEditorBodyDeletion)
}

struct MacAppliedNoteCreated: Equatable {
    let noteID: UUID
    let title: String
    let body: String
    let modifiedAt: Date
}

struct MacAppliedTitleChanged: Equatable {
    let noteID: UUID
    let title: String
    let modifiedAt: Date
}

#endif
