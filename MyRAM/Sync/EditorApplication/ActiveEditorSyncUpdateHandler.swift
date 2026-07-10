import Foundation

struct PendingRemoteTitlePublication: Equatable {
    let updateID: UUID
    let noteID: UUID
    let expectedTitle: String
}

@MainActor
final class ActiveEditorSyncUpdateHandler {
    struct Environment {
        let stateDecision: (ActiveEditorSyncUpdate) -> ActiveEditorStateApplicationDecision
        let batchDecision: (AppliedEditorMutationBatch) -> ActiveEditorApplicationDecision
        let beginRemoteBatchApply: () -> Void
        let clearRemoteBatchApplyIfNeeded: () -> Void
        let finishFailedRemoteBatchApply: () -> Void
        let applyBatch: (AppliedEditorMutationBatch) -> EditorRemoteBatchApplyResult
        let currentContent: () -> String
        let currentTitle: () -> String
        let performReload: (ActiveEditorReloadReason) -> Void
        let applySuccessfulBatchSnapshot: () -> Void
        let publishTitle: (String) -> Bool
        let recordPendingTitlePublication: (PendingRemoteTitlePublication) -> Void
        let clearPendingTitlePublication: () -> Void
        let pendingTitlePublication: () -> PendingRemoteTitlePublication?
        let isCurrentNote: (UUID) -> Bool
        let alignPublishedTitle: (String) -> Void
        let refreshUndoState: () -> Void
        let acknowledge: (ActiveEditorSyncUpdate, SyncConvergencePostCommitAdapterResult) -> Void
    }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func handle(_ update: ActiveEditorSyncUpdate?) {
        guard let update else { return }

        switch update.disposition {
        case .apply(let batch):
            handleBatch(batch, update: update)
        case .metadataOnly:
            handleMetadata(update.metadata, update: update)
        case .reload(let reason):
            handleReload(reason: reason, update: update)
        case .deferred:
            acknowledge(update, result: .stillPending)
        case .ignored:
            acknowledge(update, result: .verifiedComplete)
        }
    }

    func consumeMatchingRemoteTitlePublication(_ observedTitle: String) -> Bool {
        guard let marker = environment.pendingTitlePublication() else { return false }
        environment.clearPendingTitlePublication()
        guard environment.isCurrentNote(marker.noteID),
              marker.expectedTitle == observedTitle else {
            acknowledge(marker, result: .stillPending)
            return false
        }

        environment.alignPublishedTitle(observedTitle)
        environment.refreshUndoState()
        acknowledge(marker, result: .verifiedComplete)
        return true
    }

    func handleReload(reason: ActiveEditorReloadReason, update: ActiveEditorSyncUpdate) {
        if ActiveEditorWholeNoteFallbackGate.decision(
            reason: reason,
            expectedPreBodyHash: update.expectedPreBodyHash,
            currentContent: environment.currentContent()
        ) == .stillPending {
            acknowledge(update, result: .stillPending)
            return
        }

        switch environment.stateDecision(update) {
        case .apply:
            environment.performReload(reason)
            acknowledge(update, result: .verifiedComplete)
        case .deferUntilReintegration:
            acknowledge(update, result: .stillPending)
        case .ignore:
            acknowledge(update, result: .verifiedComplete)
        }
    }

    private func handleMetadata(
        _ metadata: ActiveEditorMetadataUpdate?,
        update: ActiveEditorSyncUpdate
    ) {
        guard let metadata else {
            acknowledge(update, result: .verifiedComplete)
            return
        }

        switch environment.stateDecision(update) {
        case .apply:
            if let remoteTitle = metadata.title {
                if publishRemoteTitle(remoteTitle, update: update) {
                    acknowledge(update, result: .verifiedComplete)
                }
            } else {
                acknowledge(update, result: .verifiedComplete)
            }
        case .deferUntilReintegration:
            acknowledge(update, result: .stillPending)
        case .ignore:
            acknowledge(update, result: .verifiedComplete)
        }
    }

    private func handleBatch(_ batch: AppliedEditorMutationBatch, update: ActiveEditorSyncUpdate) {
        switch environment.batchDecision(batch) {
        case .applyIncrementally:
            environment.beginRemoteBatchApply()
            let result = environment.applyBatch(batch)
            switch result.disposition {
            case .applied:
                environment.applySuccessfulBatchSnapshot()
                environment.clearRemoteBatchApplyIfNeeded()
                if update.metadata != nil {
                    handleMetadata(update.metadata, update: update)
                } else {
                    acknowledge(update, result: .verifiedComplete)
                }
                environment.refreshUndoState()
            case .noApplicableMutations:
                environment.clearRemoteBatchApplyIfNeeded()
                if update.metadata != nil {
                    handleMetadata(update.metadata, update: update)
                } else {
                    acknowledge(update, result: .verifiedComplete)
                }
            case .requiresReload(let reason):
                environment.finishFailedRemoteBatchApply()
                handleReload(reason: reason, update: update)
            }
        case .defer:
            acknowledge(update, result: .stillPending)
        case .reload(let reason):
            handleReload(reason: reason, update: update)
        case .ignore:
            acknowledge(update, result: .verifiedComplete)
        }
    }

    private func publishRemoteTitle(_ remoteTitle: String, update: ActiveEditorSyncUpdate) -> Bool {
        guard environment.currentTitle() != remoteTitle else {
            environment.clearPendingTitlePublication()
            environment.alignPublishedTitle(remoteTitle)
            environment.refreshUndoState()
            return true
        }

        environment.recordPendingTitlePublication(
            PendingRemoteTitlePublication(
                updateID: update.id,
                noteID: update.noteID,
                expectedTitle: remoteTitle
            )
        )
        return environment.publishTitle(remoteTitle)
    }

    private func acknowledge(
        _ update: ActiveEditorSyncUpdate,
        result: SyncConvergencePostCommitAdapterResult
    ) {
        environment.acknowledge(update, result)
    }

    private func acknowledge(
        _ marker: PendingRemoteTitlePublication,
        result: SyncConvergencePostCommitAdapterResult
    ) {
        environment.acknowledge(
            ActiveEditorSyncUpdate(
                id: marker.updateID,
                noteID: marker.noteID,
                disposition: .metadataOnly
            ),
            result
        )
    }
}
