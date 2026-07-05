import Foundation
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

enum TestOptionalReplacement<Value> {
    case preserve
    case replace(Value?)

    func resolve(_ current: Value?) -> Value? {
        switch self {
        case .preserve:
            return current
        case .replace(let value):
            return value
        }
    }
}

extension OperationIdentityPayload {
    func replacingForTest(
        version: Int? = nil,
        batchID: UUID? = nil,
        originDeviceID: UUID? = nil,
        operationIndex: Int? = nil,
        operationKind: String? = nil,
        canonicalReplayKey: CanonicalReplayKeyPayload? = nil
    ) -> OperationIdentityPayload {
        OperationIdentityPayload(
            version: version ?? self.version,
            batchID: batchID ?? UUID(uuidString: batchIDLowercase)!,
            originDeviceID: originDeviceID ?? UUID(uuidString: originDeviceIDLowercase)!,
            operationIndex: operationIndex ?? self.operationIndex,
            operationKind: operationKind ?? self.operationKind,
            canonicalReplayKey: canonicalReplayKey ?? self.canonicalReplayKey
        )
    }

    func replacingRawStringsForTest(
        batchIDLowercase: String? = nil,
        originDeviceIDLowercase: String? = nil,
        canonicalReplayKeyBatchIDLowercase: String? = nil,
        canonicalReplayKeyOriginDeviceIDLowercase: String? = nil
    ) throws -> OperationIdentityPayload {
        let rawReplayKey = RawCanonicalReplayKeyPayload(
            version: canonicalReplayKey.version,
            modifiedAtBitPattern: canonicalReplayKey.modifiedAtBitPattern,
            originDeviceIDLowercase: canonicalReplayKeyOriginDeviceIDLowercase ?? canonicalReplayKey.originDeviceIDLowercase,
            batchOrderKind: canonicalReplayKey.batchOrderKind,
            legacyCreatedAtBitPattern: canonicalReplayKey.legacyCreatedAtBitPattern,
            sequence: canonicalReplayKey.sequence,
            batchIDLowercase: canonicalReplayKeyBatchIDLowercase ?? canonicalReplayKey.batchIDLowercase,
            operationIndex: canonicalReplayKey.operationIndex
        )
        let rawIdentity = RawOperationIdentityPayload(
            version: version,
            batchIDLowercase: batchIDLowercase ?? self.batchIDLowercase,
            originDeviceIDLowercase: originDeviceIDLowercase ?? self.originDeviceIDLowercase,
            operationIndex: operationIndex,
            operationKind: operationKind,
            canonicalReplayKey: rawReplayKey
        )
        return try SyncConvergenceStableEncoding.decode(
            OperationIdentityPayload.self,
            from: SyncConvergenceStableEncoding.encode(rawIdentity)
        )
    }
}

extension CanonicalReplayKeyPayload {
    func replacingForTest(
        version: Int? = nil,
        modifiedAtBitPattern: UInt64? = nil,
        originDeviceID: UUID? = nil,
        batchOrderKind: BatchOrderKind? = nil,
        legacyCreatedAtBitPattern: TestOptionalReplacement<UInt64> = .preserve,
        sequence: TestOptionalReplacement<UInt64> = .preserve,
        batchID: UUID? = nil,
        operationIndex: Int? = nil
    ) -> CanonicalReplayKeyPayload {
        CanonicalReplayKeyPayload(
            version: version ?? self.version,
            modifiedAtBitPattern: modifiedAtBitPattern ?? self.modifiedAtBitPattern,
            originDeviceIDLowercase: (originDeviceID ?? UUID(uuidString: originDeviceIDLowercase)!).uuidString.lowercased(),
            batchOrderKind: batchOrderKind ?? self.batchOrderKind,
            legacyCreatedAtBitPattern: legacyCreatedAtBitPattern.resolve(self.legacyCreatedAtBitPattern),
            sequence: sequence.resolve(self.sequence),
            batchIDLowercase: (batchID ?? UUID(uuidString: batchIDLowercase)!).uuidString.lowercased(),
            operationIndex: operationIndex ?? self.operationIndex
        )
    }
}

private struct RawOperationIdentityPayload: Codable {
    let version: Int
    let batchIDLowercase: String
    let originDeviceIDLowercase: String
    let operationIndex: Int
    let operationKind: String
    let canonicalReplayKey: RawCanonicalReplayKeyPayload
}

private struct RawCanonicalReplayKeyPayload: Codable {
    let version: Int
    let modifiedAtBitPattern: UInt64
    let originDeviceIDLowercase: String
    let batchOrderKind: CanonicalReplayKeyPayload.BatchOrderKind
    let legacyCreatedAtBitPattern: UInt64?
    let sequence: UInt64?
    let batchIDLowercase: String
    let operationIndex: Int
}
