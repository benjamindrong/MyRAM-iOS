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
    let markFormatVersion: Int
    let markRevision: UInt64
    let markState: SyncTextMarkState

    init(
        noteID: UUID,
        body: String,
        revision: UInt64,
        state: SyncTextSequenceState,
        markFormatVersion: Int = NoteStructuralFormattingPersistence.schemaVersion,
        markRevision: UInt64 = 0,
        markState: SyncTextMarkState = .empty
    ) {
        self.noteID = noteID
        self.body = body
        self.revision = revision
        self.state = state
        self.markFormatVersion = markFormatVersion
        self.markRevision = markRevision
        self.markState = markState
    }
}

enum NoteStructuralFormattingMutationResult: Equatable {
    case unchanged(revision: UInt64)
    case replaced(previousRevision: UInt64, revision: UInt64)
}


struct NoteCombinedStructuralMutationResult: Equatable {
    let textChanged: Bool
    let markChanged: Bool
    let textRevision: UInt64
    let markRevision: UInt64
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
        let markState = try decodeMarkState(
            record: record,
            pairedWith: state
        )
        return NoteSequenceStateMutationSnapshot(
            noteID: note.id,
            body: note.content,
            revision: record.revision,
            state: state,
            markFormatVersion: record.markFormatVersion,
            markRevision: record.markRevision,
            markState: markState
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
        try requireMarkSnapshot(
            snapshot,
            record: record,
            pairedWith: currentState
        )
        guard NoteSequenceStateExactText.matches(finalState.visibleText, newBody) else {
            throw NoteSequenceStateStoreError.newStateBodyMismatch
        }
        do {
            try snapshot.markState.validating(against: finalState)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
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

    /// Installs a caller-validated authoritative body/state pair while preserving the
    /// same optimistic body, revision, and structural guards as every supplied-state mutation.
    @discardableResult
    static func installAuthoritativeState(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        body: String,
        state: SyncTextSequenceState,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        try stageSuppliedStateMutation(
            of: note,
            expected: snapshot,
            newBody: body,
            finalState: state,
            in: context
        )
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
        try requireMarkSnapshot(
            snapshot,
            record: record,
            pairedWith: failedFinalState
        )
        do {
            try snapshot.markState.validating(against: snapshot.state)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
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

    @discardableResult
    static func stageSuppliedStateAndStructuralFormattingMutation(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        newBody: String,
        finalState: SyncTextSequenceState,
        finalMarkState: SyncTextMarkState,
        in context: ModelContext
    ) throws -> NoteCombinedStructuralMutationResult {
        try requireManaged(note, in: context)
        guard snapshot.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard NoteSequenceStateExactText.matches(note.content, snapshot.body) else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(
                expected: snapshot.body,
                actual: note.content
            )
        }
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        guard record.revision == snapshot.revision else {
            throw NoteSequenceStateStoreError.staleRevision(
                expected: snapshot.revision,
                actual: record.revision
            )
        }

        let currentState = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: note.id
            )
        guard currentState == snapshot.state,
              NoteSequenceStateExactText.matches(
                currentState.visibleText,
                snapshot.body
              ) else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        try requireMarkSnapshot(
            snapshot,
            record: record,
            pairedWith: currentState
        )

        guard NoteSequenceStateExactText.matches(
            finalState.visibleText,
            newBody
        ) else {
            throw NoteSequenceStateStoreError.newStateBodyMismatch
        }
        do {
            try finalMarkState.validating(against: finalState)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let textChanged = finalState != snapshot.state
        let markChanged = finalMarkState != snapshot.markState

        let nextTextRevision = textChanged
            ? try nextRevision(after: snapshot.revision)
            : snapshot.revision
        let nextMarkRevision = markChanged
            ? try nextMarkRevision(after: snapshot.markRevision)
            : snapshot.markRevision

        let textPayload: Data? = textChanged
            ? try NoteSequenceStatePersistenceCodec.encode(
                state: finalState,
                noteID: note.id
            )
            : nil
        let markPayload: Data?
        if markChanged {
            do {
                markPayload = try NoteStructuralFormattingPersistence.encode(
                    state: finalMarkState,
                    pairedWith: finalState
                )
            } catch {
                throw NoteSequenceStateStoreError.corruptMarkState
            }
        } else {
            markPayload = nil
        }

        // All validation, overflow checks, and encoding complete before authority is staged.
        if textChanged, let textPayload {
            note.content = newBody
            record.formatVersion = NoteSequenceStatePersistenceCodec.formatVersion
            record.revision = nextTextRevision
            record.visibleUTF16Count = finalState.visibleUTF16Count
            record.tombstonedUTF16Count = finalState.tombstonedUTF16Count
            record.payloadByteCount = textPayload.count
            record.statePayloadData = textPayload
        }

        if markChanged, let markPayload {
            record.markFormatVersion =
                NoteStructuralFormattingPersistence.schemaVersion
            record.markRevision = nextMarkRevision
            record.markStatePayloadData = markPayload
        }

        return NoteCombinedStructuralMutationResult(
            textChanged: textChanged,
            markChanged: markChanged,
            textRevision: nextTextRevision,
            markRevision: nextMarkRevision
        )
    }

    static func restoreSuppliedStateAndStructuralFormattingMutationAfterFailedSave(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        failedFinalState: SyncTextSequenceState,
        failedFinalMarkState: SyncTextMarkState,
        in context: ModelContext
    ) throws {
        try requireManaged(note, in: context)
        guard snapshot.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }

        let textChanged = failedFinalState != snapshot.state
        let markChanged = failedFinalMarkState != snapshot.markState
        let expectedTextRevision = textChanged
            ? try nextRevision(after: snapshot.revision)
            : snapshot.revision
        let expectedMarkRevision = markChanged
            ? try nextMarkRevision(after: snapshot.markRevision)
            : snapshot.markRevision

        guard record.revision == expectedTextRevision else {
            throw NoteSequenceStateStoreError.staleRevision(
                expected: expectedTextRevision,
                actual: record.revision
            )
        }
        guard record.markRevision == expectedMarkRevision else {
            throw NoteSequenceStateStoreError.staleMarkRevision(
                expected: expectedMarkRevision,
                actual: record.markRevision
            )
        }

        let currentState = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: note.id
            )
        guard currentState == failedFinalState else {
            throw NoteSequenceStateStoreError.verificationFailure
        }

        let currentMarks = try decodeMarkState(
            record: record,
            pairedWith: currentState
        )
        guard currentMarks == failedFinalMarkState else {
            throw NoteSequenceStateStoreError.verificationFailure
        }

        let textPayload = try NoteSequenceStatePersistenceCodec.encode(
            state: snapshot.state,
            noteID: note.id
        )
        let markPayload: Data
        do {
            markPayload = try NoteStructuralFormattingPersistence.encode(
                state: snapshot.markState,
                pairedWith: snapshot.state
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        record.formatVersion = NoteSequenceStatePersistenceCodec.formatVersion
        record.revision = snapshot.revision
        record.visibleUTF16Count = snapshot.state.visibleUTF16Count
        record.tombstonedUTF16Count = snapshot.state.tombstonedUTF16Count
        record.payloadByteCount = textPayload.count
        record.statePayloadData = textPayload
        record.markFormatVersion = snapshot.markFormatVersion
        record.markRevision = snapshot.markRevision
        record.markStatePayloadData = markPayload
    }

    @discardableResult
    static func stageStructuralFormattingMutation(
        of note: Note,
        expected snapshot: NoteSequenceStateMutationSnapshot,
        finalMarkState: SyncTextMarkState,
        in context: ModelContext
    ) throws -> NoteStructuralFormattingMutationResult {
        try requireManaged(note, in: context)
        guard snapshot.noteID == note.id else {
            throw NoteSequenceStateStoreError.preparedStateNoteIDMismatch
        }
        guard NoteSequenceStateExactText.matches(note.content, snapshot.body) else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(
                expected: snapshot.body,
                actual: note.content
            )
        }
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        guard record.revision == snapshot.revision else {
            throw NoteSequenceStateStoreError.staleRevision(
                expected: snapshot.revision,
                actual: record.revision
            )
        }

        let currentState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard currentState == snapshot.state else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        try requireMarkSnapshot(
            snapshot,
            record: record,
            pairedWith: currentState
        )
        do {
            try finalMarkState.validating(against: currentState)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        guard finalMarkState != snapshot.markState else {
            return .unchanged(revision: snapshot.markRevision)
        }

        let nextMarkRevision = try nextMarkRevision(after: snapshot.markRevision)
        let payload: Data
        do {
            payload = try NoteStructuralFormattingPersistence.encode(
                state: finalMarkState,
                pairedWith: currentState
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }
        record.markFormatVersion = NoteStructuralFormattingPersistence.schemaVersion
        record.markRevision = nextMarkRevision
        record.markStatePayloadData = payload
        return .replaced(
            previousRevision: snapshot.markRevision,
            revision: nextMarkRevision
        )
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
        if SyncBatchAnchoredPayloadCapability.isEnabled {
            let finalState = try SyncTextLegacyBootstrap.makeLineagePreservingState(
                noteID: note.id,
                currentState: state,
                body: note.content
            )
            try apply(
                finalState,
                to: record,
                noteID: note.id,
                revision: nextRevision
            )
        } else {
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: note.content
            )
            prepared.apply(to: record, revision: nextRevision)
        }
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
            if SyncBatchAnchoredPayloadCapability.isEnabled {
                let markState = try decodeMarkState(
                    record: record,
                    pairedWith: state
                )
                let finalState = try SyncTextLegacyBootstrap.makeLineagePreservingState(
                    noteID: note.id,
                    currentState: state,
                    body: authoritativeBody
                )
                do {
                    try markState.validating(against: finalState)
                } catch {
                    throw NoteSequenceStateStoreError.corruptMarkState
                }
                try apply(
                    finalState,
                    to: record,
                    noteID: note.id,
                    revision: nextRevision
                )
            } else {
                let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                    noteID: note.id,
                    body: authoritativeBody
                )
                prepared.apply(to: record, revision: nextRevision)
            }
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

    /// Installs the deterministic union of two established anchored histories
    /// without replacing either side's operation identities.
    static func mergeRetainedLineage(
        of note: Note,
        with remoteState: SyncTextSequenceState,
        in context: ModelContext
    ) throws -> NoteSequenceStateFullBodyIntegrationResult {
        try requireManaged(note, in: context)
        guard let record = try fetchRecord(noteID: note.id, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        let localState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        guard NoteSequenceStateExactText.matches(localState.visibleText, note.content) else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(
                expected: localState.visibleText,
                actual: note.content
            )
        }

        let markState = try decodeMarkState(
            record: record,
            pairedWith: localState
        )
        let mergedState = try localState.mergingRetainedLineage(with: remoteState)
        do {
            try markState.validating(against: mergedState)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }
        guard mergedState != localState else {
            return .unchanged(revision: record.revision)
        }

        let previousRevision = record.revision
        let nextRevision = try nextRevision(after: previousRevision)
        try apply(mergedState, to: record, noteID: note.id, revision: nextRevision)
        note.content = mergedState.visibleText
        return .replaced(previousRevision: previousRevision, revision: nextRevision)
    }

    private static func apply(
        _ state: SyncTextSequenceState,
        to record: NoteSequenceStateRecord,
        noteID: UUID,
        revision: UInt64
    ) throws {
        let payload = try NoteSequenceStatePersistenceCodec.encode(
            state: state,
            noteID: noteID
        )
        record.formatVersion = NoteSequenceStatePersistenceCodec.formatVersion
        record.revision = revision
        record.visibleUTF16Count = state.visibleUTF16Count
        record.tombstonedUTF16Count = state.tombstonedUTF16Count
        record.payloadByteCount = payload.count
        record.statePayloadData = payload
    }

    private static func requireMarkSnapshot(
        _ snapshot: NoteSequenceStateMutationSnapshot,
        record: NoteSequenceStateRecord,
        pairedWith sequence: SyncTextSequenceState
    ) throws {
        guard record.markFormatVersion == snapshot.markFormatVersion else {
            throw NoteSequenceStateStoreError.unsupportedMarkVersion(
                record.markFormatVersion
            )
        }
        guard record.markRevision == snapshot.markRevision else {
            throw NoteSequenceStateStoreError.staleMarkRevision(
                expected: snapshot.markRevision,
                actual: record.markRevision
            )
        }
        let currentMarkState = try decodeMarkState(
            record: record,
            pairedWith: sequence
        )
        guard currentMarkState == snapshot.markState else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
    }

    private static func decodeMarkState(
        record: NoteSequenceStateRecord,
        pairedWith sequence: SyncTextSequenceState
    ) throws -> SyncTextMarkState {
        do {
            return try NoteStructuralFormattingPersistence.decode(
                record: record,
                pairedWith: sequence
            )
        } catch let error as NoteStructuralFormattingPersistenceError {
            switch error {
            case .unsupportedSchemaVersion(let version):
                throw NoteSequenceStateStoreError.unsupportedMarkVersion(version)
            case .corruptPayload, .pairedValidationFailed:
                throw NoteSequenceStateStoreError.corruptMarkState
            }
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }
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

    private static func nextMarkRevision(after revision: UInt64) throws -> UInt64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw NoteSequenceStateStoreError.markRevisionExhaustion
        }
        return next
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
