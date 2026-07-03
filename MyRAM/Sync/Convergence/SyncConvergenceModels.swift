import Foundation
import SwiftData

@Model
final class NoteContentSnapshot {
    @Attribute(.unique) var snapshotKey: String
    var id: UUID
    var noteID: UUID
    var contentHash: String
    var body: String
    var bodyUTF8ByteCount: Int
    var generation: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        noteID: UUID,
        contentHash: String,
        body: String,
        generation: Int,
        createdAt: Date = .now
    ) {
        self.snapshotKey = SyncConvergenceKey.snapshot(noteID: noteID, contentHash: contentHash)
        self.id = id
        self.noteID = noteID
        self.contentHash = contentHash
        self.body = body
        self.bodyUTF8ByteCount = body.utf8.count
        self.generation = generation
        self.createdAt = createdAt
    }
}

@Model
final class RetainedBodyOperation {
    @Attribute(.unique) var operationKey: String
    var id: UUID
    var noteID: UUID
    var batchID: UUID
    var originDeviceID: UUID
    var operationIndex: Int
    var operationKindRaw: String
    var utf16Offset: Int
    var utf16Length: Int?
    var text: String?
    var expectedText: String?
    var baseContentHash: String?
    var resultContentHash: String?
    // The bit pattern is authoritative for ordering; Date is retained for display and query convenience.
    private(set) var modifiedAt: Date
    private(set) var modifiedAtBitPattern: UInt64
    var canonicalReplayKeyPayloadData: Data
    var sourceRaw: String
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        noteID: UUID,
        batchID: UUID,
        originDeviceID: UUID,
        operationIndex: Int,
        operationKindRaw: String,
        utf16Offset: Int,
        utf16Length: Int? = nil,
        text: String? = nil,
        expectedText: String? = nil,
        baseContentHash: String? = nil,
        resultContentHash: String? = nil,
        modifiedAt: Date,
        canonicalReplayKeyPayloadData: Data,
        sourceRaw: String
    ) {
        self.operationKey = SyncConvergenceKey.retainedOperation(batchID: batchID, operationIndex: operationIndex)
        self.id = id
        self.noteID = noteID
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.operationIndex = operationIndex
        self.operationKindRaw = operationKindRaw
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.text = text
        self.expectedText = expectedText
        self.baseContentHash = baseContentHash
        self.resultContentHash = resultContentHash
        self.modifiedAt = modifiedAt
        self.modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: modifiedAt)
        self.canonicalReplayKeyPayloadData = canonicalReplayKeyPayloadData
        self.sourceRaw = sourceRaw
        self.payloadUTF8ByteCount = (text?.utf8.count ?? 0) + (expectedText?.utf8.count ?? 0)
    }

    func validateDateAuthority() throws {
        try SyncConvergenceDateAuthority.validate(
            date: modifiedAt,
            bitPattern: modifiedAtBitPattern,
            field: "modifiedAt"
        )
    }

    func rebuildConvenienceDatesFromAuthoritativeBits() {
        modifiedAt = SyncConvergenceDateBits.date(from: modifiedAtBitPattern)
    }

    func setModifiedAt(_ date: Date) {
        modifiedAt = date
        modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    #if DEBUG
    func testOnlySetModifiedAtWithoutUpdatingBits(_ date: Date) {
        modifiedAt = date
    }
    #endif
}

@Model
final class IncorporatedSyncBatch {
    @Attribute(.unique) var batchKey: String
    var id: UUID
    var batchID: UUID
    var originDeviceID: UUID
    // Bit-pattern fields are authoritative for ordering and contradiction checks; Dates are convenience mirrors.
    private(set) var createdAt: Date
    private(set) var createdAtBitPattern: UInt64
    var batchSequence: UInt64?
    var schemaVersion: Int
    private(set) var committedAt: Date
    private(set) var committedAtBitPattern: UInt64
    var canonicalPayloadDigest: String
    var canonicalPayloadDigestFormatVersion: Int
    var committedResultDigest: String
    var committedResultDigestFormatVersion: Int
    var affectedNotesPayloadData: Data
    var authoritativeChildCount: Int
    var authoritativeChildBytes: Int
    var authoritativeChildrenDigest: String
    var postCommitStatePayloadData: Data

