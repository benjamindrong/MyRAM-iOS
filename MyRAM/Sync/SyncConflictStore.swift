import CryptoKit
import Foundation
import NearbySyncCore

enum SyncConflictEntityType: String, Codable, Sendable {
    case note
    case folder
    case pinnedThought
}

enum SyncConflictField: String, Codable, Sendable {
    case noteTitle
    case noteContent
    case folderTitle
    case pinnedText
}

struct SyncConflictVersion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let noteID: UUID?
    let field: SyncConflictField
    let localText: String
    let remoteText: String
    let remoteRichTextContentData: Data?
    let remoteModifiedAt: Date
    let preservedAt: Date
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        entityType: SyncConflictEntityType,
        entityID: UUID,
        noteID: UUID?,
        field: SyncConflictField,
        localText: String,
        remoteText: String,
        remoteRichTextContentData: Data? = nil,
        remoteModifiedAt: Date,
        preservedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.noteID = noteID
        self.field = field
        self.localText = localText
        self.remoteText = remoteText
        self.remoteRichTextContentData = remoteRichTextContentData
        self.remoteModifiedAt = remoteModifiedAt
        self.preservedAt = preservedAt
        self.expiresAt = expiresAt
    }
}

struct SyncRemoteTextBaseline: Codable, Equatable {
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let field: SyncConflictField
    let text: String
    let richTextContentData: Data?
    let modifiedAt: Date
    let originDeviceID: String?
}

protocol SyncConflictStoring: AnyObject {
    func activeConflicts(now: Date) -> [SyncConflictVersion]
    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion]
    func removeConflict(id: UUID) -> [SyncConflictVersion]
    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion]
    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date
    ) -> Bool
    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict?
    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline?
    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline)
    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?)
    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    )
    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?)
}

extension SyncConflictStoring {
    func activeConflicts() -> [SyncConflictVersion] {
        activeConflicts(now: Date())
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> Bool {
        hasActiveConflict(entityType: entityType, entityID: entityID, field: field, now: Date())
    }
}

private protocol SyncConflictLegacyInspecting: AnyObject {
    func legacyActiveConflicts(now: Date) -> [SyncConflictVersion]
}

struct LegacyIncomingBufferedEffects: Equatable {
    var preservedConflicts: [SyncConflictVersion] = []
    var removedConflictIDs: [UUID] = []
    var removedResolvedConflicts: [SyncConflictVersion] = []
    var remoteBaselines: [SyncRemoteTextBaseline] = []
    var lifecycleResolutions: [SyncConflictVersion] = []
}

final class BufferedSyncConflictStore: SyncConflictStoring {
    private struct ConflictKey: Hashable {
        let entityType: SyncConflictEntityType
        let entityID: UUID
        let field: SyncConflictField
    }

    private let base: SyncConflictStoring
    private var bufferedConflicts: [SyncConflictVersion] = []
    private var preservedEffectConflicts: [SyncConflictVersion] = []
    private var removedConflictIDs: [UUID] = []
    private var removedResolvedConflicts: [SyncConflictVersion] = []
    private var queuedConflictsByKey: [ConflictKey: SyncTextQueuedConflict] = [:]
    private var baselinesByKey: [ConflictKey: SyncRemoteTextBaseline] = [:]
    private var lifecycleResolutionsByID: [UUID: SyncConflictVersion] = [:]

    init(base: SyncConflictStoring) {
        self.base = base
    }

