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
        conflictStore: SyncConflictStore,
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
            incomingLocalBoundaryAdapter: incomingBoundaryAdapter,
            conflictStore: conflictStore,
            anchoredRecoveryPlatform: .nativeMac
        )
        syncController.convergenceCoordinator = self
    }

    var pendingIncomingBatchCount: Int {
        pendingIncomingQueue.pendingCount
    }

    /// Durably persists an incoming batch's raw bytes, independent of whatever
    /// `submitRemoteBatch` later does with them. This is what the transport layer
    /// checks before convergence. Durable capture is necessary but does not by
    /// itself permit acknowledgement; the convergence disposition controls ACK,
    /// leaving the sender's durable copy available when work is deferred or rejected.
    func durablyCaptureIncomingBatch(_ batch: SyncBatch) -> Bool {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateInbound(batch)) != nil else {
            return false
        }
        guard !batch.changes.isEmpty else { return true }
        if pendingIncomingQueue.contains(batch.id) { return true }
        do {
            try pendingIncomingQueue.enqueueIncoming(batch)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func submitRemoteBatch(_ batch: SyncBatch) async -> SyncConvergenceRemoteBatchDisposition {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateConvergence(batch)) != nil else {
            return .acknowledgementPermitted
        }
        let outcome = await runtime.submitRemoteBatch(batch)
        await handle(outcome: outcome, sourceBatch: batch)
        return SyncConvergenceRemoteBatchDispositionPolicy.disposition(
            for: outcome,
            batchID: batch.id
        )
    }

    func submitLocalObligation(_ obligation: SyncConvergenceLocalObligation) async {
        guard (try? SyncBatchAnchoredPayloadPolicy.validateConvergence(obligation.batch)) != nil else {
            return
        }
        await handle(outcome: runtime.submitLocalObligation(obligation), sourceBatch: obligation.batch)
    }

    func resumePendingWork() async {
        await handle(outcome: runtime.resumePendingWork(), sourceBatch: nil)
    }

    func refreshAfterBootstrap() {
        presentationAdapter.refreshAfterBootstrap()
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

/// Serializes persistence and accumulator publication for one note while allowing later revisions to wait safely.
@MainActor
final class MacNoteSaveSingleFlight {
    private var activeOperations: [UUID: ActiveOperation] = [:]

    func complete(
        attempt: MacEditorSaveAttempt,
        stillOwnsAttempt: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor () async -> MacNoteSaveOperationCompletion
    ) async -> MacNoteSaveOperationCompletion {
        if let active = activeOperations[attempt.noteID] {
            let completion = await active.task.value
            if active.editorRevision != attempt.editorRevision {
                guard stillOwnsAttempt() else {
                    return .supersededBeforeStart(attempt: attempt)
                }
                // The current revision waited behind an older publication and now owns the slot.
                return await complete(
                    attempt: attempt,
                    stillOwnsAttempt: stillOwnsAttempt,
                    operation: operation
                )
            }
            return completion
        }

        let task = Task { @MainActor in
            let completion = await operation()
            if activeOperations[attempt.noteID]?.attemptID == attempt.id {
                activeOperations[attempt.noteID] = nil
            }
            return completion
        }
        activeOperations[attempt.noteID] = ActiveOperation(
            attemptID: attempt.id,
            editorRevision: attempt.editorRevision,
            task: task
        )
        return await task.value
    }

    private struct ActiveOperation {
        let attemptID: UUID
        let editorRevision: UUID
        let task: Task<MacNoteSaveOperationCompletion, Never>
    }
}

struct MacEditorSaveAttempt {
    let id = UUID()
    let noteID: UUID
    let editorRevision: UUID
    let attributedContent: NSAttributedString
}

enum MacNoteSaveMutationKind {
    case none
    case nonBodyOnly
    case body
}

enum MacNoteSavePublicationOutcome {
    case none
    case ordinaryRecorded
    case boundaryExtracted(SyncConvergenceLocalObligation?)
}

enum MacNoteSaveOperationCompletion {
    case completed(
        attempt: MacEditorSaveAttempt,
        mutationKind: MacNoteSaveMutationKind,
        publication: MacNoteSavePublicationOutcome
    )
    case supersededBeforeStart(attempt: MacEditorSaveAttempt)
    case failed(attempt: MacEditorSaveAttempt, failure: MacPendingSaveFailure)
}

enum MacEditorSaveOwnership {
    static func owns(
        selectedNoteID: UUID?,
        editorRevision: UUID,
        attempt: MacEditorSaveAttempt
    ) -> Bool {
        selectedNoteID == attempt.noteID && editorRevision == attempt.editorRevision
    }

    static func flushMayProceed(for result: MacPendingSaveResult) -> Bool {
        switch result {
        case .noChanges, .savedWithoutBodyMutation, .savedWithPendingBodyMutation:
            true
        case .superseded, .failed:
            false
        }
    }
}

/// Owns the editor-visible consequences of a save completion so stale work cannot mutate newer state.
struct MacEditorSaveState {
    let selectedNoteID: UUID?
    let editorRevision: UUID
    var hasUnsavedChanges: Bool
    var saveError: String?

    mutating func pendingResult(
        for completion: MacNoteSaveOperationCompletion,
        requestedAttempt: MacEditorSaveAttempt
    ) -> MacPendingSaveResult {
        switch completion {
        case .failed(let attempt, let failure):
            setSaveError(for: attempt, failure: failure)
            return .failed(failure)
        case .supersededBeforeStart:
            return .superseded(noteID: requestedAttempt.noteID)
        case .completed(let attempt, let mutationKind, _):
            guard owns(requestedAttempt), owns(attempt) else {
                return .superseded(noteID: requestedAttempt.noteID)
            }
            hasUnsavedChanges = false
            saveError = nil
            switch mutationKind {
            case .none:
                return .noChanges
            case .nonBodyOnly:
                return .savedWithoutBodyMutation
            case .body:
                return .savedWithPendingBodyMutation(noteID: attempt.noteID)
            }
        }
    }

    mutating func setSaveError(for attempt: MacEditorSaveAttempt, failure: MacPendingSaveFailure) {
        guard owns(attempt) else { return }
        switch failure {
        case .noteMissing:
            saveError = "Unable to save note: note was not found."
        case .captureFailed:
            saveError = "Unable to save note: local edit capture failed."
        case .persistenceFailed:
            saveError = "Unable to save note: local edit persistence failed."
        }
    }

    mutating func markBoundaryReadyIfOwned(
        requestedAttempt: MacEditorSaveAttempt,
        completingAttempt: MacEditorSaveAttempt,
        result: MacIncomingBoundaryResult
    ) {
        guard case .ready = result, owns(requestedAttempt), owns(completingAttempt) else { return }
        hasUnsavedChanges = false
        saveError = nil
    }

    private func owns(_ attempt: MacEditorSaveAttempt) -> Bool {
        MacEditorSaveOwnership.owns(
            selectedNoteID: selectedNoteID,
            editorRevision: editorRevision,
            attempt: attempt
        )
    }
}

enum MacIncomingBoundaryCompletionPolicy {
    static func result(
        for completion: MacNoteSaveOperationCompletion,
        obligation: SyncConvergenceLocalObligation?,
        requestedAttemptStillOwnsEditor: Bool,
        completingAttemptStillOwnsEditor: Bool
    ) -> MacIncomingBoundaryResult {
        switch completion {
        case .failed(_, let failure):
            return .failed(failure)
        case .supersededBeforeStart(let attempt):
            return .staleLocalState(noteID: attempt.noteID)
        case .completed(let attempt, let mutationKind, _):
            if let obligation {
                return .localObligation(obligation)
            }
            if mutationKind == .body {
                return .invariantViolation(noteID: attempt.noteID)
            }
            guard requestedAttemptStillOwnsEditor, completingAttemptStillOwnsEditor else {
                return .staleLocalState(noteID: attempt.noteID)
            }
            return .ready
        }
    }
}
#endif