    init(
        id: UUID = UUID(),
        batchID: UUID,
        originDeviceID: UUID,
        createdAt: Date,
        batchSequence: UInt64?,
        schemaVersion: Int,
        committedAt: Date,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        committedResultDigest: String,
        committedResultDigestFormatVersion: Int,
        affectedNotesPayloadData: Data,
        authoritativeChildCount: Int,
        authoritativeChildBytes: Int,
        authoritativeChildrenDigest: String,
        postCommitStatePayloadData: Data
    ) {
        self.batchKey = SyncConvergenceKey.incorporatedBatch(batchID: batchID)
        self.id = id
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.createdAt = createdAt
        self.createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: createdAt)
        self.batchSequence = batchSequence
        self.schemaVersion = schemaVersion
        self.committedAt = committedAt
        self.committedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: committedAt)
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.committedResultDigest = committedResultDigest
        self.committedResultDigestFormatVersion = committedResultDigestFormatVersion
        self.affectedNotesPayloadData = affectedNotesPayloadData
        self.authoritativeChildCount = authoritativeChildCount
        self.authoritativeChildBytes = authoritativeChildBytes
        self.authoritativeChildrenDigest = authoritativeChildrenDigest
        self.postCommitStatePayloadData = postCommitStatePayloadData
    }

    func validateDateAuthority() throws {
        try SyncConvergenceDateAuthority.validate(
            date: createdAt,
            bitPattern: createdAtBitPattern,
            field: "createdAt"
        )
        try SyncConvergenceDateAuthority.validate(
            date: committedAt,
            bitPattern: committedAtBitPattern,
            field: "committedAt"
        )
    }

    func rebuildConvenienceDatesFromAuthoritativeBits() {
        createdAt = SyncConvergenceDateBits.date(from: createdAtBitPattern)
        committedAt = SyncConvergenceDateBits.date(from: committedAtBitPattern)
    }

    func setCreatedAt(_ date: Date) {
        createdAt = date
        createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    func setCommittedAt(_ date: Date) {
        committedAt = date
        committedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    #if DEBUG
    func testOnlySetCreatedAtWithoutUpdatingBits(_ date: Date) {
        createdAt = date
    }

    func testOnlySetCommittedAtWithoutUpdatingBits(_ date: Date) {
        committedAt = date
    }
    #endif
}

@Model
final class IncorporatedBatchTombstone {
    static let maximumEncodedByteCount = 512
    static let supportedTombstoneFormatVersion = CanonicalIncorporatedBatchTombstonePayloadV1.tombstoneFormatVersion

    @Attribute(.unique) private(set) var tombstoneKey: String
    private(set) var id: UUID
    private(set) var batchID: UUID
    private(set) var originDeviceID: UUID
    private(set) var canonicalPayloadDigest: String
    private(set) var canonicalPayloadDigestFormatVersion: Int
    private(set) var schemaVersion: Int
    private(set) var committedResultDigest: String
    private(set) var committedResultDigestFormatVersion: Int
    private(set) var committedAtOrderingPayloadData: Data
    private(set) var tombstoneFormatVersion: Int

    init(
        id: UUID = UUID(),
        batchID: UUID,
        originDeviceID: UUID,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        schemaVersion: Int,
        committedResultDigest: String,
        committedResultDigestFormatVersion: Int,
        committedAtOrderingPayloadData: Data,
        tombstoneFormatVersion: Int = 1
    ) throws {
        self.tombstoneKey = SyncConvergenceKey.incorporatedBatchTombstone(batchID: batchID)
        self.id = id
        self.batchID = batchID
        self.originDeviceID = originDeviceID
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.schemaVersion = schemaVersion
        self.committedResultDigest = committedResultDigest
        self.committedResultDigestFormatVersion = committedResultDigestFormatVersion
        self.committedAtOrderingPayloadData = committedAtOrderingPayloadData
        self.tombstoneFormatVersion = tombstoneFormatVersion
        try validateForPersistence()
    }

    static func makeValidated(
        id: UUID = UUID(),
        batchID: UUID,
        originDeviceID: UUID,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        schemaVersion: Int,
        committedResultDigest: String,
        committedResultDigestFormatVersion: Int,
        committedAtOrderingPayloadData: Data,
        tombstoneFormatVersion: Int = 1
    ) throws -> IncorporatedBatchTombstone {
        try IncorporatedBatchTombstone(
            id: id,
            batchID: batchID,
            originDeviceID: originDeviceID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            schemaVersion: schemaVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: committedAtOrderingPayloadData,
            tombstoneFormatVersion: tombstoneFormatVersion
        )
    }

    var isWithinFixedSizeLimit: Bool {
        (try? validateForPersistence()) != nil
    }

    func canonicalTombstonePayloadV1() throws -> CanonicalIncorporatedBatchTombstonePayloadV1 {
        let committedAtOrdering = try CommittedAtOrderingPayload.decodeEvidenceData(committedAtOrderingPayloadData)
        let payload = CanonicalIncorporatedBatchTombstonePayloadV1(
            tombstoneFormatVersion: tombstoneFormatVersion,
            batchIDLowercase: batchID.uuidString.lowercased(),
            originDeviceIDLowercase: originDeviceID.uuidString.lowercased(),
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            schemaVersion: schemaVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion,
            committedAtOrdering: committedAtOrdering
        )
        try payload.validate()
        try committedAtOrdering.validate(against: self)
        return payload
    }

    func canonicalEncodedPayloadBytes() throws -> Data {
        try canonicalTombstonePayloadV1().encodedEvidenceData()
    }

    func validateForPersistence() throws {
        guard tombstoneFormatVersion == Self.supportedTombstoneFormatVersion else {
            throw SyncConvergenceValidationError.unsupportedTombstoneFormat(version: tombstoneFormatVersion)
        }
        let encodedPayload = try canonicalEncodedPayloadBytes()
        try Self.validateEncodedPayloadSize(encodedPayload)
    }

    static func validateEncodedPayloadSize(_ encodedPayload: Data) throws {
        guard encodedPayload.count <= maximumEncodedByteCount else {
            throw SyncConvergenceValidationError.encodedPayloadExceedsLimit(
                actual: encodedPayload.count,
                limit: maximumEncodedByteCount
            )
        }
    }

    #if DEBUG
    func testOnlySetCanonicalPayloadDigest(_ digest: String) {
        canonicalPayloadDigest = digest
    }

    func testOnlySetCommittedAtOrderingPayloadData(_ data: Data) {
        committedAtOrderingPayloadData = data
    }

    func testOnlySetTombstoneFormatVersion(_ version: Int) {
        tombstoneFormatVersion = version
    }
    #endif
}

@Model
final class IncorporatedBatchNoteEffect {
    @Attribute(.unique) var effectKey: String
    var id: UUID
    var batchID: UUID
    var noteID: UUID
    var preBodyHash: String?
    var postBodyHash: String?
    var preTitleKeyPayloadData: Data?
    var postTitleKeyPayloadData: Data?

    init(
        id: UUID = UUID(),
        batchID: UUID,
        noteID: UUID,
        preBodyHash: String? = nil,
        postBodyHash: String? = nil,
        preTitleKeyPayloadData: Data? = nil,
        postTitleKeyPayloadData: Data? = nil
    ) {
        self.effectKey = SyncConvergenceKey.batchNoteEffect(batchID: batchID, noteID: noteID)
        self.id = id
        self.batchID = batchID
        self.noteID = noteID
        self.preBodyHash = preBodyHash
        self.postBodyHash = postBodyHash
        self.preTitleKeyPayloadData = preTitleKeyPayloadData
        self.postTitleKeyPayloadData = postTitleKeyPayloadData
    }
}

@Model
final class IncorporatedBatchOperationIdentity {
    @Attribute(.unique) var identityKey: String
    var id: UUID
    var batchID: UUID
    var noteID: UUID
    var operationIndex: Int
    var operationIdentityPayloadData: Data
    var canonicalReplayKeyPayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        batchID: UUID,
        noteID: UUID,
        operationIndex: Int,
        operationIdentityPayloadData: Data,
        canonicalReplayKeyPayloadData: Data
    ) {
        self.identityKey = SyncConvergenceKey.batchOperationIdentity(batchID: batchID, operationIndex: operationIndex)
        self.id = id
        self.batchID = batchID
        self.noteID = noteID
        self.operationIndex = operationIndex
        self.operationIdentityPayloadData = operationIdentityPayloadData
        self.canonicalReplayKeyPayloadData = canonicalReplayKeyPayloadData
        self.payloadUTF8ByteCount = operationIdentityPayloadData.count + canonicalReplayKeyPayloadData.count
    }
}

