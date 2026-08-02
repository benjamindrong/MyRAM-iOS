import Foundation

enum MultipeerSyncMessageKind: String, Codable, Equatable, Sendable {
    case legacySyncEnvelope = "myram.legacySyncEnvelope.v1"
    case batchSync = "myram.batchSync.v1"
    case batchAcknowledgement = "myram.batchAcknowledgement.v1"
}

struct MultipeerSyncMessageEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let kind: MultipeerSyncMessageKind
    let schemaVersion: Int
    let payload: Data

    init(
        kind: MultipeerSyncMessageKind,
        schemaVersion: Int = Self.currentSchemaVersion,
        payload: Data
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    var canDecodeWithCurrentSchema: Bool {
        schemaVersion <= Self.currentSchemaVersion
    }
}

enum MultipeerSyncMessageCoding {
    static func encodeBatch(_ batch: SyncBatch) throws -> Data {
        try SyncBatchAnchoredPayloadPolicy.validateTransportEncode(batch)
        return try encode(
            kind: .batchSync,
            payload: SyncBatchEnvelopeCodec.encode(batch: batch)
        )
    }

    /// Source-compatible bridge for existing hosts and legacy tests. Production
    /// envelopes are representation-derived and therefore use the exact codec.
    static func encodeBatchEnvelope(_ envelope: SyncBatchEnvelope) throws -> Data {
        try SyncBatchAnchoredPayloadPolicy.validateTransportEncode(envelope.batch)

        let payload: Data
        if envelope.canDecodeWithCurrentSchema {
            payload = try SyncBatchEnvelopeCodec.encode(batch: envelope.batch)
        } else {
            // Retains the pre-MYR-174 compatibility-fixture path until existing
            // tests migrate to raw fixture bytes. Production never constructs this.
            payload = try JSONEncoder().encode(envelope)
        }

        return try encode(kind: .batchSync, payload: payload)
    }

    static func decodeBatchPayload(_ payload: Data) throws -> SyncBatchEnvelope {
        try SyncBatchEnvelopeCodec.decode(payload)
    }

    static func encode(kind: MultipeerSyncMessageKind, payload: Data) throws -> Data {
        let envelope = MultipeerSyncMessageEnvelope(kind: kind, payload: payload)
        return try JSONEncoder().encode(envelope)
    }

    static func decodeMessage(from data: Data) throws -> MultipeerSyncMessageEnvelope {
        try JSONDecoder().decode(MultipeerSyncMessageEnvelope.self, from: data)
    }
}
