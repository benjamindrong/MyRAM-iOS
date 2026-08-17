import AnchoredSequenceCore
import Foundation
import SwiftData

enum NoteSequenceStateFullBodyIntegrationResult: Equatable {
    case inserted(revision: UInt64)
    case unchanged(revision: UInt64)
    case replaced(previousRevision: UInt64, revision: UInt64)
}

struct NoteSequenceStateMutationSnapshot: Equatable, Sendable {
    let noteID: UUID
    let body: String
    let revision: UInt64
    let state: SyncTextSequenceState
}

/// Keeps a complete note body and its dark anchored-sequence state in one caller-owned transaction.
enum NoteSequenceStateFullBodyIntegration {
    static func loadMutationSnapshot(
        for note: Note,
        in context: ModelContext
    ) throws -> NoteSequenceStateMutationSnapshot {
        try requireManaged(note, in: context)
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard NoteSequenceStateExactText.matches(state.visibleText, note.content) else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(
                expected: state.visibleText,
                actual: note.content
            )
        }
        return NoteSequenceStateMutationSnapshot(
            noteID: note.id,
            body: note.content,
            revision: record.revision,
            state: state
        )
    }

    @discardableResult
    static func stageSuppliedStateMutation(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        newBody: String,
        finalState: SyncTextSequenceState,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        try requireManaged(note, in: context)
        guard snapshot.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard NoteSequenceStateExactText.matches(note.content, snapshot.body) else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(expected: snapshot.body, actual: note.content)
        }
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        guard record.revision == snapshot.revision else {
            throw NoteSequenceStateStoreError.staleRevision(expected: snapshot.revision, actual: record.revision)
        }
        let currentState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard currentState == snapshot.state,
              NoteSequenceStateExactText.matches(currentState.visibleText, snapshot.body) else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        guard NoteSequenceStateExactText.matches(finalState.visibleText, newBody) else {
            throw NoteSequenceStateStoreError.newStateBodyMismatch
        }
        let next = try nextRevision(after: snapshot.revision)
        let payload = try NoteSequenceStatePersistenceCodec.encode(state: finalState, noteID: note.id)
        note.content = newBody
        record.formatVersion = NoteSequenceStatePersistenceCodec.formatVersion
        record.revision = next
        record.visibleUTF16Count = finalState.visibleUTF16Count
        record.tombstonedUTF16Count = finalState.tombstonedUTF16Count
        record.payloadByteCount = payload.count
        record.statePayloadData = payload
        return .replaced(previousRevision: snapshot.revision, revision: next)
    }

    static func restoreSuppliedStateMutationAfterFailedSave(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        failedFinalState: SyncTextSequenceState,
        in context: ModelContext
    ) throws {
        try requireManaged(note, in: context)
        guard snapshot.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        let failedRevision = try nextRevision(after: snapshot.revision)
        guard record.revision == failedRevision else {
            throw NoteSequenceStateStoreError.staleRevision(
                expected: failedRevision,
                actual: record.revision
            )
        }
        let currentState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard currentState == failedFinalState else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        let payload = try NoteSequenceStatePersistenceCodec.encode(
            state: snapshot.state,
            noteID: note.id
        )
        record.formatVersion = NoteSequenceStatePersistenceCodec.formatVersion
        record.revision = snapshot.revision
        record.visibleUTF16Count = snapshot.state.visibleUTF16Count
        record.tombstonedUTF16Count = snapshot.state.tombstonedUTF16Count
        record.payloadByteCount = payload.count
        record.statePayloadData = payload
    }
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
