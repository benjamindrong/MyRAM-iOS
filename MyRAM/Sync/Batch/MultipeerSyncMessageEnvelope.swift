import Foundation
import SwiftData
import AnchoredSequenceCore

enum MultipeerSyncMessageKind: String, Codable, Equatable, Sendable {
    case legacySyncEnvelope = "myram.legacySyncEnvelope.v1"
    case batchSync = "myram.batchSync.v1"
    case batchAcknowledgement = "myram.batchAcknowledgement.v1"
    case bootstrapCapability = "myram.bootstrapCapability.v1"
    case bootstrapSnapshot = "myram.bootstrapSnapshot.v1"
    case bootstrapAcknowledgement = "myram.bootstrapAcknowledgement.v1"
}

struct SyncPeerBootstrapSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let folders: [SyncPeerBootstrapFolderSnapshot]
    let notes: [SyncPeerBootstrapNoteSnapshot]
    let historyCoverage: [SyncPeerBootstrapHistoryBatchCoverage]

    init(
        id: UUID,
        folders: [SyncPeerBootstrapFolderSnapshot],
        notes: [SyncPeerBootstrapNoteSnapshot],
        historyCoverage: [SyncPeerBootstrapHistoryBatchCoverage] = []
    ) {
        self.id = id
        self.folders = folders
        self.notes = notes
        self.historyCoverage = historyCoverage.sorted {
            $0.batchID.uuidString < $1.batchID.uuidString
        }
    }

    func attachingHistoryCoverage(for batches: [SyncBatch]) -> Self {
        let representedNoteIDs = Set(notes.map(\.id))
        return Self(
            id: id,
            folders: folders,
            notes: notes,
            historyCoverage: batches.compactMap { batch in
                let coverage = SyncPeerBootstrapHistoryBatchCoverage(batch: batch)
                guard coverage.noteIDs.isSubset(of: representedNoteIDs) else {
                    return nil
                }
                return coverage
            }
        )
    }
}

struct SyncPeerBootstrapHistoryBatchCoverage: Codable, Equatable, Sendable {
    let batchID: SyncBatchID
    let noteIDs: Set<SyncBatchNoteID>

    init(batchID: SyncBatchID, noteIDs: Set<SyncBatchNoteID>) {
        self.batchID = batchID
        self.noteIDs = noteIDs
    }

    init(batch: SyncBatch) {
        batchID = batch.id
        noteIDs = Set(batch.changes.map(\.noteID))
    }
}

struct SyncPeerBootstrapCapabilityAnnouncement: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int

    init(version: Int = Self.currentVersion) {
        self.version = version
    }
}

struct SyncPeerBootstrapFolderSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let parentFolderID: UUID?
}

struct SyncPeerBootstrapNoteSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let isPinned: Bool
    let createdAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let folderID: UUID?
    let formatVersion: Int
    let revision: UInt64
    let visibleUTF16Count: Int
    let tombstonedUTF16Count: Int
    let payloadByteCount: Int
    let statePayloadData: Data
}

struct SyncPeerBootstrapAcknowledgement: Codable, Equatable, Sendable {
    let snapshotID: UUID
    let coveredBatchIDs: Set<SyncBatchID>
    /// Exact note sequence-state baselines established while applying the snapshot.
    /// This is deliberately distinct from full snapshot coverage used to prune batches.
    /// Optional decoding preserves v1 wire compatibility; a missing value cannot
    /// authorize anchored synchronization for a nonempty snapshot.
    let coveredNoteIDs: Set<SyncBatchNoteID>?

    init(
        snapshotID: UUID,
        coveredBatchIDs: Set<SyncBatchID>,
        coveredNoteIDs: Set<SyncBatchNoteID>? = nil
    ) {
        self.snapshotID = snapshotID
        self.coveredBatchIDs = coveredBatchIDs
        self.coveredNoteIDs = coveredNoteIDs
    }
}

struct SyncPeerBootstrapApplyDisposition: Equatable, Sendable {
    let coveredBatchIDs: Set<SyncBatchID>
    /// Notes whose exact structural sequence baseline is safe for anchored replay.
    /// This does not imply that title, pin, folder, or other snapshot metadata matched.
    let coveredNoteIDs: Set<SyncBatchNoteID>
    let insertedNoteIDs: Set<UUID>
    let presentationRefreshRequired: Bool

