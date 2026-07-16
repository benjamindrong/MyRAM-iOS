import Foundation

final class FileBackedSyncConvergenceLocalObligationQueue {
    enum QueueError: Error, Equatable {
        case capacityExceeded
        case persistenceFailed
        case unhealthyPersistence
    }

    private let fileURL: URL?
    private let limit: Int
    private var obligations: [SyncConvergenceLocalObligation] = []
    private var health: PersistedQueueHealth = .healthy
    private var shouldFailNextPersistence = false

    init(fileURL: URL?, limit: Int = 100) {
        self.fileURL = fileURL
        self.limit = max(0, limit)
        let snapshot = loadPersistedQueue()
        obligations = snapshot.obligations
        health = snapshot.health
    }

    var pendingObligations: [SyncConvergenceLocalObligation] {
        obligations
    }

    var pendingBatches: [SyncBatch] {
        obligations.map(\.batch)
    }

    var pendingCount: Int {
        obligations.count
    }

    func snapshot() -> FileBackedSyncBatchQueueSnapshot {
        FileBackedSyncBatchQueueSnapshot(pendingBatches: pendingBatches, health: health)
    }

    func contains(_ batchID: UUID) -> Bool {
        obligations.contains { $0.id == batchID }
    }

    func pendingObligations(affecting noteID: UUID) -> [SyncConvergenceLocalObligation] {
        obligations.filter { obligation in
            Self.affectedNoteIDs(in: obligation.batch).contains(noteID)
        }
    }

    func enqueue(_ obligation: SyncConvergenceLocalObligation) throws {
        guard canPersistCurrentQueue else { throw QueueError.unhealthyPersistence }
        guard limit > 0 else { throw QueueError.capacityExceeded }
        guard !contains(obligation.id) else { return }
        guard obligations.count < limit else { throw QueueError.capacityExceeded }

        let original = obligations
        obligations.append(obligation)
        do {
            try persistQueueThrowing()
        } catch {
            obligations = original
            throw QueueError.persistenceFailed
        }
    }

    func removeObligations(withIDs ids: Set<UUID>) throws {
        guard canPersistCurrentQueue else { throw QueueError.unhealthyPersistence }
        guard !ids.isEmpty else { return }
        let original = obligations
        obligations.removeAll { ids.contains($0.id) }
        guard obligations != original else { return }

        do {
            try persistQueueThrowing()
        } catch {
            obligations = original
            throw QueueError.persistenceFailed
        }
    }

    func replacePendingBatches(_ replacement: [SyncBatch]) throws {
        try replacePendingObligations(replacement.map(SyncConvergenceLocalObligation.init(legacyBatch:)))
    }

    func replacePendingObligations(_ replacement: [SyncConvergenceLocalObligation]) throws {
        guard canReplaceQueue else { throw QueueError.unhealthyPersistence }

        let original = obligations
        obligations = Array(replacement.prefix(limit))
        do {
            try persistQueueThrowing(allowUnhealthyReplacement: true)
            health = .healthy
        } catch {
            obligations = original
            throw QueueError.persistenceFailed
        }
    }

    func injectPersistenceFailureForNextWrite() {
        shouldFailNextPersistence = true
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

    private func loadPersistedQueue() -> FileBackedSyncConvergenceLocalObligationQueueSnapshot {
        guard let fileURL else {
            return FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: [], health: .healthy)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: [], health: .fileMissing)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let version = try JSONDecoder().decode(PersistedQueueVersion.self, from: data).version
            switch version {
            case PersistedSyncConvergenceLocalObligationQueue.currentVersion:
                let persistedQueue = try JSONDecoder().decode(PersistedSyncConvergenceLocalObligationQueue.self, from: data)
                return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                    obligations: persistedQueue.obligations,
                    health: .healthy
                )
            case PersistedLegacySyncBatchQueue.currentVersion:
                let legacyQueue = try JSONDecoder().decode(PersistedLegacySyncBatchQueue.self, from: data)
                let migrated = legacyQueue.batches.map(SyncConvergenceLocalObligation.init(legacyBatch:))
                obligations = migrated
                try persistQueueThrowing(allowUnhealthyReplacement: true)
                return FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: migrated, health: .healthy)
            default:
                return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                    obligations: [],
                    health: .unsupportedVersion(version)
                )
            }
        } catch _ as DecodingError {
            return FileBackedSyncConvergenceLocalObligationQueueSnapshot(obligations: [], health: .corrupt)
        } catch {
            return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                obligations: [],
                health: .readFailed(String(describing: error))
            )
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
            let persistedQueue = PersistedSyncConvergenceLocalObligationQueue(
                version: PersistedSyncConvergenceLocalObligationQueue.currentVersion,
                obligations: obligations
            )
            let data = try JSONEncoder().encode(persistedQueue)
            try data.write(to: fileURL, options: .atomic)
            health = .healthy
        } catch {
            health = .readFailed(String(describing: error))
            throw error
        }
    }

    private static func affectedNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.compactMap { change -> UUID? in
            switch change {
            case .noteCreated(let payload):
                return payload.noteID
            case .noteTitleChanged(let payload):
                return payload.noteID
            case .noteBodyTextInserted(let payload):
                return payload.noteID
            case .noteBodyTextDeleted(let payload):
                return payload.noteID
            case .noteBodyReconciled(let payload):
                return payload.noteID
            case .noteLifecycleChanged(let payload):
                return payload.noteID
            }
        })
    }
}

struct FileBackedSyncConvergenceLocalObligationQueueSnapshot: Equatable {
    let obligations: [SyncConvergenceLocalObligation]
    let health: PersistedQueueHealth
}

struct PersistedSyncConvergenceLocalObligationQueue: Codable {
    static let currentVersion = 2

    let version: Int
    let obligations: [SyncConvergenceLocalObligation]
}

private struct PersistedQueueVersion: Codable {
    let version: Int
}

private struct PersistedLegacySyncBatchQueue: Codable {
    static let currentVersion = 1

    let version: Int
    let batches: [SyncBatch]
}
