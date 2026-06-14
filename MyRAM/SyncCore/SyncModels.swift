import Foundation

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case item
    case collection
    case marker
}

public enum SyncOperation: String, Codable, Sendable {
    case upsert
    case delete
}

public struct SyncChange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entityType: SyncEntityType
    public let entityID: String
    public let operation: SyncOperation
    public let payload: Data
    public let updatedAt: Date
    public let originDeviceID: String

    public init(
        id: UUID = UUID(),
        entityType: SyncEntityType,
        entityID: String,
        operation: SyncOperation,
        payload: Data,
        updatedAt: Date,
        originDeviceID: String
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payload = payload
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
    }
}

public struct SyncEnvelope: Codable, Equatable, Sendable {
    public let senderDeviceID: String
    public let sentAt: Date
    public let changes: [SyncChange]

    public init(senderDeviceID: String, sentAt: Date = Date(), changes: [SyncChange]) {
        self.senderDeviceID = senderDeviceID
        self.sentAt = sentAt
        self.changes = changes
    }
}

public struct SyncRecord: Equatable, Sendable {
    public let entityType: SyncEntityType
    public let entityID: String
    public var payload: Data
    public var updatedAt: Date
    public var isDeleted: Bool

    public init(
        entityType: SyncEntityType,
        entityID: String,
        payload: Data,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.entityType = entityType
        self.entityID = entityID
        self.payload = payload
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

public struct SyncApplyResult: Equatable, Sendable {
    public var appliedChangeIDs: [UUID]
    public var ignoredDuplicateIDs: [UUID]
    public var ignoredStaleIDs: [UUID]

    public init(
        appliedChangeIDs: [UUID] = [],
        ignoredDuplicateIDs: [UUID] = [],
        ignoredStaleIDs: [UUID] = []
    ) {
        self.appliedChangeIDs = appliedChangeIDs
        self.ignoredDuplicateIDs = ignoredDuplicateIDs
        self.ignoredStaleIDs = ignoredStaleIDs
    }
}
