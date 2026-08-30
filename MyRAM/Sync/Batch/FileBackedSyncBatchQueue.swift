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
        recordBenchmark(
            .queueLoaded,
            queueDepth: queue.pendingBatches.count,
            itemCount: queue.pendingBatches.count,
            outcome: snapshot.health.benchmarkLabel
        )
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

    func enqueueIncoming(_ batch: SyncBatch) throws {
        try enqueueIncomingCore(
            batch,
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled
        )
    }

    func enqueueIncomingCore(
        _ batch: SyncBatch,
        activationEnabled: Bool
    ) throws {
        try enqueueDurablyCore(batch, activationEnabled: activationEnabled)
    }

    func enqueueDurably(_ batch: SyncBatch) throws {
        try enqueueDurablyCore(
            batch,
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled
        )
    }

    func enqueueDurablyCore(
        _ batch: SyncBatch,
        activationEnabled: Bool
    ) throws {
        try SyncBatchAnchoredPayloadPolicy.validateDurableAdmissionCore(
            batch,
            activationEnabled: activationEnabled
        )
        guard canPersistCurrentQueue else {
            recordBenchmark(
                .queueWriteFailed,
                batchID: batch.id,
                queueDepth: queue.pendingBatches.count,
                outcome: "unhealthyPersistence"
            )
            throw QueueError.unhealthyPersistence
        }
        let originalBatches = queue.pendingBatches
        do {
            let didChange = try queue.enqueuePreservingExisting(batch)
            if didChange {
                try persistQueueThrowing()
                recordBenchmark(
                    .batchQueued,
                    batchID: batch.id,
                    queueDepth: queue.pendingBatches.count
                )
            } else {
                recordBenchmark(
                    .batchQueueDuplicate,
                    batchID: batch.id,
                    queueDepth: queue.pendingBatches.count
                )
            }
        } catch SyncBatchUnsentQueue.EnqueueError.capacityExceeded {
            recordBenchmark(
                .queueWriteFailed,
                batchID: batch.id,
                queueDepth: queue.pendingBatches.count,
                outcome: "capacityExceeded"
            )
            throw QueueError.capacityExceeded
        } catch {
            queue.replacePendingBatches(originalBatches)
            recordBenchmark(
                .queueWriteFailed,
                batchID: batch.id,
                queueDepth: queue.pendingBatches.count,
                outcome: "persistenceFailed"
            )
            throw QueueError.persistenceFailed
        }
    }

    func injectPersistenceFailureForNextWrite() {
        shouldFailNextPersistence = true
    }

    func removeAll(withIDs ids: Set<SyncBatchID>) {
        let existingIDs = Set(queue.pendingBatches.map(\.id))
        let removedIDs = ids.intersection(existingIDs)
        let didChange = queue.removeAll(withIDs: ids)
        if didChange {
            let persisted = persistQueue()
            for id in removedIDs {
                recordBenchmark(
                    .batchDequeued,
                    batchID: id,
                    queueDepth: queue.pendingBatches.count,
                    outcome: persisted ? "durable" : "memoryOnly"
                )
            }
        }
    }

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        guard canPersistCurrentQueue else {
            recordBenchmark(
                .queueWriteFailed,
                queueDepth: queue.pendingBatches.count,
                itemCount: ids.count,
                outcome: "unhealthyPersistence"
            )
            throw QueueError.unhealthyPersistence
        }
        let originalBatches = queue.pendingBatches
        let existingIDs = Set(originalBatches.map(\.id))
        let removedIDs = ids.intersection(existingIDs)
        let didChange = queue.removeAll(withIDs: ids)
        guard didChange else { return }

        do {
            try persistQueueThrowing()
            for id in removedIDs {
                recordBenchmark(
                    .batchDequeued,
                    batchID: id,
                    queueDepth: queue.pendingBatches.count,
                    outcome: "durable"
                )
            }
        } catch {
            queue.replacePendingBatches(originalBatches)
            recordBenchmark(
                .queueWriteFailed,
                queueDepth: queue.pendingBatches.count,
                itemCount: ids.count,
                outcome: "persistenceFailed"
            )
            throw QueueError.persistenceFailed
        }
    }

    func remove(_ batchID: SyncBatchID) {
        let didChange = queue.remove(batchID)
        if didChange {
            let persisted = persistQueue()
            recordBenchmark(
                .batchDequeued,
                batchID: batchID,
                queueDepth: queue.pendingBatches.count,
                outcome: persisted ? "durable" : "memoryOnly"
            )
        }
    }

    func replacePendingBatches(_ replacement: [SyncBatch]) throws {
        try replacement.forEach(SyncBatchAnchoredPayloadPolicy.validateDurableAdmission)
        guard canReplaceQueue else {
            recordBenchmark(
                .queueWriteFailed,
                queueDepth: queue.pendingBatches.count,
                itemCount: replacement.count,
                outcome: "unhealthyPersistence"
            )
            throw QueueError.unhealthyPersistence
        }

        let originalBatches = queue.pendingBatches
        queue.replacePendingBatches(replacement)
        do {
            try persistQueueThrowing(allowUnhealthyReplacement: true)
            health = .healthy
            recordBenchmark(
                .queueReplaced,
                queueDepth: replacement.count,
                itemCount: replacement.count,
                outcome: "durable"
            )
        } catch {
            queue.replacePendingBatches(originalBatches)
            recordBenchmark(
                .queueWriteFailed,
                queueDepth: queue.pendingBatches.count,
                itemCount: replacement.count,
                outcome: "persistenceFailed"
            )
            throw QueueError.persistenceFailed
        }
    }

    private var canPersistCurrentQueue: Bool {
        switch health {
        case .healthy, .fileMissing:
            return true
        case .corrupt, .unsupportedVersion, .unsupportedAnchoredPayload, .readFailed:
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
            try persistedQueue.batches.forEach(
                SyncBatchAnchoredPayloadPolicy.validateDurableAdmission
            )
            return FileBackedSyncBatchQueueSnapshot(
                pendingBatches: persistedQueue.batches,
                health: .healthy
            )
        } catch is SyncBatchAnchoredPayloadPolicyError {
            return FileBackedSyncBatchQueueSnapshot(
                pendingBatches: [],
                health: .unsupportedAnchoredPayload
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

    @discardableResult
    private func persistQueue() -> Bool {
        do {
            try persistQueueThrowing()
            return true
        } catch {
            recordBenchmark(
                .queueWriteFailed,
                queueDepth: queue.pendingBatches.count,
                outcome: "persistenceFailed"
            )
            return false
        }
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

    private var benchmarkQueueName: String {
        fileURL?.lastPathComponent ?? "memory"
    }

    private func recordBenchmark(
        _ eventType: MyRAMSyncBenchmarkEventType,
        batchID: SyncBatchID? = nil,
        queueDepth: Int? = nil,
        itemCount: Int? = nil,
        outcome: String? = nil
    ) {
        MyRAMSyncBenchmarkTelemetry.shared.record(
            eventType,
            batchID: batchID.map { String(describing: $0) },
            queueName: benchmarkQueueName,
            queueDepth: queueDepth,
            itemCount: itemCount,
            outcome: outcome
        )
    }
}

enum PersistedQueueHealth: Equatable {
    case healthy
    case fileMissing
    case corrupt
    case unsupportedVersion(Int)
    case unsupportedAnchoredPayload
    case readFailed(String)

    var benchmarkLabel: String {
        switch self {
        case .healthy: "healthy"
        case .fileMissing: "fileMissing"
        case .corrupt: "corrupt"
        case .unsupportedVersion: "unsupportedVersion"
        case .unsupportedAnchoredPayload: "unsupportedAnchoredPayload"
        case .readFailed: "readFailed"
        }
    }
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
