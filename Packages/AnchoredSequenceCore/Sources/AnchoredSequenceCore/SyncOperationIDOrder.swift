import Foundation

enum SyncOperationIDRawUUIDBytes {
    /// UUID tuple storage exposes the RFC 4122 bytes without string formatting semantics.
    static func bytes(of uuid: UUID) -> [UInt8] {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

enum SyncOperationIDSameAnchorSiblingOrder {
    static func isOrderedBefore(
        _ lhs: SyncOperationID,
        _ rhs: SyncOperationID
    ) -> Bool {
        if lhs.localCounter != rhs.localCounter {
            return lhs.localCounter > rhs.localCounter
        }

        let lhsBytes = SyncOperationIDRawUUIDBytes.bytes(of: lhs.deviceID)
        let rhsBytes = SyncOperationIDRawUUIDBytes.bytes(of: rhs.deviceID)
        guard lhsBytes != rhsBytes else { return false }
        return lhsBytes.lexicographicallyPrecedes(rhsBytes)
    }

    /// Every index must be valid for `runs`; duplicate operation IDs are rejected earlier.
    static func orderedRunIndices(
        _ indices: [Int],
        runs: [SyncTextSequenceRun]
    ) -> [Int] {
        indices.sorted {
            isOrderedBefore(runs[$0].operationID, runs[$1].operationID)
        }
    }
}
