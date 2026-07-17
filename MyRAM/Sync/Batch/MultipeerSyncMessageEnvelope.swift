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
    static func encodeBatchEnvelope(_ envelope: SyncBatchEnvelope) throws -> Data {
        try encode(kind: .batchSync, payload: JSONEncoder().encode(envelope))
    }

    static func encode(kind: MultipeerSyncMessageKind, payload: Data) throws -> Data {
        let envelope = MultipeerSyncMessageEnvelope(kind: kind, payload: payload)
        return try JSONEncoder().encode(envelope)
    }

    static func decodeMessage(from data: Data) throws -> MultipeerSyncMessageEnvelope {
        try JSONDecoder().decode(MultipeerSyncMessageEnvelope.self, from: data)
    }

}
