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