    var effects: LegacyIncomingBufferedEffects {
        LegacyIncomingBufferedEffects(
            preservedConflicts: preservedEffectConflicts,
            removedConflictIDs: removedConflictIDs,
            removedResolvedConflicts: removedResolvedConflicts,
            remoteBaselines: baselinesByKey.values.sorted {
                if $0.entityType.rawValue != $1.entityType.rawValue {
                    return $0.entityType.rawValue < $1.entityType.rawValue
                }
                if $0.entityID.uuidString != $1.entityID.uuidString {
                    return $0.entityID.uuidString < $1.entityID.uuidString
                }
                return $0.field.rawValue < $1.field.rawValue
            },
            lifecycleResolutions: lifecycleResolutionsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    func stageRemoteLifecycleResolution(_ conflict: SyncConflictVersion) throws {
        guard conflict.id.isLifecycleConflictID,
              conflict.entityType == .note,
              conflict.entityID == conflict.noteID,
              conflict.field == .noteTitle || conflict.field == .noteContent else {
            throw SyncLifecycleConflictStoreError.invalidDeferredResolution
        }
        if let existing = lifecycleResolutionsByID[conflict.id],
           !SyncConflictStore.lifecycleResolutionSemanticallyMatches(existing, conflict) {
            throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
        }
        lifecycleResolutionsByID[conflict.id] = conflict
    }

    func activeConflicts(now: Date) -> [SyncConflictVersion] {
        var conflicts = base.activeConflicts(now: now)
            .filter { !removedConflictIDs.contains($0.id) }
            .filter { conflict in
                conflict.id.isLifecycleConflictID || !removedResolvedConflicts.contains {
                    $0.entityType == conflict.entityType
                        && $0.entityID == conflict.entityID
                        && $0.field == conflict.field
                }
            }
        for conflict in bufferedConflicts where !conflicts.contains(where: { $0.id == conflict.id }) {
            conflicts.append(conflict)
        }
        return conflicts.sorted(by: SyncConflictStore.conflictDisplayOrder)
    }

    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        let legacyConflicts = legacyActiveConflicts(now: Date())
        if legacyConflicts.contains(where: {
            SyncTextConflictStore.isExactRemoteMatch($0.syncTextConflict, conflict.syncTextConflict)
        }) {
            return activeConflicts()
        }
        preservedEffectConflicts.append(conflict)
        if legacyConflicts.contains(where: { sameLogicalConflict($0, conflict) }) {
            queuedConflictsByKey[ConflictKey(
                entityType: conflict.entityType,
                entityID: conflict.entityID,
                field: conflict.field
            )] = SyncTextQueuedConflict(conflict: conflict.syncTextConflict)
        } else {
            bufferedConflicts.append(conflict)
        }
        return activeConflicts()
    }

    func removeConflict(id: UUID) -> [SyncConflictVersion] {
        guard !id.isLifecycleConflictID else { return activeConflicts() }
        bufferedConflicts.removeAll { $0.id == id }
        if !removedConflictIDs.contains(id) {
            removedConflictIDs.append(id)
        }
        return activeConflicts()
    }

    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        guard !conflict.id.isLifecycleConflictID else { return activeConflicts() }
        bufferedConflicts.removeAll { sameLogicalConflict($0, conflict) }
        removedResolvedConflicts.append(conflict)
        return activeConflicts()
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date
    ) -> Bool {
        activeConflicts(now: now).contains {
            $0.entityType == entityType
                && $0.entityID == entityID
                && $0.field == field
        }
    }

    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict? {
        queuedConflictsByKey[ConflictKey(entityType: entityType, entityID: entityID, field: field)]
            ?? base.queuedConflict(entityType: entityType, entityID: entityID, field: field)
    }

    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline? {
        baselinesByKey[ConflictKey(entityType: entityType, entityID: entityID, field: field)]
            ?? base.remoteBaseline(entityType: entityType, entityID: entityID, field: field)
    }

    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline) {
        baselinesByKey[ConflictKey(
            entityType: baseline.entityType,
            entityID: baseline.entityID,
            field: baseline.field
        )] = baseline
    }

    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .note,
            entityID: noteID,
            field: .noteTitle,
            text: title,
            richTextContentData: nil,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    ) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .note,
            entityID: noteID,
            field: .noteContent,
            text: content,
            richTextContentData: richTextContentData,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .pinnedThought,
            entityID: thoughtID,
            field: .pinnedText,
            text: text,
            richTextContentData: nil,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    private func legacyActiveConflicts(now: Date) -> [SyncConflictVersion] {
        var conflicts: [SyncConflictVersion]
        if let legacyInspector = base as? SyncConflictLegacyInspecting {
            conflicts = legacyInspector.legacyActiveConflicts(now: now)
        } else {
            conflicts = base.activeConflicts(now: now).filter { !$0.id.isLifecycleConflictID }
        }
        conflicts = conflicts
            .filter { !removedConflictIDs.contains($0.id) }
            .filter { conflict in
                !removedResolvedConflicts.contains {
                    $0.entityType == conflict.entityType
                        && $0.entityID == conflict.entityID
                        && $0.field == conflict.field
                }
            }
        for conflict in bufferedConflicts where !conflicts.contains(where: { $0.id == conflict.id }) {
            conflicts.append(conflict)
        }
        return conflicts
    }

    private func sameLogicalConflict(_ lhs: SyncConflictVersion, _ rhs: SyncConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.field == rhs.field
    }
}

enum SyncConflictBaselineSnapshotState: Equatable {
    case absent
    case present(Data)
}

enum SyncConflictLifecycleSnapshotState: Equatable {
    case absent
    case present(Data)
}

enum SyncConflictStoreSnapshotError: Error, Equatable {
    case baselineCaptureFailed(path: String)
    case baselineRestoreFailed(path: String)
    case lifecycleCaptureFailed(path: String)
    case lifecycleRestoreFailed(path: String)
}

struct SyncConflictStoreSnapshot {
    let textConflicts: SyncTextConflictStoreSnapshot
    let baselines: SyncConflictBaselineSnapshotState
    let lifecycle: SyncConflictLifecycleSnapshotState
}

extension SyncRemoteTextBaseline {
    var syncTextBaseline: SyncTextTrackedBaseline {
        SyncTextTrackedBaseline(
            text: text,
            data: richTextContentData,
            originDeviceID: originDeviceID
        )
    }
}

enum SyncLifecycleConflictReceiptState: String, Codable, Equatable, Sendable {
    case preparing
    case visible
    case resolved
    case expired
}

struct SyncLifecycleSourceIncorporationIdentity: Codable, Equatable, Sendable {
    let batchID: UUID
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let committedResultDigest: String
    let committedResultDigestFormatVersion: Int

    init(_ identity: SyncConvergencePersistedIncorporationIdentity) {
        batchID = identity.batchID
        canonicalPayloadDigest = identity.canonicalPayloadDigest
        canonicalPayloadDigestFormatVersion = identity.canonicalPayloadDigestFormatVersion
        committedResultDigest = identity.committedResultDigest
        committedResultDigestFormatVersion = identity.committedResultDigestFormatVersion
    }

    func matches(_ identity: SyncConvergencePersistedIncorporationIdentity) -> Bool {
        self == SyncLifecycleSourceIncorporationIdentity(identity)
    }
}

struct SyncLifecycleOptionalDataFingerprint: Codable, Equatable, Sendable {
    let isPresent: Bool
    let sha256Hex: String?

    static func make(_ data: Data?) -> Self {
        guard let data else { return Self(isPresent: false, sha256Hex: nil) }
        return Self(isPresent: true, sha256Hex: SyncLifecycleConflictIdentityV1.sha256Hex(data))
    }
}

