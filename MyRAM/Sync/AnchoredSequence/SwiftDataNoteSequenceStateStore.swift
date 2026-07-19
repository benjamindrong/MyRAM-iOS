import Foundation
import SwiftData
import AnchoredSequenceCore

@globalActor
enum NoteSequenceStatePersistenceActor {
    actor ActorType {}
    static let shared = ActorType()
}

struct NoteSequenceStateNoteSnapshot: Equatable, Sendable {
    let noteID: UUID
    let body: String
}

struct LoadedNoteSequenceState: Equatable, Sendable {
    let note: NoteSequenceStateNoteSnapshot
    let revision: UInt64
    let state: SyncTextSequenceState
}

enum NoteSequenceStateLoadResult: Equatable, Sendable {
    case missing(note: NoteSequenceStateNoteSnapshot)
    case present(LoadedNoteSequenceState)
}

enum NoteSequenceStateExpectation: Equatable, Sendable {
    case missing(expectedBody: String)
    case present(expectedRevision: UInt64, expectedBody: String)
}

protocol NoteSequenceStateStoring: Sendable {
    func load(noteID: UUID) async throws -> NoteSequenceStateLoadResult

    func compareAndSet(
        noteID: UUID,
        expected: NoteSequenceStateExpectation,
        newBody: String,
        newState: SyncTextSequenceState
    ) async throws -> LoadedNoteSequenceState
}

enum NoteSequenceStateStoreError: Error, Equatable, Sendable {
    case missingNote(UUID)
    case expectedMissingButRowExists
    case expectedRowButRowIsMissing
    case staleRevision(expected: UInt64, actual: UInt64)
    case visibleBodyChanged(expected: String, actual: String)
    case newStateBodyMismatch
    case unsupportedVersion(Int)
    case corruptState
    case revisionExhaustion
    case persistenceFailure
    case verificationFailure
}

enum NoteSequenceStateStoreTestStage: Equatable, Sendable {
    case afterExpectationValidation
    case beforeSave
    case afterSave
}

typealias NoteSequenceStateStoreTestHook =
    @Sendable (NoteSequenceStateStoreTestStage) throws -> Void

@NoteSequenceStatePersistenceActor
final class SwiftDataNoteSequenceStateStore: NoteSequenceStateStoring {
    private static let formatVersion = 1

    private let container: ModelContainer
    private let testHook: NoteSequenceStateStoreTestHook

    init(
        container: ModelContainer,
        testHook: @escaping NoteSequenceStateStoreTestHook = { _ in }
    ) {
        self.container = container
        self.testHook = testHook
    }

    func load(noteID: UUID) async throws -> NoteSequenceStateLoadResult {
        do {
            let context = makeContext()
            guard let note = try fetchNote(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.missingNote(noteID)
            }
            let snapshot = NoteSequenceStateNoteSnapshot(
                noteID: noteID,
                body: note.content
            )
            guard let record = try fetchRecord(noteID: noteID, in: context) else {
                return .missing(note: snapshot)
            }

            let state = try decodeAndValidate(
                record: record,
                noteID: noteID,
                noteBody: note.content
            )
            return .present(LoadedNoteSequenceState(
                note: snapshot,
                revision: record.revision,
                state: state
            ))
        } catch let error as NoteSequenceStateStoreError {
            throw error
        } catch {
            throw NoteSequenceStateStoreError.persistenceFailure
        }
    }

