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
        case .quarantined(let work):
            syncController.markConvergenceQuarantined(work)
        }
    }
}

@MainActor
final class MacSyncIncomingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter {
    private let surface: MacSyncIncomingLocalBoundarySurface

    init(surface: MacSyncIncomingLocalBoundarySurface) {
        self.surface = surface
    }

    func prepareForIncomingBodyMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryPreparation {
        switch await surface.prepareForIncomingBodyMutation(noteIDs) {
        case .ready:
            return .ready
        case .localObligation(let obligation):
            return .localObligation(obligation)
        case .staleLocalState(let noteID):
            return .failed(.localStateChanged(noteID: noteID))
        case .failed(let failure):
            return .failed(failure.sharedBoundaryFailure)
        case .invariantViolation(let noteID):
            return .failed(.boundaryInvariantViolation(noteID: noteID))
        }
    }
}

enum MacIncomingBoundaryResult {
    case ready
    case localObligation(SyncConvergenceLocalObligation)
    case staleLocalState(noteID: UUID)
    case failed(MacPendingSaveFailure)
    case invariantViolation(noteID: UUID)
}

private extension MacPendingSaveFailure {
    var sharedBoundaryFailure: SyncConvergenceIncomingLocalBoundaryFailure {
        switch self {
        case .noteMissing(let noteID), .captureFailed(let noteID):
            return .localCaptureFailed(noteID: noteID)
        case .persistenceFailed(let noteID):
            return .localPersistenceFailed(noteID: noteID)
        }
    }
}

@MainActor
struct MacSyncIncomingLocalBoundarySurface {
    let prepareForIncomingBodyMutation: (Set<UUID>) async -> MacIncomingBoundaryResult
}

/// Performs the ordered Mac-side admission check before an incoming body mutation is planned.
@MainActor
struct MacIncomingBoundaryPreparer {
    let selectedNoteID: () -> UUID?
    let hasUnsavedChanges: () -> Bool
    let saveSelectedNoteForBoundary: (UUID) async -> MacIncomingBoundaryResult
    let takePendingObligation: (UUID) async -> SyncConvergenceLocalObligation?

    func prepare(affecting noteIDs: Set<UUID>) async -> MacIncomingBoundaryResult {
        for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if selectedNoteID() == noteID, hasUnsavedChanges() {
                let result = await saveSelectedNoteForBoundary(noteID)
                switch result {
                case .ready:
                    // A no-body result only clears this note; later affected notes still need admission.
                    continue
                case .localObligation, .staleLocalState, .failed, .invariantViolation:
                    return result
                }
            }

            if let obligation = await takePendingObligation(noteID) {
                return .localObligation(obligation)
            }
        }
        return .ready
    }
}
#endif
