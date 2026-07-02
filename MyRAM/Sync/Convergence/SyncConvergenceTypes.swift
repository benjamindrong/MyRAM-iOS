import Foundation

enum SyncConvergenceKey {
    private static let version = "v1"

    static func snapshot(noteID: UUID, contentHash: String) -> String {
        join("snapshot", noteID.uuidString.lowercased(), contentHash)
    }

    static func retainedOperation(batchID: UUID, operationIndex: Int) -> String {
        join("operation", batchID.uuidString.lowercased(), String(operationIndex))
    }

    static func incorporatedBatch(batchID: UUID) -> String {
        join("batch", batchID.uuidString.lowercased())
    }

    static func incorporatedBatchTombstone(batchID: UUID) -> String {
        join("batch-tombstone", batchID.uuidString.lowercased())
    }

    static func batchNoteEffect(batchID: UUID, noteID: UUID) -> String {
        join("batch-note-effect", batchID.uuidString.lowercased(), noteID.uuidString.lowercased())
    }

    static func batchOperationIdentity(batchID: UUID, operationIndex: Int) -> String {
        join("batch-operation-identity", batchID.uuidString.lowercased(), String(operationIndex))
    }

    static func batchResultEvidence(batchID: UUID, noteID: UUID, kind: String) -> String {
        join("batch-result-evidence", batchID.uuidString.lowercased(), noteID.uuidString.lowercased(), kind)
    }

    static func incorporationBlockingReference(batchID: UUID, blockingBatchID: UUID, noteID: UUID) -> String {
        join(
            "incorporation-blocking-reference",
            batchID.uuidString.lowercased(),
            blockingBatchID.uuidString.lowercased(),
            noteID.uuidString.lowercased()
        )
    }

    static func incorporationContradiction(batchID: UUID, noteID: UUID?) -> String {
        join("incorporation-contradiction", batchID.uuidString.lowercased(), noteID?.uuidString.lowercased() ?? "all")
    }

    static func titleWinner(noteID: UUID) -> String {
        join("title-winner", noteID.uuidString.lowercased())
    }

    static func compaction(noteID: UUID) -> String {
        join("compaction", noteID.uuidString.lowercased())
    }

    static func diagnostic(noteID: UUID) -> String {
        join("diagnostic", noteID.uuidString.lowercased())
    }

    static func diagnosticBlockingReference(noteID: UUID, blockingBatchID: UUID, affectedNoteID: UUID) -> String {
        join(
            "diagnostic-blocking-reference",
            noteID.uuidString.lowercased(),
            blockingBatchID.uuidString.lowercased(),
            affectedNoteID.uuidString.lowercased()
        )
    }

    static func episode(noteID: UUID, generation: Int) -> String {
        join("episode", noteID.uuidString.lowercased(), String(generation))
    }

    static func reconciliationCandidate(noteID: UUID, generation: Int, candidateIdentity: String) -> String {
        join("reconciliation-candidate", noteID.uuidString.lowercased(), String(generation), candidateIdentity)
    }

    static func reconciliationCompletionEvidence(noteID: UUID, generation: Int, kind: String) -> String {
        join("reconciliation-completion", noteID.uuidString.lowercased(), String(generation), kind)
    }

    private static func join(_ parts: String...) -> String {
        ([version] + parts).joined(separator: "|")
    }
}

enum SyncConvergenceDateBits {
    static func bitPattern(for date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    static func date(from bitPattern: UInt64) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern))
    }

    static func decimalString(for bitPattern: UInt64) -> String {
        String(bitPattern)
    }

    static func bitPattern(fromDecimalString value: String) -> UInt64? {
        UInt64(value)
    }
}

struct CanonicalReplayKeyPayload: Codable, Equatable, Comparable, Sendable {
    enum BatchOrderKind: String, Codable, Sendable {
        case legacy
        case sequenced
    }

    let version: Int
    let modifiedAtBitPattern: UInt64
    let originDeviceIDLowercase: String
    let batchOrderKind: BatchOrderKind
    let legacyCreatedAtBitPattern: UInt64?
    let sequence: UInt64?
    let batchIDLowercase: String
    let operationIndex: Int

    init(
        version: Int = 1,
        modifiedAtBitPattern: UInt64,
        originDeviceIDLowercase: String,
        batchOrderKind: BatchOrderKind,
        legacyCreatedAtBitPattern: UInt64?,
        sequence: UInt64?,
        batchIDLowercase: String,
        operationIndex: Int
    ) {
        self.version = version
        self.modifiedAtBitPattern = modifiedAtBitPattern
        self.originDeviceIDLowercase = originDeviceIDLowercase.lowercased()
        self.batchOrderKind = batchOrderKind
        self.legacyCreatedAtBitPattern = legacyCreatedAtBitPattern
        self.sequence = sequence
        self.batchIDLowercase = batchIDLowercase.lowercased()
        self.operationIndex = operationIndex
    }

