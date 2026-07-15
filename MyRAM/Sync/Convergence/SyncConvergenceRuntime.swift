import Foundation
import SwiftData

enum SyncConvergenceRuntimeOutcome {
    case drained(appliedBatchIDs: Set<UUID>)
    case pending(Set<SyncConvergencePostCommitPendingWork>)
    case deferred(SyncConvergenceDeferredWork)
    case quarantined(SyncConvergenceQuarantinedWork)
    case alreadyDraining
    case blocked(SyncBatchDrainFailure)
}

protocol SyncConvergenceIncomingLocalBoundaryAdapter: AnyObject {
    @MainActor
    func prepareForIncomingBodyMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryPreparation
}

enum SyncConvergenceIncomingLocalBoundaryPreparation {
    case ready
    case localObligation(SyncConvergenceLocalObligation)
    case failed(SyncConvergenceIncomingLocalBoundaryFailure)
}

enum SyncConvergenceIncomingLocalBoundaryFailure: Equatable {
    case localCaptureFailed(noteID: UUID)
    case localPersistenceFailed(noteID: UUID)
    case boundaryInvariantViolation(noteID: UUID)
}

enum SyncConvergenceIncomingLocalBoundaryOutcome {
    case ready
    case evidenceRegistered(obligationID: UUID)
    case cannotProceed(SyncConvergenceRuntimeOutcome)
}

/// Captures the document-scale work performed while registering one or more local batches.
final class SyncConvergenceLocalEvidenceMetrics {
    private(set) var wholeBodyHashCount = 0
    private(set) var wholeBodyReconstructionCount = 0
    private(set) var retainedOperationRecordCount = 0
    private(set) var saveCount = 0
    private(set) var submittedBodyOperationCount = 0

    func reset() {
        wholeBodyHashCount = 0
        wholeBodyReconstructionCount = 0
        retainedOperationRecordCount = 0
        saveCount = 0
        submittedBodyOperationCount = 0
    }

    fileprivate func recordSubmittedBodyOperations(_ count: Int) { submittedBodyOperationCount += count }
    fileprivate func recordWholeBodyHash() { wholeBodyHashCount += 1 }
    fileprivate func recordWholeBodyReconstruction() { wholeBodyReconstructionCount += 1 }
    fileprivate func recordRetainedOperation() { retainedOperationRecordCount += 1 }
    fileprivate func recordSave() { saveCount += 1 }
}

