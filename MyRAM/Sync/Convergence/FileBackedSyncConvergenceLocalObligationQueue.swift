import Foundation

final class FileBackedSyncConvergenceLocalObligationQueue {
    enum QueueError: Error, Equatable {
        case capacityExceeded
        case persistenceFailed
        case unhealthyPersistence
        case invalidStructuralMarkObligation
        case conflictingDuplicateIdentity(UUID)
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

    @discardableResult
    func removeTerminalStructuralMarkObligations(
        for noteID: UUID
    ) throws -> Set<SyncBatchID> {
        let ids = Set(obligations.compactMap { obligation -> SyncBatchID? in
            guard SyncBatchDeliveryPartitionPlanner.classification(
                of: obligation.changes
            ) == .structuralMarkV3,
                  obligation.changes.count == 1,
                  obligation.changes[0].noteID == noteID else {
                return nil
            }
            return obligation.id
        })
        guard !ids.isEmpty else { return [] }
        let original = obligations
        obligations.removeAll { ids.contains($0.id) }
        do {
            try persistQueueThrowing()
            return ids
        } catch {
            obligations = original
            throw QueueError.persistenceFailed
        }
    }

    func pendingObligations(affecting noteID: UUID) -> [SyncConvergenceLocalObligation] {
        obligations.filter { obligation in
            Self.affectedNoteIDs(in: obligation.batch).contains(noteID)
        }
    }

    func enqueue(_ obligation: SyncConvergenceLocalObligation) throws {
        try enqueueAtomically([obligation])
    }

