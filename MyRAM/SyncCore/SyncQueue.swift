import Foundation

public actor SyncQueue {
    private var pendingChanges: [SyncChange] = []
    private var appliedChangeIDs: Set<UUID> = []

    public init() {}

    public func enqueue(_ change: SyncChange) {
        if let existingIndex = pendingChanges.firstIndex(where: { $0.syncTarget == change.syncTarget }) {
            pendingChanges[existingIndex] = change
            return
        }
        pendingChanges.append(change)
    }

    public func enqueue(_ changes: [SyncChange]) {
        for change in changes {
            enqueue(change)
        }
    }

    public func pendingBatch(limit: Int = 100) -> [SyncChange] {
        Array(pendingChanges.prefix(limit))
    }

    public func markSent(_ sentChanges: [SyncChange]) {
        let sentIDs = Set(sentChanges.map(\.id))
        pendingChanges.removeAll { sentIDs.contains($0.id) }
    }

    public func hasApplied(_ changeID: UUID) -> Bool {
        appliedChangeIDs.contains(changeID)
    }

    public func markApplied(_ changeID: UUID) {
        appliedChangeIDs.insert(changeID)
    }

    public func pendingCount() -> Int {
        pendingChanges.count
    }
}

private extension SyncChange {
    var syncTarget: SyncTarget {
        SyncTarget(entityType: entityType, entityID: entityID)
    }
}

private struct SyncTarget: Hashable {
    let entityType: SyncEntityType
    let entityID: String
}
