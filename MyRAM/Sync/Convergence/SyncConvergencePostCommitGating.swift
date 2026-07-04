import Foundation

extension SyncConvergenceCleanupPlan {
    func gated(by state: SyncConvergencePostCommitState) -> SyncConvergenceCleanupPlan {
        SyncConvergenceCleanupPlan(
            batchIDs: state.queueCleanupPending ? batchIDs : [],
            retryQueueCleanup: state.queueCleanupPending && retryQueueCleanup,
            retryLegacyCleanup: state.legacyCleanupPending && retryLegacyCleanup,
            retryPresentationRefresh: state.presentationRefreshPending && retryPresentationRefresh
        )
    }
}

extension SyncConvergencePresentationPlan {
    func gated(by state: SyncConvergencePostCommitState) -> SyncConvergencePresentationPlan {
        state.presentationRefreshPending ? self : SyncConvergencePresentationPlan(noteRoutings: [:])
    }
}
