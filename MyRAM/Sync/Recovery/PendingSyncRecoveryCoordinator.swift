import Foundation
import NearbySyncCore

@MainActor
final class PendingSyncRecoveryCoordinator {
    enum RecoveryError: Error, Equatable {
        case unhealthyLegacyQueue
        case unhealthyUnsentBatchQueue
        case unhealthyLocalObligationQueue
        case journalWriteFailed
        case replacementFailed
        case rollbackFailed
        case capturedBatchNotDurable(SyncBatchID)
    }

    private let queueAdmin: PendingSyncQueueAdministrating
    private let localQueueSnapshot: () -> FileBackedSyncBatchQueueSnapshot
    private let replaceLocalBatches: ([SyncBatch]) async throws -> Void
    private let flushReadyLocalBatch: () async throws -> SyncBatchID?
    private let journalStore: PendingSyncRecoveryJournalStore
    private let now: () -> Date
    private let transactionID: () -> UUID

    init(
        queueAdmin: PendingSyncQueueAdministrating,
        localQueueSnapshot: @escaping () -> FileBackedSyncBatchQueueSnapshot,
        replaceLocalBatches: @escaping ([SyncBatch]) async throws -> Void,
        flushReadyLocalBatch: @escaping () async throws -> SyncBatchID?,
        journalStore: PendingSyncRecoveryJournalStore = PendingSyncRecoveryJournalStore(),
        now: @escaping () -> Date = Date.init,
        transactionID: @escaping () -> UUID = UUID.init
    ) {
        self.queueAdmin = queueAdmin
        self.localQueueSnapshot = localQueueSnapshot
        self.replaceLocalBatches = replaceLocalBatches
        self.flushReadyLocalBatch = flushReadyLocalBatch
        self.journalStore = journalStore
        self.now = now
        self.transactionID = transactionID
    }

    func prepareSnapshots() async throws -> (
        legacy: SyncQueueSnapshot,
        unsent: [SyncBatch],
        local: [SyncBatch]
    ) {
        let capturedBatchID = try await flushReadyLocalBatch()

        let legacyHealth = await queueAdmin.legacyQueueHealth()
        guard legacyHealth.isRecoveryWritable else {
            throw RecoveryError.unhealthyLegacyQueue
        }

        let unsentSnapshot = queueAdmin.unsentBatchQueueSnapshot()
        guard unsentSnapshot.health.isRecoveryWritable else {
            throw RecoveryError.unhealthyUnsentBatchQueue
        }

        let localSnapshot = localQueueSnapshot()
        guard localSnapshot.health.isRecoveryWritable else {
            throw RecoveryError.unhealthyLocalObligationQueue
        }

        if let capturedBatchID,
           !unsentSnapshot.pendingBatches.contains(where: { $0.id == capturedBatchID }),
           !localSnapshot.pendingBatches.contains(where: { $0.id == capturedBatchID }) {
            throw RecoveryError.capturedBatchNotDurable(capturedBatchID)
        }

        return (
            legacy: await queueAdmin.legacyQueueSnapshot(),
            unsent: unsentSnapshot.pendingBatches,
            local: localSnapshot.pendingBatches
        )
    }

    func commitReplacement(_ replacement: SyncRecoveryReplacementState) async throws {
        queueAdmin.suspendOutboundForRecovery()

        let original: (
            legacy: SyncQueueSnapshot,
            unsent: [SyncBatch],
            local: [SyncBatch]
        )

        do {
            original = try await prepareSnapshots()
        } catch {
            queueAdmin.resumeOutboundAfterRecovery()
            throw error
        }

        let journal = PendingSyncRecoveryJournal(
            version: 1,
            transactionID: transactionID(),
            createdAt: now(),
            phase: .prepared,
            originalLegacySnapshot: original.legacy,
            originalUnsentBatches: original.unsent,
            originalLocalObligations: original.local,
            replacementLegacySnapshot: replacement.legacySnapshot,
            replacementUnsentBatches: replacement.unsentBatches,
            replacementLocalObligations: replacement.localConvergenceBatches
        )

        do {
            try journalStore.save(journal)
            try await queueAdmin.replaceLegacyQueueSnapshot(replacement.legacySnapshot)
            _ = try journalStore.updatePhase(.legacyReplaced)
            try await queueAdmin.replaceUnsentBatches(replacement.unsentBatches)
            _ = try journalStore.updatePhase(.unsentBatchesReplaced)
            try await replaceLocalBatches(replacement.localConvergenceBatches)
            _ = try journalStore.updatePhase(.localObligationsReplaced)
            await queueAdmin.refreshPendingSyncStatus()
            _ = try journalStore.updatePhase(.committed)
            try journalStore.delete()
            queueAdmin.resumeOutboundAfterRecovery()
            queueAdmin.flushAllOutboundWork()
        } catch {
            try await rollback(journal: journal, resumeOutbound: true)
            throw RecoveryError.replacementFailed
        }
    }

