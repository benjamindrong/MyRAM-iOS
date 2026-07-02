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

enum SyncBatchBodyHashCapability {
    static let defaultEnabled = false
}

enum SyncBatchSequenceReservation: Equatable {
    case reserved(UInt64)
    case sequenceLess(SequenceIssue)

    enum SequenceIssue: Equatable {
        case transientFailure
        case confirmedCorruption
        case alreadyLatched
    }
}

final class SyncBatchSequenceStore: @unchecked Sendable {
    private struct Counter: Codable {
        let lastReserved: UInt64
    }

    private struct Latch: Codable {
        let deviceID: SyncBatchDeviceID
        let createdAt: Date
    }

    enum Fault: Equatable {
        case transientReservationFailure
        case confirmedCorruption
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let durabilitySync: (URL) throws -> Void
    private let lock = NSLock()
    private var injectedFault: Fault?

    init(
        directoryURL: URL = SyncBatchSequenceStore.defaultDirectoryURL(),
        fileManager: FileManager = .default,
        durabilitySync: @escaping (URL) throws -> Void = SyncBatchSequenceStore.synchronizeFile(at:)
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.durabilitySync = durabilitySync
    }

    func nextSequence(for deviceID: SyncBatchDeviceID) -> SyncBatchSequenceReservation {
        lock.lock()
        defer { lock.unlock() }

        if isLatched(deviceID: deviceID) {
            return .sequenceLess(.alreadyLatched)
        }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if let injectedFault {
                self.injectedFault = nil
                switch injectedFault {
                case .transientReservationFailure:
                    return .sequenceLess(.transientFailure)
                case .confirmedCorruption:
                    try writeLatch(deviceID: deviceID)
                    return .sequenceLess(.confirmedCorruption)
                }
            }

            let current = try readCounter(deviceID: deviceID)
            let next = current + 1
            try writeCounter(Counter(lastReserved: next), deviceID: deviceID)
            return .reserved(next)
        } catch let error as CounterReadError {
            switch error {
            case .missing:
                do {
                    try writeCounter(Counter(lastReserved: 1), deviceID: deviceID)
                    return .reserved(1)
                } catch {
                    return .sequenceLess(.transientFailure)
                }
            case .corrupt:
                do {
                    try writeLatch(deviceID: deviceID)
                } catch {
                    return .sequenceLess(.transientFailure)
                }
                return .sequenceLess(.confirmedCorruption)
            }
        } catch {
            return .sequenceLess(.transientFailure)
        }
    }

    func injectFaultForNextReservation(_ fault: Fault) {
        lock.lock()
        injectedFault = fault
        lock.unlock()
    }

    private func readCounter(deviceID: SyncBatchDeviceID) throws -> UInt64 {
        let url = counterURL(for: deviceID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CounterReadError.missing
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Counter.self, from: data).lastReserved
        } catch {
            throw CounterReadError.corrupt
        }
    }

    private func writeCounter(_ counter: Counter, deviceID: SyncBatchDeviceID) throws {
        let data = try JSONEncoder().encode(counter)
        let url = counterURL(for: deviceID)
        try data.write(to: url, options: .atomic)
        try durabilitySync(url)
    }

    private func writeLatch(deviceID: SyncBatchDeviceID) throws {
        let data = try JSONEncoder().encode(Latch(deviceID: deviceID, createdAt: .now))
        let url = latchURL(for: deviceID)
        try data.write(to: url, options: .atomic)
        try durabilitySync(url)
    }

    private func isLatched(deviceID: SyncBatchDeviceID) -> Bool {
        let url = latchURL(for: deviceID)
        guard let data = try? Data(contentsOf: url),
              let latch = try? JSONDecoder().decode(Latch.self, from: data) else {
            return false
        }
        return latch.deviceID == deviceID
    }

    private func counterURL(for deviceID: SyncBatchDeviceID) -> URL {
        directoryURL.appendingPathComponent("\(deviceID.uuidString)-counter.json")
    }

    private func latchURL(for deviceID: SyncBatchDeviceID) -> URL {
        directoryURL.appendingPathComponent("\(deviceID.uuidString)-sequence-less.json")
    }

    private static func defaultDirectoryURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("sync-batch-sequences", isDirectory: true)
    }

    private static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        try handle.synchronize()
        try handle.close()
    }

    private enum CounterReadError: Error {
        case missing
        case corrupt
    }
}

final class SyncBatchHashCache {
    typealias HashFunction = (String) -> String

