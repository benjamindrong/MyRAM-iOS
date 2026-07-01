import Foundation

final class FileBackedSyncBatchQueue {
    private let fileURL: URL?
    private var queue: SyncBatchUnsentQueue

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

    func enqueue(_ batch: SyncBatch) {
        queue.enqueue(batch)
        persistQueue()
    }

    func removeAll(withIDs ids: Set<SyncBatchID>) {
        queue.removeAll(withIDs: ids)
        persistQueue()
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
        guard let fileURL else { return }

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
        } catch {
            return
        }
    }
}

private struct PersistedSyncBatchQueue: Codable {
    // Keep a versioned envelope so future SyncBatch shape changes can migrate safely.
    static let currentVersion = 1

    let version: Int
    let batches: [SyncBatch]
}
