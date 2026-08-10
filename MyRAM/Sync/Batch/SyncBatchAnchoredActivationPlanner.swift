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
        let recoveryChange = try recoveryChange(for: change)
        let existing = recoverySnapshot.record(for: recoveryChange.recordKey)
        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: recoveryChange,
            sequenceState: sequenceState,
            recoverySnapshot: recoverySnapshot
        )
        return try route(plan: plan, source: recoveryChange, existing: existing)
    }

    static func planRetry(
        change: SyncBatchChange,
        sequenceState: SyncTextSequenceState,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot,
        trigger: SyncBatchAnchoredRecoveryRetryTrigger
    ) throws -> SyncBatchAnchoredActivationRoute {
        let recoveryChange = try recoveryChange(for: change)
        let existing = recoverySnapshot.record(for: recoveryChange.recordKey)
        let plan = try SyncBatchAnchoredRecoveryPlanner.planRetry(
            noteID: recoveryChange.noteID,
            sequenceState: sequenceState,
            recoverySnapshot: recoverySnapshot,
            trigger: trigger
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

    private static func recoveryChange(
        for change: SyncBatchChange
    ) throws -> SyncBatchAnchoredRecoveryChange {
        switch change {
        case .noteBodyTextInsertedAnchored(let inserted):
            return .insertion(inserted)
        case .noteBodyTextDeletedAnchored(let deleted):
            return .deletion(deleted)
        default:
            throw SyncBatchAnchoredActivationPlannerError.nonAnchoredChange
        }
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

// MARK: - MYR-179 convergence integration

struct SyncConvergenceAnchoredUpdatedNoteRecord: Equatable {
    let noteID: UUID
    let title: String
    let modifiedAt: Date
    let deletedAt: Date??
    let expectedSnapshot: NoteSequenceStateMutationSnapshot
    let finalState: SyncTextSequenceState
    let finalBody: String
    let didChangeApplicationState: Bool
}

struct SyncConvergenceAnchoredStructuralBodyPlan: Equatable {
    let noteID: UUID
    let expectedSnapshot: NoteSequenceStateMutationSnapshot
    let finalState: SyncTextSequenceState
    let operationIdentities: [OperationIdentityPayload]
    let recoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
    let finalBody: String
    let latestModifiedAt: Date
    let didChangeApplicationState: Bool
    let reviewedNoApplicationChangeReason: SyncBatchAnchoredReviewedCompletionReason?
    let resultEvidence: SyncConvergenceResultEvidence
}

struct SyncConvergenceAnchoredDeferredPlan: Equatable {
    let batchID: UUID
    let noteID: UUID
    let dependency: SyncBatchAnchoredMissingDependency
    let recoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
}

enum SyncConvergenceAnchoredQuarantineEvidence: Equatable {
    case terminal(SyncBatchAnchoredStructuralFailure)
    case bootstrapConflict(SyncBatchAnchoredBootstrapConflict)
}

struct SyncConvergenceAnchoredQuarantinedPlan: Equatable {
    let batchID: UUID
    let noteID: UUID
    let evidence: SyncConvergenceAnchoredQuarantineEvidence
    let recoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition]
}

enum SyncConvergenceAnchoredBatchPlanningOutcome: Equatable {
    case success(SyncConvergenceAnchoredStructuralBodyPlan)
    case deferred(SyncConvergenceAnchoredDeferredPlan)
    case quarantined(SyncConvergenceAnchoredQuarantinedPlan)
}

enum SyncConvergenceAnchoredBatchPlannerError: Error, Equatable {
    case invalidChange
    case invalidRecoveryTransition
    case atomicityReplanMismatch
}

struct SyncConvergenceAnchoredBatchPlanner {
    func plan(
        indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        batch: SyncBatch,
        expectedSnapshot: NoteSequenceStateMutationSnapshot,
        recoverySnapshot: SyncBatchAnchoredRecoveryStoreSnapshot
    ) throws -> SyncConvergenceAnchoredBatchPlanningOutcome {
        guard !indexedChanges.isEmpty,
              indexedChanges.allSatisfy({ $0.change.noteID == expectedSnapshot.noteID }),
              recoverySnapshot.health.permitsOrdinaryMutation else {
            throw SyncConvergenceAnchoredBatchPlannerError.invalidChange
        }

        var speculativeRecovery = recoverySnapshot
        var speculativeState = expectedSnapshot.state
        var identities: [OperationIdentityPayload] = []
        var successfulRecoveryTransitions: [SyncBatchAnchoredRecoveryStoreTransition] = []
        var sawAppliedEquivalent = false

        for indexed in indexedChanges.sorted(by: { $0.operationIndex < $1.operationIndex }) {
            identities.append(
                try operationIdentity(
                    for: indexed.change,
                    batch: batch,
                    operationIndex: indexed.operationIndex
                )
            )

            let key = try recoveryKey(for: indexed.change)
            let operationRecoverySnapshot = SyncBatchAnchoredRecoveryStoreSnapshot(
                records: speculativeRecovery.records.filter { $0.key == key },
                health: speculativeRecovery.health
            )
            let route: SyncBatchAnchoredActivationRoute
            if let existing = operationRecoverySnapshot.record(for: key),
               case .waiting = existing.lifecycle {
                route = try SyncBatchAnchoredActivationPlanner.planRetry(
                    change: indexed.change,
                    sequenceState: speculativeState,
                    recoverySnapshot: operationRecoverySnapshot,
                    trigger: .restartRecovery
                )
            } else {
                route = try SyncBatchAnchoredActivationPlanner.planInitialDelivery(
                    change: indexed.change,
                    sequenceState: speculativeState,
                    recoverySnapshot: operationRecoverySnapshot
                )
            }

            switch route {
            case .applicationChange(let plan):
                speculativeState = plan.finalSequenceState
                speculativeRecovery = try applying(
                    plan.recoveryStoreTransitions,
                    to: speculativeRecovery
                )
                successfulRecoveryTransitions.append(contentsOf: plan.recoveryStoreTransitions)

            case .completedWithoutApplicationChange(let plan, let reason):
                speculativeState = plan.finalSequenceState
                speculativeRecovery = try applying(
                    plan.recoveryStoreTransitions,
                    to: speculativeRecovery
                )
                successfulRecoveryTransitions.append(contentsOf: plan.recoveryStoreTransitions)
                if reason == .appliedEquivalentRecovery {
                    sawAppliedEquivalent = true
                }

            case .waiting(let plan, let dependency):
                return .deferred(.init(
                    batchID: batch.id,
                    noteID: expectedSnapshot.noteID,
                    dependency: dependency,
                    recoveryTransitions: plan.recoveryStoreTransitions
                ))

            case .terminal(let plan, let failure):
                return .quarantined(.init(
                    batchID: batch.id,
                    noteID: expectedSnapshot.noteID,
                    evidence: .terminal(failure),
                    recoveryTransitions: plan.recoveryStoreTransitions
                ))

            case .bootstrapConflict(let plan, let conflict):
                return .quarantined(.init(
                    batchID: batch.id,
                    noteID: expectedSnapshot.noteID,
                    evidence: .bootstrapConflict(conflict),
                    recoveryTransitions: plan.recoveryStoreTransitions
                ))
            }
        }

        let finalBody = speculativeState.visibleText
        let changed = speculativeState != expectedSnapshot.state
        let evidence = SyncConvergenceResultEvidence(
            batchID: batch.id,
            noteID: expectedSnapshot.noteID,
            kind: .body,
            preHash: SyncBatchContentHash.sha256Hex(for: expectedSnapshot.body),
            postHash: SyncBatchContentHash.sha256Hex(for: finalBody),
            canonicalReplayKey: identities.last?.canonicalReplayKey
        )
        return .success(SyncConvergenceAnchoredStructuralBodyPlan(
            noteID: expectedSnapshot.noteID,
            expectedSnapshot: expectedSnapshot,
            finalState: speculativeState,
            operationIdentities: identities,
            recoveryTransitions: successfulRecoveryTransitions,
            finalBody: finalBody,
            latestModifiedAt: indexedChanges.map({ $0.change.modifiedAtForAnchoredPlanning }).max() ?? batch.createdAt,
            didChangeApplicationState: changed,
            reviewedNoApplicationChangeReason: changed
                ? nil
                : (sawAppliedEquivalent ? .appliedEquivalentRecovery : .idempotentReplay),
            resultEvidence: evidence
        ))
    }

    private func recoveryKey(
        for change: SyncBatchChange
    ) throws -> SyncBatchAnchoredRecoveryRecordKey {
        switch change {
        case .noteBodyTextInsertedAnchored(let inserted):
            return SyncBatchAnchoredRecoveryRecordKey(
                noteID: inserted.noteID,
                operationID: inserted.payload.operationID
            )
        case .noteBodyTextDeletedAnchored(let deleted):
            return SyncBatchAnchoredRecoveryRecordKey(
                noteID: deleted.noteID,
                operationID: deleted.payload.operationID
            )
        default:
            throw SyncConvergenceAnchoredBatchPlannerError.invalidChange
        }
    }

    private func operationIdentity(
        for change: SyncBatchChange,
        batch: SyncBatch,
        operationIndex: Int
    ) throws -> OperationIdentityPayload {
        let kind: String
        switch change {
        case .noteBodyTextInsertedAnchored: kind = "anchoredInsert"
        case .noteBodyTextDeletedAnchored: kind = "anchoredDelete"
        default: throw SyncConvergenceAnchoredBatchPlannerError.invalidChange
        }
        return OperationIdentityPayload(
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: operationIndex,
            operationKind: kind,
            canonicalReplayKey: .init(
                replayKey: SyncBatchReplayKey(
                    batch: batch,
                    change: change,
                    operationIndex: operationIndex
                )
            )
        )
    }

    private func applying(
        _ transitions: [SyncBatchAnchoredRecoveryStoreTransition],
        to snapshot: SyncBatchAnchoredRecoveryStoreSnapshot
    ) throws -> SyncBatchAnchoredRecoveryStoreSnapshot {
        var records = snapshot.records
        func index(_ key: SyncBatchAnchoredRecoveryRecordKey) -> Int? {
            records.firstIndex { $0.key == key }
        }
        for transition in transitions {
            switch transition {
            case .insertExpectedAbsent(let proposed):
                if let i = index(proposed.key) {
                    guard records[i] == proposed else {
                        throw SyncConvergenceAnchoredBatchPlannerError.invalidRecoveryTransition
                    }
                } else {
                    records.append(proposed)
                }
            case .replace(let expected, let replacement):
                guard expected.key == replacement.key,
                      let i = index(expected.key),
                      records[i] == expected else {
                    throw SyncConvergenceAnchoredBatchPlannerError.invalidRecoveryTransition
                }
                records[i] = replacement
            case .removeCommitted(let expected):
                guard let i = index(expected.key), records[i] == expected else {
                    throw SyncConvergenceAnchoredBatchPlannerError.invalidRecoveryTransition
                }
                records.remove(at: i)
            }
        }
        return .init(records: records, health: snapshot.health)
    }
}

private extension SyncBatchChange {
    var modifiedAtForAnchoredPlanning: Date {
        switch self {
        case .noteBodyTextInsertedAnchored(let c): return c.modifiedAt
        case .noteBodyTextDeletedAnchored(let c): return c.modifiedAt
        default: return .distantPast
        }
    }
}