    init(
        coveredBatchIDs: Set<SyncBatchID>,
        coveredNoteIDs: Set<SyncBatchNoteID> = [],
        insertedNoteIDs: Set<UUID>,
        presentationRefreshRequired: Bool
    ) {
        self.coveredBatchIDs = coveredBatchIDs
        self.coveredNoteIDs = coveredNoteIDs
        self.insertedNoteIDs = insertedNoteIDs
        self.presentationRefreshRequired = presentationRefreshRequired
    }
}

struct SyncPeerBootstrapPendingState: Equatable, Sendable {
    let snapshot: SyncPeerBootstrapSnapshot
    private let capturedBatchIDs: Set<SyncBatchID>
    /// IDs the frozen snapshot manifest actually represents. Bootstrap ACKs may
    /// prune only this set, never every batch that happened to be queued at capture.
    let coveredBatchIDs: Set<SyncBatchID>
    var withheldHistoricalBatchIDs: Set<SyncBatchID>
    var ordinarySyncReady: Bool {
        didSet {
            guard ordinarySyncReady else { return }
            withheldHistoricalBatchIDs = historicalBatchIDsThatRemainWithheld
        }
    }
    var retryAttempt: Int

    init(
        snapshot: SyncPeerBootstrapSnapshot,
        coveredBatchIDs capturedBatchIDs: Set<SyncBatchID>,
        withheldHistoricalBatchIDs: Set<SyncBatchID>,
        ordinarySyncReady: Bool,
        retryAttempt: Int
    ) {
        self.snapshot = snapshot
        self.capturedBatchIDs = capturedBatchIDs
        coveredBatchIDs = Set(snapshot.historyCoverage.map(\.batchID))
        self.withheldHistoricalBatchIDs = withheldHistoricalBatchIDs
        self.ordinarySyncReady = ordinarySyncReady
        self.retryAttempt = retryAttempt

        if ordinarySyncReady {
            self.withheldHistoricalBatchIDs = historicalBatchIDsThatRemainWithheld
        }
    }

    var snapshotID: UUID { snapshot.id }

    private var historicalBatchIDsThatRemainWithheld: Set<SyncBatchID> {
        let absentFromManifest = capturedBatchIDs.subtracting(coveredBatchIDs)
        // Empty batches carry no note delta. Keeping an unacknowledged empty entry
        // withheld preserves the existing no-op queue behavior without blocking an
        // existing note baseline that needs real manifested history to catch up.
        let emptyManifestBatchIDs = Set(
            snapshot.historyCoverage.compactMap { coverage in
                coverage.noteIDs.isEmpty ? coverage.batchID : nil
            }
        )
        return absentFromManifest.union(emptyManifestBatchIDs)
    }
}

enum SyncPeerBootstrapError: Error, Equatable {
    case duplicateFolderID(UUID)
    case duplicateNoteID(UUID)
    case duplicateHistoryBatchID(SyncBatchID)
    case historyReferencesMissingNote(SyncBatchNoteID)
    case missingFolder(UUID)
    case missingSequenceState(UUID)
    case invalidSequenceState(UUID)
    case noteBodyStateMismatch(UUID)
    case conflictingNoteIdentity(UUID)
    case conflictingMissingSequenceState(UUID)
    case destinationContextHasPendingChanges
    case commitVerificationFailed
    case anchoredRecoveryConflict(SyncBatchAnchoredRecoveryRecordKey)
}

