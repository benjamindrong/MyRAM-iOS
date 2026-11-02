import AnchoredSequenceCore
import Foundation
import SwiftData

typealias NoteLegacyFormattingProjectionOperation =
    @Sendable (Data, String) async -> NoteStructuralFormattingProjection?

typealias NoteStructuralFormattingCacheRenderOperation =
    @Sendable (SyncTextSequenceState, SyncTextMarkState) async throws -> Data?

/// Immutable, lossless evidence for a structurally valid local body/history mismatch.
/// Capturing this value performs no persistence, authority change or networking.
/// A future resolution must durably retain this exact snapshot, including raw mark
/// and sequence bytes, and prove queue ownership before changing either authority.
struct NoteLocalDivergenceSnapshot: Codable, Equatable, Sendable {
    let noteID: UUID
    let savedTitle: String
    let savedBody: String
    let savedRichTextContentData: Data?
    let savedIsPinned: Bool?
    let savedCreatedAt: Date
    let savedModifiedAt: Date
    let savedDeletedAt: Date?
    let savedFolderID: UUID?
    let sequenceVisibleText: String
    let sequenceFormatVersion: Int
    let sequenceRevision: UInt64
    let sequenceVisibleUTF16Count: Int
    let sequenceTombstonedUTF16Count: Int
    let sequencePayloadByteCount: Int
    let sequencePayloadData: Data
    let markFormatVersion: Int
    let markRevision: UInt64
    let markStatePayloadData: Data
}

/// An immutable, append-only ledger of local note/body versus anchored-history evidence.
/// Neither a captured snapshot nor this ledger authorizes choosing a winner or resuming sync.
struct NoteLocalDivergenceEvidenceEnvelope: Codable, Equatable {
    static let supportedVersion = 1

    let formatVersion: Int
    var snapshots: [NoteLocalDivergenceSnapshot]

    static let empty = Self(formatVersion: supportedVersion, snapshots: [])

    func validate() throws {
        guard formatVersion == Self.supportedVersion else {
            throw NoteLocalDivergenceEvidenceStoreError.unsupportedVersion(formatVersion)
        }
        for (index, snapshot) in snapshots.enumerated() {
            guard snapshot.sequencePayloadByteCount == snapshot.sequencePayloadData.count,
                  snapshot.sequenceVisibleUTF16Count >= 0,
                  snapshot.sequenceTombstonedUTF16Count >= 0,
                  !NoteSequenceStateExactText.matches(
                    snapshot.savedBody, snapshot.sequenceVisibleText
                  ),
                  !snapshots.prefix(index).contains(snapshot) else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
    }
}

enum NoteLocalDivergenceEvidenceStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case corruptArchive
    case staleSnapshot
    case persistenceFailed
}

struct NoteLocalDivergenceEvidenceFileIO: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var readData: @Sendable (URL) throws -> Data
    var createDirectory: @Sendable (URL) throws -> Void
    var writeData: @Sendable (Data, URL) throws -> Void

    static let live = Self(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        readData: { try Data(contentsOf: $0) },
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        writeData: { data, url in try data.write(to: url, options: [.atomic]) }
    )
}

/// Serialized on the same persistence actor as the structural snapshot source.
/// The archive never updates the note, sequence, formatting, queues or networking.
@NoteSequenceStatePersistenceActor
final class NoteLocalDivergenceEvidenceStore {
    private let fileURL: URL
    private let fileIO: NoteLocalDivergenceEvidenceFileIO

    init(
        fileURL: URL = NoteLocalDivergenceEvidenceStore.defaultFileURL(),
        fileIO: NoteLocalDivergenceEvidenceFileIO = .live
    ) {
        self.fileURL = fileURL
        self.fileIO = fileIO
    }

    /// Preserve only a currently verified local divergence. Never overwrite an
    /// earlier generation from the same note; it may contain unsent user work.
    @discardableResult
    func preserve(
        _ snapshot: NoteLocalDivergenceSnapshot,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator
    ) throws -> Bool {
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        var envelope = try loadEnvelope()
        if envelope.snapshots.contains(snapshot) {
            return false
        }
        envelope.snapshots.append(snapshot)
        try saveEnvelope(envelope)
        // A late local mutation cannot make the captured evidence authoritative.
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return true
    }

    func snapshots(for noteID: UUID) throws -> [NoteLocalDivergenceSnapshot] {
        try loadEnvelope().snapshots.filter { $0.noteID == noteID }
    }

