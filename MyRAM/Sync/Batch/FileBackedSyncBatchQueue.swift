import Foundation

final class FileBackedSyncBatchQueue {
    enum QueueError: Error, Equatable {
        case capacityExceeded
        case persistenceFailed
    }

    private let fileURL: URL?
    private var queue: SyncBatchUnsentQueue
    private var shouldFailNextPersistence = false

    init(fileURL: URL?, limit: Int = 100) {
        self.fileURL = fileURL
        queue = SyncBatchUnsentQueue(limit: limit)
        loadPersistedQueue()
    }

    var isEmpty: Bool {
        queue.isEmpty
    }

    var pendingBatches: [SyncBatch] {
        queue.pendingBatches
    }

    var first: SyncBatch? {
        queue.first
    }

    func contains(_ batchID: SyncBatchID) -> Bool {
        queue.contains(batchID)
    }

    func enqueue(_ batch: SyncBatch) {
        let didChange = queue.enqueue(batch)
        if didChange {
            persistQueue()
        }
    }

    func enqueueIncoming(_ batch: SyncBatch) throws {
        let originalBatches = queue.pendingBatches
        do {
            let didChange = try queue.enqueuePreservingExisting(batch)
            if didChange {
                try persistQueueThrowing()
            }
        } catch SyncBatchUnsentQueue.EnqueueError.capacityExceeded {
            throw QueueError.capacityExceeded
        } catch {
            queue.replacePendingBatches(originalBatches)
            throw QueueError.persistenceFailed
        }
    }

    func injectPersistenceFailureForNextWrite() {
        shouldFailNextPersistence = true
    }

    func removeAll(withIDs ids: Set<SyncBatchID>) {
        try? removeBatches(withIDs: ids)
    }

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        let originalBatches = queue.pendingBatches
        let didChange = queue.removeAll(withIDs: ids)
        guard didChange else { return }

        do {
            try persistQueueThrowing()
        } catch {
            queue.replacePendingBatches(originalBatches)
            throw QueueError.persistenceFailed
        }
    }

    func remove(_ batchID: SyncBatchID) {
        let didChange = queue.remove(batchID)
        if didChange {
            persistQueue()
        }
    }

    private func loadPersistedQueue() {
        guard let fileURL else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let persistedQueue = try JSONDecoder().decode(PersistedSyncBatchQueue.self, from: data)
            guard persistedQueue.version == PersistedSyncBatchQueue.currentVersion else { return }
            for batch in persistedQueue.batches {
                queue.enqueue(batch)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            return
        }
    }

    private func persistQueue() {
        try? persistQueueThrowing()
    }

    private func persistQueueThrowing() throws {
        guard let fileURL else { return }
        if shouldFailNextPersistence {
            shouldFailNextPersistence = false
            throw QueueError.persistenceFailed
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistedQueue = PersistedSyncBatchQueue(
            version: PersistedSyncBatchQueue.currentVersion,
            batches: queue.pendingBatches
        )
        let data = try JSONEncoder().encode(persistedQueue)
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct PersistedSyncBatchQueue: Codable {
    // Keep a versioned envelope so future SyncBatch shape changes can migrate safely.
    static let currentVersion = 1

    let version: Int
    let batches: [SyncBatch]
}
