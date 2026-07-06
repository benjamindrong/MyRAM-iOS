import Foundation

enum ExplicitDeleteProvenanceTier: String, Codable, Equatable, Sendable {
    case full
    case compacted
}

enum ExplicitDeleteProvenanceConstants {
    static let formatVersion = 1
    static let contextUTF16CodeUnits = 32
}

struct ExplicitDeleteProvenanceRecord: Codable, Equatable, Sendable {
    let formatVersion: Int
    let tier: ExplicitDeleteProvenanceTier
    let noteID: UUID
    let batchID: UUID
    let operationIndex: Int
    let originDeviceID: UUID
    let canonicalReplayKey: CanonicalReplayKeyPayload
    let baseContentHash: String
    let resultContentHash: String
    let deletedText: String?
    let deletedTextDigest: String
    let deletedUTF16Length: Int
    let leftContext: String?
    let leftContextDigest: String
    let leftContextUTF16Length: Int
    let rightContext: String?
    let rightContextDigest: String
    let rightContextUTF16Length: Int
    let originalUTF16Offset: Int
    let occurrenceOrdinal: Int
    let createdAt: Date
    let createdAtBitPattern: UInt64
    let payloadByteCount: Int
    let baseSnapshotGeneration: Int?

    var identity: SyncConvergenceRetainedOperationIdentity {
        SyncConvergenceRetainedOperationIdentity(batchID: batchID, operationIndex: operationIndex)
    }

    var provenanceKey: String {
        SyncConvergenceKey.explicitDeleteProvenance(batchID: batchID, operationIndex: operationIndex)
    }

    func canonicalPayloadData() throws -> Data {
        try SyncConvergenceStableEncoding.encode(self)
    }

    func fullFidelityAuditProjection() -> ExplicitDeleteProvenanceAuditProjection {
        ExplicitDeleteProvenanceAuditProjection(
            identity: identity,
            noteID: noteID,
            originDeviceID: originDeviceID,
            canonicalReplayKey: canonicalReplayKey,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            deletedTextDigest: deletedTextDigest,
            deletedUTF16Length: deletedUTF16Length,
            leftContextDigest: leftContextDigest,
            leftContextUTF16Length: leftContextUTF16Length,
            rightContextDigest: rightContextDigest,
            rightContextUTF16Length: rightContextUTF16Length,
            occurrenceOrdinal: occurrenceOrdinal,
            formatVersion: formatVersion,
            tier: tier,
            payloadByteCount: payloadByteCount,
            baseSnapshotGeneration: baseSnapshotGeneration
        )
    }
}

struct ExplicitDeleteProvenanceProjection: Equatable {
    let record: ExplicitDeleteProvenanceRecord
    let canonicalPayloadData: Data

    var auditProjection: ExplicitDeleteProvenanceAuditProjection {
        record.fullFidelityAuditProjection()
    }
}

struct ExplicitDeleteProvenanceAuditProjection: Equatable {
    let identity: SyncConvergenceRetainedOperationIdentity
    let noteID: UUID
    let originDeviceID: UUID
    let canonicalReplayKey: CanonicalReplayKeyPayload
    let baseContentHash: String
    let resultContentHash: String
    let deletedTextDigest: String
    let deletedUTF16Length: Int
    let leftContextDigest: String
    let leftContextUTF16Length: Int
    let rightContextDigest: String
    let rightContextUTF16Length: Int
    let occurrenceOrdinal: Int
    let formatVersion: Int
    let tier: ExplicitDeleteProvenanceTier
    let payloadByteCount: Int
    let baseSnapshotGeneration: Int?
}

struct ValidatedExplicitDeleteOccurrence: Equatable {
    let record: ExplicitDeleteProvenanceRecord
    let utf16Range: Range<Int>
    let resolvedDeletedText: String
    let resolvedLeftContext: String
    let resolvedRightContext: String
}

enum ExplicitDeleteProvenanceBuildResult: Equatable {
    case record(ExplicitDeleteProvenanceRecord)
    case recoveryRequired(ExplicitDeleteProvenanceFailure)
}

enum ExplicitDeleteProvenanceValidationResult: Equatable {
    case valid(ValidatedExplicitDeleteOccurrence)
    case recoveryRequired(ExplicitDeleteProvenanceFailure)
}

enum ExplicitDeleteProvenanceCompactionResult: Equatable {
    case compacted(ExplicitDeleteProvenanceRecord)
    case retainedFull(ExplicitDeleteProvenanceFailure)
    case recoveryRequired(ExplicitDeleteProvenanceFailure)
}

enum ExplicitDeleteProvenanceFailure: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidOperationIdentity
    case invalidReplayKey
    case operationIsNotDelete
    case missingDeletePayload
    case invalidUTF16Range
    case baseHashMismatch
    case deletedTextMismatch
    case resultHashMismatch
    case malformedContextEvidence
    case occurrenceNotFound
    case ambiguousOccurrence
    case contradictoryDuplicateProvenance
    case corruptPersistedProvenance
    case nodeAbsentFromGraph
    case missingSnapshot
    case snapshotHashMismatch
}

enum ExplicitDeleteProvenanceDigest {
    static func canonicalDigest(for value: String) -> String {
        SyncBatchContentHash.sha256Hex(for: value)
    }
}
