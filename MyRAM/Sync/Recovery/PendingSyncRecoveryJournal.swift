import Foundation
import NearbySyncCore

struct PendingSyncRecoveryJournal: Codable, Equatable {
    enum Phase: String, Codable {
        case prepared
        case legacyReplaced
        case unsentBatchesReplaced
        case localObligationsReplaced
        case committed
    }

    let version: Int
    let transactionID: UUID
    let createdAt: Date
    var phase: Phase

    let originalLegacySnapshot: SyncQueueSnapshot
    let originalUnsentBatches: [SyncBatch]
    let originalLocalObligations: [SyncBatch]

    let replacementLegacySnapshot: SyncQueueSnapshot
    let replacementUnsentBatches: [SyncBatch]
    let replacementLocalObligations: [SyncBatch]

    init(
        version: Int = 1,
        transactionID: UUID = UUID(),
        createdAt: Date = Date(),
        phase: Phase = .prepared,
        originalLegacySnapshot: SyncQueueSnapshot,
        originalUnsentBatches: [SyncBatch],
        originalLocalObligations: [SyncBatch],
        replacementLegacySnapshot: SyncQueueSnapshot,
        replacementUnsentBatches: [SyncBatch],
        replacementLocalObligations: [SyncBatch]
    ) {
        self.version = version
        self.transactionID = transactionID
        self.createdAt = createdAt
        self.phase = phase
        self.originalLegacySnapshot = originalLegacySnapshot
        self.originalUnsentBatches = originalUnsentBatches
        self.originalLocalObligations = originalLocalObligations
        self.replacementLegacySnapshot = replacementLegacySnapshot
        self.replacementUnsentBatches = replacementUnsentBatches
        self.replacementLocalObligations = replacementLocalObligations
    }
}

final class PendingSyncRecoveryJournalStore {
    enum StoreError: Error, Equatable {
        case unsupportedVersion(Int)
        case corrupt
        case persistenceFailed
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = PendingSyncRecoveryJournalStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() throws -> PendingSyncRecoveryJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let journal = try decoder.decode(PendingSyncRecoveryJournal.self, from: data)
            guard journal.version == 1 else {
                throw StoreError.unsupportedVersion(journal.version)
            }
            return journal
        } catch let error as StoreError {
            throw error
        } catch let error as DecodingError {
            _ = error
            throw StoreError.corrupt
        } catch {
            throw StoreError.persistenceFailed
        }
    }

    func save(_ journal: PendingSyncRecoveryJournal) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(journal)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StoreError.persistenceFailed
        }
    }

    func updatePhase(_ phase: PendingSyncRecoveryJournal.Phase) throws -> PendingSyncRecoveryJournal {
        guard var journal = try load() else {
            throw StoreError.corrupt
        }
        journal.phase = phase
        try save(journal)
        return journal
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw StoreError.persistenceFailed
        }
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("pending-sync-recovery-journal.json")
    }
}
