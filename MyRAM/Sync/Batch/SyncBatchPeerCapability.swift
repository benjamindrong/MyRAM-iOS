import Foundation

struct SyncBatchPeerCapability: Equatable, Sendable {
    let schemas: Set<SyncBatchEnvelopeSchemaVersion>

    init(schemas: Set<SyncBatchEnvelopeSchemaVersion>) throws {
        guard !schemas.isEmpty else {
            throw SyncBatchPeerCapabilityCodecError.emptyCapability
        }
        self.schemas = schemas
    }

    fileprivate init(uncheckedSchemas: Set<SyncBatchEnvelopeSchemaVersion>) {
        schemas = uncheckedSchemas
    }

    static let v1Only = SyncBatchPeerCapability(uncheckedSchemas: [.v1])
    static let v2Only = SyncBatchPeerCapability(uncheckedSchemas: [.v2])
    static let v1AndV2 = SyncBatchPeerCapability(uncheckedSchemas: [.v1, .v2])

    var supportsV1: Bool {
        schemas.contains(.v1)
    }

    var supportsV2: Bool {
        schemas.contains(.v2)
    }

    fileprivate func intersecting(
        _ other: SyncBatchPeerCapability
    ) -> SyncBatchPeerCapability {
        SyncBatchPeerCapability(
            uncheckedSchemas: schemas.intersection(other.schemas)
        )
    }
}

enum SyncBatchPeerCapabilityCodecError: Error, Equatable, Sendable {
    case emptyCapability
    case emptyToken
    case duplicateVersion(Int)
    case unsupportedVersion(Int)
    case nonCanonicalInteger(String)
    case nonAscendingVersions
    case malformedUTF8
}

enum SyncBatchPeerCapabilityCodec {
    static let discoveryInfoKey = "batch-schemas"

    static var productionCapability: SyncBatchPeerCapability {
        SyncBatchAnchoredPayloadCapability.isEnabled ? .v1AndV2 : .v1Only
    }

    static var productionDiscoveryInfo: [String: String] {
        [discoveryInfoKey: encode(productionCapability)]
    }

    static var productionInvitationContext: Data {
        Data(encode(productionCapability).utf8)
    }

    static func encode(_ capability: SyncBatchPeerCapability) -> String {
        capability.schemas
            .map(\.rawValue)
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }

    static func decode(_ rawValue: String) throws -> SyncBatchPeerCapability {
        guard !rawValue.isEmpty else {
            throw SyncBatchPeerCapabilityCodecError.emptyCapability
        }

        let tokens = rawValue.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        var schemas: Set<SyncBatchEnvelopeSchemaVersion> = []
        var previousRawValue: Int?

        for rawToken in tokens {
            let token = String(rawToken)
            guard !token.isEmpty else {
                throw SyncBatchPeerCapabilityCodecError.emptyToken
            }
            guard isCanonicalPositiveInteger(token),
                  let integerValue = Int(token) else {
                throw SyncBatchPeerCapabilityCodecError.nonCanonicalInteger(token)
            }
            guard let schema = SyncBatchEnvelopeSchemaVersion(
                rawValue: integerValue
            ) else {
                throw SyncBatchPeerCapabilityCodecError.unsupportedVersion(
                    integerValue
                )
            }

            if let previousRawValue {
                if integerValue == previousRawValue {
                    throw SyncBatchPeerCapabilityCodecError.duplicateVersion(
                        integerValue
                    )
                }
                if integerValue < previousRawValue {
                    throw SyncBatchPeerCapabilityCodecError.nonAscendingVersions
                }
            }

            guard schemas.insert(schema).inserted else {
                throw SyncBatchPeerCapabilityCodecError.duplicateVersion(
                    integerValue
                )
            }
            previousRawValue = integerValue
        }

        return try SyncBatchPeerCapability(schemas: schemas)
    }

    static func decodeInvitationContext(
        _ data: Data
    ) throws -> SyncBatchPeerCapability {
        guard let rawValue = String(data: data, encoding: .utf8) else {
            throw SyncBatchPeerCapabilityCodecError.malformedUTF8
        }
        return try decode(rawValue)
    }

    private static func isCanonicalPositiveInteger(_ value: String) -> Bool {
        let zero = UInt8(ascii: "0")
        let nine = UInt8(ascii: "9")
        guard let first = value.utf8.first,
              first != zero,
              value.utf8.allSatisfy({ $0 >= zero && $0 <= nine }) else {
            return false
        }
        return true
    }
}

struct SyncBatchPeerCapabilityRegistry: Sendable {
    enum EvidenceSource: Hashable, Sendable {
        case discoveryInformation
        case invitationContext
    }

    enum NormalizedEvidence: Equatable, Sendable {
        case valid(SyncBatchPeerCapability)
        case fallbackV1

        var capability: SyncBatchPeerCapability {
            switch self {
            case .valid(let capability):
                capability
            case .fallbackV1:
                .v1Only
            }
        }
    }

    private var evidenceByPeerDeviceID:
        [String: [EvidenceSource: NormalizedEvidence]] = [:]

    mutating func recordDiscoveryValue(
        _ value: String?,
        forPeerDeviceID peerDeviceID: String
    ) {
        let evidence: NormalizedEvidence
        if let value,
           let capability = try? SyncBatchPeerCapabilityCodec.decode(value) {
            evidence = .valid(capability)
        } else {
            evidence = .fallbackV1
        }
        record(
            evidence,
            source: .discoveryInformation,
            forPeerDeviceID: peerDeviceID
        )
    }

    mutating func recordInvitationContext(
        _ context: Data?,
        forPeerDeviceID peerDeviceID: String
    ) {
        let evidence: NormalizedEvidence
        if let context,
           let capability = try? SyncBatchPeerCapabilityCodec
            .decodeInvitationContext(context) {
            evidence = .valid(capability)
        } else {
            evidence = .fallbackV1
        }
        record(
            evidence,
            source: .invitationContext,
            forPeerDeviceID: peerDeviceID
        )
    }

    mutating func clearEvidence(forPeerDeviceID peerDeviceID: String) {
        evidenceByPeerDeviceID.removeValue(forKey: peerDeviceID)
    }

    func effectiveCapability(
        forPeerDeviceID peerDeviceID: String
    ) -> SyncBatchPeerCapability {
        guard let evidence = evidenceByPeerDeviceID[peerDeviceID],
              let first = evidence.values.first else {
            return .v1Only
        }

        return evidence.values.dropFirst().reduce(first.capability) {
            $0.intersecting($1.capability)
        }
    }

    func hasExplicitCurrentSessionV2Support(
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        effectiveCapability(forPeerDeviceID: peerDeviceID).supportsV2
    }

    func evidence(
        from source: EvidenceSource,
        forPeerDeviceID peerDeviceID: String
    ) -> NormalizedEvidence? {
        evidenceByPeerDeviceID[peerDeviceID]?[source]
    }

    private mutating func record(
        _ evidence: NormalizedEvidence,
        source: EvidenceSource,
        forPeerDeviceID peerDeviceID: String
    ) {
        evidenceByPeerDeviceID[peerDeviceID, default: [:]][source] = evidence
    }
}
