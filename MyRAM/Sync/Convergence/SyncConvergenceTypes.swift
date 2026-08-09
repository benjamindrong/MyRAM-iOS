import Foundation

enum SyncConvergenceKey {
    private static let version = "v2"

    static func snapshot(noteID: UUID, contentHash: String) -> String {
        join(.namespace("snapshot"), .uuid(noteID), .string(contentHash))
    }

    static func retainedOperation(batchID: UUID, operationIndex: Int) -> String {
        join(.namespace("operation"), .uuid(batchID), .int(operationIndex))
    }

    static func explicitDeleteProvenance(batchID: UUID, operationIndex: Int) -> String {
        join(.namespace("explicit-delete-provenance"), .uuid(batchID), .int(operationIndex))
    }

    static func incorporatedBatch(batchID: UUID) -> String {
        join(.namespace("batch"), .uuid(batchID))
    }

    static func incorporatedBatchTombstone(batchID: UUID) -> String {
        join(.namespace("batch-tombstone"), .uuid(batchID))
    }

    static func batchNoteEffect(batchID: UUID, noteID: UUID) -> String {
        join(.namespace("batch-note-effect"), .uuid(batchID), .uuid(noteID))
    }

    static func batchOperationIdentity(batchID: UUID, operationIndex: Int) -> String {
        join(.namespace("batch-operation-identity"), .uuid(batchID), .int(operationIndex))
    }

    static func batchResultEvidence(batchID: UUID, noteID: UUID, kind: String) -> String {
        join(.namespace("batch-result-evidence"), .uuid(batchID), .uuid(noteID), .string(kind))
    }

    static func incorporationBlockingReference(batchID: UUID, blockingBatchID: UUID, noteID: UUID) -> String {
        join(
            .namespace("incorporation-blocking-reference"),
            .uuid(batchID),
            .uuid(blockingBatchID),
            .uuid(noteID)
        )
    }

    static func incorporationContradiction(batchID: UUID, noteID: UUID?) -> String {
        join(.namespace("incorporation-contradiction"), .uuid(batchID), .optionalUUID(noteID))
    }

    static func titleWinner(noteID: UUID) -> String {
        join(.namespace("title-winner"), .uuid(noteID))
    }

    static func compaction(noteID: UUID) -> String {
        join(.namespace("compaction"), .uuid(noteID))
    }

    static func diagnostic(noteID: UUID) -> String {
        join(.namespace("diagnostic"), .uuid(noteID))
    }

    static func diagnosticBlockingReference(noteID: UUID, blockingBatchID: UUID, affectedNoteID: UUID) -> String {
        join(
            .namespace("diagnostic-blocking-reference"),
            .uuid(noteID),
            .uuid(blockingBatchID),
            .uuid(affectedNoteID)
        )
    }

    static func episode(noteID: UUID, generation: Int) -> String {
        join(.namespace("episode"), .uuid(noteID), .int(generation))
    }

    static func reconciliationCandidate(noteID: UUID, generation: Int, candidateIdentity: String) -> String {
        join(.namespace("reconciliation-candidate"), .uuid(noteID), .int(generation), .string(candidateIdentity))
    }

    static func reconciliationCompletionEvidence(noteID: UUID, generation: Int, kind: String) -> String {
        join(.namespace("reconciliation-completion"), .uuid(noteID), .int(generation), .string(kind))
    }

    private static func join(_ components: Component...) -> String {
        ([version] + components.map(\.encoded)).joined(separator: "|")
    }

    private enum Component {
        case namespace(String)
        case uuid(UUID)
        case optionalUUID(UUID?)
        case int(Int)
        case string(String)