@MainActor
enum SyncPeerBootstrapSnapshotPersistence {
    static func build(from context: ModelContext) throws -> SyncPeerBootstrapSnapshot {
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let notes = try context.fetch(FetchDescriptor<Note>())
        let records = try context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
        let recordsByNoteID = Dictionary(grouping: records, by: \.noteID)

        let noteSnapshots = try notes.map { note -> SyncPeerBootstrapNoteSnapshot in
            guard let matches = recordsByNoteID[note.id], matches.count == 1,
                  let record = matches.first else {
                throw SyncPeerBootstrapError.missingSequenceState(note.id)
            }
            let state: SyncTextSequenceState
            do {
                state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                    record: record,
                    noteID: note.id
                )
            } catch {
                throw SyncPeerBootstrapError.invalidSequenceState(note.id)
            }
            guard NoteSequenceStateExactText.matches(state.visibleText, note.content) else {
                throw SyncPeerBootstrapError.noteBodyStateMismatch(note.id)
            }
            return SyncPeerBootstrapNoteSnapshot(
                id: note.id,
                title: note.title,
                body: note.content,
                isPinned: note.isPinned ?? false,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                deletedAt: note.deletedAt,
                folderID: note.folder?.id,
                formatVersion: record.formatVersion,
                revision: record.revision,
                visibleUTF16Count: record.visibleUTF16Count,
                tombstonedUTF16Count: record.tombstonedUTF16Count,
                payloadByteCount: record.payloadByteCount,
                statePayloadData: record.statePayloadData
            )
        }

