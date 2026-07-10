import Foundation

final class FileBackedSyncBatchQueue {
    enum QueueError: Error, Equatable {
        case capacityExceeded
        case persistenceFailed
        case unhealthyPersistence
    }

    private let fileURL: URL?
    private var queue: SyncBatchUnsentQueue
    private var health: PersistedQueueHealth = .healthy
    private var shouldFailNextPersistence = false

    init(fileURL: URL?, limit: Int = 100) {
        self.fileURL = fileURL
        queue = SyncBatchUnsentQueue(limit: limit)
        let snapshot = loadPersistedQueue()
        queue.replacePendingBatches(snapshot.pendingBatches)
        health = snapshot.health
    }

    var isEmpty: Bool {
        queue.isEmpty
    }

    var pendingBatches: [SyncBatch] {
        queue.pendingBatches
    }

    var pendingCount: Int {
        queue.pendingBatches.count
    }

    var first: SyncBatch? {
        queue.first
    }

    func snapshot() -> FileBackedSyncBatchQueueSnapshot {
        FileBackedSyncBatchQueueSnapshot(pendingBatches: queue.pendingBatches, health: health)
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
        guard canPersistCurrentQueue else { throw QueueError.unhealthyPersistence }
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
        let didChange = queue.removeAll(withIDs: ids)
        if didChange {
            persistQueue()
        }
    }

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        guard canPersistCurrentQueue else { throw QueueError.unhealthyPersistence }
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

    func replacePendingBatches(_ replacement: [SyncBatch]) throws {
        guard canReplaceQueue else { throw QueueError.unhealthyPersistence }

        let originalBatches = queue.pendingBatches
        queue.replacePendingBatches(replacement)
        do {
            try persistQueueThrowing(allowUnhealthyReplacement: true)
            health = .healthy
        } catch {
            queue.replacePendingBatches(originalBatches)
            throw QueueError.persistenceFailed
        }
    }

    private var canPersistCurrentQueue: Bool {
        switch health {
        case .healthy, .fileMissing:
            return true
        case .corrupt, .unsupportedVersion, .readFailed:
            return false
        }
    }

    private var canReplaceQueue: Bool {
        canPersistCurrentQueue
    }

    private func loadPersistedQueue() -> FileBackedSyncBatchQueueSnapshot {
        guard let fileURL else {
            return FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .healthy)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .fileMissing)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let persistedQueue = try JSONDecoder().decode(PersistedSyncBatchQueue.self, from: data)
            guard persistedQueue.version == PersistedSyncBatchQueue.currentVersion else {
                return FileBackedSyncBatchQueueSnapshot(
                    pendingBatches: [],
                    health: .unsupportedVersion(persistedQueue.version)
                )
            }
            return FileBackedSyncBatchQueueSnapshot(
                pendingBatches: persistedQueue.batches,
                health: .healthy
            )
        } catch _ as DecodingError {
            return FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .corrupt)
        } catch {
            return FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [],
                health: .readFailed(String(describing: error))
            )
        }
    }

    private func persistQueue() {
        try? persistQueueThrowing()
    }

    private func persistQueueThrowing(allowUnhealthyReplacement: Bool = false) throws {
        guard let fileURL else { return }
        guard allowUnhealthyReplacement || canPersistCurrentQueue else {
            throw QueueError.unhealthyPersistence
        }
        if shouldFailNextPersistence {
            shouldFailNextPersistence = false
            health = .readFailed("Injected persistence failure")
            throw QueueError.persistenceFailed
        }

        do {
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
            health = .healthy
        } catch {
            health = .readFailed(String(describing: error))
            throw error
        }
    }
}

enum PersistedQueueHealth: Equatable {
    case healthy
    case fileMissing
    case corrupt
    case unsupportedVersion(Int)
    case readFailed(String)
}

struct FileBackedSyncBatchQueueSnapshot: Equatable {
    let pendingBatches: [SyncBatch]
    let health: PersistedQueueHealth
}

private struct PersistedSyncBatchQueue: Codable {
    // Keep a versioned envelope so future SyncBatch shape changes can migrate safely.
    static let currentVersion = 1

    let version: Int
    let batches: [SyncBatch]
}
