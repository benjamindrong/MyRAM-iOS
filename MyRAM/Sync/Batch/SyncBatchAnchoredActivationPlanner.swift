import AnchoredSequenceCore
import Foundation

enum SyncBatchAnchoredReviewedCompletionReason: Equatable, Sendable {
    case appliedEquivalentRecovery
    case idempotentReplay
}

enum SyncBatchAnchoredActivationRoute: Equatable, Sendable {
    case applicationChange(SyncBatchAnchoredRecoveryCommitPlan)
    case completedWithoutApplicationChange(
        SyncBatchAnchoredRecoveryCommitPlan,
        reason: SyncBatchAnchoredReviewedCompletionReason
    )
    case waiting(
        SyncBatchAnchoredRecoveryCommitPlan,
        dependency: SyncBatchAnchoredMissingDependency
    )
    case terminal(
        SyncBatchAnchoredRecoveryCommitPlan,
        failure: SyncBatchAnchoredStructuralFailure
    )
    case bootstrapConflict(
        SyncBatchAnchoredRecoveryCommitPlan,
        conflict: SyncBatchAnchoredBootstrapConflict
    )
}

enum SyncBatchAnchoredActivationPlannerError: Error, Equatable {
    case nonAnchoredChange
    case ambiguousNoApplicationChange
    case transitionOwnershipUnproven
}

/// Classifies MYR-177 planning output before generic convergence can interpret it.
/// This component is pure: callers own both application and recovery persistence.
enum SyncBatchAnchoredActivationPlanner {
    static func planInitialDelivery(
        change: SyncBatchChange,
        sequenceState: SyncTextSequenceState,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot
    ) throws -> SyncBatchAnchoredActivationRoute {
        let recoveryChange: SyncBatchAnchoredRecoveryChange
        switch change {
        case .noteBodyTextInsertedAnchored(let inserted):
            recoveryChange = .insertion(inserted)
        case .noteBodyTextDeletedAnchored(let deleted):
            recoveryChange = .deletion(deleted)
        default:
            throw SyncBatchAnchoredActivationPlannerError.nonAnchoredChange
        }
        let existing = recoverySnapshot.record(for: recoveryChange.recordKey)
        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: recoveryChange,
            sequenceState: sequenceState,
            recoverySnapshot: recoverySnapshot
        )
        return try route(plan: plan, source: recoveryChange, existing: existing)
    }

    static func planRetry(
        noteID: SyncBatchNoteID,
        sequenceState: SyncTextSequenceState,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot,
        trigger: SyncBatchAnchoredRecoveryRetryTrigger
    ) throws -> [SyncBatchAnchoredActivationRoute] {
        let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
            noteID: noteID,
            sequenceState: sequenceState,
            recoverySnapshot: recoverySnapshot,
            trigger: trigger
        )
        guard let source = plan.appliedRecords.first?.change else {
            return []
        }
        let existing = recoverySnapshot.record(for: source.recordKey)
        return [try route(plan: plan, source: source, existing: existing)]
    }

    private static func route(
        plan: SyncBatchAnchoredRecoveryCommitPlan,
        source: SyncBatchAnchoredRecoveryChange,
        existing: SyncBatchAnchoredRecoveryRecord?
    ) throws -> SyncBatchAnchoredActivationRoute {
        if let lifecycle = finalLifecycle(for: source.recordKey, plan: plan, existing: existing) {
            switch lifecycle {
            case .waiting(let dependency):
                try requireNonSuccessTransitionOwnership(plan)
                return .waiting(plan, dependency: dependency)
            case .terminalStructuralFailure(let failure):
                try requireNonSuccessTransitionOwnership(plan)
                return .terminal(plan, failure: failure)
            case .bootstrapContentConflict(let conflict):
                try requireNonSuccessTransitionOwnership(plan)
                return .bootstrapConflict(plan, conflict: conflict)
            }
        }
        if plan.didChangeApplicationState {
            return .applicationChange(plan)
        }
        guard plan.appliedRecords.contains(where: { $0.key == source.recordKey }) else {
            throw SyncBatchAnchoredActivationPlannerError.ambiguousNoApplicationChange
        }
        return .completedWithoutApplicationChange(
            plan,
            reason: existing == nil ? .idempotentReplay : .appliedEquivalentRecovery
        )
    }

    private static func finalLifecycle(
        for key: SyncBatchAnchoredRecoveryRecordKey,
        plan: SyncBatchAnchoredRecoveryCommitPlan,
        existing: SyncBatchAnchoredRecoveryRecord?
    ) -> SyncBatchAnchoredRecoveryLifecycle? {
        for transition in plan.recoveryStoreTransitions.reversed() where transition.key == key {
            switch transition {
            case .insertExpectedAbsent(let record), .replace(_, let record): return record.lifecycle
            case .removeCommitted: return nil
            }
        }
        return existing?.lifecycle
    }

    private static func requireNonSuccessTransitionOwnership(
        _ plan: SyncBatchAnchoredRecoveryCommitPlan
    ) throws {
        guard !plan.didChangeApplicationState,
              plan.recoveryStoreTransitions.allSatisfy({ transition in
                  if case .removeCommitted = transition { return false }
                  return true
              }) else {
            throw SyncBatchAnchoredActivationPlannerError.transitionOwnershipUnproven
        }
    }
}