@MainActor
final class SyncConvergenceRuntime {
    private let context: ModelContext
    private let container: ModelContainer
    private let convergenceQueue: FileBackedSyncBatchQueue
    private let localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue
    private weak var localBatchTransportAdapter: SyncConvergenceLocalBatchTransportAdapter?
    private let presentationAdapter: SyncConvergencePresentationAdapter
    private let planner = SyncConvergencePlanner()
    private let incorporationExecutor = SyncConvergenceIncorporationExecutor()
    private lazy var postCommitExecutor = SyncConvergencePostCommitExecutor(
        store: SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container)),
        queueCleanupAdapter: convergenceQueue,
        presentationAdapter: presentationAdapter
    )
    private lazy var pendingPostCommitSource = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
    private var isDraining = false
    private var drainRequestedWhileActive = false
    private let localEvidenceMetrics: SyncConvergenceLocalEvidenceMetrics?
    private weak var incomingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter?

    init(
        context: ModelContext,
        convergenceQueue: FileBackedSyncBatchQueue,
        localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue,
        localBatchTransportAdapter: SyncConvergenceLocalBatchTransportAdapter?,
        presentationAdapter: SyncConvergencePresentationAdapter,
        incomingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter? = nil,
        localEvidenceMetrics: SyncConvergenceLocalEvidenceMetrics? = nil
    ) {
        self.context = context
        container = context.container
        self.convergenceQueue = convergenceQueue
        self.localObligationQueue = localObligationQueue
        self.localBatchTransportAdapter = localBatchTransportAdapter
        self.presentationAdapter = presentationAdapter
        self.incomingLocalBoundaryAdapter = incomingLocalBoundaryAdapter
        self.localEvidenceMetrics = localEvidenceMetrics
    }

    func submitRemoteBatch(_ batch: SyncBatch) async -> SyncConvergenceRuntimeOutcome {
        guard !batch.changes.isEmpty else { return .drained(appliedBatchIDs: []) }
        if !convergenceQueue.contains(batch.id) {
            do {
                try convergenceQueue.enqueueIncoming(batch)
            } catch {
                return .blocked(SyncBatchDrainFailureClassifier.classify(error, batchID: batch.id))
            }
        }
        return await drain()
    }

    func submitLocalBatch(_ batch: SyncBatch) async -> SyncConvergenceRuntimeOutcome {
        await submitLocalObligation(SyncConvergenceLocalObligation(legacyBatch: batch))
    }

    func submitLocalObligation(_ obligation: SyncConvergenceLocalObligation) async -> SyncConvergenceRuntimeOutcome {
        do {
            if case .captured = obligation.evidence {
                _ = try SyncConvergenceLocalEvidenceCapture.validate(obligation: obligation)
            }
            try localObligationQueue.enqueue(obligation)
            switch try await satisfyLocalObligations() {
            case .complete:
                return .drained(appliedBatchIDs: [])
            case .deferred(let deferred):
                return .deferred(SyncConvergenceDeferredWork(incoming: [], localObligations: deferred))
            case .quarantined(let quarantined):
                return .quarantined(SyncConvergenceQuarantinedWork(items: quarantined))
            case .blocked(let failure):
                return .blocked(failure)
            }
        } catch {
            return .blocked(SyncBatchDrainFailureClassifier.classify(error, batchID: obligation.id))
        }
    }

    func admitPendingLocalObligationForIncomingMutation(
        _ obligation: SyncConvergenceLocalObligation
    ) async -> SyncConvergenceIncomingLocalBoundaryOutcome {
        await admitLocalObligationForIncomingBoundary(obligation)
    }

    func admitQueuedLocalObligationsForIncomingMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryOutcome {
        for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            for obligation in localObligationQueue.pendingObligations(affecting: noteID) {
                let outcome = await admitLocalObligationForIncomingBoundary(obligation)
                if case .cannotProceed = outcome {
                    return outcome
                }
            }
        }
        return .ready
    }

    func resumePendingWork() async -> SyncConvergenceRuntimeOutcome {
        await drain()
    }

    private func drain() async -> SyncConvergenceRuntimeOutcome {
        guard !isDraining else {
            drainRequestedWhileActive = true
            return .alreadyDraining
        }
        isDraining = true
        defer { isDraining = false }
        var appliedBatchIDs: Set<UUID> = []

        repeat {
            drainRequestedWhileActive = false
            var localDeferredItems: [SyncConvergenceDeferredItem] = []

            do {
                switch try await satisfyLocalObligations() {
                case .complete:
                    break
                case .deferred(let deferred):
                    localDeferredItems = deferred
                case .quarantined(let quarantined):
                    return .quarantined(SyncConvergenceQuarantinedWork(items: quarantined))
                case .blocked(let failure):
                    return .blocked(failure)
                }
            } catch {
                return .blocked(SyncBatchDrainFailureClassifier.classify(error))
            }

            let pendingRequests: [SyncConvergencePostCommitRequest]
            do {
                pendingRequests = try pendingPostCommitSource.loadPendingPostCommitRequests()
            } catch {
                return .blocked(SyncBatchDrainFailure(batchID: nil, kind: .corruptHistory))
            }
            for request in pendingRequests {
                let outcome = await postCommitExecutor.execute(request)
                if let terminal = Self.terminalOutcome(forPostCommit: outcome, batchID: request.sourceBatchID) {
                    return terminal
                }
            }

            var attemptedBatchIDs: Set<UUID> = []
            var blockedNoteIDs: Set<UUID> = []
            var blockedOrigins: Set<UUID> = []
            var deferredItems: [SyncConvergenceDeferredItem] = []
            var madeIncomingProgress = false

            while let candidateIndex = SyncConvergenceDrainPassScheduler.nextEligibleIndex(
                candidates: incomingCandidates(),
                attemptedBatchIDs: attemptedBatchIDs,
                blockedNoteIDs: blockedNoteIDs,
                blockedOrigins: blockedOrigins
            ) {
                let batch = convergenceQueue.pendingBatches[candidateIndex]
                switch await satisfyIncomingLocalBoundary(noteIDs: Self.bodyMutationNoteIDs(in: batch)) {
                case .ready:
                    break
                case .evidenceRegistered:
                    drainRequestedWhileActive = true
                    continue
                case .cannotProceed(let outcome):
                    return outcome
                }
                attemptedBatchIDs.insert(batch.id)
                let input: SyncConvergencePlanningInput
                do {
                    input = try makePlanningInput(for: batch)
                } catch let failure as SyncConvergenceTransactionFailure {
                    return .blocked(Self.drainFailure(for: failure, batchID: batch.id))
                } catch {
                    return .blocked(SyncBatchDrainFailure(batchID: batch.id, kind: .unexpected))
                }
                let planning = planner.plan(input: input)
                switch planning {
                case .planned(let incorporationInput):
                    let incorporation = incorporationExecutor.incorporate(
                        input: incorporationInput,
                        transaction: SwiftDataSyncConvergencePersistenceTransaction(context: context),
                        committedAt: .now
                    )
                    switch incorporation {
                    case .incorporated(let result):
                        appliedBatchIDs.insert(result.batchID)
                        madeIncomingProgress = true
                        let postCommit = await postCommitExecutor.execute(SyncConvergencePostCommitRequest(result: result))
                        if let terminal = Self.terminalOutcome(forPostCommit: postCommit, batchID: batch.id) {
                            return terminal
                        }
                    case .alreadyIncorporated(let result):
                        madeIncomingProgress = true
                        let postCommit = await postCommitExecutor.execute(SyncConvergencePostCommitRequest(result: result))
                        if let terminal = Self.terminalOutcome(forPostCommit: postCommit, batchID: batch.id) {
                            return terminal
                        }
                    case .failedBeforeCommit(let failure), .failedAndRolledBack(let failure):
                        return .blocked(Self.drainFailure(for: failure, batchID: batch.id))
                    }
                case .alreadyIncorporated(let cleanupPlan):
                    do {
                        let cleanupBatchIDs = cleanupPlan.batchIDs.isEmpty ? [batch.id] : Array(cleanupPlan.batchIDs)
                        for cleanupBatchID in cleanupBatchIDs {
                            switch try pendingPostCommitSource.loadPostCommitStatus(forBatchID: cleanupBatchID) {
                            case .pending(let request), .tombstone(let request):
                                let outcome = await postCommitExecutor.execute(request)
                                if let terminal = Self.terminalOutcome(forPostCommit: outcome, batchID: cleanupBatchID) {
                                    return terminal
                                }
                            case .completed:
                                try convergenceQueue.removeBatches(withIDs: [cleanupBatchID])
                                guard !convergenceQueue.contains(cleanupBatchID) else {
                                    return .blocked(SyncBatchDrainFailure(batchID: cleanupBatchID, kind: .persistence))
                                }
                                madeIncomingProgress = true
                            case .missing:
                                return .blocked(SyncBatchDrainFailure(batchID: cleanupBatchID, kind: .persistence))
                            }
                        }
                    } catch {
                        return .blocked(SyncBatchDrainFailure(batchID: batch.id, kind: .persistence))
                    }
                case .deferred(let reason):
                    let affectedNoteIDs = Self.affectedNoteIDs(in: batch)
                    blockedNoteIDs.formUnion(affectedNoteIDs)
                    blockedOrigins.insert(batch.originDeviceID)
                    deferredItems.append(SyncConvergenceDeferredItem(
                        domain: .incoming,
                        batchID: batch.id,
                        affectedNoteIDs: affectedNoteIDs,
                        reason: .planning(reason)
                    ))
                case .failedBeforeCommit(let failure):
                    return .blocked(Self.drainFailure(for: failure, batchID: batch.id))
                }
            }

            if madeIncomingProgress {
                drainRequestedWhileActive = true
            } else if !deferredItems.isEmpty || !localDeferredItems.isEmpty {
                return .deferred(SyncConvergenceDeferredWork(
                    incoming: deferredItems,
                    localObligations: localDeferredItems
                ))
            }
        } while drainRequestedWhileActive
        return .drained(appliedBatchIDs: appliedBatchIDs)
    }

    /// Maps a post-commit executor outcome to a terminal `drain()` result, or `nil` when
    /// draining should continue with the next queued item.
    private static func terminalOutcome(
        forPostCommit outcome: SyncConvergencePostCommitOutcome,
        batchID: UUID?
    ) -> SyncConvergenceRuntimeOutcome? {
        switch outcome {
        case .complete:
            return nil
        case .pending(let pending):
            return .pending(pending)
        case .failedBeforeWork:
            return .blocked(SyncBatchDrainFailure(batchID: batchID, kind: .persistence))
        }
    }

    private enum SyncConvergenceLocalObligationPassOutcome {
        case complete
        case deferred([SyncConvergenceDeferredItem])
        case quarantined([SyncConvergenceQuarantinedItem])
        case blocked(SyncBatchDrainFailure)
    }

    private enum SyncConvergenceLocalAdmissionResult {
        case evidenceRegistered(obligationID: UUID)
    }

    private func satisfyLocalObligations() async throws -> SyncConvergenceLocalObligationPassOutcome {
        var attemptedBatchIDs: Set<UUID> = []
        var blockedNoteIDs: Set<UUID> = []
        var blockedOrigins: Set<UUID> = []
        var deferredItems: [SyncConvergenceDeferredItem] = []
        var quarantinedItems: [SyncConvergenceQuarantinedItem] = []

        while let candidateIndex = SyncConvergenceDrainPassScheduler.nextEligibleIndex(
            candidates: localCandidates(),
            attemptedBatchIDs: attemptedBatchIDs,
            blockedNoteIDs: blockedNoteIDs,
            blockedOrigins: blockedOrigins
        ) {
            let obligation = localObligationQueue.pendingObligations[candidateIndex]
            attemptedBatchIDs.insert(obligation.id)
            do {
                _ = try admitQueuedLocalObligation(obligation)
            } catch SyncConvergenceTransactionFailure.staleAuthoritativeState {
                guard case .legacyMissing = obligation.evidence else {
                    return .blocked(SyncBatchDrainFailure(batchID: obligation.id, kind: .staleAuthoritativeState))
                }
                let affectedNoteIDs = Self.affectedNoteIDs(in: obligation.batch)
                blockedNoteIDs.formUnion(affectedNoteIDs)
                blockedOrigins.insert(obligation.batch.originDeviceID)
                deferredItems.append(SyncConvergenceDeferredItem(
                    domain: .localObligation,
                    batchID: obligation.id,
                    affectedNoteIDs: affectedNoteIDs,
                    reason: .legacyLocalEvidenceStale
                ))
                continue
            } catch let evidenceError as SyncConvergenceLocalEvidenceCaptureError {
                let affectedNoteIDs = Self.affectedNoteIDs(in: obligation.batch)
                blockedNoteIDs.formUnion(affectedNoteIDs)
                blockedOrigins.insert(obligation.batch.originDeviceID)
                quarantinedItems.append(SyncConvergenceQuarantinedItem(
                    domain: .localObligation,
                    batchID: obligation.id,
                    affectedNoteIDs: affectedNoteIDs,
                    originDeviceID: obligation.batch.originDeviceID,
                    reason: Self.quarantineReason(for: evidenceError)
                ))
                continue
            } catch let failure as SyncConvergenceTransactionFailure {
                return .blocked(Self.drainFailure(for: failure, batchID: obligation.id))
            }

            guard let localBatchTransportAdapter else {
                let affectedNoteIDs = Self.affectedNoteIDs(in: obligation.batch)
                blockedNoteIDs.formUnion(affectedNoteIDs)
                blockedOrigins.insert(obligation.batch.originDeviceID)
                deferredItems.append(SyncConvergenceDeferredItem(
                    domain: .localObligation,
                    batchID: obligation.id,
                    affectedNoteIDs: affectedNoteIDs,
                    reason: .transportUnavailable
                ))
                continue
            }
            do {
                try await localBatchTransportAdapter.acceptLocalBatch(obligation.batch)
                try localObligationQueue.removeObligations(withIDs: [obligation.id])
                guard !localObligationQueue.contains(obligation.id) else {
                    return .blocked(SyncBatchDrainFailure(batchID: obligation.id, kind: .queuePersistence))
                }
            } catch {
                return .blocked(SyncBatchDrainFailureClassifier.classify(error, batchID: obligation.id))
            }
        }
        if !quarantinedItems.isEmpty {
            return .quarantined(quarantinedItems)
        }
        return deferredItems.isEmpty ? .complete : .deferred(deferredItems)
    }

    private func satisfyIncomingLocalBoundary(noteIDs: Set<UUID>) async -> SyncConvergenceIncomingLocalBoundaryOutcome {
        guard !noteIDs.isEmpty, let incomingLocalBoundaryAdapter else { return .ready }

        switch await incomingLocalBoundaryAdapter.prepareForIncomingBodyMutation(affecting: noteIDs) {
        case .ready:
            return .ready
        case .localObligation(let obligation):
            return await admitLocalObligationForIncomingBoundary(obligation)
        case .failed(let failure):
            return .cannotProceed(.blocked(Self.drainFailure(for: failure, noteIDs: noteIDs)))
        }
    }

    private static func drainFailure(
        for failure: SyncConvergenceIncomingLocalBoundaryFailure,
        noteIDs: Set<UUID>
    ) -> SyncBatchDrainFailure {
        _ = failure
        _ = noteIDs
        return SyncBatchDrainFailure(batchID: nil, kind: .queuePersistence)
    }

    private func admitLocalObligationForIncomingBoundary(
        _ obligation: SyncConvergenceLocalObligation
    ) async -> SyncConvergenceIncomingLocalBoundaryOutcome {
        do {
            try localObligationQueue.enqueue(obligation)
            _ = try admitQueuedLocalObligation(obligation)
            return .evidenceRegistered(obligationID: obligation.id)
        } catch let evidenceError as SyncConvergenceLocalEvidenceCaptureError {
            return .cannotProceed(.quarantined(SyncConvergenceQuarantinedWork(items: [
                SyncConvergenceQuarantinedItem(
                    domain: .localObligation,
                    batchID: obligation.id,
                    affectedNoteIDs: Self.affectedNoteIDs(in: obligation.batch),
                    originDeviceID: obligation.batch.originDeviceID,
                    reason: Self.quarantineReason(for: evidenceError)
                )
            ])))
        } catch let failure as SyncConvergenceTransactionFailure {
            return .cannotProceed(.blocked(Self.drainFailure(for: failure, batchID: obligation.id)))
        } catch {
            return .cannotProceed(.blocked(SyncBatchDrainFailureClassifier.classify(error, batchID: obligation.id)))
        }
    }

    private func makePlanningInput(for batch: SyncBatch) throws -> SyncConvergencePlanningInput {
        let queued = convergenceQueue.pendingBatches.enumerated().map {
            SyncConvergenceQueuedBatch(batch: $0.element, queuePosition: $0.offset)
        }
        let noteIDs = Self.affectedNoteIDs(in: [batch] + convergenceQueue.pendingBatches)
        return SyncConvergencePlanningInput(
            incomingBatch: batch,
            currentNotes: try loadCurrentNotes(noteIDs: noteIDs),
            retainedSnapshots: try loadRetainedSnapshots(noteIDs: noteIDs),
            retainedLocalOperations: try loadRetainedOperations(noteIDs: noteIDs, source: .local),
            retainedRemoteOperations: try loadRetainedOperations(noteIDs: noteIDs, source: .remote),
            queuedBatches: queued,
            persistedTitleWinners: try loadTitleWinners(noteIDs: noteIDs),
            incorporatedBatches: try loadIncorporatedBatches(batchIDs: Set(queued.map(\.batch.id)).union([batch.id])),
            incorporatedTombstones: try loadIncorporatedTombstones(batchIDs: Set(queued.map(\.batch.id)).union([batch.id])),
            historyStates: try loadHistoryStates(noteIDs: noteIDs),
            candidateQueuePosition: queued.first(where: { $0.batch.id == batch.id })?.queuePosition
        )
    }

    private func incomingCandidates() -> [SyncConvergenceQueueCandidate] {
        convergenceQueue.pendingBatches.enumerated().map { index, batch in
            SyncConvergenceQueueCandidate(
                batchID: batch.id,
                originDeviceID: batch.originDeviceID,
                affectedNoteIDs: Self.affectedNoteIDs(in: batch),
                queuePosition: index
            )
        }
    }

    private func localCandidates() -> [SyncConvergenceQueueCandidate] {
        localObligationQueue.pendingObligations.enumerated().map { index, obligation in
            SyncConvergenceQueueCandidate(
                batchID: obligation.id,
                originDeviceID: obligation.batch.originDeviceID,
                affectedNoteIDs: Self.affectedNoteIDs(in: obligation.batch),
                queuePosition: index
            )
        }
    }

    private func registerLocalEvidence(for obligation: SyncConvergenceLocalObligation) throws {
        let batch = obligation.batch
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
#if DEBUG
        localEvidenceMetrics?.recordSubmittedBodyOperations(
            batch.changes.filter(SyncConvergenceLocalEvidenceCapture.isBodyTextOperation).count
        )
#endif
        switch obligation.evidence {
        case .captured:
            try registerCapturedLocalBodyEvidence(for: obligation, transaction: transaction)
        case .legacyMissing:
            try recoverLegacyLocalBodyEvidence(for: batch, transaction: transaction)
        }
        try registerLocalTitleEvidence(for: batch, transaction: transaction)
        try transaction.save()
#if DEBUG
        localEvidenceMetrics?.recordSave()
#endif
    }

    private func admitQueuedLocalObligation(
        _ obligation: SyncConvergenceLocalObligation
    ) throws -> SyncConvergenceLocalAdmissionResult {
        if case .captured = obligation.evidence {
            _ = try SyncConvergenceLocalEvidenceCapture.validate(obligation: obligation)
        }
        try registerLocalEvidence(for: obligation)
        try verifyRegisteredLocalEvidence(for: obligation)
        return .evidenceRegistered(obligationID: obligation.id)
    }

    private func verifyRegisteredLocalEvidence(for obligation: SyncConvergenceLocalObligation) throws {
        let capturedChanges = try SyncConvergenceLocalEvidenceCapture.validate(obligation: obligation)
        guard !capturedChanges.isEmpty else { return }
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        for (operationIndex, capturedChange) in capturedChanges.enumerated() {
            guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation(capturedChange.change) else { continue }
            guard let evidence = capturedChange.evidence else {
                throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: Self.noteID(for: capturedChange.change))
            }
            let expectedRecord = try retainedOperationRecord(
                batch: obligation.batch,
                change: capturedChange.change,
                operationIndex: operationIndex,
                baseHash: evidence.preBodyHash,
                resultHash: evidence.postBodyHash
            )
            let identity = SyncConvergenceRetainedOperationIdentity(
                batchID: obligation.id,
                operationIndex: operationIndex
            )
            guard let registeredRecord = try transaction.loadRetainedOperation(identity: identity),
                  registeredRecord.source == .local,
                  registeredRecord.operation == expectedRecord else {
                throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: evidence.noteID)
            }
        }
    }

    private func registerCapturedLocalBodyEvidence(
        for obligation: SyncConvergenceLocalObligation,
        transaction: SwiftDataSyncConvergencePersistenceTransaction
    ) throws {
        let capturedChanges = try SyncConvergenceLocalEvidenceCapture.validate(obligation: obligation)
        let batch = obligation.batch

        for (operationIndex, capturedChange) in capturedChanges.enumerated() {
            guard SyncConvergenceLocalEvidenceCapture.isBodyTextOperation(capturedChange.change) else { continue }
            guard let evidence = capturedChange.evidence else {
                throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: Self.noteID(for: capturedChange.change))
            }
            let record = try retainedOperationRecord(
                batch: batch,
                change: capturedChange.change,
                operationIndex: operationIndex,
                baseHash: evidence.preBodyHash,
                resultHash: evidence.postBodyHash
            )
            let identity = SyncConvergenceRetainedOperationIdentity(batchID: batch.id, operationIndex: operationIndex)
            if let existing = try transaction.loadRetainedOperation(identity: identity) {
                guard existing.source == .local,
                      existing.operation == record else {
                    throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: evidence.noteID)
                }
                continue
            }
            try transaction.insertRetainedOperation(record, source: .local)
