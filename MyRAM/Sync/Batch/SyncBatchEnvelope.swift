import Foundation

struct SyncBatchEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let batch: SyncBatch

    init(schemaVersion: Int = Self.currentSchemaVersion, batch: SyncBatch) {
        self.schemaVersion = schemaVersion
        self.batch = batch
    }

    var canDecodeWithCurrentSchema: Bool {
        schemaVersion <= Self.currentSchemaVersion
    }
}

/// Transport-level confirmation that a peer has durably captured a batch. It says
/// nothing about whether the batch has been converged/applied yet — only that the
/// sender no longer needs to keep retrying redelivery of these bytes.
struct SyncBatchAcknowledgement: Codable, Equatable, Sendable {
    let batchID: SyncBatchID
}
