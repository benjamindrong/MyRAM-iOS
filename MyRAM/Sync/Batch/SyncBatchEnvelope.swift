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

/// Confirmation that the remote peer completed convergence for a durable batch.
/// The sender keeps its durable copy until this acknowledgement is received.
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

/// Session-scoped ownership of one transport handoff for a durable batch and stable peer.
/// Reservations are tokenized so a stale send completion from an invalidated session cannot
/// release ownership established by a later reconnect.
struct SyncBatchOutstandingDeliveryTracker: Equatable, Sendable {
    struct Reservation: Equatable, Sendable {
        let batchID: SyncBatchID
        let peerDeviceID: String
        fileprivate let token: UUID
    }

    private struct Key: Hashable, Sendable {
        let batchID: SyncBatchID
        let peerDeviceID: String
    }

    private var tokenByKey: [Key: UUID] = [:]

    mutating func reserve(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Reservation? {
        let key = Key(batchID: batchID, peerDeviceID: peerDeviceID)
        guard tokenByKey[key] == nil else { return nil }
        let token = UUID()
        tokenByKey[key] = token
        return Reservation(
            batchID: batchID,
            peerDeviceID: peerDeviceID,
            token: token
        )
    }

    func isAwaitingAcknowledgement(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) -> Bool {
        tokenByKey[Key(batchID: batchID, peerDeviceID: peerDeviceID)] != nil
    }

    mutating func release(_ reservation: Reservation) {
        let key = Key(
            batchID: reservation.batchID,
            peerDeviceID: reservation.peerDeviceID
        )
        guard tokenByKey[key] == reservation.token else { return }
        tokenByKey.removeValue(forKey: key)
    }

    mutating func release(
        _ batchID: SyncBatchID,
        forPeerDeviceID peerDeviceID: String
    ) {
        tokenByKey.removeValue(
            forKey: Key(batchID: batchID, peerDeviceID: peerDeviceID)
        )
    }

    mutating func release(_ batchID: SyncBatchID) {
        tokenByKey = tokenByKey.filter { $0.key.batchID != batchID }
    }

    mutating func release(_ batchIDs: Set<SyncBatchID>) {
        tokenByKey = tokenByKey.filter { !batchIDs.contains($0.key.batchID) }
    }

    mutating func release(
        _ batchIDs: Set<SyncBatchID>,
        forPeerDeviceID peerDeviceID: String
    ) {
        tokenByKey = tokenByKey.filter { entry in
            entry.key.peerDeviceID != peerDeviceID || !batchIDs.contains(entry.key.batchID)
        }
    }

    mutating func invalidateSession(forPeerDeviceID peerDeviceID: String) {
        tokenByKey = tokenByKey.filter { $0.key.peerDeviceID != peerDeviceID }
    }

    mutating func reset() {
        tokenByKey.removeAll()
    }
}

/// Bounds duplicate receiver work while one delivery of the same batch is already queued
/// or executing. Batch identity, not transient peer/session identity, owns convergence work.
struct SyncBatchPendingReceiveTracker: Equatable, Sendable {
    private var batchIDs: Set<SyncBatchID> = []

    mutating func begin(_ batchID: SyncBatchID) -> Bool {
        batchIDs.insert(batchID).inserted
    }

    mutating func finish(_ batchID: SyncBatchID) {
        batchIDs.remove(batchID)
    }

    func contains(_ batchID: SyncBatchID) -> Bool {
        batchIDs.contains(batchID)
    }
}
