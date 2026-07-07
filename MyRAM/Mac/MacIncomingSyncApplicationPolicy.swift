#if os(macOS)
import Foundation

enum MacSelectedEditorState: Equatable {
    case ready
    case unsafeForIncrementalApply
}

struct MacIncomingSyncApplicationPlan: Equatable {
    let shouldRefreshNotesList: Bool
    let editorActions: [MacSelectedEditorAction]
    let reloadSelectedEditorReason: MacSelectedEditorReloadReason?
}

enum MacSelectedEditorAction: Equatable {
    case applyBodyInsertion(AppliedEditorBodyInsertion)
    case applyBodyDeletion(AppliedEditorBodyDeletion)
}

enum MacSelectedEditorReloadReason: Equatable {
    case unsafeIncrementalApply
}

enum MacIncomingSyncApplicationPolicy {
    static func plan(
        appliedBatch: MacAppliedSyncBatch,
        selectedNoteID: UUID?,
        editorState: MacSelectedEditorState
    ) -> MacIncomingSyncApplicationPlan {
        guard !appliedBatch.changes.isEmpty else {
            return MacIncomingSyncApplicationPlan(
                shouldRefreshNotesList: false,
                editorActions: [],
                reloadSelectedEditorReason: nil
            )
        }

        var editorActions: [MacSelectedEditorAction] = []
        var hasListChange = false

        for change in appliedBatch.changes {
            switch change {
            case .noteCreated, .titleChanged:
                hasListChange = true
            case .bodyInserted(let insertion):
                if insertion.noteID == selectedNoteID {
                    editorActions.append(.applyBodyInsertion(insertion))
                } else {
                    hasListChange = true
                }
            case .bodyDeleted(let deletion):
                if deletion.noteID == selectedNoteID {
                    editorActions.append(.applyBodyDeletion(deletion))
                } else {
                    hasListChange = true
                }
            }
        }

        if !editorActions.isEmpty, editorState == .unsafeForIncrementalApply {
            return MacIncomingSyncApplicationPlan(
                shouldRefreshNotesList: true,
                editorActions: [],
                reloadSelectedEditorReason: .unsafeIncrementalApply
            )
        }

        return MacIncomingSyncApplicationPlan(
            shouldRefreshNotesList: hasListChange || !editorActions.isEmpty,
            editorActions: editorActions,
            reloadSelectedEditorReason: nil
        )
    }
}
#endif
