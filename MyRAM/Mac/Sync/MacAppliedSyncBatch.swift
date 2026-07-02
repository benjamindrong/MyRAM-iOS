#if os(macOS)
import Foundation

struct MacAppliedSyncBatch: Equatable {
    let batchID: UUID
    let changes: [MacAppliedSyncChange]
}

enum MacAppliedSyncChange: Equatable {
    case noteCreated(MacAppliedNoteCreated)
    case titleChanged(MacAppliedTitleChanged)
    case bodyInserted(MacAppliedBodyInsertion)
    case bodyDeleted(MacAppliedBodyDeletion)
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

struct MacAppliedBodyInsertion: Equatable {
    let noteID: UUID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
}

struct MacAppliedBodyDeletion: Equatable {
    let noteID: UUID
    let range: NSRange
    let deletedText: String
    let modifiedAt: Date
}
#endif
