import CryptoKit
import Foundation

typealias SyncBatchDeviceID = UUID
typealias SyncBatchID = UUID
typealias SyncBatchNoteID = UUID
typealias SyncBatchFolderID = UUID

struct SyncBatch: Codable, Equatable, Identifiable, Sendable {
    let id: SyncBatchID
    let originDeviceID: SyncBatchDeviceID
    let createdAt: Date
    let batchSequence: UInt64?
    let changes: [SyncBatchChange]

    init(
        id: SyncBatchID,
        originDeviceID: SyncBatchDeviceID,
        createdAt: Date,
        batchSequence: UInt64? = nil,
        changes: [SyncBatchChange]
    ) {
        self.id = id
        self.originDeviceID = originDeviceID
        self.createdAt = createdAt
        self.batchSequence = batchSequence
        self.changes = changes
    }
}

enum SyncBatchChange: Codable, Equatable, Sendable {
    case noteCreated(SyncBatchNoteCreatedChange)
    case noteTitleChanged(SyncBatchNoteTitleChangedChange)
    case noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange)
    case noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange)
    case noteBodyReconciled(SyncBatchNoteBodyReconciledChange)
}

struct SyncBatchNoteCreatedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let title: String
    let body: String
    let folderID: SyncBatchFolderID?
    let createdAt: Date
    let modifiedAt: Date
    // MYR-123 keeps rich text out of the shared positional payload so text
    // mutations cannot target stale RTF bytes.
}

struct SyncBatchNoteTitleChangedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let title: String
    let modifiedAt: Date
}

struct SyncBatchNoteBodyTextInsertedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
    let baseContentHash: String?

    init(
        noteID: SyncBatchNoteID,
        utf16Offset: Int,
        text: String,
        modifiedAt: Date,
        baseContentHash: String? = nil
    ) {
        self.noteID = noteID
        self.utf16Offset = utf16Offset
        self.text = text
        self.modifiedAt = modifiedAt
        self.baseContentHash = baseContentHash
    }
}

struct SyncBatchNoteBodyTextDeletedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String?
    let modifiedAt: Date
    let baseContentHash: String?

    init(
        noteID: SyncBatchNoteID,
        utf16Offset: Int,
        utf16Length: Int,
        expectedText: String?,
        modifiedAt: Date,
        baseContentHash: String? = nil
    ) {
        self.noteID = noteID
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.expectedText = expectedText
        self.modifiedAt = modifiedAt
        self.baseContentHash = baseContentHash
    }
}

struct SyncBatchNoteBodyReconciledChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let replacementBody: String
    let replacementContentHash: String
    let modifiedAt: Date
}

enum SyncBatchContentHash {
    static func sha256Hex(for content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncBatchApplyPreflightError: Error, Equatable {
    case mismatchedBaseContentHash(noteID: SyncBatchNoteID, expected: String, actual: String)
    case unsupportedReconciliation(noteID: SyncBatchNoteID)
}

final class SyncBatchSequenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix = "myram.sync.batchSequence"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func nextSequence(for deviceID: SyncBatchDeviceID) -> UInt64 {
        let key = "\(keyPrefix).\(deviceID.uuidString)"
        let current = UInt64(defaults.object(forKey: key) as? Int ?? 0)
        let next = current + 1
        defaults.set(Int(next), forKey: key)
        return next
    }
}

enum CanonicalBatchOrder: Codable, Equatable, Comparable, Sendable {
    case legacy(createdAt: Date, batchID: SyncBatchID)
    case sequenced(UInt64)

    private var sortKey: SortKey {
        switch self {
        case .legacy(let createdAt, let batchID):
            SortKey(kind: 0, legacyCreatedAt: createdAt, sequence: nil, batchID: batchID)
        case .sequenced(let sequence):
            SortKey(kind: 1, legacyCreatedAt: nil, sequence: sequence, batchID: nil)
        }
    }

    static func < (lhs: CanonicalBatchOrder, rhs: CanonicalBatchOrder) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    private struct SortKey: Comparable {
        let kind: Int
        let legacyCreatedAt: Date?
        let sequence: UInt64?
        let batchID: UUID?

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            switch (lhs.legacyCreatedAt, rhs.legacyCreatedAt) {
            case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
                return lhsDate < rhsDate
            default:
                break
            }
            switch (lhs.sequence, rhs.sequence) {
            case (.some(let lhsSequence), .some(let rhsSequence)) where lhsSequence != rhsSequence:
                return lhsSequence < rhsSequence
            default:
                break
            }
            switch (lhs.batchID, rhs.batchID) {
            case (.some(let lhsID), .some(let rhsID)):
                return lhsID.uuidString < rhsID.uuidString
            default:
                return false
            }
        }
    }
}

struct SyncBatchReplayKey: Codable, Equatable, Comparable, Sendable {
    let modifiedAt: Date
    let originDeviceID: SyncBatchDeviceID
    let batchOrder: CanonicalBatchOrder
    let stableBatchID: SyncBatchID
    let operationIndex: Int

    init(batch: SyncBatch, change: SyncBatchChange, operationIndex: Int) {
        self.modifiedAt = change.modifiedAtForReplayOrdering
        self.originDeviceID = batch.originDeviceID
        self.batchOrder = batch.canonicalBatchOrder
        self.stableBatchID = batch.id
        self.operationIndex = operationIndex
    }

    static func < (lhs: SyncBatchReplayKey, rhs: SyncBatchReplayKey) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        if lhs.originDeviceID != rhs.originDeviceID {
            return lhs.originDeviceID.uuidString < rhs.originDeviceID.uuidString
        }
        if lhs.batchOrder != rhs.batchOrder { return lhs.batchOrder < rhs.batchOrder }
        if lhs.stableBatchID != rhs.stableBatchID {
            return lhs.stableBatchID.uuidString < rhs.stableBatchID.uuidString
        }
        return lhs.operationIndex < rhs.operationIndex
    }
}

extension SyncBatch {
    var canonicalBatchOrder: CanonicalBatchOrder {
        if let batchSequence {
            return .sequenced(batchSequence)
        }
        return .legacy(createdAt: createdAt, batchID: id)
    }
}

extension SyncBatchChange {
    var modifiedAtForReplayOrdering: Date {
        switch self {
        case .noteCreated(let change):
            change.modifiedAt
        case .noteTitleChanged(let change):
            change.modifiedAt
        case .noteBodyTextInserted(let change):
            change.modifiedAt
        case .noteBodyTextDeleted(let change):
            change.modifiedAt
        case .noteBodyReconciled(let change):
            change.modifiedAt
        }
    }
}
