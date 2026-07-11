import XCTest
import NearbySyncCore
@testable import MyRAM

@MainActor
final class PendingSyncRecoveryTests: XCTestCase {
    func testJournalStorePersistsPhaseUpdatesAndDeletes() throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = PendingSyncRecoveryJournalStore(fileURL: fileURL)
        let journal = makeJournal()

        try store.save(journal)
        XCTAssertEqual(try store.load(), journal)

        var expected = journal
        expected.phase = .legacyReplaced
        XCTAssertEqual(try store.updatePhase(.legacyReplaced), expected)
        XCTAssertEqual(try store.load()?.phase, .legacyReplaced)

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testCoordinatorRollsBackOriginalQueuesWhenReplacementFailsAfterLegacy() async throws {
        let fileURL = temporaryJournalURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let originalLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-1")])
        let replacementLegacy = SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-2")])
        let originalUnsent = [makeBatch(idSuffix: 1)]
        let originalLocal = [makeBatch(idSuffix: 2)]
        var localBatches = originalLocal
        let admin = FakePendingSyncQueueAdmin(
            legacySnapshot: originalLegacy,
            unsentSnapshot: FileBackedSyncBatchQueueSnapshot(
                pendingBatches: originalUnsent,
                health: .healthy
            )
        )
        let coordinator = PendingSyncRecoveryCoordinator(
            queueAdmin: admin,
            localQueueSnapshot: {
                FileBackedSyncBatchQueueSnapshot(pendingBatches: localBatches, health: .healthy)
            },
            replaceLocalBatches: { batches in
                localBatches = batches
            },
            flushReadyLocalBatch: {},
            journalStore: PendingSyncRecoveryJournalStore(fileURL: fileURL),
            now: { Date(timeIntervalSince1970: 100) },
            transactionID: { UUID(uuidString: "00000000-0000-0000-0000-000000160001")! }
        )
        admin.failNextUnsentReplacement = true
        let replacement = SyncRecoveryReplacementState(
            legacySnapshot: replacementLegacy,
            unsentBatches: [],
            localConvergenceBatches: [],
            replacedLegacyCount: 1,
            replacedUnsentBatchCount: 1,
            replacedLocalObligationCount: 1
        )

        do {
            try await coordinator.commitReplacement(replacement)
            XCTFail("Expected replacement failure")
        } catch {
            XCTAssertEqual(error as? PendingSyncRecoveryCoordinator.RecoveryError, .replacementFailed)
        }

        XCTAssertEqual(admin.legacySnapshot, originalLegacy)
        XCTAssertEqual(admin.unsentSnapshot.pendingBatches, originalUnsent)
        XCTAssertEqual(localBatches, originalLocal)
        XCTAssertFalse(admin.isSuspended)
        XCTAssertNil(try PendingSyncRecoveryJournalStore(fileURL: fileURL).load())
    }

    private func temporaryJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pending-sync-recovery-journal.json")
    }

    private func makeJournal() -> PendingSyncRecoveryJournal {
        PendingSyncRecoveryJournal(
            transactionID: UUID(uuidString: "00000000-0000-0000-0000-000000160000")!,
            createdAt: Date(timeIntervalSince1970: 100),
            originalLegacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-1")]),
            originalUnsentBatches: [makeBatch(idSuffix: 1)],
            originalLocalObligations: [makeBatch(idSuffix: 2)],
            replacementLegacySnapshot: SyncQueueSnapshot(pendingChanges: [makeLegacyChange(entityID: "note-2")]),
            replacementUnsentBatches: [],
            replacementLocalObligations: []
        )
    }

    private func makeLegacyChange(entityID: String) -> SyncChange {
        SyncChange(
            entityType: .item,
            entityID: entityID,
            operation: .upsert,
            payload: Data(entityID.utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
    }

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000160999")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }
}

@MainActor
private final class FakePendingSyncQueueAdmin: PendingSyncQueueAdministrating {
    var legacySnapshot: SyncQueueSnapshot
    var legacyHealth: SyncQueuePersistenceHealth = .healthy
    var unsentSnapshot: FileBackedSyncBatchQueueSnapshot
    var isSuspended = false
    var didFlushAllOutboundWork = false
    var failNextUnsentReplacement = false

    init(legacySnapshot: SyncQueueSnapshot, unsentSnapshot: FileBackedSyncBatchQueueSnapshot) {
        self.legacySnapshot = legacySnapshot
        self.unsentSnapshot = unsentSnapshot
    }

    func suspendOutboundForRecovery() {
        isSuspended = true
    }

    func resumeOutboundAfterRecovery() {
        isSuspended = false
    }

    func legacyQueueSnapshot() async -> SyncQueueSnapshot {
        legacySnapshot
    }

    func legacyQueueHealth() async -> SyncQueuePersistenceHealth {
        legacyHealth
    }

    func replaceLegacyQueueSnapshot(_ snapshot: SyncQueueSnapshot) async throws {
        legacySnapshot = snapshot
    }

    func unsentBatchQueueSnapshot() -> FileBackedSyncBatchQueueSnapshot {
        unsentSnapshot
    }

    func replaceUnsentBatches(_ batches: [SyncBatch]) throws {
        if failNextUnsentReplacement {
            failNextUnsentReplacement = false
            throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
        }
        unsentSnapshot = FileBackedSyncBatchQueueSnapshot(pendingBatches: batches, health: .healthy)
    }

    func refreshPendingSyncStatus() async {}

    func flushAllOutboundWork() {
        didFlushAllOutboundWork = true
    }
}