    private func loadEnvelope() throws -> NoteLocalDivergenceEvidenceEnvelope {
        guard fileIO.fileExists(fileURL) else { return .empty }
        do {
            let data = try fileIO.readData(fileURL)
            let envelope = try JSONDecoder().decode(
                NoteLocalDivergenceEvidenceEnvelope.self,
                from: data
            )
            try envelope.validate()
            return envelope
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            throw error
        } catch is DecodingError {
            throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
        } catch {
            throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
        }
    }

    private func saveEnvelope(_ expected: NoteLocalDivergenceEvidenceEnvelope) throws {
        try expected.validate()
        do {
            try fileIO.createDirectory(fileURL.deletingLastPathComponent())
            let bytes = try JSONEncoder().encode(expected)
            try fileIO.writeData(bytes, fileURL)
            // Never report durable preservation on a write that cannot be read back
            // with the exact same authorities, including byte-exact mark payloads.
            let persisted = try loadEnvelope()
            guard persisted == expected else {
                throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
            }
        } catch {
            throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("local-divergence-evidence-v1.json")
    }
}

@NoteSequenceStatePersistenceActor
final class NoteSequenceStateBootstrapMigrator {
    private struct LegacyMarkMigrationSnapshot: Sendable {
        let noteID: UUID
        let body: String
        let sequenceRevision: UInt64
        let sequenceState: SyncTextSequenceState
        let sequencePayloadData: Data
        let markFormatVersion: Int
        let markRevision: UInt64
        let markStatePayloadData: Data
        let legacyRichTextContentData: Data?
    }

    private let container: ModelContainer
    private let allowsExistingStateReplacement: Bool
    private let operationIDReserver: any SyncOperationIDReserving
    private let legacyFormattingProjection: NoteLegacyFormattingProjectionOperation
    private let renderDerivedFormattingCache: NoteStructuralFormattingCacheRenderOperation
    private let saveOperation: @Sendable (ModelContext) throws -> Void
    private let beforeEachNote: @Sendable (UUID) throws -> Void

    init(
        container: ModelContainer,
        allowsExistingStateReplacement: Bool = !SyncBatchAnchoredPayloadCapability.isEnabled,
        operationIDReserver: any SyncOperationIDReserving = MyRAMSyncOperationIDAllocator.shared,
        legacyFormattingProjection: @escaping NoteLegacyFormattingProjectionOperation = { _, _ in nil },
        renderDerivedFormattingCache: @escaping NoteStructuralFormattingCacheRenderOperation = { _, _ in nil },
        saveOperation: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) {
        self.container = container
        self.allowsExistingStateReplacement = allowsExistingStateReplacement
        self.operationIDReserver = operationIDReserver
        self.legacyFormattingProjection = legacyFormattingProjection
        self.renderDerivedFormattingCache = renderDerivedFormattingCache
        self.saveOperation = saveOperation
        self.beforeEachNote = beforeEachNote
    }

    func runToCompletion() async throws {
        _ = try await migrate(preservingDivergentStates: false)
    }

    /// The captured note body and its structurally valid anchored sequence are
    /// independent retained authorities until an explicit conflict resolution.
    /// A divergence is not permission to replace either representation.
    func runPreservingDivergentStates() async throws -> Set<UUID> {
        try await migrate(preservingDivergentStates: true)
    }

    private func migrate(preservingDivergentStates: Bool) async throws -> Set<UUID> {
        let enumerationContext = ModelContext(container)
        enumerationContext.autosaveEnabled = false
        let noteIDs = try enumerationContext.fetch(FetchDescriptor<Note>())
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }

        let store = SwiftDataNoteSequenceStateStore(container: container)
        var divergentNoteIDs = Set<UUID>()
        for noteID in noteIDs {
            try beforeEachNote(noteID)

            if allowsExistingStateReplacement && !preservingDivergentStates {
                do {
                    _ = try await store.loadOrBootstrapForLegacyMarkMigration(
                        noteID: noteID
                    )
                } catch let error as NoteSequenceStateStoreError {
                    guard error == .corruptState else { throw error }
                    _ = try await store.ensureBootstrapStateForCurrentBody(
                        noteID: noteID
                    )
                }
            } else {
                do {
                    switch try await store.load(noteID: noteID) {
                    case .missing:
                        _ = try await store.loadOrBootstrapForLegacyMarkMigration(
                            noteID: noteID
                        )
                    case .present:
                        break
                    }
                } catch let error as NoteSequenceStateStoreError {
                    guard preservingDivergentStates,
                          error == .corruptState,
                          try hasValidSequenceWithDivergentBody(noteID: noteID) else {
                        throw error
                    }
                    divergentNoteIDs.insert(noteID)
                    continue
                }
            }

            try await migrateStructuralMarksIfNeeded(noteID: noteID)
        }
        return divergentNoteIDs
    }