@Model
final class IncorporatedBatchResultEvidence {
    @Attribute(.unique) var resultEvidenceKey: String
    var id: UUID
    var batchID: UUID
    var noteID: UUID
    var resultKindRaw: String
    var resultEvidencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        batchID: UUID,
        noteID: UUID,
        resultKindRaw: String,
        resultEvidencePayloadData: Data
    ) {
        self.resultEvidenceKey = SyncConvergenceKey.batchResultEvidence(
            batchID: batchID,
            noteID: noteID,
            kind: resultKindRaw
        )
        self.id = id
        self.batchID = batchID
        self.noteID = noteID
        self.resultKindRaw = resultKindRaw
        self.resultEvidencePayloadData = resultEvidencePayloadData
        self.payloadUTF8ByteCount = resultEvidencePayloadData.count
    }
}

@Model
final class IncorporationBlockingReference {
    @Attribute(.unique) var blockingReferenceKey: String
    var id: UUID
    var batchID: UUID
    var blockingBatchID: UUID
    var noteID: UUID
    var blockingBatchReferencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        batchID: UUID,
        blockingBatchID: UUID,
        noteID: UUID,
        blockingBatchReferencePayloadData: Data
    ) {
        self.blockingReferenceKey = SyncConvergenceKey.incorporationBlockingReference(
            batchID: batchID,
            blockingBatchID: blockingBatchID,
            noteID: noteID
        )
        self.id = id
        self.batchID = batchID
        self.blockingBatchID = blockingBatchID
        self.noteID = noteID
        self.blockingBatchReferencePayloadData = blockingBatchReferencePayloadData
        self.payloadUTF8ByteCount = blockingBatchReferencePayloadData.count
    }
}