#if DEBUG
            localEvidenceMetrics?.recordRetainedOperation()
#endif
        }
    }

    private func recoverLegacyLocalBodyEvidence(
        for batch: SyncBatch,
        transaction: SwiftDataSyncConvergencePersistenceTransaction
    ) throws {
        let indexedBodyChanges = batch.changes.enumerated().compactMap { index, change -> (Int, SyncBatchChange)? in
            switch change {
            case .noteBodyTextInserted, .noteBodyTextDeleted:
                return (index, change)
            case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
                return nil
            }
        }
        guard !indexedBodyChanges.isEmpty else { return }

        for (noteID, changes) in Dictionary(grouping: indexedBodyChanges, by: { Self.noteID(for: $0.1) }).sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard var currentBody = try transaction.loadNote(id: noteID)?.body else {
                continue
            }
            var recordsByIndex: [Int: SyncConvergenceRetainedOperationRecord] = [:]
            for (operationIndex, change) in changes.reversed() {
#if DEBUG
                localEvidenceMetrics?.recordWholeBodyHash()
#endif
                let resultHash = SyncBatchContentHash.sha256Hex(for: currentBody)
#if DEBUG
                localEvidenceMetrics?.recordWholeBodyReconstruction()
#endif
                let previousBody = try bodyBeforeApplying(change, currentBody: currentBody)
#if DEBUG
                localEvidenceMetrics?.recordWholeBodyHash()
#endif
                let baseHash = SyncBatchContentHash.sha256Hex(for: previousBody)
                try validateLocalBaseHash(change, reconstructedBaseHash: baseHash)
                recordsByIndex[operationIndex] = try retainedOperationRecord(
                    batch: batch,
                    change: change,
                    operationIndex: operationIndex,
                    baseHash: baseHash,
                    resultHash: resultHash
                )
                currentBody = previousBody
            }

            for operationIndex in recordsByIndex.keys.sorted() {
                let identity = SyncConvergenceRetainedOperationIdentity(batchID: batch.id, operationIndex: operationIndex)
                if let existing = try transaction.loadRetainedOperation(identity: identity) {
                    guard existing.source == .local,
                          existing.operation == recordsByIndex[operationIndex] else {
                        throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: noteID)
                    }
                    continue
                }
                try transaction.insertRetainedOperation(recordsByIndex[operationIndex]!, source: .local)
#if DEBUG
                localEvidenceMetrics?.recordRetainedOperation()
#endif
            }
        }
    }

    private func registerLocalTitleEvidence(
        for batch: SyncBatch,
        transaction: SwiftDataSyncConvergencePersistenceTransaction
    ) throws {
        for (operationIndex, change) in batch.changes.enumerated() {
            guard case .noteTitleChanged(let titleChange) = change else { continue }
            let replayKey = CanonicalReplayKeyPayload(
                replayKey: SyncBatchReplayKey(batch: batch, change: change, operationIndex: operationIndex)
            )
            let currentWinner = try transaction.loadTitleWinner(noteID: titleChange.noteID)
            if let currentWinner,
               try ValidatedCanonicalReplayKey(replayKey) < ValidatedCanonicalReplayKey(currentWinner.canonicalReplayKey) {
                continue
            }
            try transaction.insertOrUpdateTitleWinner(SyncConvergenceTitleWinnerRecord(
                noteID: titleChange.noteID,
                title: titleChange.title,
                canonicalReplayKey: replayKey,
                operationIdentity: OperationIdentityPayload(
                    batchID: batch.id,
                    originDeviceID: batch.originDeviceID,
                    operationIndex: operationIndex,
                    operationKind: Self.operationKind(for: change),
                    canonicalReplayKey: replayKey
                ),
                updatedAt: .now
            ))
        }
    }

    private func retainedOperationRecord(
        batch: SyncBatch,
        change: SyncBatchChange,
        operationIndex: Int,
        baseHash: String,
        resultHash: String
    ) throws -> SyncConvergenceRetainedOperationRecord {
        let replayKey = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: batch, change: change, operationIndex: operationIndex)
        )
        switch change {
        case .noteBodyTextInserted(let inserted):
            return SyncConvergenceRetainedOperationRecord(
                noteID: inserted.noteID,
                batchID: batch.id,
                originDeviceID: batch.originDeviceID,
                operationIndex: operationIndex,
                operationKind: .insert,
                utf16Offset: inserted.utf16Offset,
                utf16Length: nil,
                text: inserted.text,
                expectedText: nil,
                baseContentHash: baseHash,
                resultContentHash: resultHash,
                canonicalReplayKey: replayKey,
                modifiedAt: inserted.modifiedAt
            )
        case .noteBodyTextDeleted(let deleted):
            return SyncConvergenceRetainedOperationRecord(
                noteID: deleted.noteID,
                batchID: batch.id,
                originDeviceID: batch.originDeviceID,
                operationIndex: operationIndex,
                operationKind: .delete,
                utf16Offset: deleted.utf16Offset,
                utf16Length: deleted.utf16Length,
                text: nil,
                expectedText: deleted.expectedText,
                baseContentHash: baseHash,
                resultContentHash: resultHash,
                canonicalReplayKey: replayKey,
                modifiedAt: deleted.modifiedAt
            )
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
            throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: Self.noteID(for: change))
        }
    }

    private func bodyBeforeApplying(_ change: SyncBatchChange, currentBody: String) throws -> String {
        switch change {
        case .noteBodyTextInserted(let inserted):
            guard let range = currentBody.syncBatchSafeUTF16Range(
                location: inserted.utf16Offset,
                length: inserted.text.utf16.count
            ),
                  (currentBody as NSString).substring(with: range) == inserted.text else {
                throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: inserted.noteID)
            }
            let mutable = NSMutableString(string: currentBody)
            mutable.deleteCharacters(in: range)
            return String(mutable)
        case .noteBodyTextDeleted(let deleted):
            guard let expectedText = deleted.expectedText,
                  currentBody.syncBatchSafeUTF16Range(location: deleted.utf16Offset, length: 0) != nil else {
                throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: deleted.noteID)
            }
            let mutable = NSMutableString(string: currentBody)
            mutable.insert(expectedText, at: deleted.utf16Offset)
            return String(mutable)
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
            throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: Self.noteID(for: change))
        }
    }

    private func validateLocalBaseHash(_ change: SyncBatchChange, reconstructedBaseHash: String) throws {
        let declared: String?
        let noteID: UUID
        switch change {
        case .noteBodyTextInserted(let inserted):
            declared = inserted.baseContentHash
            noteID = inserted.noteID
        case .noteBodyTextDeleted(let deleted):
            declared = deleted.baseContentHash
            noteID = deleted.noteID
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
            return
        }
        if let declared, declared != reconstructedBaseHash {
            throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: noteID)
        }
    }

    private func loadCurrentNotes(noteIDs: Set<UUID>) throws -> [SyncConvergenceProjectedNote] {
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        return try noteIDs.compactMap { noteID in
            try transaction.loadNote(id: noteID).map {
                SyncConvergenceProjectedNote(
                    noteID: $0.noteID,
                    folderID: $0.folderID,
                    title: $0.title,
                    body: $0.body,
                    createdAt: $0.createdAt,
                    modifiedAt: $0.modifiedAt
                )
            }
        }
    }

    private func loadTitleWinners(noteIDs: Set<UUID>) throws -> [SyncConvergenceTitleWinnerProjection] {
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        return try noteIDs.compactMap { try transaction.loadTitleWinner(noteID: $0) }
    }

    private func loadIncorporatedBatches(batchIDs: Set<UUID>) throws -> [SyncConvergenceIncorporatedBatchProjection] {
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        return try batchIDs.compactMap { batchID -> SyncConvergenceIncorporatedBatchProjection? in
            guard let root = try transaction.loadIncorporatedBatch(batchID: batchID) else {
                return nil
            }
            return SyncConvergenceIncorporatedBatchProjection(
                batchID: root.batchID,
                noteID: nil,
                canonicalPayloadDigest: root.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: root.canonicalPayloadDigestFormatVersion,
                cleanupPlan: SyncConvergenceCleanupPlan(
                    batchIDs: [root.batchID],
                    retryQueueCleanup: false,
                    retryLegacyCleanup: false,
                    retryPresentationRefresh: false
                )
            )
        }
    }

    private func loadIncorporatedTombstones(batchIDs: Set<UUID>) throws -> [SyncConvergenceIncorporatedBatchProjection] {
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        return try batchIDs.compactMap { batchID -> SyncConvergenceIncorporatedBatchProjection? in
            guard let tombstone = try transaction.loadTombstone(batchID: batchID) else {
                return nil
            }
            return SyncConvergenceIncorporatedBatchProjection(
                batchID: tombstone.batchID,
                noteID: nil,
                canonicalPayloadDigest: tombstone.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: tombstone.canonicalPayloadDigestFormatVersion,
                cleanupPlan: SyncConvergenceCleanupPlan(
                    batchIDs: [tombstone.batchID],
                    retryQueueCleanup: false,
                    retryLegacyCleanup: false,
                    retryPresentationRefresh: false
                )
            )
        }
    }

    private func loadRetainedSnapshots(noteIDs: Set<UUID>) throws -> [SyncConvergenceRetainedSnapshot] {
        try noteIDs.flatMap { noteID -> [SyncConvergenceRetainedSnapshot] in
            let descriptor = FetchDescriptor<NoteContentSnapshot>(
                predicate: #Predicate { $0.noteID == noteID },
                sortBy: [SortDescriptor(\.generation)]
            )
            return try context.fetch(descriptor).map {
                SyncConvergenceRetainedSnapshot(
                    noteID: $0.noteID,
                    contentHash: $0.contentHash,
                    body: $0.body,
                    generation: $0.generation
                )
            }
        }
    }

    private func loadRetainedOperations(
        noteIDs: Set<UUID>,
        source: SyncConvergenceRetainedOperationSource
    ) throws -> [SyncConvergenceRetainedOperation] {
        try noteIDs.flatMap { noteID -> [SyncConvergenceRetainedOperation] in
            let sourceRaw = source.rawValue
            let descriptor = FetchDescriptor<RetainedBodyOperation>(
                predicate: #Predicate { $0.noteID == noteID && $0.sourceRaw == sourceRaw },
                sortBy: [SortDescriptor(\.modifiedAt)]
            )
            return try context.fetch(descriptor).map { model in
                guard let kind = SyncConvergencePlannedBodyOperation.Kind(rawValue: model.operationKindRaw) else {
                    throw SyncConvergenceTransactionFailure.corruptHistory(noteID: model.noteID)
                }
                let replayKey = try CanonicalReplayKeyPayload.decodeEvidenceData(model.canonicalReplayKeyPayloadData)
                return SyncConvergenceRetainedOperation(
                    noteID: model.noteID,
                    batchID: model.batchID,
                    originDeviceID: model.originDeviceID,
                    operationIndex: model.operationIndex,
                    operationKind: kind,
                    utf16Offset: model.utf16Offset,
                    utf16Length: model.utf16Length,
                    text: model.text,
                    expectedText: model.expectedText,
                    baseContentHash: model.baseContentHash,
                    resultContentHash: model.resultContentHash,
                    canonicalReplayKey: replayKey
                )
            }
        }
    }

    private func loadHistoryStates(noteIDs: Set<UUID>) throws -> [SyncConvergenceHistoryAccountingProjection] {
        try noteIDs.map { noteID in
            let snapshots = try context.fetch(FetchDescriptor<NoteContentSnapshot>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let retainedOperations = try context.fetch(FetchDescriptor<RetainedBodyOperation>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let provenance = try context.fetch(FetchDescriptor<ExplicitDeleteProvenance>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let diagnostics = try context.fetch(FetchDescriptor<ConvergenceNoteDiagnosticState>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let blockingReferences = try context.fetch(FetchDescriptor<ConvergenceBlockingBatchReference>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let roots = try context.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let incorporatedBatchIDs = Set(roots.map(\.batchID))
            let incorporatedRoots = try incorporatedBatchIDs.map { batchID in
                let descriptor = FetchDescriptor<IncorporatedSyncBatch>(
                    predicate: #Predicate { $0.batchID == batchID }
                )
                guard let root = try context.fetch(descriptor).first else {
                    throw SyncConvergenceTransactionFailure.corruptHistory(noteID: noteID)
                }
                return root
            }
            for root in incorporatedRoots {
                let affectedNoteIDs = try SyncConvergenceAffectedNotesPayloadV1
                    .decodeData(root.affectedNotesPayloadData)
                    .noteIDs
                guard affectedNoteIDs.contains(noteID) else {
                    throw SyncConvergenceTransactionFailure.corruptHistory(noteID: noteID)
                }
            }
            let operationIdentities = try context.fetch(FetchDescriptor<IncorporatedBatchOperationIdentity>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let resultEvidence = try context.fetch(FetchDescriptor<IncorporatedBatchResultEvidence>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let incorporationBlockingReferences = try context.fetch(FetchDescriptor<IncorporationBlockingReference>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let contradictions = try context.fetch(FetchDescriptor<IncorporationContradictionDiagnostic>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let compactionStates = try context.fetch(FetchDescriptor<NoteHistoryCompactionState>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let reconciliationEpisodes = try context.fetch(FetchDescriptor<ReconciliationEpisode>(
                predicate: #Predicate { $0.noteID == noteID }
            ))
            let persistedCleanupBytes = compactionStates.reduce(0) { $0 + $1.cleanupEvidenceBytes }
            let activeReconciliationEpisodes = reconciliationEpisodes.filter { $0.completedAtBitPattern == nil }
            let completedReconciliationEpisodes = reconciliationEpisodes.filter { $0.completedAtBitPattern != nil }
            let reconciliationEvidenceBytes = reconciliationEpisodes.reduce(0) {
                $0 + $1.logicalGroupingPayloadData.count
            }
            return SyncConvergenceHistoryAccountingProjection(
                noteID: noteID,
                snapshotCount: snapshots.count,
                retainedOperationCount: retainedOperations.count,
                snapshotBytes: snapshots.reduce(0) { $0 + $1.bodyUTF8ByteCount },
                retainedOperationBytes: retainedOperations.reduce(0) { $0 + $1.payloadUTF8ByteCount },
                explicitDeleteProvenanceCount: provenance.count,
                explicitDeleteProvenanceBytes: provenance.reduce(0) { $0 + $1.payloadByteCount },
                fullIncorporationEvidenceBytes: fullIncorporationEvidenceBytes(
                    roots: incorporatedRoots,
                    noteEffects: roots,
                    operationIdentities: operationIdentities,
                    resultEvidence: resultEvidence
                ),
                diagnosticEvidenceBytes: diagnostics.reduce(0) { $0 + $1.diagnosticEvidencePayloadData.count }
                    + blockingReferences.reduce(0) { $0 + $1.payloadUTF8ByteCount }
                    + incorporationBlockingReferences.reduce(0) { $0 + $1.payloadUTF8ByteCount }
                    + contradictions.reduce(0) { $0 + $1.payloadUTF8ByteCount },
                cleanupEvidenceBytes: persistedCleanupBytes,
                completedReconciliationEpisodeCount: completedReconciliationEpisodes.count,
                activeReconciliationEpisodeCount: activeReconciliationEpisodes.count,
                reconciliationEvidenceBytes: reconciliationEvidenceBytes
            )
        }
    }

#if DEBUG
    /// Exposes the production history projection to structural scalability tests.
    func loadHistoryStatesForTesting(noteIDs: Set<UUID>) throws -> [SyncConvergenceHistoryAccountingProjection] {
        try loadHistoryStates(noteIDs: noteIDs)
    }
#endif

    private func fullIncorporationEvidenceBytes(
        roots: [IncorporatedSyncBatch],
        noteEffects: [IncorporatedBatchNoteEffect],
        operationIdentities: [IncorporatedBatchOperationIdentity],
        resultEvidence: [IncorporatedBatchResultEvidence]
    ) -> Int {
        roots.reduce(0) {
            $0
                + $1.affectedNotesPayloadData.count
                + $1.authoritativeChildBytes
                + ($1.postCommitWorkPayloadData?.count ?? 0)
                + $1.postCommitStatePayloadData.count
        }
        + noteEffects.reduce(0) {
            $0
                + ($1.preTitleKeyPayloadData?.count ?? 0)
                + ($1.postTitleKeyPayloadData?.count ?? 0)
        }
        + operationIdentities.reduce(0) { $0 + $1.payloadUTF8ByteCount }
        + resultEvidence.reduce(0) { $0 + $1.payloadUTF8ByteCount }
    }

    private static func affectedNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.map(Self.noteID(for:)))
    }

    private static func affectedNoteIDs(in batches: [SyncBatch]) -> Set<UUID> {
        Set(batches.flatMap { $0.changes.map(Self.noteID(for:)) })
    }

    private static func bodyMutationNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.compactMap { change -> UUID? in
            switch change {
            case .noteCreated(let payload):
                return payload.noteID
            case .noteBodyTextInserted(let payload):
                return payload.noteID
            case .noteBodyTextDeleted(let payload):
                return payload.noteID
            case .noteBodyReconciled(let payload):
                return payload.noteID
            case .noteTitleChanged:
                return nil
            }
        })
    }

    private static func noteID(for change: SyncBatchChange) -> UUID {
        switch change {
        case .noteCreated(let change):
            return change.noteID
        case .noteTitleChanged(let change):
            return change.noteID
        case .noteBodyTextInserted(let change):
            return change.noteID
        case .noteBodyTextDeleted(let change):
            return change.noteID
        case .noteBodyReconciled(let change):
            return change.noteID
        }
    }

    private static func operationKind(for change: SyncBatchChange) -> String {
        switch change {
        case .noteCreated:
            return "create"
        case .noteTitleChanged:
            return "title"
        case .noteBodyTextInserted:
            return "insert"
        case .noteBodyTextDeleted:
            return "delete"
        case .noteBodyReconciled:
            return "reconcile"
        }
    }

    private static func drainFailure(
        for failure: SyncConvergenceTransactionFailure,
        batchID: UUID
    ) -> SyncBatchDrainFailure {
        let kind: SyncBatchDrainFailureKind
        switch failure {
        case .swiftDataFetch, .swiftDataSave:
            kind = .persistence
        case .corruptHistory:
            kind = .corruptHistory
        case .invalidMergePlan:
            kind = .invalidMergePlan
        case .inconsistentIncorporationState:
            kind = .inconsistentIncorporationState
        case .staleAuthoritativeState:
            kind = .staleAuthoritativeState
        case .unprovenTextLoss:
            kind = .unprovenTextLoss
        case .unsupportedDigestFormat:
            kind = .unsupportedDigestFormat
        case .unexpected:
            kind = .unexpected
        }
        return SyncBatchDrainFailure(batchID: batchID, kind: kind)
    }

    private static func quarantineReason(
        for error: SyncConvergenceLocalEvidenceCaptureError
    ) -> SyncConvergenceQuarantineReason {
        switch error {
        case .continuityViolation:
            return .localEvidenceContinuityViolation
        case .indexedChangeMismatch:
            return .localEvidenceIndexMismatch
        case .invalidBodyOperation, .missingBodyEvidence:
            return .localEvidenceInvalidOperation
        case .mismatchedBaseHash:
            return .localEvidenceBaseHashMismatch
        }
    }

    private static func drainFailure(
        for reason: SyncConvergenceDeferredReason,
        batchID: UUID
    ) -> SyncBatchDrainFailure {
        let kind: SyncBatchDrainFailureKind
        switch reason {
        case .unreconstructableBase:
            kind = .mismatchedBase
        case .unsupportedReconciliation:
            kind = .unsupportedReconciliation
        case .historyPressure:
            kind = .corruptHistory
        }
        return SyncBatchDrainFailure(batchID: batchID, kind: kind)
    }
}

#if os(iOS)
final class NotesViewModelConvergencePresentationAdapter: SyncConvergencePresentationAdapter {
    private weak var viewModel: NotesViewModel?

    init(viewModel: NotesViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func refreshPresentation(for request: SyncConvergencePresentationRequest) async -> SyncConvergencePostCommitAdapterResult {
        guard let viewModel else { return .verifiedComplete }
        guard viewModel.currentNote?.id == request.noteID else { return .verifiedComplete }
        guard request.routing == .none || request.committedBodyHash == request.committedPostBodyHash else {
            return .verifiedComplete
        }

        let disposition: ActiveEditorSyncDisposition
        switch request.routing {
        case .incremental:
            let mutations = request.incrementalOperations.compactMap(AppliedEditorMutation.init(postCommitOperation:))
            guard mutations.count == request.incrementalOperations.count else { return .failed }
            disposition = .apply(AppliedEditorMutationBatch(
                noteID: request.noteID,
                mutations: mutations,
                authoritativeBody: request.committedNote.body
            ))
        case .wholeNoteFallback:
            guard let receipt = request.rewriteSafetyReceipt,
                  receipt.noteID == request.noteID,
                  receipt.priorBodyHash == request.expectedPreBodyHash,
                  receipt.candidateBodyHash == request.committedPostBodyHash else {
                return .stillPending
            }
            disposition = .reload(.authoritativeConvergencePresentation)
        case .none:
            disposition = .metadataOnly
        }

        let update = ActiveEditorSyncUpdate(
            id: request.incorporationIdentity.batchID,
            noteID: request.noteID,
            metadata: ActiveEditorMetadataUpdate(title: request.committedTitle),
            disposition: disposition,
            expectedPreBodyHash: request.routing == .wholeNoteFallback ? request.expectedPreBodyHash : nil
        )
        return await viewModel.publishConvergencePresentationUpdate(
            update,
            incorporationIdentity: request.incorporationIdentity
        )
    }
}
#endif

private extension AppliedEditorMutation {
    init?(postCommitOperation operation: SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload) {
        switch operation.kind {
        case .insert:
            guard let text = operation.text else { return nil }
            self = .bodyInsertion(
                AppliedEditorBodyInsertion(
                    noteID: operation.noteID,
                    utf16Offset: operation.utf16Offset,
                    text: text,
                    modifiedAt: operation.operationIdentity.canonicalReplayKey.modifiedAt
                )
            )
        case .delete:
            guard let utf16Length = operation.utf16Length,
                  let expectedText = operation.expectedText else { return nil }
            self = .bodyDeletion(
                AppliedEditorBodyDeletion(
                    noteID: operation.noteID,
                    range: NSRange(location: operation.utf16Offset, length: utf16Length),
                    deletedText: expectedText,
                    modifiedAt: operation.operationIdentity.canonicalReplayKey.modifiedAt
                )
            )
        }
    }
}
