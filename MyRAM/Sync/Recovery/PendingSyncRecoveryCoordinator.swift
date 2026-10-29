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
        case pendingLocalEditsNotDurable
        case capturedBatchNotDurable(SyncBatchID)
    }

    private let queueAdmin: PendingSyncQueueAdministrating
    private let localQueueSnapshot: () -> FileBackedSyncConvergenceLocalObligationQueueSnapshot
    private let replaceLocalObligations: ([SyncConvergenceLocalObligation]) async throws -> Void
    private let flushReadyLocalBatch: () async throws -> SyncBatchID?
    private let journalStore: PendingSyncRecoveryJournalStore
    private let now: () -> Date
    private let transactionID: () -> UUID

    init(
        queueAdmin: PendingSyncQueueAdministrating,
        localQueueSnapshot: @escaping () -> FileBackedSyncConvergenceLocalObligationQueueSnapshot,
        replaceLocalObligations: @escaping ([SyncConvergenceLocalObligation]) async throws -> Void,
        flushReadyLocalBatch: @escaping () async throws -> SyncBatchID?,
        journalStore: PendingSyncRecoveryJournalStore = PendingSyncRecoveryJournalStore(),
        now: @escaping () -> Date = Date.init,
        transactionID: @escaping () -> UUID = UUID.init
    ) {
        self.queueAdmin = queueAdmin
        self.localQueueSnapshot = localQueueSnapshot
        self.replaceLocalObligations = replaceLocalObligations
        self.flushReadyLocalBatch = flushReadyLocalBatch
        self.journalStore = journalStore
        self.now = now
        self.transactionID = transactionID
    }

    func prepareSnapshots() async throws -> (
        legacy: SyncQueueSnapshot,
        unsent: [SyncBatch],
        local: [SyncBatch],
        localEvidence: [SyncConvergenceLocalObligation]
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
           !localSnapshot.obligations.map(\.batch).contains(where: { $0.id == capturedBatchID }) {
            throw RecoveryError.capturedBatchNotDurable(capturedBatchID)
        }

        return (
            legacy: await queueAdmin.legacyQueueSnapshot(),
            unsent: unsentSnapshot.pendingBatches,
            local: localSnapshot.obligations.map(\.batch),
            localEvidence: localSnapshot.obligations
        )
    }

    func commitReplacement(_ replacement: SyncRecoveryReplacementState) async throws {
        queueAdmin.suspendOutboundForRecovery()

        let original: (
            legacy: SyncQueueSnapshot,
            unsent: [SyncBatch],
            local: [SyncBatch],
            localEvidence: [SyncConvergenceLocalObligation]
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
            replacementLocalObligations: replacement.localConvergenceBatches,
            originalLocalEvidence: original.localEvidence
        )

        do {
            try journalStore.save(journal)
            try await queueAdmin.replaceLegacyQueueSnapshot(replacement.legacySnapshot)
            _ = try journalStore.updatePhase(.legacyReplaced)
            try await queueAdmin.replaceUnsentBatches(replacement.unsentBatches)
            _ = try journalStore.updatePhase(.unsentBatchesReplaced)
            try await replaceLocalObligations(replacement.localConvergenceBatches.map(SyncConvergenceLocalObligation.init(legacyBatch:)))
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
        prepareDurableState: () async throws -> Void,
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
            local: [SyncBatch],
            localEvidence: [SyncConvergenceLocalObligation]
        )
        let replacement: SyncRecoveryReplacementState
        let recoveryTimestamp: Date

        do {
            try await prepareDurableState()
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
            local: [SyncBatch],
            localEvidence: [SyncConvergenceLocalObligation]
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
            replacementLocalObligations: replacement.localConvergenceBatches,
            originalLocalEvidence: original.localEvidence
        )

        do {
            try journalStore.save(journal)
            try await queueAdmin.replaceLegacyQueueSnapshot(replacement.legacySnapshot)
            _ = try journalStore.updatePhase(.legacyReplaced)
            try await queueAdmin.replaceUnsentBatches(replacement.unsentBatches)
            _ = try journalStore.updatePhase(.unsentBatchesReplaced)
            try await replaceLocalObligations(replacement.localConvergenceBatches.map(SyncConvergenceLocalObligation.init(legacyBatch:)))
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
            // Queue owners can admit an edit while an earlier queue's asynchronous
            // replacement is running. Rebase and durably journal later admissions
            // immediately before each subsequent queue replacement.
            var preserved = try await preserveCurrentWork(in: journal)
            try await queueAdmin.replaceLegacyQueueSnapshot(preserved.originalLegacySnapshot)
            preserved = try await preserveCurrentWork(in: preserved)
            try await queueAdmin.replaceUnsentBatches(preserved.originalUnsentBatches)
            preserved = try await preserveCurrentWork(in: preserved)
            let localEvidence = preserved.originalLocalEvidence
                ?? preserved.originalLocalObligations.map(SyncConvergenceLocalObligation.init(legacyBatch:))
            try await replaceLocalObligations(localEvidence)
            await queueAdmin.refreshPendingSyncStatus()
            try journalStore.delete()
            if resumeOutbound {
                queueAdmin.resumeOutboundAfterRecovery()
            }
        } catch {
            throw RecoveryError.rollbackFailed
        }
    }

    private func preserveCurrentWork(
        in journal: PendingSyncRecoveryJournal
    ) async throws -> PendingSyncRecoveryJournal {
        let current = try await prepareSnapshots()
        let legacy = SyncQueueSnapshot(
            pendingChanges: preservingLaterWork(
                original: journal.originalLegacySnapshot.pendingChanges,
                replacement: journal.replacementLegacySnapshot.pendingChanges,
                current: current.legacy.pendingChanges,
                id: { $0.id }
            ),
            appliedChangeIDs: Array(Set(journal.originalLegacySnapshot.appliedChangeIDs + current.legacy.appliedChangeIDs)),
            pendingAcknowledgementIDs: Array(Set(journal.originalLegacySnapshot.pendingAcknowledgementIDs + current.legacy.pendingAcknowledgementIDs))
        )
        let unsent = preservingLaterWork(
            original: journal.originalUnsentBatches,
            replacement: journal.replacementUnsentBatches,
            current: current.unsent,
            id: { $0.id }
        )
        let unsentIDs = Set(unsent.map(\.id))
        let local = preservingLaterWork(
            original: journal.originalLocalObligations,
            replacement: journal.replacementLocalObligations,
            current: current.local,
            id: { $0.id }
        ).filter { !unsentIDs.contains($0.id) }
        let originalEvidence = Dictionary(
            (journal.originalLocalEvidence ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentEvidence = Dictionary(
            current.localEvidence.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localEvidence = local.map { batch in
            originalEvidence[batch.id] ?? currentEvidence[batch.id]
                ?? SyncConvergenceLocalObligation(legacyBatch: batch)
        }
        let preserved = PendingSyncRecoveryJournal(
            version: journal.version,
            transactionID: journal.transactionID,
            createdAt: journal.createdAt,
            phase: journal.phase,
            originalLegacySnapshot: legacy,
            originalUnsentBatches: unsent,
            originalLocalObligations: local,
            replacementLegacySnapshot: journal.replacementLegacySnapshot,
            replacementUnsentBatches: journal.replacementUnsentBatches,
            replacementLocalObligations: journal.replacementLocalObligations,
            originalLocalEvidence: localEvidence
        )
        // An interrupted replacement must be able to restore every admission
        // already observed, including transfers from local to unsent ownership.
        try journalStore.save(preserved)
        return preserved
    }

    private func preservingLaterWork<T>(
        original: [T], replacement: [T], current: [T], id: (T) -> UUID
    ) -> [T] {
        let transactionIDs = Set((original + replacement).map(id))
        return original + current.filter { !transactionIDs.contains(id($0)) }
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
        case .corrupt, .unsupportedVersion, .unsupportedAnchoredPayload, .readFailed:
            false
        }
    }
}
