import CryptoKit
import Foundation

public enum SyncTextLegacyBootstrapFormatVersion: UInt32, Sendable {
    case v1 = 1
}

public struct SyncTextLegacyBootstrapDescriptor: Equatable, Sendable {
    public let operationID: SyncOperationID
    public let state: SyncTextSequenceState
}

/// Introduces a preexisting full-body snapshot as one operation-owned sequence run.
public enum SyncTextLegacyBootstrap {
    public static func makeDescriptor(
        noteID: UUID,
        body: String,
        formatVersion: SyncTextLegacyBootstrapFormatVersion = .v1
    ) throws -> SyncTextLegacyBootstrapDescriptor {
        let operationID = legacyOperationID(
            noteID: noteID,
            body: body,
            formatVersion: formatVersion
        )

        guard !body.isEmpty else {
            return SyncTextLegacyBootstrapDescriptor(
                operationID: operationID,
                state: .empty
            )
        }

        let origin = try SyncTextInsertionOrigin(
            leftElementID: nil,
            rightElementID: nil
        )
        let run = try SyncTextSequenceRun(
            operationID: operationID,
            origin: origin,
            text: body
        )
        let fragment = try SyncTextSequenceFragment(
            operationID: operationID,
            startOffset: 0,
            utf16Length: body.utf16.count,
            visibility: .visible
        )
        let state = try SyncTextSequenceState(
            runs: [run],
            fragments: [fragment]
        )

        return SyncTextLegacyBootstrapDescriptor(
            operationID: operationID,
            state: state
        )
    }

    public static func makeState(
        noteID: UUID,
        body: String,
        formatVersion: SyncTextLegacyBootstrapFormatVersion = .v1
    ) throws -> SyncTextSequenceState {
        try makeDescriptor(
            noteID: noteID,
            body: body,
            formatVersion: formatVersion
        ).state
    }

    /// Replaces visible legacy/full-body text without replacing the established
    /// structural lineage. Existing visible elements become tombstones so anchors
    /// already captured against them remain durable; the replacement body is then
    /// appended as one deterministic structural insertion.
    public static func makeLineagePreservingState(
        noteID: UUID,
        currentState: SyncTextSequenceState,
        body: String,
        formatVersion: SyncTextLegacyBootstrapFormatVersion = .v1
    ) throws -> SyncTextSequenceState {
        guard !exactUTF16Matches(currentState.visibleText, body) else {
            return currentState
        }

        var candidate = currentState
        if candidate.visibleUTF16Count > 0 {
            let operationID = transitionOperationID(
                noteID: noteID,
                currentState: currentState,
                targetBody: body,
                role: .delete,
                formatVersion: formatVersion
            )
            let payload = try candidate.deleteOperationPayload(
                operationID: operationID,
                inVisibleUTF16Range: 0..<candidate.visibleUTF16Count
            )
            candidate = try candidate.incorporating(delete: payload)
        }

        if !body.isEmpty {
            let operationID = transitionOperationID(
                noteID: noteID,
                currentState: currentState,
                targetBody: body,
                role: .insert,
                formatVersion: formatVersion
            )
            let payload = try candidate.insertOperationPayload(
                operationID: operationID,
                atVisibleUTF16Offset: 0
            )
            candidate = try candidate.incorporating(
                insert: payload,
                insertedText: body
            )
        }

        return candidate
    }

    private static func legacyOperationID(
        noteID: UUID,
        body: String,
        formatVersion: SyncTextLegacyBootstrapFormatVersion
    ) -> SyncOperationID {
        switch formatVersion {
        case .v1:
            let bodyContentHash = SHA256.hash(data: bodyHashInputV1(body))
            let legacyRunDigest = SHA256.hash(
                data: legacyRunHashInputV1(
                    noteID: noteID,
                    formatVersion: formatVersion,
                    bodyContentHash: bodyContentHash
                )
            )
            return operationID(from: legacyRunDigest)
        }
    }

    private enum TransitionOperationRole: UInt8 {
        case delete = 1
        case insert = 2
    }

