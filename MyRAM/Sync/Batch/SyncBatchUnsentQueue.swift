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

    mutating func enqueue(_ batch: SyncBatch) {
        // Batch IDs are stable, so retries should retain one copy of each offline batch.
        guard limit > 0, !batches.contains(where: { $0.id == batch.id }) else { return }
        batches.append(batch)
        if batches.count > limit {
            batches.removeFirst(batches.count - limit)
        }
    }

    mutating func removeAll(withIDs ids: Set<SyncBatchID>) {
        guard !ids.isEmpty else { return }
        batches.removeAll { ids.contains($0.id) }
    }

    mutating func drain() -> [SyncBatch] {
        let pending = batches
        batches.removeAll()
        return pending
    }
}
