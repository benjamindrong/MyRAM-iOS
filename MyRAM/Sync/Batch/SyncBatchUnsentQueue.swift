import Foundation

struct SyncBatchUnsentQueue {
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
    mutating func removeAll(withIDs ids: Set<SyncBatchID>) -> Bool {
        guard !ids.isEmpty else { return false }
        let originalCount = batches.count
        batches.removeAll { ids.contains($0.id) }
        return batches.count != originalCount
    }

    mutating func drain() -> [SyncBatch] {
        let pending = batches
        batches.removeAll()
        return pending
    }
}