struct SyncLifecycleConflictIdentityV1: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 1
    static let semanticDomain = "myram.lifecycle-conflict.identity.v1"

    let formatVersion: Int
    let domain: String
    let sourceBatchID: UUID
    let canonicalPayloadDigest: String
    let canonicalPayloadDigestFormatVersion: Int
    let lifecycleOperationIdentity: OperationIdentityPayload
    let noteID: UUID
    let field: SyncConflictField
    let localTextSHA256: String
    let localDataFingerprint: SyncLifecycleOptionalDataFingerprint
    let incomingTextSHA256: String
    let incomingDataFingerprint: SyncLifecycleOptionalDataFingerprint

    init(
        sourceBatchID: UUID,
        canonicalPayloadDigest: String,
        canonicalPayloadDigestFormatVersion: Int,
        lifecycleOperationIdentity: OperationIdentityPayload,
        noteID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        incomingText: String,
        incomingData: Data?
    ) {
        formatVersion = Self.supportedFormatVersion
        domain = Self.semanticDomain
        self.sourceBatchID = sourceBatchID
        self.canonicalPayloadDigest = canonicalPayloadDigest
        self.canonicalPayloadDigestFormatVersion = canonicalPayloadDigestFormatVersion
        self.lifecycleOperationIdentity = lifecycleOperationIdentity
        self.noteID = noteID
        self.field = field
        localTextSHA256 = Self.sha256Hex(Data(localText.utf8))
        localDataFingerprint = .make(localData)
        incomingTextSHA256 = Self.sha256Hex(Data(incomingText.utf8))
        incomingDataFingerprint = .make(incomingData)
    }

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion,
              domain == Self.semanticDomain,
              UUID(uuidString: sourceBatchID.uuidString) != nil,
              canonicalPayloadDigest.count == 64,
              canonicalPayloadDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              canonicalPayloadDigestFormatVersion > 0,
              field == .noteTitle || field == .noteContent,
              localTextSHA256.count == 64,
              incomingTextSHA256.count == 64,
              localDataFingerprint.isPresent == (localDataFingerprint.sha256Hex != nil),
              incomingDataFingerprint.isPresent == (incomingDataFingerprint.sha256Hex != nil)
        else {
            throw SyncLifecycleConflictStoreError.contradictoryIdentity
        }
        try lifecycleOperationIdentity.validate()
    }

    func deterministicUUID(domain: String) throws -> UUID {
        try validate()
        struct DomainSeparatedIdentity: Codable {
            let domain: String
            let identity: SyncLifecycleConflictIdentityV1
        }
        let bytes = Array(SHA256.hash(data: try SyncConvergenceStableEncoding.encode(
            DomainSeparatedIdentity(domain: domain, identity: self)
        )))
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        let hex = uuidBytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value), uuid.isLifecycleConflictID else {
            throw SyncLifecycleConflictStoreError.contradictoryIdentity
        }
        return uuid
    }

    fileprivate static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SyncLifecycleConflictIntent: Codable, Equatable, Sendable {
    static let conflictIDDomain = "myram.lifecycle-conflict.id.v1"
    static let materializationIDDomain = "myram.lifecycle-conflict.materialization.v1"

    let sourceIdentity: SyncLifecycleSourceIncorporationIdentity
    let identity: SyncLifecycleConflictIdentityV1
    let materializationID: UUID
    let conflictID: UUID
    let localText: String
    let localData: Data?
    let incomingText: String
    let incomingData: Data?
    let incomingModifiedAt: Date
    let preservedAt: Date
    let expiresAt: Date

    init(
        sourceIdentity: SyncLifecycleSourceIncorporationIdentity,
        lifecycleOperationIdentity: OperationIdentityPayload,
        noteID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        incomingText: String,
        incomingData: Data?,
        incomingModifiedAt: Date,
        preservedAt: Date,
        expiresAt: Date
    ) throws {
        self.sourceIdentity = sourceIdentity
        identity = SyncLifecycleConflictIdentityV1(
            sourceBatchID: sourceIdentity.batchID,
            canonicalPayloadDigest: sourceIdentity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: sourceIdentity.canonicalPayloadDigestFormatVersion,
            lifecycleOperationIdentity: lifecycleOperationIdentity,
            noteID: noteID,
            field: field,
            localText: localText,
            localData: localData,
            incomingText: incomingText,
            incomingData: incomingData
        )
        materializationID = try identity.deterministicUUID(domain: Self.materializationIDDomain)
        conflictID = try identity.deterministicUUID(domain: Self.conflictIDDomain)
        self.localText = localText
        self.localData = localData
        self.incomingText = incomingText
        self.incomingData = incomingData
        self.incomingModifiedAt = incomingModifiedAt
        self.preservedAt = preservedAt
        self.expiresAt = expiresAt
        try validate()
    }

    var conflictVersion: SyncConflictVersion {
        SyncConflictVersion(
            id: conflictID,
            entityType: .note,
            entityID: identity.noteID,
            noteID: identity.noteID,
            field: identity.field,
            localText: localText,
            remoteText: incomingText,
            remoteRichTextContentData: incomingData,
            remoteModifiedAt: incomingModifiedAt,
            preservedAt: preservedAt,
            expiresAt: expiresAt
        )
    }

    func validate() throws {
        try identity.validate()
        let recomputedIdentity = SyncLifecycleConflictIdentityV1(
            sourceBatchID: sourceIdentity.batchID,
            canonicalPayloadDigest: sourceIdentity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: sourceIdentity.canonicalPayloadDigestFormatVersion,
            lifecycleOperationIdentity: identity.lifecycleOperationIdentity,
            noteID: identity.noteID,
            field: identity.field,
            localText: localText,
            localData: localData,
            incomingText: incomingText,
            incomingData: incomingData
        )
        guard recomputedIdentity == identity,
              try identity.deterministicUUID(domain: Self.materializationIDDomain) == materializationID,
              try identity.deterministicUUID(domain: Self.conflictIDDomain) == conflictID,
              materializationID.isLifecycleConflictID,
              conflictID.isLifecycleConflictID,
              preservedAt <= expiresAt else {
            throw SyncLifecycleConflictStoreError.contradictoryIdentity
        }
    }
}

