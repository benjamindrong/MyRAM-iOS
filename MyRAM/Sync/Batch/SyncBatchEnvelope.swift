import Foundation

enum SyncBatchEnvelopeSchemaVersion: Int, Codable, CaseIterable, Hashable, Sendable {
    case v1 = 1
    case v2 = 2
}

enum SyncBatchEnvelopeError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case mixedBodyOperationRepresentations
    case representationMismatch(
        schema: SyncBatchEnvelopeSchemaVersion,
        representation: SyncBatchBodyOperationRepresentation
    )
}

struct SyncBatchEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: SyncBatchEnvelopeSchemaVersion
    let batch: SyncBatch

    fileprivate init(batch: SyncBatch) throws {
        switch batch.bodyOperationRepresentation {
        case .none, .legacy:
            schemaVersion = .v1
        case .anchored:
            schemaVersion = .v2
        case .mixed:
            throw SyncBatchEnvelopeError.mixedBodyOperationRepresentations
        }
        self.batch = batch
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case batch
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion.rawValue, forKey: .schemaVersion)
        try container.encode(batch, forKey: .batch)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard let decodedSchemaVersion = SyncBatchEnvelopeSchemaVersion(
            rawValue: rawSchemaVersion
        ) else {
            throw SyncBatchEnvelopeError.unsupportedSchemaVersion(rawSchemaVersion)
        }

        let decodedBatch = try container.decode(SyncBatch.self, forKey: .batch)
        try Self.validateExact(
            schema: decodedSchemaVersion,
            representation: decodedBatch.bodyOperationRepresentation
        )

        schemaVersion = decodedSchemaVersion
        batch = decodedBatch
    }

    private static func validateExact(
        schema: SyncBatchEnvelopeSchemaVersion,
        representation: SyncBatchBodyOperationRepresentation
    ) throws {
        if representation == .mixed {
            throw SyncBatchEnvelopeError.mixedBodyOperationRepresentations
        }

        switch (schema, representation) {
        case (.v1, .none), (.v1, .legacy), (.v2, .anchored):
            return
        default:
            throw SyncBatchEnvelopeError.representationMismatch(
                schema: schema,
                representation: representation
            )
        }
    }
}

enum SyncBatchEnvelopeCodec {
    static func encode(batch: SyncBatch) throws -> Data {
        let envelope = try SyncBatchEnvelope(batch: batch)

        let encoder = JSONEncoder()
        if envelope.schemaVersion == .v2 {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> SyncBatchEnvelope {
        try JSONDecoder().decode(SyncBatchEnvelope.self, from: data)
    }
}

/// Transport-level confirmation that a peer has durably captured a batch. It says
/// nothing about whether the batch has been converged/applied yet — only that the
/// sender no longer needs to keep retrying redelivery of these bytes.
struct SyncBatchAcknowledgement: Codable, Equatable, Sendable {
    let batchID: SyncBatchID
}