        var encoded: String {
            let type: String
            let value: String
            switch self {
            case .namespace(let namespace):
                type = "n"
                value = namespace
            case .uuid(let uuid):
                type = "u"
                value = uuid.uuidString.lowercased()
            case .optionalUUID(.some(let uuid)):
                type = "ou"
                value = uuid.uuidString.lowercased()
            case .optionalUUID(.none):
                type = "on"
                value = ""
            case .int(let int):
                type = "i"
                value = String(int)
            case .string(let string):
                type = "s"
                value = string
            }
            return "\(type):\(value.utf8.count):\(value)"
        }
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

struct CanonicalReplayKeyPayload: Codable, Equatable, Sendable {
    static let supportedVersion = 1

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
        self.originDeviceIDLowercase = originDeviceIDLowercase
        self.batchOrderKind = batchOrderKind
        self.legacyCreatedAtBitPattern = legacyCreatedAtBitPattern
        self.sequence = sequence
        self.batchIDLowercase = batchIDLowercase
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
            originDeviceIDLowercase: replayKey.originDeviceID.uuidString.lowercased(),
            batchOrderKind: orderKind,
            legacyCreatedAtBitPattern: legacyCreatedAt,
            sequence: sequence,
            batchIDLowercase: replayKey.stableBatchID.uuidString.lowercased(),
            operationIndex: replayKey.operationIndex
        )
    }

    var modifiedAt: Date {
        SyncConvergenceDateBits.date(from: modifiedAtBitPattern)
    }

    func encodedEvidenceData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodeEvidenceData(_ data: Data) throws -> Self {
        let payload: Self
        do {
            payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        } catch {
            throw SyncConvergenceValidationError.replayKeyDecodeFailed
        }
        try payload.validate()
        return payload
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw SyncConvergenceValidationError.unsupportedEvidenceVersion(field: "canonicalReplayKey", version: version)
        }
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            originDeviceIDLowercase,
            field: "originDeviceIDLowercase"
        )
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            batchIDLowercase,
            field: "batchIDLowercase"
        )
        guard operationIndex >= 0 else {
            throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "operationIndex")
        }
        switch batchOrderKind {
        case .legacy:
            guard legacyCreatedAtBitPattern != nil else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "legacyCreatedAtBitPattern")
            }
            guard sequence == nil else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "sequence")
            }
        case .sequenced:
            guard legacyCreatedAtBitPattern == nil else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "legacyCreatedAtBitPattern")
            }
            guard sequence != nil else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "sequence")
            }
        }
    }
}

struct ValidatedCanonicalReplayKey: Comparable, Sendable {
    let payload: CanonicalReplayKeyPayload
    private let batchOrderSortKey: BatchOrderSortKey

    init(_ payload: CanonicalReplayKeyPayload) throws {
        try payload.validate()
        self.payload = payload
        switch payload.batchOrderKind {
        case .legacy:
            guard let legacyCreatedAtBitPattern = payload.legacyCreatedAtBitPattern else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "legacyCreatedAtBitPattern")
            }
            self.batchOrderSortKey = .legacy(
                createdAt: SyncConvergenceDateBits.date(from: legacyCreatedAtBitPattern),
                batchIDLowercase: payload.batchIDLowercase
            )
        case .sequenced:
            guard let sequence = payload.sequence else {
                throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "sequence")
            }
            self.batchOrderSortKey = .sequenced(sequence)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.payload.modifiedAt != rhs.payload.modifiedAt {
            return lhs.payload.modifiedAt < rhs.payload.modifiedAt
        }
        if lhs.payload.originDeviceIDLowercase != rhs.payload.originDeviceIDLowercase {
            return lhs.payload.originDeviceIDLowercase < rhs.payload.originDeviceIDLowercase
        }
        if lhs.batchOrderSortKey != rhs.batchOrderSortKey {
            return lhs.batchOrderSortKey < rhs.batchOrderSortKey
        }
        if lhs.payload.batchIDLowercase != rhs.payload.batchIDLowercase {
            return lhs.payload.batchIDLowercase < rhs.payload.batchIDLowercase
        }
        return lhs.payload.operationIndex < rhs.payload.operationIndex
    }

    private enum BatchOrderSortKey: Comparable, Sendable {
        case legacy(createdAt: Date, batchIDLowercase: String)
        case sequenced(UInt64)

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.legacy(let lhsCreatedAt, let lhsBatchID), .legacy(let rhsCreatedAt, let rhsBatchID)):
                if lhsCreatedAt != rhsCreatedAt { return lhsCreatedAt < rhsCreatedAt }
                return lhsBatchID < rhsBatchID
            case (.legacy, .sequenced):
                return true
            case (.sequenced, .legacy):
                return false
            case (.sequenced(let lhsSequence), .sequenced(let rhsSequence)):
                return lhsSequence < rhsSequence
            }
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

