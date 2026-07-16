#if os(macOS)
import Foundation

@MainActor
struct MacSyncConvergencePresentationSurface {
    let selectedNoteID: () -> UUID?
    let hasUnsavedChanges: () -> Bool
    let refreshNotesList: () -> Void
    let closeRemovedSelectedEditor: (UUID) -> Void
    let applyIncremental: ([MacSelectedEditorAction], UUID, String) -> EditorRemoteBatchApplyResult
    let reloadSelectedEditor: (UUID, String) -> Bool
    let currentEditorBody: () -> String?
}

@MainActor
final class MacSyncConvergencePresentationAdapter: SyncConvergencePresentationAdapter {
    private let surface: MacSyncConvergencePresentationSurface

    init(surface: MacSyncConvergencePresentationSurface) {
        self.surface = surface
    }

    func refreshPresentation(for request: SyncConvergencePresentationRequest) async -> SyncConvergencePostCommitAdapterResult {
        guard request.noteID == request.committedNote.noteID else { return .failed }
        guard request.committedBodyHash == SyncBatchContentHash.sha256Hex(for: request.committedNote.body) else { return .failed }
        guard request.routing == .none || request.routing == .noteRemoved || request.committedPostBodyHash == SyncBatchContentHash.sha256Hex(for: request.committedNote.body) else { return .failed }

        surface.refreshNotesList()

        guard surface.selectedNoteID() == request.noteID else {
            return .verifiedComplete
        }

        switch request.routing {
        case .none:
            return .verifiedComplete
        case .noteRemoved:
            surface.closeRemovedSelectedEditor(request.noteID)
            return .verifiedComplete
        case .incremental:
            return refreshIncrementalPresentation(for: request)
        case .wholeNoteFallback:
            return refreshWholeNotePresentation(for: request)
        }
    }

    private func refreshIncrementalPresentation(
        for request: SyncConvergencePresentationRequest
    ) -> SyncConvergencePostCommitAdapterResult {
        guard !surface.hasUnsavedChanges() else { return .stillPending }
        let actions = request.incrementalOperations.compactMap(MacSelectedEditorAction.init(postCommitOperation:))
        guard actions.count == request.incrementalOperations.count else { return .failed }

        let result = surface.applyIncremental(actions, request.noteID, request.committedNote.body)
        switch result.disposition {
        case .applied, .noApplicableMutations:
            guard surface.currentEditorBody() == request.committedNote.body else { return .failed }
            return .verifiedComplete
        case .requiresReload:
            return .stillPending
        }
    }

    private func refreshWholeNotePresentation(
        for request: SyncConvergencePresentationRequest
    ) -> SyncConvergencePostCommitAdapterResult {
        guard let receipt = request.rewriteSafetyReceipt,
              receipt.noteID == request.noteID,
              receipt.priorBodyHash == request.expectedPreBodyHash,
              receipt.candidateBodyHash == request.committedPostBodyHash else {
            return .failed
        }
        guard !surface.hasUnsavedChanges() else { return .stillPending }
        guard surface.reloadSelectedEditor(request.noteID, request.committedNote.body) else { return .stillPending }
        guard surface.currentEditorBody() == request.committedNote.body else { return .failed }
        return .verifiedComplete
    }
}

private extension MacSelectedEditorAction {
    init?(postCommitOperation operation: SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload) {
        switch operation.kind {
        case .insert:
            guard let text = operation.text else { return nil }
            self = .applyBodyInsertion(AppliedEditorBodyInsertion(
                noteID: operation.noteID,
                utf16Offset: operation.utf16Offset,
                text: text,
                modifiedAt: operation.operationIdentity.canonicalReplayKey.modifiedAt
            ))
        case .delete:
            guard let utf16Length = operation.utf16Length,
                  let expectedText = operation.expectedText else { return nil }
            self = .applyBodyDeletion(AppliedEditorBodyDeletion(
                noteID: operation.noteID,
                range: NSRange(location: operation.utf16Offset, length: utf16Length),
                deletedText: expectedText,
                modifiedAt: operation.operationIdentity.canonicalReplayKey.modifiedAt
            ))
        }
    }
}
#endif
