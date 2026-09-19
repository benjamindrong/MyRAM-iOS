import AnchoredSequenceCore
import Foundation
import SwiftData

typealias NoteLegacyFormattingProjectionOperation =
    @Sendable (Data, String) async -> NoteStructuralFormattingProjection?

typealias NoteStructuralFormattingCacheRenderOperation =
    @Sendable (SyncTextSequenceState, SyncTextMarkState) async throws -> Data?

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
        let enumerationContext = ModelContext(container)
        enumerationContext.autosaveEnabled = false
        let noteIDs = try enumerationContext.fetch(FetchDescriptor<Note>())
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }

        let store = SwiftDataNoteSequenceStateStore(container: container)
        for noteID in noteIDs {
            try beforeEachNote(noteID)

            if allowsExistingStateReplacement {
                _ = try await store.ensureBootstrapStateForCurrentBody(
                    noteID: noteID
                )
            } else {
                switch try await store.load(noteID: noteID) {
                case .missing:
                    _ = try await store.loadOrBootstrapForLegacyMarkMigration(
                        noteID: noteID
                    )
                case .present:
                    break
                }
            }

            try await migrateStructuralMarksIfNeeded(noteID: noteID)
        }
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
