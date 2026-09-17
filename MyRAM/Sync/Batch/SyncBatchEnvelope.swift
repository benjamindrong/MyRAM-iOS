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
        let data = try encoder.encode(envelope)
        MyRAMSyncBenchmarkTelemetry.shared.record(
            .messageEncoded,
            batchID: String(describing: batch.id),
            itemCount: batch.changes.count,
            outcome: "batchSync",
            detail: "schema-v\(envelope.schemaVersion.rawValue)"
        )
        return data
    }

    static func decode(_ data: Data) throws -> SyncBatchEnvelope {
        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: data)
        MyRAMSyncBenchmarkTelemetry.shared.record(
            .messageDecoded,
            batchID: String(describing: envelope.batch.id),
            itemCount: envelope.batch.changes.count,
            outcome: "batchSync",
            detail: "schema-v\(envelope.schemaVersion.rawValue)"
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

struct SyncBatchAcknowledgementOutbox: Equatable, Sendable {
    private var batchIDsByPeerDeviceID: [String: [SyncBatchID]] = [:]

    mutating func enqueue(_ batchID: SyncBatchID, forPeerDeviceID peerDeviceID: String) {
        var pending = batchIDsByPeerDeviceID[peerDeviceID] ?? []
        guard !pending.contains(batchID) else { return }
        pending.append(batchID)
        batchIDsByPeerDeviceID[peerDeviceID] = pending
    }

    func pendingBatchIDs(forPeerDeviceID peerDeviceID: String) -> [SyncBatchID] {
        batchIDsByPeerDeviceID[peerDeviceID] ?? []
    }

    mutating func remove(_ batchID: SyncBatchID, forPeerDeviceID peerDeviceID: String) {
        guard var pending = batchIDsByPeerDeviceID[peerDeviceID] else { return }
        pending.removeAll { $0 == batchID }
        if pending.isEmpty {
            batchIDsByPeerDeviceID.removeValue(forKey: peerDeviceID)
        } else {
            batchIDsByPeerDeviceID[peerDeviceID] = pending
        }
    }
}

/// Session-scoped ownership of a successful transport handoff. Durable queue ownership
/// remains separate: a batch stays queued until the peer acknowledgement removes it.
struct SyncBatchOutstandingDeliveryTracker: Equatable, Sendable {
    private struct Key: Hashable, Sendable {
        let batchID: SyncBatchID
        let peerDeviceID: String
    }

    private var keys: Set<Key> = []

    mutating func reserve(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        keys.insert(Key(batchID: batchID, peerDeviceID: peerDeviceID)).inserted
    }

    func isAwaitingAcknowledgement(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        keys.contains(Key(batchID: batchID, peerDeviceID: peerDeviceID))
    }

    mutating func release(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) {
        keys.remove(Key(batchID: batchID, peerDeviceID: peerDeviceID))
    }

    mutating func release(
        _ batchIDs: Set<SyncBatchID>,
        forPeerDeviceID peerDeviceID: String
    ) {
        keys = keys.filter { key in
            key.peerDeviceID != peerDeviceID || !batchIDs.contains(key.batchID)
        }
    }

    mutating func invalidateSession(forPeerDeviceID peerDeviceID: String) {
        keys = keys.filter { $0.peerDeviceID != peerDeviceID }
    }

    mutating func reset() {
        keys.removeAll()
    }
}

/// Bounds duplicate receiver work while one delivery of the same batch is already queued
/// or executing. It is containment only; sender delivery ownership remains authoritative.
struct SyncBatchPendingReceiveTracker: Equatable, Sendable {
    private struct Key: Hashable, Sendable {
        let batchID: SyncBatchID
        let peerDeviceID: String
    }

    private var keys: Set<Key> = []

    mutating func begin(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        keys.insert(Key(batchID: batchID, peerDeviceID: peerDeviceID)).inserted
    }

    mutating func finish(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) {
        keys.remove(Key(batchID: batchID, peerDeviceID: peerDeviceID))
    }

    func contains(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        keys.contains(Key(batchID: batchID, peerDeviceID: peerDeviceID))
    }
}