@Model
final class IncorporationContradictionDiagnostic {
    @Attribute(.unique) var contradictionKey: String
    var id: UUID
    var batchID: UUID
    var noteID: UUID?
    var diagnosticEvidencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        batchID: UUID,
        noteID: UUID?,
        diagnosticEvidencePayloadData: Data
    ) {
        self.contradictionKey = SyncConvergenceKey.incorporationContradiction(batchID: batchID, noteID: noteID)
        self.id = id
        self.batchID = batchID
        self.noteID = noteID
        self.diagnosticEvidencePayloadData = diagnosticEvidencePayloadData
        self.payloadUTF8ByteCount = diagnosticEvidencePayloadData.count
    }
}

@Model
final class NoteTitleWinner {
    @Attribute(.unique) var titleWinnerKey: String
    var id: UUID
    var noteID: UUID
    var title: String
    var canonicalReplayKeyPayloadData: Data
    var operationIdentityPayloadData: Data
    // updatedAtBitPattern is the authoritative update identity; updatedAt is a convenience mirror.
    private(set) var updatedAt: Date
    private(set) var updatedAtBitPattern: UInt64

    init(
        id: UUID = UUID(),
        noteID: UUID,
        title: String,
        canonicalReplayKeyPayloadData: Data,
        operationIdentityPayloadData: Data,
        updatedAt: Date
    ) {
        self.titleWinnerKey = SyncConvergenceKey.titleWinner(noteID: noteID)
        self.id = id
        self.noteID = noteID
        self.title = title
        self.canonicalReplayKeyPayloadData = canonicalReplayKeyPayloadData
        self.operationIdentityPayloadData = operationIdentityPayloadData
        self.updatedAt = updatedAt
        self.updatedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: updatedAt)
    }

    func validateDateAuthority() throws {
        try SyncConvergenceDateAuthority.validate(
            date: updatedAt,
            bitPattern: updatedAtBitPattern,
            field: "updatedAt"
        )
    }

    func rebuildConvenienceDatesFromAuthoritativeBits() {
        updatedAt = SyncConvergenceDateBits.date(from: updatedAtBitPattern)
    }

    func setUpdatedAt(_ date: Date) {
        updatedAt = date
        updatedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    #if DEBUG
    func testOnlySetUpdatedAtWithoutUpdatingBits(_ date: Date) {
        updatedAt = date
    }
    #endif
}

