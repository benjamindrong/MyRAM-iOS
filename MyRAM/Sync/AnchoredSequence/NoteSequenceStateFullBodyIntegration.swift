import Foundation
import SwiftData

enum NoteSequenceStateFullBodyIntegrationResult: Equatable {
    case inserted(revision: UInt64)
    case unchanged(revision: UInt64)
    case replaced(previousRevision: UInt64, revision: UInt64)
}

/// Keeps a complete note body and its dark anchored-sequence state in one caller-owned transaction.
enum NoteSequenceStateFullBodyIntegration {
    static func insertNewNote(
        _ note: Note,
        preparedState: PreparedInitialNoteSequenceState,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        guard preparedState.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard NoteSequenceStateExactText.matches(preparedState.body, note.content) else {
            throw NoteSequenceStateStoreError.newStateBodyMismatch
        }
        guard try fetchNote(noteID: note.id, in: context) == nil else {
            throw NoteSequenceStateStoreError.noteAlreadyExists(note.id)
        }
        guard try fetchRecord(noteID: note.id, in: context) == nil else {
            throw NoteSequenceStateStoreError.stateAlreadyExists(note.id)
        }

        let record = preparedState.makeRevisionZeroRecord()
        context.insert(note)
        context.insert(record)
        return .inserted(revision: 0)
    }

    static func ensureCurrentBodyState(
        for note: Note,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        try requireManaged(note, in: context)
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: note.content
            )
            context.insert(prepared.makeRevisionZeroRecord())
            return .inserted(revision: 0)
        }

        let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard !NoteSequenceStateExactText.matches(state.visibleText, note.content) else {
            return .unchanged(revision: record.revision)
        }

        let previousRevision = record.revision
        let nextRevision = try nextRevision(after: previousRevision)
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: note.content
        )
        prepared.apply(to: record, revision: nextRevision)
        return .replaced(
            previousRevision: previousRevision,
            revision: nextRevision
        )
    }

    static func replaceBody(
        of note: Note,
        with authoritativeBody: String,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        try requireManaged(note, in: context)

        if let record = try fetchRecord(noteID: note.id, in: context) {
            let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                record: record,
                noteID: note.id
            )
            guard !NoteSequenceStateExactText.matches(
                state.visibleText,
                authoritativeBody
            ) else {
                note.content = authoritativeBody
                return .unchanged(revision: record.revision)
            }

            let previousRevision = record.revision
            let nextRevision = try nextRevision(after: previousRevision)
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: authoritativeBody
            )
            prepared.apply(to: record, revision: nextRevision)
            note.content = authoritativeBody
            return .replaced(
                previousRevision: previousRevision,
                revision: nextRevision
            )
        }

        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: authoritativeBody
        )
        context.insert(prepared.makeRevisionZeroRecord())
        note.content = authoritativeBody
        return .inserted(revision: 0)
    }

    private static func requireManaged(
        _ note: Note,
        in context: ModelContext
    ) throws {
        guard let fetched = try fetchNote(noteID: note.id, in: context),
              fetched === note else {
            throw NoteSequenceStateStoreError.noteContextMismatch(note.id)
        }
    }

    private static func nextRevision(after revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw NoteSequenceStateStoreError.revisionExhaustion
        }
        return next
    }

    private static func fetchNote(
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

    private static func fetchRecord(
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