        return SyncPeerBootstrapSnapshot(
            id: UUID(),
            folders: folders.map {
                SyncPeerBootstrapFolderSnapshot(
                    id: $0.id,
                    name: $0.name,
                    createdAt: $0.createdAt,
                    modifiedAt: $0.modifiedAt,
                    parentFolderID: $0.parentFolder?.id
                )
            }.sorted { $0.id.uuidString < $1.id.uuidString },
            notes: noteSnapshots.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    static func apply(
        _ snapshot: SyncPeerBootstrapSnapshot,
        to context: ModelContext,
        pendingIncomingBatches: FileBackedSyncBatchQueue? = nil,
        anchoredRecoveryStore: FileBackedSyncBatchAnchoredRecoveryStore? = nil,
        saveContext: (() throws -> Void)? = nil
    ) throws -> SyncPeerBootstrapApplyDisposition {
        try validate(snapshot)
        guard !context.hasChanges else {
            throw SyncPeerBootstrapError.destinationContextHasPendingChanges
        }

        let existingFolders = try context.fetch(FetchDescriptor<Folder>())
        let existingNotes = try context.fetch(FetchDescriptor<Note>())
        let existingRecords = try context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
        var foldersByID = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id, $0) })
        let notesByID = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0) })
        let recordsByNoteID = Dictionary(grouping: existingRecords, by: \.noteID)
        var fullyCoveredNoteIDs: Set<SyncBatchNoteID> = []
        var sequenceBaselineCoveredNoteIDs: Set<SyncBatchNoteID> = []
        var insertedNoteIDs: Set<UUID> = []
        var didMutate = false

        do {
            for folderSnapshot in snapshot.folders {
                if let existing = foldersByID[folderSnapshot.id] {
                    if existing.name != folderSnapshot.name
                        || existing.createdAt != folderSnapshot.createdAt
                        || existing.modifiedAt != folderSnapshot.modifiedAt
                        || existing.parentFolder?.id != folderSnapshot.parentFolderID {
                        // Folder divergence does not invalidate unrelated note coverage.
                    }
                } else {
                    let folder = Folder(name: folderSnapshot.name)
                    folder.id = folderSnapshot.id
                    folder.createdAt = folderSnapshot.createdAt
                    folder.modifiedAt = folderSnapshot.modifiedAt
                    context.insert(folder)
                    foldersByID[folder.id] = folder
                    didMutate = true
                }
            }

            for folderSnapshot in snapshot.folders where existingFolders.allSatisfy({ $0.id != folderSnapshot.id }) {
                foldersByID[folderSnapshot.id]?.parentFolder = folderSnapshot.parentFolderID.flatMap { foldersByID[$0] }
            }

            for noteSnapshot in snapshot.notes {
                let snapshotRecord = makeRecord(from: noteSnapshot)
                if let note = notesByID[noteSnapshot.id] {
                    guard note.createdAt == noteSnapshot.createdAt else {
                        throw SyncPeerBootstrapError.conflictingNoteIdentity(noteSnapshot.id)
                    }
                    let bodyEquivalent = NoteSequenceStateExactText.matches(
                        note.content,
                        noteSnapshot.body
                    )
                    let visibleEquivalent = note.title == noteSnapshot.title
                        && bodyEquivalent
                        && (note.isPinned ?? false) == noteSnapshot.isPinned
                        && note.modifiedAt == noteSnapshot.modifiedAt
                        && note.deletedAt == noteSnapshot.deletedAt
                        && note.folder?.id == noteSnapshot.folderID
                    let records = recordsByNoteID[note.id] ?? []
                    if records.count == 1, let record = records.first {
                        let localState: SyncTextSequenceState
                        let snapshotState: SyncTextSequenceState
                        do {
                            localState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                                record: record,
                                noteID: note.id
                            )
                            snapshotState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                                record: snapshotRecord,
                                noteID: note.id
                            )
                        } catch {
                            throw SyncPeerBootstrapError.invalidSequenceState(note.id)
                        }
                        let localBodyMatchesState = NoteSequenceStateExactText.matches(
                            localState.visibleText,
                            note.content
                        )
                        let exactSequenceBaseline = recordExactlyMatches(record, noteSnapshot)
                        if localBodyMatchesState && exactSequenceBaseline {
                            sequenceBaselineCoveredNoteIDs.insert(note.id)
                        } else if localBodyMatchesState {
                            do {
                                _ = try localState.mergingRetainedLineage(with: snapshotState)
                                if let pendingIncomingBatches, let anchoredRecoveryStore {
                                    try persistBootstrapOwnership(
                                        for: note.id,
                                        peerSnapshotState: snapshotState,
                                        pendingIncomingBatches: pendingIncomingBatches,
                                        anchoredRecoveryStore: anchoredRecoveryStore
                                    )
                                }
                                let visibleBodyBeforeMerge = note.content
                                let mergeResult = try NoteSequenceStateFullBodyIntegration.mergeRetainedLineage(
                                    of: note,
                                    with: snapshotState,
                                    in: context
                                )
                                sequenceBaselineCoveredNoteIDs.insert(note.id)
                                if case .replaced = mergeResult {
                                    if !NoteSequenceStateExactText.matches(note.content, visibleBodyBeforeMerge) {
                                        note.richTextContentData = nil
                                    }
                                    note.modifiedAt = max(note.modifiedAt, noteSnapshot.modifiedAt)
                                    didMutate = true
                                }
                            } catch SyncTextSequenceMergeError.noSharedRetainedLineage {
                                // Independent histories have no safe structural union.
                            }
                        }
                        if visibleEquivalent && exactSequenceBaseline {
                            fullyCoveredNoteIDs.insert(note.id)
                        }
                    } else if records.isEmpty {
                        guard bodyEquivalent else {
                            throw SyncPeerBootstrapError.conflictingMissingSequenceState(note.id)
                        }
                        context.insert(snapshotRecord)
                        sequenceBaselineCoveredNoteIDs.insert(note.id)
                        if visibleEquivalent {
                            fullyCoveredNoteIDs.insert(note.id)
                        }
                        didMutate = true
                    } else {
                        throw SyncPeerBootstrapError.invalidSequenceState(note.id)
                    }
                } else {
                    let note = Note(
                        title: noteSnapshot.title,
                        content: noteSnapshot.body,
                        folder: noteSnapshot.folderID.flatMap { foldersByID[$0] }
                    )
                    note.id = noteSnapshot.id
                    note.isPinned = noteSnapshot.isPinned
                    note.createdAt = noteSnapshot.createdAt
                    note.modifiedAt = noteSnapshot.modifiedAt
                    note.deletedAt = noteSnapshot.deletedAt
                    context.insert(note)
                    context.insert(snapshotRecord)
                    insertedNoteIDs.insert(note.id)
                    fullyCoveredNoteIDs.insert(note.id)
                    sequenceBaselineCoveredNoteIDs.insert(note.id)
                    didMutate = true
                }
            }

            if didMutate {
                if let saveContext {
                    try saveContext()
                } else {
                    try context.save()
                }
                let committedNotes = try context.fetch(FetchDescriptor<Note>())
                let committedRecords = try context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
                let committedNoteIDs = Set(committedNotes.map(\.id))
                let committedRecordIDs = Set(committedRecords.map(\.noteID))
                guard insertedNoteIDs.isSubset(of: committedNoteIDs),
                      insertedNoteIDs.isSubset(of: committedRecordIDs) else {
                    throw SyncPeerBootstrapError.commitVerificationFailed
                }
            }
        } catch {
            context.rollback()
            throw error
        }

        return SyncPeerBootstrapApplyDisposition(
            coveredBatchIDs: Set(snapshot.historyCoverage.compactMap { coverage in
                coverage.noteIDs.isSubset(of: fullyCoveredNoteIDs)
                    ? coverage.batchID
                    : nil
            }),
            coveredNoteIDs: sequenceBaselineCoveredNoteIDs,
            insertedNoteIDs: insertedNoteIDs,
            presentationRefreshRequired: didMutate
        )
    }

    private static func persistBootstrapOwnership(
        for noteID: SyncBatchNoteID,
        peerSnapshotState: SyncTextSequenceState,
        pendingIncomingBatches: FileBackedSyncBatchQueue,
        anchoredRecoveryStore: FileBackedSyncBatchAnchoredRecoveryStore
    ) throws {
        let changes = pendingIncomingBatches.pendingBatches.flatMap(\.changes).compactMap {
            change -> SyncBatchAnchoredRecoveryChange? in
            switch change {
            case .noteBodyTextInsertedAnchored(let insertion) where insertion.noteID == noteID:
                let matchingRun = peerSnapshotState.runs.first {
                    $0.operationID == insertion.payload.operationID
                }
                guard let matchingRun,
                      matchingRun.origin.leftElementID == insertion.payload.anchor.leftElementID,
                      matchingRun.origin.rightElementID == insertion.payload.anchor.rightElementID,
                      matchingRun.text == insertion.text else { return nil }
                return .insertion(insertion)
            case .noteBodyTextDeletedAnchored(let deletion) where deletion.noteID == noteID:
                guard let replayed = try? SyncBatchAnchoredDeleteReplay.applying(
                    deletion,
                    to: peerSnapshotState
                ).sequenceState,
                      replayed == peerSnapshotState else { return nil }
                return .deletion(deletion)
            default:
                return nil
            }
        }

        let snapshot = anchoredRecoveryStore.snapshot()
        guard snapshot.health.permitsOrdinaryMutation else {
            throw SyncBatchAnchoredRecoveryStoreError.unhealthyPersistence
        }
        var transitions: [SyncBatchAnchoredRecoveryStoreTransition] = []
        var changesByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryChange] = [:]
        for change in changes {
            let key = change.recordKey
            if let queued = changesByKey[key] {
                guard queued == change else {
                    throw SyncPeerBootstrapError.anchoredRecoveryConflict(key)
                }
                continue
            }
            changesByKey[key] = change
            if let existing = snapshot.record(for: key) {
                guard existing.change == change,
                      !existing.lifecycle.isTerminal else {
                    throw SyncPeerBootstrapError.anchoredRecoveryConflict(key)
                }
                switch existing.lifecycle {
                case .waiting, .bootstrapOwned:
                    continue
                case .terminalStructuralFailure, .bootstrapContentConflict:
                    throw SyncPeerBootstrapError.anchoredRecoveryConflict(key)
                }
            }
            let record = try SyncBatchAnchoredRecoveryRecord(
                change: change,
                lifecycle: .bootstrapOwned
            )
            transitions.append(.insertExpectedAbsent(record))
        }
        _ = try anchoredRecoveryStore.apply(transitions)
    }

    private static func validate(_ snapshot: SyncPeerBootstrapSnapshot) throws {
        let folderIDs = Set(snapshot.folders.map(\.id))
        guard folderIDs.count == snapshot.folders.count else {
            let duplicate = Dictionary(grouping: snapshot.folders, by: \.id).first { $0.value.count > 1 }!.key
            throw SyncPeerBootstrapError.duplicateFolderID(duplicate)
        }
        let noteIDs = Set(snapshot.notes.map(\.id))
        guard noteIDs.count == snapshot.notes.count else {
            let duplicate = Dictionary(grouping: snapshot.notes, by: \.id).first { $0.value.count > 1 }!.key
            throw SyncPeerBootstrapError.duplicateNoteID(duplicate)
        }
        let historyBatchIDs = Set(snapshot.historyCoverage.map(\.batchID))
        guard historyBatchIDs.count == snapshot.historyCoverage.count else {
            let duplicate = Dictionary(grouping: snapshot.historyCoverage, by: \.batchID)
                .first { $0.value.count > 1 }!.key
            throw SyncPeerBootstrapError.duplicateHistoryBatchID(duplicate)
        }
        for coverage in snapshot.historyCoverage {
            if let missingNoteID = coverage.noteIDs.first(where: { !noteIDs.contains($0) }) {
                throw SyncPeerBootstrapError.historyReferencesMissingNote(missingNoteID)
            }
        }
        for folder in snapshot.folders {
            if let parentID = folder.parentFolderID, !folderIDs.contains(parentID) {
                throw SyncPeerBootstrapError.missingFolder(parentID)
            }
        }
        for note in snapshot.notes {
            if let folderID = note.folderID, !folderIDs.contains(folderID) {
                throw SyncPeerBootstrapError.missingFolder(folderID)
            }
            let record = makeRecord(from: note)
            let state: SyncTextSequenceState
            do {
                state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                    record: record,
                    noteID: note.id
                )
            } catch {
                throw SyncPeerBootstrapError.invalidSequenceState(note.id)
            }
            guard NoteSequenceStateExactText.matches(state.visibleText, note.body) else {
                throw SyncPeerBootstrapError.noteBodyStateMismatch(note.id)
            }
        }
    }

    private static func makeRecord(from note: SyncPeerBootstrapNoteSnapshot) -> NoteSequenceStateRecord {
        NoteSequenceStateRecord(
            noteID: note.id,
            formatVersion: note.formatVersion,
            revision: note.revision,
            visibleUTF16Count: note.visibleUTF16Count,
            tombstonedUTF16Count: note.tombstonedUTF16Count,
            payloadByteCount: note.payloadByteCount,
            statePayloadData: note.statePayloadData
        )
    }

    private static func recordExactlyMatches(
        _ record: NoteSequenceStateRecord,
        _ note: SyncPeerBootstrapNoteSnapshot
    ) -> Bool {
        record.formatVersion == note.formatVersion
            && record.revision == note.revision
            && record.visibleUTF16Count == note.visibleUTF16Count
            && record.tombstonedUTF16Count == note.tombstonedUTF16Count
            && record.payloadByteCount == note.payloadByteCount
            && record.statePayloadData == note.statePayloadData
    }
}