struct SyncLifecycleConflictEntry: Codable, Equatable, Sendable {
    let intent: SyncLifecycleConflictIntent
    var receiptState: SyncLifecycleConflictReceiptState
    var conflict: SyncConflictVersion?
    var publicationAuthorized: Bool
}

struct SyncDeferredRemoteLifecycleResolution: Codable, Equatable, Sendable {
    let conflict: SyncConflictVersion
    let receivedAt: Date

    func validate() throws {
        guard conflict.id.isLifecycleConflictID,
              conflict.entityType == .note,
              conflict.noteID == conflict.entityID,
              conflict.field == .noteTitle || conflict.field == .noteContent else {
            throw SyncLifecycleConflictStoreError.invalidDeferredResolution
        }
    }
}

private struct SyncLifecycleConflictPersistenceEnvelope: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 1

    let formatVersion: Int
    var entries: [SyncLifecycleConflictEntry]
    var deferredRemoteResolutions: [SyncDeferredRemoteLifecycleResolution]

    static let empty = Self(formatVersion: supportedFormatVersion, entries: [], deferredRemoteResolutions: [])

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw SyncLifecycleConflictStoreError.unsupportedPersistenceVersion
        }
        var conflictIDs: Set<UUID> = []
        var materializationIDs: Set<UUID> = []
        for entry in entries {
            try entry.intent.validate()
            guard conflictIDs.insert(entry.intent.conflictID).inserted,
                  materializationIDs.insert(entry.intent.materializationID).inserted else {
                throw SyncLifecycleConflictStoreError.contradictoryIdentity
            }
            switch entry.receiptState {
            case .preparing:
                guard !entry.publicationAuthorized,
                      entry.conflict == nil || entry.conflict == entry.intent.conflictVersion else {
                    throw SyncLifecycleConflictStoreError.contradictoryReceipt
                }
            case .visible:
                guard entry.conflict == entry.intent.conflictVersion else {
                    throw SyncLifecycleConflictStoreError.contradictoryReceipt
                }
            case .resolved, .expired:
                guard entry.conflict == nil, !entry.publicationAuthorized else {
                    throw SyncLifecycleConflictStoreError.contradictoryReceipt
                }
            }
        }
        var markerIDs: Set<UUID> = []
        for marker in deferredRemoteResolutions {
            try marker.validate()
            guard markerIDs.insert(marker.conflict.id).inserted else {
                throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
            }
        }
    }
}

enum SyncLifecycleConflictStoreError: Error, Equatable {
    case unsupportedPersistenceVersion
    case persistenceUnavailable
    case contradictoryIdentity
    case contradictoryReceipt
    case contradictoryDeferredResolution
    case invalidDeferredResolution
    case missingLifecycleConflict
    case baselineVerificationFailed
}

final class SyncConflictStore: SyncConflictStoring, SyncConflictLegacyInspecting {
    struct FileIO {
        var fileExists: (String) -> Bool
        var readData: (URL) throws -> Data
        var createDirectory: (URL) throws -> Void
        var writeData: (Data, URL) throws -> Void
        var removeItem: (URL) throws -> Void

        static let live = FileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            createDirectory: {
                try FileManager.default.createDirectory(
                    at: $0,
                    withIntermediateDirectories: true
                )
            },
            writeData: { data, url in try data.write(to: url, options: [.atomic]) },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
    }

    static let retention = SyncTextConflictPolicy.retention

    private let fileURL: URL
    private let textConflictStore: SyncTextConflictStore
    private let fileIO: FileIO
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init(fileURL: URL = SyncConflictStore.defaultFileURL()) {
        self.init(fileURL: fileURL, fileIO: .live, textFileIO: .live)
    }