    private let hash: HashFunction
    private var bodiesByNoteID: [SyncBatchNoteID: String] = [:]
    private var hashesByNoteID: [SyncBatchNoteID: String] = [:]

    init(hash: @escaping HashFunction = SyncBatchContentHash.sha256Hex(for:)) {
        self.hash = hash
    }

    func hashForBody(_ body: String, noteID: SyncBatchNoteID) -> String {
        if bodiesByNoteID[noteID] == body, let cachedHash = hashesByNoteID[noteID] {
            return cachedHash
        }

        let computedHash = hash(body)
        bodiesByNoteID[noteID] = body
        hashesByNoteID[noteID] = computedHash
        return computedHash
    }
}

struct SyncBatchPreflight {
    typealias BodyProvider = (SyncBatchNoteID) throws -> String?

    let bodyHashCapabilityEnabled: Bool
    let hashCache: SyncBatchHashCache

    init(bodyHashCapabilityEnabled: Bool, hashCache: SyncBatchHashCache = SyncBatchHashCache()) {
        self.bodyHashCapabilityEnabled = bodyHashCapabilityEnabled
        self.hashCache = hashCache
    }

    func validate(batch: SyncBatch, bodyProvider: BodyProvider) throws {
        var workingBodies: [SyncBatchNoteID: String] = [:]
        var missingNotes: Set<SyncBatchNoteID> = []

        for change in batch.changes {
            switch change {
            case .noteCreated(let change):
                if let existingBody = try bodyProvider(change.noteID) {
                    workingBodies[change.noteID] = existingBody
                } else {
                    workingBodies[change.noteID] = change.body
                    missingNotes.remove(change.noteID)
                }

            case .noteTitleChanged:
                continue

            case .noteBodyTextInserted(let change):
                guard var body = try workingBody(
                    noteID: change.noteID,
                    workingBodies: &workingBodies,
                    missingNotes: &missingNotes,
                    bodyProvider: bodyProvider
                ) else { continue }

                try validateBaseHash(change.baseContentHash, noteID: change.noteID, body: body)
                guard !change.text.isEmpty else { continue }
                let clampedOffset = body.syncBatchClampedUTF16Offset(change.utf16Offset)
                let insertionOffset = body.syncBatchSafeInsertionOffset(fallingForwardFrom: clampedOffset)
                body = body.syncBatchInserting(change.text, atUTF16Offset: insertionOffset)
                workingBodies[change.noteID] = body

            case .noteBodyTextDeleted(let change):
                guard var body = try workingBody(
                    noteID: change.noteID,
                    workingBodies: &workingBodies,
                    missingNotes: &missingNotes,
                    bodyProvider: bodyProvider
                ) else { continue }

                guard change.utf16Length > 0,
                      let range = body.syncBatchSafeUTF16Range(
                        location: change.utf16Offset,
                        length: change.utf16Length
                      ) else {
                    continue
                }

                try validateBaseHash(change.baseContentHash, noteID: change.noteID, body: body)
                let targetText = (body as NSString).substring(with: range)
                if let expectedText = change.expectedText, targetText != expectedText {
                    continue
                }

                body = (body as NSString).replacingCharacters(in: range, with: "")
                workingBodies[change.noteID] = body

            case .noteBodyReconciled(let change):
                throw SyncBatchApplyPreflightError.unsupportedReconciliation(noteID: change.noteID)
            }
        }
    }

    private func workingBody(
        noteID: SyncBatchNoteID,
        workingBodies: inout [SyncBatchNoteID: String],
        missingNotes: inout Set<SyncBatchNoteID>,
        bodyProvider: BodyProvider
    ) throws -> String? {
        if let body = workingBodies[noteID] {
            return body
        }
        if missingNotes.contains(noteID) {
            return nil
        }
        guard let body = try bodyProvider(noteID) else {
            missingNotes.insert(noteID)
            return nil
        }
        workingBodies[noteID] = body
        return body
    }

    private func validateBaseHash(_ expectedHash: String?, noteID: SyncBatchNoteID, body: String) throws {
        guard bodyHashCapabilityEnabled, let expectedHash else { return }

        let actualHash = hashCache.hashForBody(body, noteID: noteID)
        guard actualHash == expectedHash else {
            throw SyncBatchApplyPreflightError.mismatchedBaseContentHash(
                noteID: noteID,
                expected: expectedHash,
                actual: actualHash
            )
        }
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
