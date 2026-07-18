import Foundation

enum SyncSequenceIdentityError: Error, Equatable, Sendable {
    case malformedDeviceID(String)
    case negativeElementOffset(Int)
    case negativeRunLength(Int)
    case malformedEncoding
}

private enum SyncSequenceIdentityValidation {
    /// This limited validation duplication intentionally keeps sequence identity
    /// independent from convergence-specific types and migration errors.
    static func canonicalUUID(from value: String) throws -> UUID {
        guard
            let uuid = UUID(uuidString: value),
            value == uuid.uuidString.lowercased()
        else {
            throw SyncSequenceIdentityError.malformedDeviceID(value)
        }

        return uuid
    }
}

protocol SyncSequenceStableCodable: Codable {}

extension SyncSequenceStableCodable {
    /// Returns deterministic data for tests, diagnostics, and identity hashing.
    ///
    /// This is not the anchored transport representation. Anchored payloads must
    /// encode operation-owned runs, using one operation ID plus ranges or lengths,
    /// never one encoded object per UTF-16 unit.
    func stableEncodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes stable diagnostic or hashing data while preserving semantic errors.
    static func decodeStableData(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as SyncSequenceIdentityError {
            throw error
        } catch {
            throw SyncSequenceIdentityError.malformedEncoding
        }
    }
}

/// Identifies one operation at capture time.
///
/// `deviceID` remains stable for one installation identity. Its counters must be
/// reserved monotonically and never reused. Failed reservations may leave gaps.
/// Resetting the counter requires a new device ID, and reinstallation generates a
/// new random device ID instead of restoring an old identity with a reset counter.
/// The identity remains unchanged across retries, rebundling, retransmission, or a
/// different batch operation index; batch and replay evidence are intentionally
/// not part of this capture-time identity.
/// Reservation and enforcement belong to a later anchored-sequence subtask.
struct SyncOperationID: Equatable, Hashable, Sendable {
    let deviceID: UUID
    let localCounter: UInt64
}

extension SyncOperationID: Codable {
    private enum CodingKeys: String, CodingKey {
        case deviceID
        case localCounter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID.uuidString.lowercased(), forKey: .deviceID)
        try container.encode(localCounter, forKey: .localCounter)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDeviceID = try container.decode(String.self, forKey: .deviceID)
        let deviceID = try SyncSequenceIdentityValidation.canonicalUUID(from: encodedDeviceID)
        let localCounter = try container.decode(UInt64.self, forKey: .localCounter)
        self.init(deviceID: deviceID, localCounter: localCounter)
    }
}

extension SyncOperationID: SyncSequenceStableCodable {}

/// Identifies one UTF-16 code unit owned by an inserted operation.
///
/// This identity records element ownership and later tie-breaking identity; it is
/// not an insertion anchor. Placement requires a later left-origin reference or a
/// beginning-of-note sentinel. Ordering must compare `(operationID, elementOffset)`
/// structurally because counters are reserved per operation, not per element. Code
/// must never flatten the offset into `localCounter` or assume a contiguous element
/// clock. Later structural mutations must also preserve valid UTF-16 boundaries and
/// must not split surrogate pairs.
struct SyncTextElementID: Equatable, Hashable, Sendable {
    let operationID: SyncOperationID
    let elementOffset: Int

    init(
        operationID: SyncOperationID,
        elementOffset: Int
    ) throws {
        guard elementOffset >= 0 else {
            throw SyncSequenceIdentityError.negativeElementOffset(elementOffset)
        }

        self.operationID = operationID
        self.elementOffset = elementOffset
    }

    /// Constructs an identity only after the caller has proven the run bounds.
    fileprivate init(
        unchecked operationID: SyncOperationID,
        offset: Int
    ) {
        self.operationID = operationID
        self.elementOffset = offset
    }
}

extension SyncTextElementID: Codable {
    private enum CodingKeys: String, CodingKey {
        case operationID
        case elementOffset
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(elementOffset, forKey: .elementOffset)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operationID = try container.decode(SyncOperationID.self, forKey: .operationID)
        let elementOffset = try container.decode(Int.self, forKey: .elementOffset)
        try self.init(operationID: operationID, elementOffset: elementOffset)
    }
}

extension SyncTextElementID: SyncSequenceStableCodable {}

/// A non-persistent, lazily derived view of an operation-owned UTF-16 run.
struct SyncTextElementIDRun: RandomAccessCollection, Sendable {
    typealias Index = Int
    typealias Element = SyncTextElementID

    let operationID: SyncOperationID
    let utf16Count: Int

    var startIndex: Int { 0 }
    var endIndex: Int { utf16Count }

    fileprivate init(
        operationID: SyncOperationID,
        trustedUTF16Count: Int
    ) {
        self.operationID = operationID
        self.utf16Count = trustedUTF16Count
    }

    init(
        operationID: SyncOperationID,
        externallySourcedUTF16Count: Int
    ) throws {
        guard externallySourcedUTF16Count >= 0 else {
            throw SyncSequenceIdentityError.negativeRunLength(externallySourcedUTF16Count)
        }

        self.operationID = operationID
        self.utf16Count = externallySourcedUTF16Count
    }

    subscript(index: Int) -> SyncTextElementID {
        precondition(
            index >= startIndex && index < endIndex,
            "SyncTextElementIDRun index out of bounds"
        )

        return SyncTextElementID(
            unchecked: operationID,
            offset: index
        )
    }
}

extension SyncOperationID {
    /// Derives stable element identities without allocating a per-element array.
    func elementIDs(for text: String) -> SyncTextElementIDRun {
        SyncTextElementIDRun(
            operationID: self,
            trustedUTF16Count: text.utf16.count
        )
    }
}
