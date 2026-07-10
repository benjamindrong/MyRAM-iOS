import Foundation

#if DEBUG
final class EditorRemoteFullDocumentMetrics {
    private(set) var richTextEncodeCount = 0
    private(set) var attributedStringCopyCount = 0
    private(set) var authoritativeBodyComparisonCount = 0
    private(set) var wholeNoteReloadCount = 0

    func reset() {
        richTextEncodeCount = 0
        attributedStringCopyCount = 0
        authoritativeBodyComparisonCount = 0
        wholeNoteReloadCount = 0
    }

    func recordRichTextEncode() { richTextEncodeCount += 1 }
    func recordAttributedStringCopy() { attributedStringCopyCount += 1 }
    func recordAuthoritativeBodyComparison() { authoritativeBodyComparisonCount += 1 }
    func recordWholeNoteReload() { wholeNoteReloadCount += 1 }
}
#endif

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