    /// Read-only capture for an explicitly identified divergent note. Never
    /// converts an unsupported/malformed sequence into a recoverable conflict.
    func validatedDivergenceSnapshot(noteID: UUID) throws -> NoteLocalDivergenceSnapshot? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = try fetchNote(noteID: noteID, in: context),
              let record = try fetchRecord(noteID: noteID, in: context) else {
            return nil
        }
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        guard !NoteSequenceStateExactText.matches(sequence.visibleText, note.content) else {
            return nil
        }
        return NoteLocalDivergenceSnapshot(
            noteID: note.id,
            savedTitle: note.title,
            savedBody: note.content,
            savedRichTextContentData: note.richTextContentData,
            savedIsPinned: note.isPinned,
            savedCreatedAt: note.createdAt,
            savedModifiedAt: note.modifiedAt,
            savedDeletedAt: note.deletedAt,
            savedFolderID: note.folder?.id,
            sequenceVisibleText: sequence.visibleText,
            sequenceFormatVersion: record.formatVersion,
            sequenceRevision: record.revision,
            sequenceVisibleUTF16Count: record.visibleUTF16Count,
            sequenceTombstonedUTF16Count: record.tombstonedUTF16Count,
            sequencePayloadByteCount: record.payloadByteCount,
            sequencePayloadData: record.statePayloadData,
            markFormatVersion: record.markFormatVersion,
            markRevision: record.markRevision,
            markStatePayloadData: record.markStatePayloadData
        )
    }

    /// Detects stale evidence before any future explicit resolution attempt.
    /// In particular, matching visible text alone cannot authorize mutation.
    func revalidateDivergenceSnapshot(_ expected: NoteLocalDivergenceSnapshot) throws -> Bool {
        try validatedDivergenceSnapshot(noteID: expected.noteID) == expected
    }

    private func hasValidSequenceWithDivergentBody(noteID: UUID) throws -> Bool {
        try validatedDivergenceSnapshot(noteID: noteID) != nil
    }

    private func migrateStructuralMarksIfNeeded(
        noteID: UUID
    ) async throws {
        let snapshot = try loadLegacyMarkMigrationSnapshot(noteID: noteID)

        if snapshot.markFormatVersion == NoteStructuralFormattingPersistence.schemaVersion {
            let context = ModelContext(container)
            guard let record = try fetchRecord(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
            }
            do {
                _ = try NoteStructuralFormattingPersistence.decode(
                    record: record,
                    pairedWith: snapshot.sequenceState
                )
            } catch let error as NoteStructuralFormattingPersistenceError {
                switch error {
                case .unsupportedSchemaVersion(let version):
                    throw NoteSequenceStateStoreError.unsupportedMarkVersion(version)
                case .corruptPayload, .pairedValidationFailed:
                    throw NoteSequenceStateStoreError.corruptMarkState
                }
            }
            return
        }

        guard snapshot.markFormatVersion == 0 else {
            throw NoteSequenceStateStoreError.unsupportedMarkVersion(
                snapshot.markFormatVersion
            )
        }
        guard snapshot.markRevision == 0,
              snapshot.markStatePayloadData.isEmpty else {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let finalMarkState = try await migratedMarkState(from: snapshot)
        let canonicalPayload: Data
        do {
            canonicalPayload = try NoteStructuralFormattingPersistence.encode(
                state: finalMarkState,
                pairedWith: snapshot.sequenceState
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let rebuiltCache = try await renderDerivedFormattingCache(
            snapshot.sequenceState,
            finalMarkState
        )

        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let note = try fetchNote(noteID: noteID, in: context),
                  let record = try fetchRecord(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
            }

            let currentSequence = try NoteSequenceStatePersistenceCodec
                .decodeStructurallyValidatedState(
                    record: record,
                    noteID: noteID
                )
            guard record.revision == snapshot.sequenceRevision,
                  record.statePayloadData == snapshot.sequencePayloadData,
                  currentSequence == snapshot.sequenceState,
                  NoteSequenceStateExactText.matches(note.content, snapshot.body),
                  record.markFormatVersion == snapshot.markFormatVersion,
                  record.markRevision == snapshot.markRevision,
                  record.markStatePayloadData == snapshot.markStatePayloadData,
                  note.richTextContentData == snapshot.legacyRichTextContentData else {
                throw NoteSequenceStateStoreError.verificationFailure
            }

            let (nextMarkRevision, overflow) = record.markRevision
                .addingReportingOverflow(1)
            guard !overflow else {
                throw NoteSequenceStateStoreError.markRevisionExhaustion
            }

            record.markFormatVersion =
                NoteStructuralFormattingPersistence.schemaVersion
            record.markRevision = nextMarkRevision
            record.markStatePayloadData = canonicalPayload
            note.richTextContentData = rebuiltCache

            do {
                try saveOperation(context)
            } catch {
                context.rollback()
                throw NoteSequenceStateStoreError.persistenceFailure
            }
        } catch let error as NoteSequenceStateStoreError {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw NoteSequenceStateStoreError.persistenceFailure
        }

        try verifyCommittedMigration(
            snapshot: snapshot,
            expectedMarkState: finalMarkState,
            expectedPayload: canonicalPayload,
            expectedCache: rebuiltCache
        )
    }

    private func loadLegacyMarkMigrationSnapshot(
        noteID: UUID
    ) throws -> LegacyMarkMigrationSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = try fetchNote(noteID: noteID, in: context),
              let record = try fetchRecord(noteID: noteID, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: noteID
            )
        guard NoteSequenceStateExactText.matches(
            sequence.visibleText,
            note.content
        ) else {
            throw NoteSequenceStateStoreError.corruptState
        }

        return LegacyMarkMigrationSnapshot(
            noteID: noteID,
            body: note.content,
            sequenceRevision: record.revision,
            sequenceState: sequence,
            sequencePayloadData: record.statePayloadData,
            markFormatVersion: record.markFormatVersion,
            markRevision: record.markRevision,
            markStatePayloadData: record.markStatePayloadData,
            legacyRichTextContentData: note.richTextContentData
        )
    }

    private func migratedMarkState(
        from snapshot: LegacyMarkMigrationSnapshot
    ) async throws -> SyncTextMarkState {
        guard let legacyData = snapshot.legacyRichTextContentData,
              let projection = await legacyFormattingProjection(
                legacyData,
                snapshot.body
              ),
              NoteSequenceStateExactText.matches(
                projection.plainText,
                snapshot.body
              ),
              NoteSequenceStateExactText.matches(
                projection.plainText,
                snapshot.sequenceState.visibleText
              ) else {
            return .empty
        }

        do {
            return try await NoteStructuralFormattingEditPlanner.prepare(
                sequence: snapshot.sequenceState,
                currentMarkState: .empty,
                desiredProjection: projection,
                operationIDReserver: operationIDReserver
            ).finalMarkState
        } catch is NoteStructuralFormattingEditPlannerError {
            return .empty
        } catch is SyncTextSequenceStateError {
            return .empty
        }
    }

    private func verifyCommittedMigration(
        snapshot: LegacyMarkMigrationSnapshot,
        expectedMarkState: SyncTextMarkState,
        expectedPayload: Data,
        expectedCache: Data?
    ) throws {
        let context = ModelContext(container)
        guard let note = try fetchNote(noteID: snapshot.noteID, in: context),
              let record = try fetchRecord(noteID: snapshot.noteID, in: context),
              record.revision == snapshot.sequenceRevision,
              record.statePayloadData == snapshot.sequencePayloadData,
              record.markFormatVersion ==
                NoteStructuralFormattingPersistence.schemaVersion,
              record.markRevision == 1,
              record.markStatePayloadData == expectedPayload,
              note.richTextContentData == expectedCache else {
            throw NoteSequenceStateStoreError.verificationFailure
        }

        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: snapshot.noteID
            )
        let marks: SyncTextMarkState
        do {
            marks = try NoteStructuralFormattingPersistence.decode(
                record: record,
                pairedWith: sequence
            )
        } catch {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        guard sequence == snapshot.sequenceState,
              marks == expectedMarkState,
              NoteSequenceStateExactText.matches(
                note.content,
                snapshot.body
              ) else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
    }

    private func fetchNote(
        noteID: UUID,
        in context: ModelContext
    ) throws -> Note? {
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchRecord(
        noteID: UUID,
        in context: ModelContext
    ) throws -> NoteSequenceStateRecord? {
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
