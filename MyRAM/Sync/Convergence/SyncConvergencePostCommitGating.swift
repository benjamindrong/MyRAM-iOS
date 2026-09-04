import Foundation

extension SyncConvergenceCleanupPlan {
    func gated(by state: SyncConvergencePostCommitState) -> SyncConvergenceCleanupPlan {
        let lifecycleAllowsDownstreamWork = !state.lifecycleMaterializationPending && !state.lifecyclePublicationPending
        return SyncConvergenceCleanupPlan(
            batchIDs: lifecycleAllowsDownstreamWork && state.queueCleanupPending ? batchIDs : [],
            retryQueueCleanup: lifecycleAllowsDownstreamWork && state.queueCleanupPending && retryQueueCleanup,
            retryLegacyCleanup: lifecycleAllowsDownstreamWork && state.legacyCleanupPending && retryLegacyCleanup,
            retryPresentationRefresh: lifecycleAllowsDownstreamWork && state.presentationRefreshPending && retryPresentationRefresh
        )
    }
}

extension SyncConvergencePresentationPlan {
    func gated(by state: SyncConvergencePostCommitState) -> SyncConvergencePresentationPlan {
        guard !state.lifecycleMaterializationPending, state.presentationRefreshPending else {
            return SyncConvergencePresentationPlan(noteRoutings: [:])
        }
        return self
    }
}
