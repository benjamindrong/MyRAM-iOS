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
    let metadata: ActiveEditorMetadataUpdate?
    let disposition: ActiveEditorSyncDisposition

    init(
        id: UUID = UUID(),
        noteID: UUID,
        metadata: ActiveEditorMetadataUpdate? = nil,
        disposition: ActiveEditorSyncDisposition
    ) {
        self.id = id
        self.noteID = noteID
        self.metadata = metadata
        self.disposition = disposition
    }
}

struct ActiveEditorMetadataUpdate: Equatable {
    let title: String?
}

enum ActiveEditorSyncDisposition: Equatable {
    case apply(AppliedEditorMutationBatch)
    case metadataOnly
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

enum ActiveEditorStateApplicationDecision: Equatable {
    case apply
    case deferUntilReintegration(ActiveEditorDeferredReason)
    case ignore(ActiveEditorIgnoredReason)
}

enum ActiveEditorApplicationPolicy {
    static func decision(
        editorBufferOwner: EditorBufferOwner,
        hasPendingNoteCommit: Bool,
        hasActivePinnedTextEdit: Bool,
        hasMarkedText: Bool,
        isApplyingUndo: Bool,
        editorAvailable: Bool,
        selectedNoteMatches: Bool
    ) -> ActiveEditorApplicationDecision {
        guard selectedNoteMatches else {
            return .ignore(.targetNoteIsNotActive)
        }

        if let deferredReason = sharedDeferredReason(
            editorBufferOwner: editorBufferOwner,
            hasPendingNoteCommit: hasPendingNoteCommit,
            hasActivePinnedTextEdit: hasActivePinnedTextEdit,
            hasMarkedText: hasMarkedText,
            isApplyingUndo: isApplyingUndo
        ) {
            return .`defer`(deferredReason)
        }

        guard editorAvailable else {
            return .reload(.editorUnavailable)
        }

        return .applyIncrementally
    }

    static func stateDecision(
        editorBufferOwner: EditorBufferOwner,
        hasPendingNoteCommit: Bool,
        hasActivePinnedTextEdit: Bool,
        hasMarkedText: Bool,
        isApplyingUndo: Bool,
        selectedNoteMatches: Bool
    ) -> ActiveEditorStateApplicationDecision {
        guard selectedNoteMatches else {
            return .ignore(.targetNoteIsNotActive)
        }

        if let deferredReason = sharedDeferredReason(
            editorBufferOwner: editorBufferOwner,
            hasPendingNoteCommit: hasPendingNoteCommit,
            hasActivePinnedTextEdit: hasActivePinnedTextEdit,
            hasMarkedText: hasMarkedText,
            isApplyingUndo: isApplyingUndo
        ) {
            return .deferUntilReintegration(deferredReason)
        }

        return .apply
    }

    private static func sharedDeferredReason(
        editorBufferOwner: EditorBufferOwner,
        hasPendingNoteCommit: Bool,
        hasActivePinnedTextEdit: Bool,
        hasMarkedText: Bool,
        isApplyingUndo: Bool
    ) -> ActiveEditorDeferredReason? {
        if hasMarkedText {
            return .markedTextComposition
        }

        if hasActivePinnedTextEdit {
            return .activePinnedTextEdit
        }

        if hasPendingNoteCommit {
            return .pendingLocalCommit
        }

        if isApplyingUndo {
            return .restoringHistory
        }

        switch editorBufferOwner {
        case .idle:
            return nil
        case .restoringHistory:
            return .restoringHistory
        case .localEditing, .applyingRemoteSync, .resolvingConflict:
            return .editorBufferOwnedByLocalMutation
        }
    }
}
