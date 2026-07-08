import Foundation

struct EditorRemoteBatchApplyResult: Equatable {
    let appliedCount: Int
    let disposition: EditorRemoteApplyDisposition
}

enum EditorRemoteApplyDisposition: Equatable {
    case applied
    case noApplicableMutations
    case requiresReload(ActiveEditorReloadReason)
}