    func compareAndSet(
        noteID: UUID,
        expected: NoteSequenceStateExpectation,
        newBody: String,
        newState: SyncTextSequenceState
    ) async throws -> LoadedNoteSequenceState {
        guard newState.visibleText == newBody else {
            throw NoteSequenceStateStoreError.newStateBodyMismatch
        }

        let context = makeContext()
        do {
            guard let note = try fetchNote(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.missingNote(noteID)
            }
            let record = try fetchRecord(noteID: noteID, in: context)
            if let record {
                _ = try decodeAndValidate(
                    record: record,
                    noteID: noteID,
                    noteBody: note.content
                )
            }

            let nextRevision = try validate(
                expected: expected,
                noteBody: note.content,
                record: record
            )
            try testHook(.afterExpectationValidation)

            let payload = try encode(state: newState, noteID: noteID)
            note.content = newBody
            if let record {
                update(
                    record,
                    revision: nextRevision,
                    state: newState,
                    payload: payload
                )
            } else {
                context.insert(makeRecord(
                    noteID: noteID,
                    revision: nextRevision,
                    state: newState,
                    payload: payload
                ))
            }

            try testHook(.beforeSave)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw NoteSequenceStateStoreError.persistenceFailure
            }
            try testHook(.afterSave)

            return try verifyCommittedState(
                noteID: noteID,
                body: newBody,
                revision: nextRevision,
                state: newState,
                payload: payload
            )
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
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func fetchNote(noteID: UUID, in context: ModelContext) throws -> Note? {
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

    private func validate(
        expected: NoteSequenceStateExpectation,
        noteBody: String,
        record: NoteSequenceStateRecord?
    ) throws -> UInt64 {
        switch (expected, record) {
        case (.missing(let expectedBody), nil):
            try requireExpectedBody(expectedBody, actualBody: noteBody)
            return 0

        case (.missing, .some):
            throw NoteSequenceStateStoreError.expectedMissingButRowExists

        case (.present, nil):
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing

        case let (.present(expectedRevision, expectedBody), .some(record)):
            guard expectedRevision == record.revision else {
                throw NoteSequenceStateStoreError.staleRevision(
                    expected: expectedRevision,
                    actual: record.revision
                )
            }
            try requireExpectedBody(expectedBody, actualBody: noteBody)
            let (nextRevision, overflow) = record.revision.addingReportingOverflow(1)
            guard !overflow else {
                throw NoteSequenceStateStoreError.revisionExhaustion
            }
            return nextRevision
        }
    }

    private func requireExpectedBody(
        _ expectedBody: String,
        actualBody: String
    ) throws {
        guard expectedBody == actualBody else {
            throw NoteSequenceStateStoreError.visibleBodyChanged(
                expected: expectedBody,
                actual: actualBody
            )
        }
    }

    private func makeRecord(
        noteID: UUID,
        revision: UInt64,
        state: SyncTextSequenceState,
        payload: Data
    ) -> NoteSequenceStateRecord {
        NoteSequenceStateRecord(
            noteID: noteID,
            formatVersion: Self.formatVersion,
            revision: revision,
            visibleUTF16Count: state.visibleUTF16Count,
            tombstonedUTF16Count: state.tombstonedUTF16Count,
            payloadByteCount: payload.count,
            statePayloadData: payload
        )
    }

    private func update(
        _ record: NoteSequenceStateRecord,
        revision: UInt64,
        state: SyncTextSequenceState,
        payload: Data
    ) {
        record.formatVersion = Self.formatVersion
        record.revision = revision
        record.visibleUTF16Count = state.visibleUTF16Count
        record.tombstonedUTF16Count = state.tombstonedUTF16Count
        record.payloadByteCount = payload.count
        record.statePayloadData = payload
    }

    private func encode(
        state: SyncTextSequenceState,
        noteID: UUID
    ) throws -> Data {
        let persisted = PersistedNoteSequenceStateV1(
            formatVersion: Self.formatVersion,
            noteID: noteID.uuidString.lowercased(),
            runs: state.runs.map { run in
                PersistedRunV1(
                    operationID: run.operationID,
                    leftOrigin: run.origin.leftElementID,
                    rightOrigin: run.origin.rightElementID,
                    text: run.text
                )
            },
            fragments: state.fragments.map { fragment in
                PersistedFragmentV1(
                    operationID: fragment.operationID,
                    startOffset: fragment.startOffset,
                    utf16Length: fragment.utf16Length,
                    visibility: fragment.visibility.rawValue
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(persisted)
        } catch {
            throw NoteSequenceStateStoreError.persistenceFailure
        }
    }

    private func decodeAndValidate(
        record: NoteSequenceStateRecord,
        noteID: UUID,
        noteBody: String
    ) throws -> SyncTextSequenceState {
        guard record.formatVersion == Self.formatVersion else {
            throw NoteSequenceStateStoreError.unsupportedVersion(record.formatVersion)
        }

        let version: PersistedVersionHeader
        do {
            version = try JSONDecoder().decode(
                PersistedVersionHeader.self,
                from: record.statePayloadData
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptState
        }
        guard version.formatVersion == Self.formatVersion else {
            throw NoteSequenceStateStoreError.unsupportedVersion(version.formatVersion)
        }

        let persisted: PersistedNoteSequenceStateV1
        do {
            persisted = try JSONDecoder().decode(
                PersistedNoteSequenceStateV1.self,
                from: record.statePayloadData
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptState
        }

        guard let payloadNoteID = UUID(uuidString: persisted.noteID),
              persisted.noteID == payloadNoteID.uuidString.lowercased(),
              payloadNoteID == noteID,
              record.noteID == noteID else {
            throw NoteSequenceStateStoreError.corruptState
        }

        let state: SyncTextSequenceState
        do {
            let runs = try persisted.runs.map { persistedRun in
                try SyncTextSequenceRun(
                    operationID: persistedRun.operationID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: persistedRun.leftOrigin,
                        rightElementID: persistedRun.rightOrigin
                    ),
                    text: persistedRun.text
                )
            }
            let fragments = try persisted.fragments.map { persistedFragment in
                guard let visibility = SyncTextSequenceElementVisibility(
                    rawValue: persistedFragment.visibility
                ) else {
                    throw NoteSequenceStateStoreError.corruptState
                }
                return try SyncTextSequenceFragment(
                    operationID: persistedFragment.operationID,
                    startOffset: persistedFragment.startOffset,
                    utf16Length: persistedFragment.utf16Length,
                    visibility: visibility
                )
            }
            state = try SyncTextSequenceState(runs: runs, fragments: fragments)
        } catch let error as NoteSequenceStateStoreError {
            throw error
        } catch {
            throw NoteSequenceStateStoreError.corruptState
        }

        guard record.visibleUTF16Count == state.visibleUTF16Count,
              record.tombstonedUTF16Count == state.tombstonedUTF16Count,
              record.payloadByteCount == record.statePayloadData.count,
              state.visibleText == noteBody else {
            throw NoteSequenceStateStoreError.corruptState
        }
        return state
    }

    private func verifyCommittedState(
        noteID: UUID,
        body: String,
        revision: UInt64,
        state: SyncTextSequenceState,
        payload: Data
    ) throws -> LoadedNoteSequenceState {
        do {
            let verificationContext = makeContext()
            guard let note = try fetchNote(noteID: noteID, in: verificationContext),
                  let record = try fetchRecord(noteID: noteID, in: verificationContext),
                  note.content == body,
                  record.revision == revision,
                  record.statePayloadData == payload else {
                throw NoteSequenceStateStoreError.verificationFailure
            }
            let decodedState = try decodeAndValidate(
                record: record,
                noteID: noteID,
                noteBody: note.content
            )
            guard decodedState == state else {
                throw NoteSequenceStateStoreError.verificationFailure
            }
            return LoadedNoteSequenceState(
                note: NoteSequenceStateNoteSnapshot(noteID: noteID, body: body),
                revision: revision,
                state: decodedState
            )
        } catch {
            throw NoteSequenceStateStoreError.verificationFailure
        }
    }
}

private struct PersistedVersionHeader: Decodable {
    let formatVersion: Int
}

private struct PersistedNoteSequenceStateV1: Codable {
    let formatVersion: Int
    let noteID: String
    let runs: [PersistedRunV1]
    let fragments: [PersistedFragmentV1]
}

private struct PersistedRunV1: Codable {
    let operationID: SyncOperationID
    let leftOrigin: SyncTextElementID?
    let rightOrigin: SyncTextElementID?
    let text: String
}

private struct PersistedFragmentV1: Codable {
    let operationID: SyncOperationID
    let startOffset: Int
    let utf16Length: Int
    let visibility: String
}
