import Foundation

struct SyncBatchUnsentQueue {
    enum EnqueueError: Error, Equatable {
        case capacityExceeded(limit: Int)
    }

    private let limit: Int
    private var batches: [SyncBatch] = []

    init(limit: Int = 100) {
        self.limit = max(0, limit)
    }

    var isEmpty: Bool {
        batches.isEmpty
    }

    var pendingBatches: [SyncBatch] {
        batches
    }

    var first: SyncBatch? {
        batches.first
    }

    mutating func replacePendingBatches(_ batches: [SyncBatch]) {
        self.batches = Array(batches.prefix(limit))
    }

    func contains(_ batchID: SyncBatchID) -> Bool {
        batches.contains { $0.id == batchID }
    }

    @discardableResult
    mutating func enqueue(_ batch: SyncBatch) -> Bool {
        // Batch IDs are stable, so retries should retain one copy of each offline batch.
        guard limit > 0, !batches.contains(where: { $0.id == batch.id }) else { return false }
        batches.append(batch)
        if batches.count > limit {
            batches.removeFirst(batches.count - limit)
        }
        return true
    }

    @discardableResult
    mutating func enqueuePreservingExisting(_ batch: SyncBatch) throws -> Bool {
        guard limit > 0 else { throw EnqueueError.capacityExceeded(limit: limit) }
        guard !batches.contains(where: { $0.id == batch.id }) else { return false }
        guard batches.count < limit else { throw EnqueueError.capacityExceeded(limit: limit) }

        batches.append(batch)
        return true
    }

    @discardableResult
    mutating func removeAll(withIDs ids: Set<SyncBatchID>) -> Bool {
        guard !ids.isEmpty else { return false }
        let originalCount = batches.count
        batches.removeAll { ids.contains($0.id) }
        return batches.count != originalCount
    }

    @discardableResult
    mutating func remove(_ batchID: SyncBatchID) -> Bool {
        removeAll(withIDs: [batchID])
    }

    mutating func drain() -> [SyncBatch] {
        let pending = batches
        batches.removeAll()
        return pending
    }
}
