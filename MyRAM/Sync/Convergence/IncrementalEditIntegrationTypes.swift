import Foundation

struct IncrementalEditCausalValidationInput {
    let anchorContent: String
    let anchorContentHash: String
    let operations: [SyncConvergenceRetainedOperationRecord]
    let incorporatedOperationIdentities: Set<SyncConvergenceRetainedOperationIdentity>
}

enum IncrementalEditCausalValidationResult: Equatable {
    case valid(RetainedOperationCausalGraph)
    case recoveryRequired(IncrementalEditRecoveryReason)
}

enum IncrementalEditRecoveryReason: Equatable {
    case anchorHashMismatch
    case unreconstructableBase
    case missingCausalPredecessor
    case ambiguousCausalChain
    case invalidOperationIdentity
    case invalidReplayKey
}

struct ValidatedRetainedOperationNode: Equatable {
    let operation: SyncConvergenceRetainedOperationRecord
    let identity: SyncConvergenceRetainedOperationIdentity
    let replayKey: ValidatedCanonicalReplayKey
    let baseContentHash: String
    let resultContentHash: String
    let predecessorIdentity: SyncConvergenceRetainedOperationIdentity?
    let successorIdentity: SyncConvergenceRetainedOperationIdentity?
}

struct RetainedOperationCausalGraph: Equatable {
    let anchorContentHash: String
    let rootIdentities: [SyncConvergenceRetainedOperationIdentity]
    let nodes: [ValidatedRetainedOperationNode]
}