    func enqueueAtomically(_ newObligations: [SyncConvergenceLocalObligation]) throws {
        guard !newObligations.isEmpty else { return }
        try newObligations.forEach(Self.validateDurableObligation)
        guard canPersistCurrentQueue else { throw QueueError.unhealthyPersistence }
        guard limit > 0 else { throw QueueError.capacityExceeded }

        var existingByID = Dictionary(
            uniqueKeysWithValues: obligations.map { ($0.id, $0) }
        )
        var additions: [SyncConvergenceLocalObligation] = []
        additions.reserveCapacity(newObligations.count)
        for obligation in newObligations {
            if let existing = existingByID[obligation.id] {
                guard existing == obligation else {
                    throw QueueError.conflictingDuplicateIdentity(obligation.id)
                }
                continue
            }
            existingByID[obligation.id] = obligation
            additions.append(obligation)
        }
        guard !additions.isEmpty else { return }
        guard obligations.count + additions.count <= limit else {
            throw QueueError.capacityExceeded
        }

        let original = obligations
        let originalHealth = health
        obligations.append(contentsOf: additions)
        do {
            try persistQueueThrowing()
        } catch {
            obligations = original
            if persistedImageMatchesPriorState(
                obligations: original,
                health: originalHealth
            ) {
                health = originalHealth
                throw QueueError.persistenceFailed
            }
            throw QueueError.unhealthyPersistence
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
        try replacement.forEach(SyncBatchAnchoredPayloadPolicy.validateDurableAdmission)
        try replacePendingObligations(replacement.map(SyncConvergenceLocalObligation.init(legacyBatch:)))
    }

    func replacePendingObligations(_ replacement: [SyncConvergenceLocalObligation]) throws {
        try replacement.forEach(Self.validateDurableObligation)
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
        case .corrupt, .unsupportedVersion, .unsupportedAnchoredPayload, .readFailed:
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
                try persistedQueue.obligations.forEach(Self.validateDurableObligation)
                return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                    obligations: persistedQueue.obligations,
                    health: .healthy
                )
            case PersistedLegacySyncConvergenceLocalObligationQueue.currentVersion:
                let legacyQueue = try JSONDecoder().decode(
                    PersistedLegacySyncConvergenceLocalObligationQueue.self,
                    from: data
                )
                try legacyQueue.obligations.forEach(Self.validateLegacyV2Obligation)
                obligations = legacyQueue.obligations
                try persistQueueThrowing(allowUnhealthyReplacement: true)
                return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                    obligations: legacyQueue.obligations,
                    health: .healthy
                )
            case PersistedLegacySyncBatchQueue.currentVersion:
                let legacyQueue = try JSONDecoder().decode(PersistedLegacySyncBatchQueue.self, from: data)
                try legacyQueue.batches.forEach(
                    SyncBatchAnchoredPayloadPolicy.validateDurableAdmission
                )
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
        } catch is SyncBatchAnchoredPayloadPolicyError {
            return FileBackedSyncConvergenceLocalObligationQueueSnapshot(
                obligations: [],
                health: .unsupportedAnchoredPayload
            )
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
            throw error
        }
    }

    private func persistedImageMatchesPriorState(
        obligations expectedObligations: [SyncConvergenceLocalObligation],
        health priorHealth: PersistedQueueHealth
    ) -> Bool {
        guard let fileURL else {
            return priorHealth == .healthy
        }

        switch priorHealth {
        case .fileMissing:
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                health = .readFailed("Unexpected persisted queue image after failed write")
                return false
            }
            return expectedObligations.isEmpty
        case .healthy:
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                health = .readFailed("Persisted queue image missing after failed write")
                return false
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let version = try JSONDecoder().decode(
                    PersistedQueueVersion.self,
                    from: data
                ).version
                guard version == PersistedSyncConvergenceLocalObligationQueue.currentVersion else {
                    health = .unsupportedVersion(version)
                    return false
                }
                let persisted = try JSONDecoder().decode(
                    PersistedSyncConvergenceLocalObligationQueue.self,
                    from: data
                )
                try persisted.obligations.forEach(Self.validateDurableObligation)
                guard persisted.obligations == expectedObligations else {
                    health = .readFailed("Persisted queue image changed after failed write")
                    return false
                }
                return true
            } catch is SyncBatchAnchoredPayloadPolicyError {
                health = .unsupportedAnchoredPayload
                return false
            } catch _ as DecodingError {
                health = .corrupt
                return false
            } catch {
                health = .readFailed(String(describing: error))
                return false
            }
        case .corrupt, .unsupportedVersion, .unsupportedAnchoredPayload, .readFailed:
            return false
        }
    }

    private static func validateDurableObligation(
        _ obligation: SyncConvergenceLocalObligation
    ) throws {
        try SyncBatchAnchoredPayloadPolicy.validateDurableAdmission(obligation.batch)
        switch SyncBatchDeliveryPartitionPlanner.classification(of: obligation.batch.changes) {
        case .v1Compatible, .anchoredV2:
            return
        case .structuralMarkV3:
            guard obligation.batch.changes.count == 1,
                  case .noteStructuralMarksChanged(let change) = obligation.batch.changes[0],
                  !change.operations.isEmpty else {
                throw QueueError.invalidStructuralMarkObligation
            }
        case .invalidMixedRepresentation:
            throw QueueError.invalidStructuralMarkObligation
        }
    }

    private static func validateLegacyV2Obligation(
        _ obligation: SyncConvergenceLocalObligation
    ) throws {
        try validateDurableObligation(obligation)
        guard SyncBatchDeliveryPartitionPlanner.classification(
            of: obligation.batch.changes
        ) != .structuralMarkV3 else {
            throw QueueError.invalidStructuralMarkObligation
        }
    }

    private static func affectedNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.map(\.noteID))
    }
}

struct FileBackedSyncConvergenceLocalObligationQueueSnapshot: Equatable {
    let obligations: [SyncConvergenceLocalObligation]
    let health: PersistedQueueHealth
}

struct PersistedSyncConvergenceLocalObligationQueue: Codable {
    static let currentVersion = 3

    let version: Int
    let obligations: [SyncConvergenceLocalObligation]
}

private struct PersistedQueueVersion: Codable {
    let version: Int
}

private struct PersistedLegacySyncConvergenceLocalObligationQueue: Codable {
    static let currentVersion = 2

    let version: Int
    let obligations: [SyncConvergenceLocalObligation]
}

private struct PersistedLegacySyncBatchQueue: Codable {
    static let currentVersion = 1

    let version: Int
    let batches: [SyncBatch]
}
