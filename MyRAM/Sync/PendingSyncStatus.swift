import Foundation

enum PendingSyncDomain: Equatable {
    case legacy
    case unsentBatches
    case localConvergenceObligations
    case recoveryJournal
}

struct PendingSyncHealthIssue: Equatable {
    let domain: PendingSyncDomain
    let description: String
}

struct PendingSyncStatus: Equatable {
    var legacyChanges: Int
    var unsentBatches: Int
    var localConvergenceObligations: Int
    var healthIssues: [PendingSyncHealthIssue]

    var totalOutboundItems: Int {
        legacyChanges + unsentBatches + localConvergenceObligations
    }

    static let empty = PendingSyncStatus(
        legacyChanges: 0,
        unsentBatches: 0,
        localConvergenceObligations: 0,
        healthIssues: []
    )
}