enum SyncConvergenceValidationError: Error, Equatable {
    case malformedUUID(field: String, value: String)
    case unsupportedEvidenceVersion(field: String, version: Int)
    case unsupportedTombstoneFormat(version: Int)
    case malformedDigest(field: String, value: String)
    case replayKeyDecodeFailed
    case invalidReplayKeyShape(field: String)
    case committedAtOrderingDecodeFailed
    case modelPayloadDisagreement(field: String)
    case dateAuthorityMismatch(field: String)
    case encodedPayloadExceedsLimit(actual: Int, limit: Int)
}

struct CommittedAtOrderingPayload: Codable, Equatable, Sendable {
    static let supportedVersion = 1

    let version: Int
    let committedAtBitPattern: UInt64
    let batchIDLowercase: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case committedAtBitPattern = "t"
        case batchIDLowercase = "b"
    }

    init(version: Int = Self.supportedVersion, committedAtBitPattern: UInt64, batchIDLowercase: String) {
        self.version = version
        self.committedAtBitPattern = committedAtBitPattern
        self.batchIDLowercase = batchIDLowercase
    }

    init(batchID: UUID, committedAt: Date) {
        self.init(
            committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
            batchIDLowercase: batchID.uuidString.lowercased()
        )
    }

    var committedAt: Date {
        SyncConvergenceDateBits.date(from: committedAtBitPattern)
    }

    func encodedEvidenceData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodeEvidenceData(_ data: Data) throws -> Self {
        let payload: Self
        do {
            payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        } catch {
            throw SyncConvergenceValidationError.committedAtOrderingDecodeFailed
        }
        try payload.validate()
        return payload
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw SyncConvergenceValidationError.unsupportedEvidenceVersion(field: "committedAtOrdering", version: version)
        }
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            batchIDLowercase,
            field: "batchIDLowercase"
        )
    }

    func validate(against batch: IncorporatedSyncBatch) throws {
        try validate()
        guard batchIDLowercase == batch.batchID.uuidString.lowercased() else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "batchID")
        }
        guard committedAtBitPattern == batch.committedAtBitPattern else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "committedAtBitPattern")
        }
    }

    func validate(against tombstone: IncorporatedBatchTombstone) throws {
        try validate()
        guard batchIDLowercase == tombstone.batchID.uuidString.lowercased() else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "batchID")
        }
    }
}

struct CanonicalIncorporatedBatchTombstonePayloadV1: Codable, Equatable, Sendable {
    static let tombstoneFormatVersion = 1

    let tombstoneFormatVersion: Int
    let batchIDLowercase: String
    let originDeviceIDLowercase: String
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let schemaVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int
    let committedAtOrdering: CommittedAtOrderingPayload

    enum CodingKeys: String, CodingKey {
        case tombstoneFormatVersion = "v"
        case batchIDLowercase = "b"
        case originDeviceIDLowercase = "o"
        case canonicalPayloadDigest = "d"
        case canonicalPayloadDigestFormatVersion = "df"
        case schemaVersion = "s"
        case committedResultDigest = "r"
        case committedResultDigestFormatVersion = "rf"
        case committedAtOrdering = "c"
    }

    init(
        tombstoneFormatVersion: Int = Self.tombstoneFormatVersion,
        batchIDLowercase: String,
        originDeviceIDLowercase: String,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        schemaVersion: Int,
        committedResultDigest: String,
        committedResultDigestFormatVersion: Int,
        committedAtOrdering: CommittedAtOrderingPayload
    ) {
        self.tombstoneFormatVersion = tombstoneFormatVersion
        self.batchIDLowercase = batchIDLowercase
        self.originDeviceIDLowercase = originDeviceIDLowercase
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.schemaVersion = schemaVersion
        self.committedResultDigest = committedResultDigest
        self.committedResultDigestFormatVersion = committedResultDigestFormatVersion
        self.committedAtOrdering = committedAtOrdering
    }

