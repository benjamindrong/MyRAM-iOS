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


enum NoteStructuralFormattingCanonicalization {
    static func fontSizeMilliPoints(_ pointSize: Double) -> Int? {
        guard pointSize.isFinite else { return nil }
        let scaled = pointSize * 1_000
        guard scaled.isFinite else { return nil }
        let rounded = scaled.rounded(.toNearestOrAwayFromZero)
        guard rounded >= Double(Int.min),
              rounded <= Double(Int.max) else {
            return nil
        }
        let value = Int(rounded)
        guard (11_000...40_000).contains(value) else { return nil }
        return value
    }

    static func rgbaColor(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double
    ) -> SyncTextMarkRGBAColor? {
        guard let red = rgbaByte(red),
              let green = rgbaByte(green),
              let blue = rgbaByte(blue),
              let alpha = rgbaByte(alpha) else {
            return nil
        }
        return SyncTextMarkRGBAColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    private static func rgbaByte(_ component: Double) -> UInt8? {
        guard component.isFinite else { return nil }
        let clamped = min(max(component, 0), 1)
        let rounded = (clamped * 255).rounded(.toNearestOrAwayFromZero)
        guard rounded >= 0, rounded <= 255 else { return nil }
        return UInt8(rounded)
    }
}