    private static func transitionOperationID(
        noteID: UUID,
        currentState: SyncTextSequenceState,
        targetBody: String,
        role: TransitionOperationRole,
        formatVersion: SyncTextLegacyBootstrapFormatVersion
    ) -> SyncOperationID {
        switch formatVersion {
        case .v1:
            let stateDigest = SHA256.hash(data: stateHashInputV1(currentState))
            let targetBodyDigest = SHA256.hash(data: bodyHashInputV1(targetBody))
            var input = Data("AnchoredSequenceCore.LegacyLineageTransitionID".utf8)
            input.append(0)
            appendUInt32BigEndian(formatVersion.rawValue, to: &input)
            input.append(contentsOf: rawUUIDBytes(noteID))
            input.append(contentsOf: stateDigest)
            input.append(contentsOf: targetBodyDigest)
            input.append(role.rawValue)
            return operationID(from: SHA256.hash(data: input))
        }
    }

    private static func stateHashInputV1(_ state: SyncTextSequenceState) -> Data {
        var input = Data("AnchoredSequenceCore.LegacyLineageState".utf8)
        input.append(0)
        appendUInt64BigEndian(UInt64(state.runs.count), to: &input)
        for run in state.runs {
            appendOperationID(run.operationID, to: &input)
            appendElementID(run.origin.leftElementID, to: &input)
            appendElementID(run.origin.rightElementID, to: &input)
            input.append(contentsOf: SHA256.hash(data: bodyHashInputV1(run.text)))
        }
        appendUInt64BigEndian(UInt64(state.fragments.count), to: &input)
        for fragment in state.fragments {
            appendOperationID(fragment.operationID, to: &input)
            appendUInt64BigEndian(UInt64(fragment.startOffset), to: &input)
            appendUInt64BigEndian(UInt64(fragment.utf16Length), to: &input)
            input.append(fragment.visibility == .visible ? 1 : 2)
        }
        return input
    }

    private static func appendOperationID(
        _ operationID: SyncOperationID,
        to data: inout Data
    ) {
        data.append(contentsOf: rawUUIDBytes(operationID.deviceID))
        appendUInt64BigEndian(operationID.localCounter, to: &data)
    }

    private static func appendElementID(
        _ elementID: SyncTextElementID?,
        to data: inout Data
    ) {
        guard let elementID else {
            data.append(0)
            return
        }
        data.append(1)
        appendOperationID(elementID.operationID, to: &data)
        appendUInt64BigEndian(UInt64(elementID.elementOffset), to: &data)
    }

    private static func bodyHashInputV1(_ body: String) -> Data {
        var input = Data("AnchoredSequenceCore.LegacyBodyContent".utf8)
        input.append(0)
        appendUInt64BigEndian(UInt64(body.utf16.count), to: &input)

        // Hash the addressing substrate directly so normalization cannot alter identity.
        for codeUnit in body.utf16 {
            input.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
            input.append(UInt8(truncatingIfNeeded: codeUnit))
        }
        return input
    }

    private static func legacyRunHashInputV1(
        noteID: UUID,
        formatVersion: SyncTextLegacyBootstrapFormatVersion,
        bodyContentHash: SHA256.Digest
    ) -> Data {
        var input = Data("AnchoredSequenceCore.LegacyRunID".utf8)
        input.append(0)
        appendUInt32BigEndian(formatVersion.rawValue, to: &input)
        input.append(contentsOf: rawUUIDBytes(noteID))
        input.append(contentsOf: bodyContentHash)
        return input
    }

    private static func operationID(from digest: SHA256.Digest) -> SyncOperationID {
        let digestBytes = Array(digest)
        var uuidBytes = Array(digestBytes[0..<16])
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80

        var localCounter: UInt64 = 0
        for byte in digestBytes[16..<24] {
            localCounter = (localCounter << 8) | UInt64(byte)
        }

        return SyncOperationID(
            deviceID: UUID(uuid: uuidTuple(from: uuidBytes)),
            localCounter: localCounter
        )
    }

    private static func appendUInt32BigEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func appendUInt64BigEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func rawUUIDBytes(_ uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15
        ]
    }

    private static func uuidTuple(from bytes: [UInt8]) -> uuid_t {
        (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }

    private static func exactUTF16Matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