    init(
        fileURL: URL = SyncConflictStore.defaultFileURL(),
        fileIO: FileIO,
        textFileIO: SyncTextConflictStore.FileIO = .live
    ) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        textConflictStore = SyncTextConflictStore(fileURL: fileURL, fileIO: textFileIO)
        migrateLegacyConflictsIfNeeded()
    }

    func activeConflicts(now: Date = Date()) -> [SyncConflictVersion] {
        let legacy = legacyActiveConflicts(now: now)
        let lifecycle = actionableLifecycleConflicts(now: now)
        return (legacy + lifecycle).sorted(by: Self.conflictDisplayOrder)
    }

    fileprivate static func conflictDisplayOrder(_ lhs: SyncConflictVersion, _ rhs: SyncConflictVersion) -> Bool {
        if lhs.preservedAt == rhs.preservedAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.preservedAt > rhs.preservedAt
    }

    func legacyActiveConflicts(now: Date) -> [SyncConflictVersion] {
        textConflictStore.activeConflicts(now: now).compactMap(SyncConflictVersion.init)
    }

    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        guard !conflict.id.isLifecycleConflictID else { return activeConflicts() }
        _ = textConflictStore.preserve(conflict.syncTextConflict)
        return activeConflicts()
    }

    func removeConflict(id: UUID) -> [SyncConflictVersion] {
        guard !id.isLifecycleConflictID else { return activeConflicts() }
        _ = textConflictStore.removeConflict(id: id)
        return activeConflicts()
    }

    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        guard !conflict.id.isLifecycleConflictID else { return activeConflicts() }
        _ = textConflictStore.removeResolvedConflict(conflict.syncTextConflict)
        return activeConflicts()
    }

    func activeConflict(id: UUID, now: Date = Date()) -> SyncConflictVersion? {
        activeConflicts(now: now).first { $0.id == id }
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date = Date()
    ) -> Bool {
        activeConflicts(now: now).contains {
            $0.entityType == entityType && $0.entityID == entityID && $0.field == field
        }
    }

    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict? {
        textConflictStore.queuedConflict(
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue
        )
    }

    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline? {
        loadBaselines().first {
            $0.entityType == entityType
                && $0.entityID == entityID
                && $0.field == field
        }
    }

    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline) {
        var baselines = loadBaselines()
        if let index = baselines.firstIndex(where: {
            $0.entityType == baseline.entityType
                && $0.entityID == baseline.entityID
                && $0.field == baseline.field
        }) {
            baselines[index] = baseline
        } else {
            baselines.append(baseline)
        }
        saveBaselines(baselines)
    }

    func saveRemoteBaselineChecked(_ baseline: SyncRemoteTextBaseline) throws {
        try saveRemoteBaselinesChecked([baseline])
        guard try remoteBaselineChecked(
            entityType: baseline.entityType,
            entityID: baseline.entityID,
            field: baseline.field
        ) == baseline else {
            throw SyncLifecycleConflictStoreError.baselineVerificationFailed
        }
    }

    func remoteBaselineChecked(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) throws -> SyncRemoteTextBaseline? {
        try loadBaselinesChecked().first {
            $0.entityType == entityType && $0.entityID == entityID && $0.field == field
        }
    }

    func commitLegacyIncomingEffectsChecked(_ effects: LegacyIncomingBufferedEffects) throws {
        try textConflictStore.commitChecked(SyncTextConflictCommitEffects(
            preservedConflicts: effects.preservedConflicts
                .filter { !$0.id.isLifecycleConflictID }
                .map(\.syncTextConflict),
            removedConflictIDs: effects.removedConflictIDs.filter { !$0.isLifecycleConflictID },
            removedResolvedConflicts: effects.removedResolvedConflicts
                .filter { !$0.id.isLifecycleConflictID }
                .map(\.syncTextConflict)
        ))
        try saveRemoteBaselinesChecked(effects.remoteBaselines)
        for conflict in effects.lifecycleResolutions {
            if try !applyRemoteLifecycleResolutionChecked(conflict) {
                try persistDeferredRemoteLifecycleResolutionChecked(conflict)
            }
        }
    }

    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteTitle,
                text: title,
                richTextContentData: nil,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    ) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteContent,
                text: content,
                richTextContentData: richTextContentData,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: thoughtID,
                field: .pinnedText,
                text: text,
                richTextContentData: nil,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    func materializeLifecycleConflicts(
        _ intents: [SyncLifecycleConflictIntent],
        now: Date = Date()
    ) -> SyncConvergencePostCommitAdapterResult {
        do {
            var state = try loadLifecycleStateChecked()
            for intent in intents.sorted(by: { $0.conflictID.uuidString < $1.conflictID.uuidString }) {
                try intent.validate()
                if let existingIndex = state.entries.firstIndex(where: { $0.intent.conflictID == intent.conflictID }) {
                    guard state.entries[existingIndex].intent == intent else {
                        throw SyncLifecycleConflictStoreError.contradictoryIdentity
                    }
                    switch state.entries[existingIndex].receiptState {
                    case .resolved, .expired, .visible:
                        continue
                    case .preparing:
                        try finishPreparingLifecycleEntry(at: existingIndex, state: &state, now: now)
                    }
                    continue
                }
                guard !state.entries.contains(where: { $0.intent.materializationID == intent.materializationID }) else {
                    throw SyncLifecycleConflictStoreError.contradictoryIdentity
                }
                state.entries.append(SyncLifecycleConflictEntry(
                    intent: intent,
                    receiptState: .preparing,
                    conflict: nil,
                    publicationAuthorized: false
                ))
                try saveLifecycleStateChecked(state)
                guard let index = state.entries.firstIndex(where: { $0.intent.conflictID == intent.conflictID }) else {
                    throw SyncLifecycleConflictStoreError.contradictoryIdentity
                }
                try finishPreparingLifecycleEntry(at: index, state: &state, now: now)
            }
            return .verifiedComplete
        } catch {
            return .failed
        }
    }

    func authorizeLifecyclePublication(
        _ intents: [SyncLifecycleConflictIntent]
    ) -> SyncConvergencePostCommitAdapterResult {
        do {
            let expected = intents.sorted { $0.conflictID.uuidString < $1.conflictID.uuidString }
            guard let sourceIdentity = expected.first?.sourceIdentity else {
                throw SyncLifecycleConflictStoreError.contradictoryIdentity
            }
            var expectedConflictIDs: Set<UUID> = []
            var expectedMaterializationIDs: Set<UUID> = []
            for intent in expected {
                try intent.validate()
                guard intent.sourceIdentity == sourceIdentity,
                      expectedConflictIDs.insert(intent.conflictID).inserted,
                      expectedMaterializationIDs.insert(intent.materializationID).inserted else {
                    throw SyncLifecycleConflictStoreError.contradictoryIdentity
                }
            }

            var state = try loadLifecycleStateChecked()
            let sourceIndices = state.entries.indices.filter {
                state.entries[$0].intent.sourceIdentity == sourceIdentity
            }
            guard sourceIndices.count == expected.count else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }

            var matchedIndices: [Int] = []
            for intent in expected {
                guard let index = sourceIndices.first(where: {
                    state.entries[$0].intent.conflictID == intent.conflictID
                }), state.entries[index].intent == intent else {
                    throw SyncLifecycleConflictStoreError.contradictoryReceipt
                }
                try verifyLifecycleEntry(state.entries[index])
                if state.entries[index].receiptState == .preparing {
                    return .stillPending
                }
                matchedIndices.append(index)
            }

            var changed = false
            for index in matchedIndices where state.entries[index].receiptState == .visible {
                if !state.entries[index].publicationAuthorized {
                    state.entries[index].publicationAuthorized = true
                    changed = true
                }
            }
            if changed {
                try saveLifecycleStateChecked(state)
            }
            return .verifiedComplete
        } catch {
            return .failed
        }
    }

    func lifecycleConflict(id: UUID) throws -> SyncConflictVersion? {
        guard id.isLifecycleConflictID else { return nil }
        let state = try loadLifecycleStateChecked()
        guard let entry = state.entries.first(where: { $0.intent.conflictID == id }) else { return nil }
        try verifyLifecycleEntry(entry)
        return entry.conflict
    }

    func markLifecycleResolvedChecked(id: UUID) throws {
        guard id.isLifecycleConflictID else { throw SyncLifecycleConflictStoreError.missingLifecycleConflict }
        var state = try loadLifecycleStateChecked()
        guard let index = state.entries.firstIndex(where: { $0.intent.conflictID == id }) else {
            throw SyncLifecycleConflictStoreError.missingLifecycleConflict
        }
        try verifyLifecycleEntry(state.entries[index])
        if state.entries[index].receiptState == .expired {
            throw SyncLifecycleConflictStoreError.contradictoryReceipt
        }
        if state.entries[index].receiptState == .resolved { return }
        state.entries[index].receiptState = .resolved
        state.entries[index].publicationAuthorized = false
        state.entries[index].conflict = nil
        try saveLifecycleStateChecked(state)
    }

    func cleanupResolvedLifecycleConflictChecked(id: UUID) throws {
        guard id.isLifecycleConflictID else { return }
        let state = try loadLifecycleStateChecked()
        guard let entry = state.entries.first(where: { $0.intent.conflictID == id }),
              entry.receiptState == .resolved,
              entry.conflict == nil else {
            throw SyncLifecycleConflictStoreError.contradictoryReceipt
        }
    }

    func applyRemoteLifecycleResolutionChecked(_ receivedConflict: SyncConflictVersion) throws -> Bool {
        guard receivedConflict.id.isLifecycleConflictID else { return false }
        var state = try loadLifecycleStateChecked()
        guard let index = state.entries.firstIndex(where: { $0.intent.conflictID == receivedConflict.id }) else {
            return false
        }
        try verifyLifecycleEntry(state.entries[index])
        guard deferredConflict(receivedConflict, isCompatibleWith: state.entries[index].intent) else {
            throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
        }
        if state.entries[index].receiptState == .resolved || state.entries[index].receiptState == .expired {
            return true
        }
        state.entries[index].receiptState = .resolved
        state.entries[index].publicationAuthorized = false
        state.entries[index].conflict = nil
        state.deferredRemoteResolutions.removeAll { $0.conflict.id == receivedConflict.id }
        try saveLifecycleStateChecked(state)
        return true
    }

    func persistDeferredRemoteLifecycleResolutionChecked(
        _ conflict: SyncConflictVersion,
        receivedAt: Date = Date()
    ) throws {
        let marker = SyncDeferredRemoteLifecycleResolution(conflict: conflict, receivedAt: receivedAt)
        try marker.validate()
        var state = try loadLifecycleStateChecked()
        if let entry = state.entries.first(where: { $0.intent.conflictID == conflict.id }) {
            try verifyLifecycleEntry(entry)
            guard deferredConflict(conflict, isCompatibleWith: entry.intent) else {
                throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
            }
            return
        }
        if let existing = state.deferredRemoteResolutions.first(where: { $0.conflict.id == conflict.id }) {
            guard Self.lifecycleResolutionSemanticallyMatches(existing.conflict, conflict) else {
                throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
            }
            return
        }
        state.deferredRemoteResolutions.append(marker)
        try saveLifecycleStateChecked(state)
    }

    func snapshot() throws -> SyncConflictStoreSnapshot {
        SyncConflictStoreSnapshot(
            textConflicts: try textConflictStore.snapshot(),
            baselines: try baselineSnapshotState(),
            lifecycle: try lifecycleSnapshotState()
        )
    }

    func restore(_ snapshot: SyncConflictStoreSnapshot) throws {
        try textConflictStore.restore(snapshot.textConflicts)
        do {
            switch snapshot.baselines {
            case .absent:
                if fileIO.fileExists(baselineFileURL.path) {
                    try fileIO.removeItem(baselineFileURL)
                }
            case .present(let baselinesData):
                try fileIO.createDirectory(baselineFileURL.deletingLastPathComponent())
                try fileIO.writeData(baselinesData, baselineFileURL)
            }
        } catch {
            throw SyncConflictStoreSnapshotError.baselineRestoreFailed(path: baselineFileURL.path)
        }
        do {
            switch snapshot.lifecycle {
            case .absent:
                if fileIO.fileExists(lifecycleFileURL.path) {
                    try fileIO.removeItem(lifecycleFileURL)
                }
            case .present(let lifecycleData):
                try fileIO.createDirectory(lifecycleFileURL.deletingLastPathComponent())
                try fileIO.writeData(lifecycleData, lifecycleFileURL)
            }
        } catch {
            throw SyncConflictStoreSnapshotError.lifecycleRestoreFailed(path: lifecycleFileURL.path)
        }
    }

    private func actionableLifecycleConflicts(now: Date) -> [SyncConflictVersion] {
        do {
            var state = try loadLifecycleStateChecked()
            for index in state.entries.indices where
                state.entries[index].receiptState == .visible &&
                state.entries[index].publicationAuthorized &&
                state.entries[index].intent.expiresAt <= now {
                var candidate = state
                candidate.entries[index].receiptState = .expired
                candidate.entries[index].publicationAuthorized = false
                candidate.entries[index].conflict = nil
                do {
                    try saveLifecycleStateChecked(candidate)
                    state = candidate
                } catch {
                    // Retention cleanup may never make a visible conflict disappear
                    // unless the terminal receipt transition is durable.
                }
            }
            return try state.entries.compactMap { entry in
                try verifyLifecycleEntry(entry)
                guard entry.receiptState == .visible,
                      entry.publicationAuthorized,
                      let conflict = entry.conflict else { return nil }
                return conflict
            }
        } catch {
            // Corrupt or contradictory lifecycle state is fail-closed and never
            // reclassified into the legacy namespace.
            return []
        }
    }

    private func finishPreparingLifecycleEntry(
        at index: Int,
        state: inout SyncLifecycleConflictPersistenceEnvelope,
        now: Date
    ) throws {
        guard state.entries.indices.contains(index), state.entries[index].receiptState == .preparing else {
            throw SyncLifecycleConflictStoreError.contradictoryReceipt
        }
        let intent = state.entries[index].intent
        if let markerIndex = state.deferredRemoteResolutions.firstIndex(where: { $0.conflict.id == intent.conflictID }) {
            let marker = state.deferredRemoteResolutions[markerIndex]
            guard deferredConflict(marker.conflict, isCompatibleWith: intent) else {
                throw SyncLifecycleConflictStoreError.contradictoryDeferredResolution
            }
            state.entries[index].receiptState = .resolved
            state.entries[index].conflict = nil
            state.entries[index].publicationAuthorized = false
            state.deferredRemoteResolutions.remove(at: markerIndex)
            try saveLifecycleStateChecked(state)
            return
        }
        if intent.expiresAt <= now {
            state.entries[index].receiptState = .expired
            state.entries[index].conflict = nil
            state.entries[index].publicationAuthorized = false
            try saveLifecycleStateChecked(state)
            return
        }
        if let existingConflict = state.entries[index].conflict {
            guard existingConflict == intent.conflictVersion else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }
        } else {
            state.entries[index].conflict = intent.conflictVersion
            try saveLifecycleStateChecked(state)
        }
        let reloaded = try loadLifecycleStateChecked()
        guard let verified = reloaded.entries.first(where: { $0.intent.conflictID == intent.conflictID }),
              verified.receiptState == .preparing,
              verified.intent == intent,
              verified.conflict == intent.conflictVersion else {
            throw SyncLifecycleConflictStoreError.contradictoryReceipt
        }
        state = reloaded
        guard let reloadedIndex = state.entries.firstIndex(where: { $0.intent.conflictID == intent.conflictID }) else {
            throw SyncLifecycleConflictStoreError.contradictoryReceipt
        }
        state.entries[reloadedIndex].receiptState = .visible
        state.entries[reloadedIndex].publicationAuthorized = false
        try saveLifecycleStateChecked(state)
    }

    private func verifyLifecycleEntry(_ entry: SyncLifecycleConflictEntry) throws {
        try entry.intent.validate()
        if let conflict = entry.conflict {
            guard conflict == entry.intent.conflictVersion else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }
        }
        switch entry.receiptState {
        case .preparing:
            guard !entry.publicationAuthorized else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }
        case .visible:
            guard entry.conflict != nil else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }
        case .resolved, .expired:
            guard entry.conflict == nil, !entry.publicationAuthorized else {
                throw SyncLifecycleConflictStoreError.contradictoryReceipt
            }
        }
    }

    private func deferredConflict(
        _ conflict: SyncConflictVersion,
        isCompatibleWith intent: SyncLifecycleConflictIntent
    ) -> Bool {
        conflict.id == intent.conflictID
            && conflict.entityType == .note
            && conflict.entityID == intent.identity.noteID
            && conflict.noteID == intent.identity.noteID
            && conflict.field == intent.identity.field
            && conflict.localText == intent.localText
            && conflict.remoteText == intent.incomingText
            && conflict.remoteRichTextContentData == intent.incomingData
            && conflict.remoteModifiedAt == intent.incomingModifiedAt
    }

    fileprivate static func lifecycleResolutionSemanticallyMatches(
        _ lhs: SyncConflictVersion,
        _ rhs: SyncConflictVersion
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.noteID == rhs.noteID
            && lhs.field == rhs.field
            && lhs.localText == rhs.localText
            && lhs.remoteText == rhs.remoteText
            && lhs.remoteRichTextContentData == rhs.remoteRichTextContentData
            && lhs.remoteModifiedAt == rhs.remoteModifiedAt
    }

    private func loadLifecycleStateChecked() throws -> SyncLifecycleConflictPersistenceEnvelope {
        guard fileIO.fileExists(lifecycleFileURL.path) else { return .empty }
        do {
            let data = try fileIO.readData(lifecycleFileURL)
            let state = try decoder.decode(SyncLifecycleConflictPersistenceEnvelope.self, from: data)
            try state.validate()
            return state
        } catch let error as SyncLifecycleConflictStoreError {
            throw error
        } catch {
            throw SyncLifecycleConflictStoreError.persistenceUnavailable
        }
    }

    private func saveLifecycleStateChecked(_ state: SyncLifecycleConflictPersistenceEnvelope) throws {
        try state.validate()
        do {
            try fileIO.createDirectory(lifecycleFileURL.deletingLastPathComponent())
            try fileIO.writeData(try encoder.encode(state), lifecycleFileURL)
            let persisted = try decoder.decode(
                SyncLifecycleConflictPersistenceEnvelope.self,
                from: fileIO.readData(lifecycleFileURL)
            )
            try persisted.validate()
            guard persisted == state else {
                throw SyncLifecycleConflictStoreError.persistenceUnavailable
            }
        } catch let error as SyncLifecycleConflictStoreError {
            throw error
        } catch {
            throw SyncLifecycleConflictStoreError.persistenceUnavailable
        }
    }

    private func lifecycleSnapshotState() throws -> SyncConflictLifecycleSnapshotState {
        guard fileIO.fileExists(lifecycleFileURL.path) else { return .absent }
        do {
            return .present(try fileIO.readData(lifecycleFileURL))
        } catch {
            throw SyncConflictStoreSnapshotError.lifecycleCaptureFailed(path: lifecycleFileURL.path)
        }
    }

    private func baselineSnapshotState() throws -> SyncConflictBaselineSnapshotState {
        guard fileIO.fileExists(baselineFileURL.path) else {
            return .absent
        }
        do {
            return .present(try fileIO.readData(baselineFileURL))
        } catch {
            throw SyncConflictStoreSnapshotError.baselineCaptureFailed(path: baselineFileURL.path)
        }
    }

    private func migrateLegacyConflictsIfNeeded() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if (try? decoder.decode([SyncTextConflictVersion].self, from: data)) != nil {
            return
        }
        guard let legacyConflicts = try? decoder.decode([SyncConflictVersion].self, from: data) else {
            return
        }
        _ = textConflictStore.replaceConflicts(legacyConflicts.map(\.syncTextConflict))
    }

    private func loadBaselines() -> [SyncRemoteTextBaseline] {
        guard let data = try? Data(contentsOf: baselineFileURL) else { return [] }
        return (try? decoder.decode([SyncRemoteTextBaseline].self, from: data)) ?? []
    }

    private func loadBaselinesChecked() throws -> [SyncRemoteTextBaseline] {
        guard fileIO.fileExists(baselineFileURL.path) else { return [] }
        let data = try fileIO.readData(baselineFileURL)
        return try decoder.decode([SyncRemoteTextBaseline].self, from: data)
    }

    private func saveRemoteBaselinesChecked(_ baselines: [SyncRemoteTextBaseline]) throws {
        guard !baselines.isEmpty else { return }
        var updatedBaselines = try loadBaselinesChecked()
        for baseline in baselines {
            if let index = updatedBaselines.firstIndex(where: {
                $0.entityType == baseline.entityType
                    && $0.entityID == baseline.entityID
                    && $0.field == baseline.field
            }) {
                updatedBaselines[index] = baseline
            } else {
                updatedBaselines.append(baseline)
            }
        }
        try fileIO.createDirectory(baselineFileURL.deletingLastPathComponent())
        try fileIO.writeData(try encoder.encode(updatedBaselines), baselineFileURL)
    }

    private func saveBaselines(_ baselines: [SyncRemoteTextBaseline]) {
        do {
            try FileManager.default.createDirectory(
                at: baselineFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(baselines)
            try data.write(to: baselineFileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist sync baselines: \(error)")
        }
    }

    private var baselineFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-remote-text-baselines.json")
    }

    private var lifecycleFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-lifecycle-conflicts.json")
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
    }
}

