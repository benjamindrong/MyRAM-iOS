#if os(macOS)
import Foundation
import SwiftData

@MainActor
final class MacSyncConvergenceCoordinator {
    private let syncController: MacSyncBatchController
    private let pendingIncomingQueue: FileBackedSyncBatchQueue
    private let localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue
    private let presentationAdapter: MacSyncConvergencePresentationAdapter
    private let incomingBoundaryAdapter: MacSyncIncomingLocalBoundaryAdapter
    private let runtime: SyncConvergenceRuntime

    init(
        context: ModelContext,
        syncController: MacSyncBatchController,
        presentationSurface: MacSyncConvergencePresentationSurface,
        incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface,
        pendingIncomingQueueFileURL: URL? = SyncBatchQueueFileLocation.pendingIncoming(for: .nativeMac),
        localObligationQueueFileURL: URL? = SyncBatchQueueFileLocation.pendingLocalConvergence(for: .nativeMac)
    ) {
        self.syncController = syncController
        pendingIncomingQueue = FileBackedSyncBatchQueue(fileURL: pendingIncomingQueueFileURL)
        localObligationQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationQueueFileURL)
        presentationAdapter = MacSyncConvergencePresentationAdapter(surface: presentationSurface)
        incomingBoundaryAdapter = MacSyncIncomingLocalBoundaryAdapter(surface: incomingBoundarySurface)
        runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: pendingIncomingQueue,
            localObligationQueue: localObligationQueue,
            localBatchTransportAdapter: syncController,
            presentationAdapter: presentationAdapter,
            incomingLocalBoundaryAdapter: incomingBoundaryAdapter
        )
        syncController.convergenceCoordinator = self
    }

    var pendingIncomingBatchCount: Int {
        pendingIncomingQueue.pendingCount
    }

    func submitRemoteBatch(_ batch: SyncBatch) async {
        await handle(outcome: runtime.submitRemoteBatch(batch), sourceBatch: batch)
    }

    func submitLocalBatch(_ batch: SyncBatch) async {
        await handle(outcome: runtime.submitLocalBatch(batch), sourceBatch: batch)
    }

    func submitLocalObligation(_ obligation: SyncConvergenceLocalObligation) async {
        await handle(outcome: runtime.submitLocalObligation(obligation), sourceBatch: obligation.batch)
    }

    func resumePendingWork() async {
        await handle(outcome: runtime.resumePendingWork(), sourceBatch: nil)
    }

    private func handle(outcome: SyncConvergenceRuntimeOutcome, sourceBatch: SyncBatch?) async {
        switch outcome {
        case .drained:
            syncController.clearConvergenceStatus(appliedBatch: sourceBatch)
        case .pending, .deferred, .alreadyDraining:
            syncController.markConvergenceWaiting()
        case .blocked(let failure):
            syncController.markConvergenceBlocked(failure)
        case .quarantined:
            syncController.markConvergenceBlocked(SyncBatchDrainFailure(batchID: sourceBatch?.id, kind: .corruptHistory))
        }
    }
}

@MainActor
final class MacSyncIncomingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter {
    private let surface: MacSyncIncomingLocalBoundarySurface

    init(surface: MacSyncIncomingLocalBoundarySurface) {
        self.surface = surface
    }

    func takePendingLocalObligationIfNeeded(
        beforeIncomingBodyMutationFor noteIDs: Set<UUID>
    ) async -> SyncConvergenceLocalObligation? {
        await surface.flushPendingLocalObligation(noteIDs)
    }
}

@MainActor
struct MacSyncIncomingLocalBoundarySurface {
    let flushPendingLocalObligation: (Set<UUID>) async -> SyncConvergenceLocalObligation?
}
#endif
