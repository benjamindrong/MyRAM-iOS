import Foundation

enum EditorBufferOwner {
    case idle
    case localEditing
    case applyingRemoteSync
    case restoringHistory
    case resolvingConflict
}

struct ActiveEditorSyncUpdate: Identifiable, Equatable {
    let id: UUID
    let noteID: UUID
    let disposition: ActiveEditorSyncDisposition

    init(id: UUID = UUID(), noteID: UUID, disposition: ActiveEditorSyncDisposition) {
        self.id = id
        self.noteID = noteID
        self.disposition = disposition
    }
}

enum ActiveEditorSyncDisposition: Equatable {
    case apply(AppliedEditorMutationBatch)
    case reload(ActiveEditorReloadReason)
    case deferred(ActiveEditorDeferredReason)
    case ignored(ActiveEditorIgnoredReason)
}

enum ActiveEditorReloadReason: Equatable {
    case editorUnavailable
    case invalidInsertionOffset
    case invalidDeletionRange
    case deletedTextMismatch
    case preApplyBodyMismatch
    case postApplyBodyMismatch
    case unsupportedIntegratedChange
    case partialBatchApplication
}

enum ActiveEditorDeferredReason: Equatable {
    case pendingLocalCommit
    case activePinnedTextEdit
    case restoringHistory
    case markedTextComposition
    case editorBufferOwnedByLocalMutation
}

enum ActiveEditorIgnoredReason: Equatable {
    case targetNoteIsNotActive
    case supersededByNewerEditorUpdate
}

enum ActiveEditorApplicationDecision: Equatable {
    case applyIncrementally
    case `defer`(ActiveEditorDeferredReason)
    case reload(ActiveEditorReloadReason)
    case ignore(ActiveEditorIgnoredReason)
}

enum ActiveEditorApplicationPolicy {
    static func decision(
        editorBufferOwner: EditorBufferOwner,
        hasPendingNoteCommit: Bool,
        hasActivePinnedTextEdit: Bool,
        hasMarkedText: Bool,
        editorAvailable: Bool,
        selectedNoteMatches: Bool
    ) -> ActiveEditorApplicationDecision {
        guard selectedNoteMatches else {
            return .ignore(.targetNoteIsNotActive)
        }

        guard editorAvailable else {
            return .reload(.editorUnavailable)
        }

        if hasMarkedText {
            return .`defer`(.markedTextComposition)
        }

        if hasActivePinnedTextEdit {
            return .`defer`(.activePinnedTextEdit)
        }

        if hasPendingNoteCommit {
            return .`defer`(.pendingLocalCommit)
        }

        switch editorBufferOwner {
        case .idle:
            return .applyIncrementally
        case .restoringHistory:
            return .`defer`(.restoringHistory)
        case .localEditing, .applyingRemoteSync, .resolvingConflict:
            return .`defer`(.editorBufferOwnedByLocalMutation)
        }
    }
}