    func resetPendingSync(
        prepareDurableState: () throws -> Void,
        buildReplacement: (
            _ legacy: SyncQueueSnapshot,
            _ unsent: [SyncBatch],
            _ local: [SyncBatch],
            _ recoveryTimestamp: Date
        ) throws -> SyncRecoveryReplacementState
    ) async throws {
        queueAdmin.suspendOutboundForRecovery()

        let original: (
            legacy: SyncQueueSnapshot,
            unsent: [SyncBatch],
            local: [SyncBatch]
        )
        let replacement: SyncRecoveryReplacementState
        let recoveryTimestamp: Date

        do {
            try prepareDurableState()
            original = try await prepareSnapshots()
            recoveryTimestamp = now()
            replacement = try buildReplacement(
                original.legacy,
                original.unsent,
                original.local,
                recoveryTimestamp
            )
        } catch {
            queueAdmin.resumeOutboundAfterRecovery()
            throw error
        }

        try await applyReplacement(replacement, original: original, createdAt: recoveryTimestamp)
    }

    private func applyReplacement(
        _ replacement: SyncRecoveryReplacementState,
        original: (
            legacy: SyncQueueSnapshot,
            unsent: [SyncBatch],
            local: [SyncBatch]
        ),
        createdAt: Date
    ) async throws {
        let journal = PendingSyncRecoveryJournal(
            version: 1,
            transactionID: transactionID(),
            createdAt: createdAt,
            phase: .prepared,
            originalLegacySnapshot: original.legacy,
            originalUnsentBatches: original.unsent,
            originalLocalObligations: original.local,
            replacementLegacySnapshot: replacement.legacySnapshot,
            replacementUnsentBatches: replacement.unsentBatches,
            replacementLocalObligations: replacement.localConvergenceBatches
        )

        do {
            try journalStore.save(journal)
            try await queueAdmin.replaceLegacyQueueSnapshot(replacement.legacySnapshot)
            _ = try journalStore.updatePhase(.legacyReplaced)
            try await queueAdmin.replaceUnsentBatches(replacement.unsentBatches)
            _ = try journalStore.updatePhase(.unsentBatchesReplaced)
            try await replaceLocalBatches(replacement.localConvergenceBatches)
            _ = try journalStore.updatePhase(.localObligationsReplaced)
            await queueAdmin.refreshPendingSyncStatus()
            _ = try journalStore.updatePhase(.committed)
            try journalStore.delete()
            queueAdmin.resumeOutboundAfterRecovery()
            queueAdmin.flushAllOutboundWork()
        } catch {
            try await rollback(journal: journal, resumeOutbound: true)
            throw RecoveryError.replacementFailed
        }
    }

    func rollbackIfNeededOnLaunch() async throws {
        guard let journal = try journalStore.load() else { return }
        if journal.phase == .committed {
            try journalStore.delete()
            return
        }
        queueAdmin.suspendOutboundForRecovery()
        try await rollback(journal: journal, resumeOutbound: false)
    }

    private func rollback(journal: PendingSyncRecoveryJournal, resumeOutbound: Bool) async throws {
        do {
            try await queueAdmin.replaceLegacyQueueSnapshot(journal.originalLegacySnapshot)
            try await queueAdmin.replaceUnsentBatches(journal.originalUnsentBatches)
            try await replaceLocalBatches(journal.originalLocalObligations)
            await queueAdmin.refreshPendingSyncStatus()
            try journalStore.delete()
            if resumeOutbound {
                queueAdmin.resumeOutboundAfterRecovery()
            }
        } catch {
            throw RecoveryError.rollbackFailed
        }
    }
}

private extension SyncQueuePersistenceHealth {
    var isRecoveryWritable: Bool {
        switch self {
        case .healthy, .fileMissing:
            true
        case .corrupt, .readFailed:
            false
        }
    }
}

private extension PersistedQueueHealth {
    var isRecoveryWritable: Bool {
        switch self {
        case .healthy, .fileMissing:
            true
        case .corrupt, .unsupportedVersion, .readFailed:
            false
        }
    }
}
