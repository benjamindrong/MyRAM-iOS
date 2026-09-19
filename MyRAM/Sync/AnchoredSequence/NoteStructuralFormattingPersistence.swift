import AnchoredSequenceCore
import Foundation

enum NoteStructuralFormattingPersistenceError:
    Error,
    Equatable
{
    case unsupportedSchemaVersion(Int)
    case corruptPayload
    case pairedValidationFailed
}

enum NoteStructuralFormattingPersistence {
    static let schemaVersion = 1

    static let canonicalEmptyPayload: Data = {
        do {
            return try encodeCanonicalPayload(state: .empty)
        } catch {
            preconditionFailure(
                "Canonical empty structural-mark payload must always encode: \(error)"
            )
        }
    }()

    static func encode(
        state: SyncTextMarkState,
        pairedWith sequence: SyncTextSequenceState
    ) throws -> Data {
        do {
            try state.validating(against: sequence)
        } catch {
            throw NoteStructuralFormattingPersistenceError.pairedValidationFailed
        }
        return try encodeCanonicalPayload(state: state)
    }

    static func decode(
        record: NoteSequenceStateRecord,
        pairedWith sequence: SyncTextSequenceState
    ) throws -> SyncTextMarkState {
        guard record.markFormatVersion == schemaVersion else {
            throw NoteStructuralFormattingPersistenceError.unsupportedSchemaVersion(
                record.markFormatVersion
            )
        }

        let header: PersistedStructuralMarkVersionHeader
        do {
            header = try JSONDecoder().decode(
                PersistedStructuralMarkVersionHeader.self,
                from: record.markStatePayloadData
            )
        } catch {
            throw NoteStructuralFormattingPersistenceError.corruptPayload
        }
        guard header.formatVersion == schemaVersion else {
            throw NoteStructuralFormattingPersistenceError.unsupportedSchemaVersion(
                header.formatVersion
            )
        }

        let persisted: PersistedStructuralMarkStateV1
        do {
            persisted = try JSONDecoder().decode(
                PersistedStructuralMarkStateV1.self,
                from: record.markStatePayloadData
            )
        } catch {
            throw NoteStructuralFormattingPersistenceError.corruptPayload
        }

        let state: SyncTextMarkState
        do {
            state = try SyncTextMarkState(operations: persisted.operations)
            try state.validating(against: sequence)
        } catch {
            throw NoteStructuralFormattingPersistenceError.pairedValidationFailed
        }
        return state
    }

    static func installCanonicalEmptyState(
        on record: NoteSequenceStateRecord
    ) {
        record.markFormatVersion = schemaVersion
        record.markRevision = 0
        record.markStatePayloadData = canonicalEmptyPayload
    }

    private static func encodeCanonicalPayload(
        state: SyncTextMarkState
    ) throws -> Data {
        let persisted = PersistedStructuralMarkStateV1(
            formatVersion: schemaVersion,
            operations: state.operations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(persisted)
        } catch {
            throw NoteStructuralFormattingPersistenceError.corruptPayload
        }
    }
}

private struct PersistedStructuralMarkVersionHeader: Decodable {
    let formatVersion: Int
}

private struct PersistedStructuralMarkStateV1: Codable {
    let formatVersion: Int
    let operations: [SyncTextMarkOperation]
}
