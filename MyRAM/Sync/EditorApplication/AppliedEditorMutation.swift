import Foundation

struct AppliedEditorBodyInsertion: Equatable, Sendable {
    let noteID: UUID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
}

struct AppliedEditorBodyDeletion: Equatable, Sendable {
    let noteID: UUID
    let range: NSRange
    let deletedText: String
    let modifiedAt: Date
}

enum AppliedEditorMutation: Equatable, Sendable {
    case bodyInsertion(AppliedEditorBodyInsertion)
    case bodyDeletion(AppliedEditorBodyDeletion)

    var noteID: UUID {
        switch self {
        case .bodyInsertion(let insertion):
            insertion.noteID
        case .bodyDeletion(let deletion):
            deletion.noteID
        }
    }
}

struct AppliedEditorMutationBatch: Equatable, Sendable {
    let noteID: UUID
    let mutations: [AppliedEditorMutation]
    let authoritativeBody: String
}