@Model
final class NoteHistoryCompactionState {
    @Attribute(.unique) var compactionKey: String
    var id: UUID
    var noteID: UUID
    var oldestRetainedGeneration: Int
    var newestRetainedGeneration: Int
    var retainedOperationCount: Int
    var retainedOperationBytes: Int
    var retainedSnapshotCount: Int
    var retainedSnapshotBytes: Int
    var fullIncorporationEvidenceBytes: Int
    var episodeEvidenceBytes: Int
    var diagnosticEvidenceBytes: Int
    var cleanupEvidenceBytes: Int
    var pressureStateRaw: String?
    var updatedAt: Date

    init(id: UUID = UUID(), noteID: UUID, updatedAt: Date = .now) {
        self.compactionKey = SyncConvergenceKey.compaction(noteID: noteID)
        self.id = id
        self.noteID = noteID
        self.oldestRetainedGeneration = 0
        self.newestRetainedGeneration = 0
        self.retainedOperationCount = 0
        self.retainedOperationBytes = 0
        self.retainedSnapshotCount = 0
        self.retainedSnapshotBytes = 0
        self.fullIncorporationEvidenceBytes = 0
        self.episodeEvidenceBytes = 0
        self.diagnosticEvidenceBytes = 0
        self.cleanupEvidenceBytes = 0
        self.pressureStateRaw = nil
        self.updatedAt = updatedAt
    }
}

@Model
final class ConvergenceNoteDiagnosticState {
    @Attribute(.unique) var diagnosticKey: String
    var id: UUID
    var noteID: UUID
    var statusRaw: String
    var blockingReferenceCount: Int
    var diagnosticEvidencePayloadData: Data
    // Bit patterns are authoritative for duplicate and contradiction checks; Dates are convenience mirrors.
    private(set) var createdAt: Date
    private(set) var createdAtBitPattern: UInt64
    private(set) var updatedAt: Date
    private(set) var updatedAtBitPattern: UInt64

    init(
        id: UUID = UUID(),
        noteID: UUID,
        statusRaw: String,
        blockingReferenceCount: Int = 0,
        diagnosticEvidencePayloadData: Data = Data(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.diagnosticKey = SyncConvergenceKey.diagnostic(noteID: noteID)
        self.id = id
        self.noteID = noteID
        self.statusRaw = statusRaw
        self.blockingReferenceCount = blockingReferenceCount
        self.diagnosticEvidencePayloadData = diagnosticEvidencePayloadData
        self.createdAt = createdAt
        self.createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: createdAt)
        self.updatedAt = updatedAt
        self.updatedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: updatedAt)
    }

    func validateDateAuthority() throws {
        try SyncConvergenceDateAuthority.validate(
            date: createdAt,
            bitPattern: createdAtBitPattern,
            field: "createdAt"
        )
        try SyncConvergenceDateAuthority.validate(
            date: updatedAt,
            bitPattern: updatedAtBitPattern,
            field: "updatedAt"
        )
    }

    func rebuildConvenienceDatesFromAuthoritativeBits() {
        createdAt = SyncConvergenceDateBits.date(from: createdAtBitPattern)
        updatedAt = SyncConvergenceDateBits.date(from: updatedAtBitPattern)
    }

    func setCreatedAt(_ date: Date) {
        createdAt = date
        createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    func setUpdatedAt(_ date: Date) {
        updatedAt = date
        updatedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: date)
    }

    #if DEBUG
    func testOnlySetCreatedAtWithoutUpdatingBits(_ date: Date) {
        createdAt = date
    }

    func testOnlySetUpdatedAtWithoutUpdatingBits(_ date: Date) {
        updatedAt = date
    }
    #endif
}

