import Foundation

public protocol SyncStore: AnyObject, Sendable {
    func record(for entityType: SyncEntityType, entityID: String) async -> SyncRecord?
    func apply(_ change: SyncChange) async -> Bool
    func allRecords() async -> [SyncRecord]
}

public actor InMemorySyncStore: SyncStore {
    private var records: [RecordKey: SyncRecord] = [:]

    public init(seedRecords: [SyncRecord] = []) {
        for record in seedRecords {
            records[RecordKey(type: record.entityType, id: record.entityID)] = record
        }
    }

    public func record(for entityType: SyncEntityType, entityID: String) -> SyncRecord? {
        records[RecordKey(type: entityType, id: entityID)]
    }

    public func apply(_ change: SyncChange) -> Bool {
        let key = RecordKey(type: change.entityType, id: change.entityID)

        if let existing = records[key], existing.updatedAt > change.updatedAt {
            return false
        }

        records[key] = SyncRecord(
            entityType: change.entityType,
            entityID: change.entityID,
            payload: change.payload,
            updatedAt: change.updatedAt,
            isDeleted: change.operation == .delete
        )
        return true
    }

    public func allRecords() -> [SyncRecord] {
        records.values.sorted {
            if $0.entityType.rawValue == $1.entityType.rawValue {
                return $0.entityID < $1.entityID
            }
            return $0.entityType.rawValue < $1.entityType.rawValue
        }
    }
}

private struct RecordKey: Hashable {
    let type: SyncEntityType
    let id: String
}