extension SyncConflictVersion {
    init?(_ conflict: SyncTextConflictVersion) {
        guard let entityID = UUID(uuidString: conflict.entityID),
              let entityType = SyncConflictEntityType(conflict.entityType),
              let field = SyncConflictField(rawValue: conflict.fieldID) else {
            return nil
        }
        let noteID = conflict.contextID.flatMap(UUID.init(uuidString:))
            ?? (entityType == .note ? entityID : nil)
        self.init(
            id: conflict.id,
            entityType: entityType,
            entityID: entityID,
            noteID: noteID,
            field: field,
            localText: conflict.localText,
            remoteText: conflict.remoteText,
            remoteRichTextContentData: conflict.remoteData,
            remoteModifiedAt: conflict.remoteUpdatedAt,
            preservedAt: conflict.preservedAt,
            expiresAt: conflict.expiresAt
        )
    }

    var syncTextConflict: SyncTextConflictVersion {
        SyncTextConflictVersion(
            id: id,
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue,
            contextID: noteID?.uuidString,
            localText: localText,
            remoteText: remoteText,
            remoteData: remoteRichTextContentData,
            remoteUpdatedAt: remoteModifiedAt,
            preservedAt: preservedAt,
            expiresAt: expiresAt
        )
    }
}

extension UUID {
    var isLifecycleConflictID: Bool {
        let components = uuidString.split(separator: "-")
        guard components.count == 5, let versionCharacter = components[2].first else { return false }
        return versionCharacter == "8"
    }
}

private extension SyncConflictEntityType {
    init?(_ entityType: SyncEntityType) {
        switch entityType {
        case .item:
            self = .note
        case .collection:
            self = .folder
        case .marker:
            self = .pinnedThought
        case .attachment, .conflict:
            return nil
        }
    }

    var syncEntityType: SyncEntityType {
        switch self {
        case .note:
            .item
        case .folder:
            .collection
        case .pinnedThought:
            .marker
        }
    }
}