@Model
final class ConvergenceBlockingBatchReference {
    @Attribute(.unique) var blockingReferenceKey: String
    var id: UUID
    var noteID: UUID
    var blockingBatchID: UUID
    var affectedNoteID: UUID
    var originDeviceID: UUID
    var queuePosition: Int
    var blockingBatchReferencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        noteID: UUID,
        blockingBatchID: UUID,
        affectedNoteID: UUID,
        originDeviceID: UUID,
        queuePosition: Int,
        blockingBatchReferencePayloadData: Data
    ) {
        self.blockingReferenceKey = SyncConvergenceKey.diagnosticBlockingReference(
            noteID: noteID,
            blockingBatchID: blockingBatchID,
            affectedNoteID: affectedNoteID
        )
        self.id = id
        self.noteID = noteID
        self.blockingBatchID = blockingBatchID
        self.affectedNoteID = affectedNoteID
        self.originDeviceID = originDeviceID
        self.queuePosition = queuePosition
        self.blockingBatchReferencePayloadData = blockingBatchReferencePayloadData
        self.payloadUTF8ByteCount = blockingBatchReferencePayloadData.count
    }
}

@Model
final class ReconciliationEpisode {
    @Attribute(.unique) var episodeKey: String
    var id: UUID
    var noteID: UUID
    var generation: Int
    var stateRaw: String
    var logicalGroupingPayloadData: Data
    var didEmitLocalCandidate: Bool
    var freshAgreedHash: String?
    // completedAtBitPattern is authoritative when present; completedAt is a convenience mirror.
    private(set) var completedAt: Date?
    private(set) var completedAtBitPattern: UInt64?

    init(
        id: UUID = UUID(),
        noteID: UUID,
        generation: Int,
        stateRaw: String,
        logicalGroupingPayloadData: Data = Data(),
        didEmitLocalCandidate: Bool = false,
        freshAgreedHash: String? = nil,
        completedAt: Date? = nil
    ) {
        self.episodeKey = SyncConvergenceKey.episode(noteID: noteID, generation: generation)
        self.id = id
        self.noteID = noteID
        self.generation = generation
        self.stateRaw = stateRaw
        self.logicalGroupingPayloadData = logicalGroupingPayloadData
        self.didEmitLocalCandidate = didEmitLocalCandidate
        self.freshAgreedHash = freshAgreedHash
        self.completedAt = completedAt
        self.completedAtBitPattern = completedAt.map { SyncConvergenceDateBits.bitPattern(for: $0) }
    }

    func validateDateAuthority() throws {
        try SyncConvergenceDateAuthority.validate(
            date: completedAt,
            bitPattern: completedAtBitPattern,
            field: "completedAt"
        )
    }

    func rebuildConvenienceDatesFromAuthoritativeBits() {
        completedAt = completedAtBitPattern.map(SyncConvergenceDateBits.date(from:))
    }

    func setCompletedAt(_ date: Date?) {
        completedAt = date
        completedAtBitPattern = date.map { SyncConvergenceDateBits.bitPattern(for: $0) }
    }

    #if DEBUG
    func testOnlySetCompletedAtWithoutUpdatingBits(_ date: Date?) {
        completedAt = date
    }
    #endif
}

enum SyncConvergencePersistenceValidation {
    static func validate(_ operation: RetainedBodyOperation) throws {
        try operation.validateDateAuthority()
        _ = try CanonicalReplayKeyPayload.decodeEvidenceData(operation.canonicalReplayKeyPayloadData)
    }