    func encodedEvidenceData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    func validate() throws {
        guard tombstoneFormatVersion == Self.tombstoneFormatVersion else {
            throw SyncConvergenceValidationError.unsupportedTombstoneFormat(version: tombstoneFormatVersion)
        }
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(batchIDLowercase, field: "batchIDLowercase")
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            originDeviceIDLowercase,
            field: "originDeviceIDLowercase"
        )
        try SyncConvergenceContractValidation.validateSHA256HexDigest(
            canonicalPayloadDigest,
            field: "canonicalPayloadDigest"
        )
        try SyncConvergenceContractValidation.validateSHA256HexDigest(
            committedResultDigest,
            field: "committedResultDigest"
        )
        try committedAtOrdering.validate()
        guard committedAtOrdering.batchIDLowercase == batchIDLowercase else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "committedAtOrdering.batchID")
        }
    }
}

enum SyncConvergenceContractValidation {
    static func validateCanonicalLowercaseUUID(_ value: String, field: String) throws {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else {
            throw SyncConvergenceValidationError.malformedUUID(field: field, value: value)
        }
    }

    static func validateSHA256HexDigest(_ value: String, field: String) throws {
        guard value.count == 64,
              value.allSatisfy({ character in
                  ("0"..."9").contains(character) || ("a"..."f").contains(character)
              })
        else {
            throw SyncConvergenceValidationError.malformedDigest(field: field, value: value)
        }
    }
}

enum SyncConvergenceDateAuthority {
    static func validate(date: Date, bitPattern: UInt64, field: String) throws {
        guard SyncConvergenceDateBits.bitPattern(for: date) == bitPattern else {
            throw SyncConvergenceValidationError.dateAuthorityMismatch(field: field)
        }
    }

    static func validate(date: Date?, bitPattern: UInt64?, field: String) throws {
        switch (date, bitPattern) {
        case (.none, .none):
            return
        case (.some(let date), .some(let bitPattern)):
            try validate(date: date, bitPattern: bitPattern, field: field)
        default:
            throw SyncConvergenceValidationError.dateAuthorityMismatch(field: field)
        }
    }
}

struct OperationIdentityPayload: Codable, Equatable, Sendable {
    static let supportedVersion = 1

    let version: Int
    let batchIDLowercase: String
    let originDeviceIDLowercase: String
    let operationIndex: Int
    let operationKind: String
    let canonicalReplayKey: CanonicalReplayKeyPayload

    init(
        version: Int = Self.supportedVersion,
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

    func encodedPayloadData() throws -> Data {
        try validate()
        return try SyncConvergenceStableEncoding.encode(self)
    }

    static func decodePayloadData(_ data: Data) throws -> Self {
        let payload = try SyncConvergenceStableEncoding.decode(Self.self, from: data)
        try payload.validate()
        return payload
    }

    func validate() throws {
        guard version == Self.supportedVersion else {
            throw SyncConvergenceValidationError.unsupportedEvidenceVersion(field: "operationIdentity", version: version)
        }
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            batchIDLowercase,
            field: "batchIDLowercase"
        )
        try SyncConvergenceContractValidation.validateCanonicalLowercaseUUID(
            originDeviceIDLowercase,
            field: "originDeviceIDLowercase"
        )
        guard operationIndex >= 0 else {
            throw SyncConvergenceValidationError.invalidReplayKeyShape(field: "operationIndex")
        }
        try canonicalReplayKey.validate()
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
    case anchorlessMatchingBaseEvidenceUnavailable(noteID: UUID, batchID: UUID)
    case unreconstructableBase(noteID: UUID, batchID: UUID, baseContentHash: String)
    case unsupportedReconciliation(noteID: UUID, batchID: UUID)
    case historyPressure(noteID: UUID, blockingBatchID: UUID?)
}

enum SyncConvergenceTransactionFailure: Error, Equatable {
    case swiftDataFetch
    case swiftDataSave
    case corruptHistory(noteID: UUID?)
    case invalidMergePlan(noteID: UUID?)
    case inconsistentIncorporationState(noteID: UUID?)
    case staleAuthoritativeState(noteID: UUID?)
    case unprovenTextLoss(noteID: UUID?)
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
        case .staleAuthoritativeState:
            return .staleAuthoritativeState
        case .unprovenTextLoss:
            return .unprovenTextLoss
        case .unsupportedDigestFormat:
            return .unsupportedDigestFormat
        case .unexpected:
            return .unexpected
        }
    }
}