struct MultipeerSyncMessageEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let kind: MultipeerSyncMessageKind
    let schemaVersion: Int
    let payload: Data

    init(
        kind: MultipeerSyncMessageKind,
        schemaVersion: Int = Self.currentSchemaVersion,
        payload: Data
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    var canDecodeWithCurrentSchema: Bool {
        schemaVersion <= Self.currentSchemaVersion
    }
}

enum MultipeerSyncMessageCoding {
    static func encodeBatch(_ batch: SyncBatch) throws -> Data {
        try SyncBatchAnchoredPayloadPolicy.validateTransportEncode(batch)
        return try encode(
            kind: .batchSync,
            payload: SyncBatchEnvelopeCodec.encode(batch: batch)
        )
    }

    static func decodeBatchPayload(_ payload: Data) throws -> SyncBatchEnvelope {
        try SyncBatchEnvelopeCodec.decode(payload)
    }

    static func encode(kind: MultipeerSyncMessageKind, payload: Data) throws -> Data {
        let envelope = MultipeerSyncMessageEnvelope(kind: kind, payload: payload)
        return try JSONEncoder().encode(envelope)
    }

    static func decodeMessage(from data: Data) throws -> MultipeerSyncMessageEnvelope {
        try JSONDecoder().decode(MultipeerSyncMessageEnvelope.self, from: data)
    }
}
