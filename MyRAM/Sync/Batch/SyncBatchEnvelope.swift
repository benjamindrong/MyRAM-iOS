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
    /// Retained for source compatibility with legacy V1 tests. Supported wire
    /// versions are represented by `SyncBatchEnvelopeSchemaVersion`.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let batch: SyncBatch

    /// Production construction derives the wire schema from the batch body
    /// representation. Callers cannot select a schema through this initializer.
    init(batch: SyncBatch) {
        switch batch.bodyOperationRepresentation {
        case .none, .legacy:
            schemaVersion = SyncBatchEnvelopeSchemaVersion.v1.rawValue
        case .anchored:
            schemaVersion = SyncBatchEnvelopeSchemaVersion.v2.rawValue
        case .mixed:
            preconditionFailure("Mixed body-operation representations cannot form an envelope")
        }
        self.batch = batch
    }

    /// Legacy fixture construction retained while existing compatibility tests are
    /// migrated. Production callers must use `init(batch:)` or the codec.
    @available(*, deprecated, message: "Legacy compatibility fixture construction only")
    init(schemaVersion: Int, batch: SyncBatch) {
        self.schemaVersion = schemaVersion
        self.batch = batch
    }

    var canDecodeWithCurrentSchema: Bool {
        (try? Self.validateExact(schemaVersion: schemaVersion, batch: batch)) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case batch
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(batch, forKey: .batch)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard SyncBatchEnvelopeSchemaVersion(rawValue: rawSchemaVersion) != nil else {
            throw SyncBatchEnvelopeError.unsupportedSchemaVersion(rawSchemaVersion)
        }

        schemaVersion = rawSchemaVersion
        batch = try container.decode(SyncBatch.self, forKey: .batch)
    }

    fileprivate static func validateExact(
        schemaVersion rawSchemaVersion: Int,
        batch: SyncBatch
    ) throws {
        guard let schemaVersion = SyncBatchEnvelopeSchemaVersion(rawValue: rawSchemaVersion) else {
            throw SyncBatchEnvelopeError.unsupportedSchemaVersion(rawSchemaVersion)
        }

        let representation = batch.bodyOperationRepresentation
        if representation == .mixed {
            throw SyncBatchEnvelopeError.mixedBodyOperationRepresentations
        }

        switch (schemaVersion, representation) {
        case (.v1, .none), (.v1, .legacy), (.v2, .anchored):
            return
        default:
            throw SyncBatchEnvelopeError.representationMismatch(
                schema: schemaVersion,
                representation: representation
            )
        }
    }
}

enum SyncBatchEnvelopeCodec {
    static func encode(batch: SyncBatch) throws -> Data {
        let envelope: SyncBatchEnvelope
        switch batch.bodyOperationRepresentation {
        case .none, .legacy, .anchored:
            envelope = SyncBatchEnvelope(batch: batch)
        case .mixed:
            throw SyncBatchEnvelopeError.mixedBodyOperationRepresentations
        }

        let encoder = JSONEncoder()
        if envelope.schemaVersion == SyncBatchEnvelopeSchemaVersion.v2.rawValue {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> SyncBatchEnvelope {
        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: data)
        try SyncBatchEnvelope.validateExact(
            schemaVersion: envelope.schemaVersion,
            batch: envelope.batch
        )
        return envelope
    }
}

/// Transport-level confirmation that a peer has durably captured a batch. It says
/// nothing about whether the batch has been converged/applied yet — only that the
/// sender no longer needs to keep retrying redelivery of these bytes.
struct SyncBatchAcknowledgement: Codable, Equatable, Sendable {
    let batchID: SyncBatchID
}