    static func validate(_ batch: IncorporatedSyncBatch) throws {
        try batch.validateDateAuthority()
    }

    static func validate(_ tombstone: IncorporatedBatchTombstone) throws {
        try tombstone.validateForPersistence()
    }

    static func validate(_ operationIdentity: IncorporatedBatchOperationIdentity) throws {
        let canonicalReplayKey = try CanonicalReplayKeyPayload.decodeEvidenceData(
            operationIdentity.canonicalReplayKeyPayloadData
        )
        let operationIdentityPayload = try OperationIdentityPayload.decodePayloadData(
            operationIdentity.operationIdentityPayloadData
        )
        guard operationIdentityPayload.canonicalReplayKey == canonicalReplayKey else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "canonicalReplayKey")
        }
    }

    static func validate(_ noteEffect: IncorporatedBatchNoteEffect) throws {
        if let preTitleKeyPayloadData = noteEffect.preTitleKeyPayloadData {
            _ = try CanonicalReplayKeyPayload.decodeEvidenceData(preTitleKeyPayloadData)
        }
        if let postTitleKeyPayloadData = noteEffect.postTitleKeyPayloadData {
            _ = try CanonicalReplayKeyPayload.decodeEvidenceData(postTitleKeyPayloadData)
        }
    }

    static func validate(_ titleWinner: NoteTitleWinner) throws {
        try titleWinner.validateDateAuthority()
        let canonicalReplayKey = try CanonicalReplayKeyPayload.decodeEvidenceData(
            titleWinner.canonicalReplayKeyPayloadData
        )
        let operationIdentityPayload = try OperationIdentityPayload.decodePayloadData(
            titleWinner.operationIdentityPayloadData
        )
        guard operationIdentityPayload.canonicalReplayKey == canonicalReplayKey else {
            throw SyncConvergenceValidationError.modelPayloadDisagreement(field: "canonicalReplayKey")
        }
    }

    static func validate(_ diagnosticState: ConvergenceNoteDiagnosticState) throws {
        try diagnosticState.validateDateAuthority()
    }

    static func validate(_ episode: ReconciliationEpisode) throws {
        try episode.validateDateAuthority()
    }
}

@Model
final class ReconciliationCandidateRecord {
    @Attribute(.unique) var candidateKey: String
    var id: UUID
    var noteID: UUID
    var generation: Int
    var candidateRoleRaw: String
    var candidateIdentity: String
    var candidateEvidencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        noteID: UUID,
        generation: Int,
        candidateRoleRaw: String,
        candidateIdentity: String,
        candidateEvidencePayloadData: Data
    ) {
        self.candidateKey = SyncConvergenceKey.reconciliationCandidate(
            noteID: noteID,
            generation: generation,
            candidateIdentity: candidateIdentity
        )
        self.id = id
        self.noteID = noteID
        self.generation = generation
        self.candidateRoleRaw = candidateRoleRaw
        self.candidateIdentity = candidateIdentity
        self.candidateEvidencePayloadData = candidateEvidencePayloadData
        self.payloadUTF8ByteCount = candidateEvidencePayloadData.count
    }
}

@Model
final class ReconciliationCompletionEvidenceRecord {
    @Attribute(.unique) var completionEvidenceKey: String
    var id: UUID
    var noteID: UUID
    var generation: Int
    var kindRaw: String
    var evidencePayloadData: Data
    var payloadUTF8ByteCount: Int

    init(
        id: UUID = UUID(),
        noteID: UUID,
        generation: Int,
        kindRaw: String,
        evidencePayloadData: Data
    ) {
        self.completionEvidenceKey = SyncConvergenceKey.reconciliationCompletionEvidence(
            noteID: noteID,
            generation: generation,
            kind: kindRaw
        )
        self.id = id
        self.noteID = noteID
        self.generation = generation
        self.kindRaw = kindRaw
        self.evidencePayloadData = evidencePayloadData
        self.payloadUTF8ByteCount = evidencePayloadData.count
    }
}