    init(replayKey: SyncBatchReplayKey) {
        let orderKind: BatchOrderKind
        let legacyCreatedAt: UInt64?
        let sequence: UInt64?
        switch replayKey.batchOrder {
        case .legacy(let createdAt, _):
            orderKind = .legacy
            legacyCreatedAt = SyncConvergenceDateBits.bitPattern(for: createdAt)
            sequence = nil
        case .sequenced(let batchSequence):
            orderKind = .sequenced
            legacyCreatedAt = nil
            sequence = batchSequence
        }

        self.init(
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: replayKey.modifiedAt),
            originDeviceIDLowercase: replayKey.originDeviceID.uuidString,
            batchOrderKind: orderKind,
            legacyCreatedAtBitPattern: legacyCreatedAt,
            sequence: sequence,
            batchIDLowercase: replayKey.stableBatchID.uuidString,
            operationIndex: replayKey.operationIndex
        )
    }

    static func < (lhs: CanonicalReplayKeyPayload, rhs: CanonicalReplayKeyPayload) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        if lhs.originDeviceIDLowercase != rhs.originDeviceIDLowercase {
            return lhs.originDeviceIDLowercase < rhs.originDeviceIDLowercase
        }
        if lhs.batchOrderSortKey != rhs.batchOrderSortKey {
            return lhs.batchOrderSortKey < rhs.batchOrderSortKey
        }
        if lhs.batchIDLowercase != rhs.batchIDLowercase {
            return lhs.batchIDLowercase < rhs.batchIDLowercase
        }
        return lhs.operationIndex < rhs.operationIndex
    }

    var modifiedAt: Date {
        SyncConvergenceDateBits.date(from: modifiedAtBitPattern)
    }

    private var batchOrderSortKey: BatchOrderSortKey {
        switch batchOrderKind {
        case .legacy:
            BatchOrderSortKey(kind: 0, legacyCreatedAt: legacyCreatedAtBitPattern, sequence: nil, batchID: batchIDLowercase)
        case .sequenced:
            BatchOrderSortKey(kind: 1, legacyCreatedAt: nil, sequence: sequence, batchID: nil)
        }
    }

    private struct BatchOrderSortKey: Comparable {
        let kind: Int
        let legacyCreatedAt: UInt64?
        let sequence: UInt64?
        let batchID: String?

        static func < (lhs: BatchOrderSortKey, rhs: BatchOrderSortKey) -> Bool {
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.legacyCreatedAt != rhs.legacyCreatedAt {
                return (lhs.legacyCreatedAt ?? 0) < (rhs.legacyCreatedAt ?? 0)
            }
            if lhs.sequence != rhs.sequence {
                return (lhs.sequence ?? 0) < (rhs.sequence ?? 0)
            }
            return (lhs.batchID ?? "") < (rhs.batchID ?? "")
        }
    }
}

enum SyncConvergenceStableEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

struct OperationIdentityPayload: Codable, Equatable, Sendable {
    let version: Int
    let batchIDLowercase: String
    let originDeviceIDLowercase: String
    let operationIndex: Int
    let operationKind: String
    let canonicalReplayKey: CanonicalReplayKeyPayload

    init(
        version: Int = 1,
        batchID: UUID,
        originDeviceID: UUID,
        operationIndex: Int,
        operationKind: String,
        canonicalReplayKey: CanonicalReplayKeyPayload
    ) {
        self.version = version
        self.batchIDLowercase = batchID.uuidString.lowercased()
        self.originDeviceIDLowercase = originDeviceID.uuidString.lowercased()
        self.operationIndex = operationIndex
        self.operationKind = operationKind
        self.canonicalReplayKey = canonicalReplayKey
    }
}

enum SyncBatchQueueFailure: Equatable {
    case capacity
    case persistence
}

enum SyncConvergenceOutcome: Equatable {
    case committed(SyncConvergenceCommitSummary)
    case alreadyIncorporated(SyncConvergenceCleanupPlan)
    case deferred(SyncConvergenceDeferredReason)
    case failedBeforeCommit(SyncConvergenceTransactionFailure)
}

struct SyncConvergenceCommitSummary: Equatable {
    let batchIDs: Set<UUID>
    let affectedNoteIDs: Set<UUID>
    let postCommitState: SyncConvergencePostCommitState
}

struct SyncConvergenceCleanupPlan: Equatable {
    let batchIDs: Set<UUID>
    let retryQueueCleanup: Bool
    let retryLegacyCleanup: Bool
    let retryPresentationRefresh: Bool
}

enum SyncConvergenceDeferredReason: Equatable {
    case unreconstructableBase(noteID: UUID, batchID: UUID, baseContentHash: String)
    case unsupportedReconciliation(noteID: UUID, batchID: UUID)
    case historyPressure(noteID: UUID, blockingBatchID: UUID?)
}

enum SyncConvergenceTransactionFailure: Equatable {
    case swiftDataFetch
    case swiftDataSave
    case corruptHistory(noteID: UUID?)
    case invalidMergePlan(noteID: UUID?)
    case inconsistentIncorporationState(noteID: UUID?)
    case unsupportedDigestFormat(noteID: UUID?, batchID: UUID, formatVersion: Int)
    case unexpected
}

struct SyncConvergencePostCommitState: Codable, Equatable, Sendable {
    let queueCleanupPending: Bool
    let legacyCleanupPending: Bool
    let presentationRefreshPending: Bool

    static let none = SyncConvergencePostCommitState(
        queueCleanupPending: false,
        legacyCleanupPending: false,
        presentationRefreshPending: false
    )
}

enum SyncConvergenceDrainFailureMapping {
    static func failureKind(for failure: SyncConvergenceTransactionFailure) -> SyncBatchDrainFailureKind {
        switch failure {
        case .swiftDataFetch, .swiftDataSave:
            return .persistence
        case .corruptHistory:
            return .corruptHistory
        case .invalidMergePlan:
            return .invalidMergePlan
        case .inconsistentIncorporationState:
            return .inconsistentIncorporationState
        case .unsupportedDigestFormat:
            return .unsupportedDigestFormat
        case .unexpected:
            return .unexpected
        }
    }
}
