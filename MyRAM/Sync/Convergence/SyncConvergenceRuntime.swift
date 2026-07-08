import Foundation
import SwiftData

enum SyncConvergenceRuntimeOutcome {
    case drained(appliedBatchIDs: Set<UUID>)
    case pending(Set<SyncConvergencePostCommitPendingWork>)
    case alreadyDraining
    case blocked(SyncBatchDrainFailure)
}

@MainActor
final class SyncConvergenceRuntime {
    private let context: ModelContext
    private let convergenceQueue: FileBackedSyncBatchQueue
    private let localObligationQueue: FileBackedSyncBatchQueue
    private weak var localBatchTransportAdapter: SyncConvergenceLocalBatchTransportAdapter?
    private let presentationAdapter: SyncConvergencePresentationAdapter
    private let planner = SyncConvergencePlanner()
    private let incorporationExecutor = SyncConvergenceIncorporationExecutor()
    private lazy var postCommitExecutor = SyncConvergencePostCommitExecutor(
        store: SwiftDataSyncConvergencePostCommitStore(context: context),
        queueCleanupAdapter: convergenceQueue,
        presentationAdapter: presentationAdapter
    )
    private lazy var pendingPostCommitSource = SwiftDataSyncConvergencePostCommitStore(context: context)
    private var isDraining = false
    private var drainRequestedWhileActive = false

    init(
        context: ModelContext,
        convergenceQueue: FileBackedSyncBatchQueue,
        localObligationQueue: FileBackedSyncBatchQueue,
        localBatchTransportAdapter: SyncConvergenceLocalBatchTransportAdapter?,
        presentationAdapter: SyncConvergencePresentationAdapter
    ) {
        self.context = context
        self.convergenceQueue = convergenceQueue
        self.localObligationQueue = localObligationQueue
        self.localBatchTransportAdapter = localBatchTransportAdapter
        self.presentationAdapter = presentationAdapter
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
        do {
            try localObligationQueue.enqueueIncoming(batch)
            try await satisfyLocalObligations()
            return .drained(appliedBatchIDs: [])
        } catch {
            return .blocked(SyncBatchDrainFailureClassifier.classify(error, batchID: batch.id))
        }
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

            do {
                try await satisfyLocalObligations()
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
                switch outcome {
                case .complete:
                    continue
                case .pending(let pending):
                    return .pending(pending)
                case .failedBeforeWork:
                    return .blocked(SyncBatchDrainFailure(batchID: request.sourceBatchID, kind: .persistence))
                }
            }

            while let batch = convergenceQueue.first {
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
                        let postCommit = await postCommitExecutor.execute(SyncConvergencePostCommitRequest(result: result))
                        switch postCommit {
                        case .complete:
                            break
                        case .pending(let pending):
                            return .pending(pending)
                        case .failedBeforeWork:
                            return .blocked(SyncBatchDrainFailure(batchID: batch.id, kind: .persistence))
                        }
                    case .alreadyIncorporated(let result):
                        let postCommit = await postCommitExecutor.execute(SyncConvergencePostCommitRequest(result: result))
                        switch postCommit {
                        case .complete:
                            break
                        case .pending(let pending):
                            return .pending(pending)
                        case .failedBeforeWork:
                            return .blocked(SyncBatchDrainFailure(batchID: batch.id, kind: .persistence))
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
                                switch outcome {
                                case .complete:
                                    continue
                                case .pending(let pending):
                                    return .pending(pending)
                                case .failedBeforeWork:
                                    return .blocked(SyncBatchDrainFailure(batchID: cleanupBatchID, kind: .persistence))
                                }
                            case .completed:
                                try convergenceQueue.removeBatches(withIDs: [cleanupBatchID])
                                guard !convergenceQueue.contains(cleanupBatchID) else {
                                    return .blocked(SyncBatchDrainFailure(batchID: cleanupBatchID, kind: .persistence))
                                }
                            case .missing:
                                return .blocked(SyncBatchDrainFailure(batchID: cleanupBatchID, kind: .persistence))
                            }
                        }
                    } catch {
                        return .blocked(SyncBatchDrainFailure(batchID: batch.id, kind: .persistence))
                    }
                case .deferred(let reason):
                    return .blocked(Self.drainFailure(for: reason, batchID: batch.id))
                case .failedBeforeCommit(let failure):
                    return .blocked(Self.drainFailure(for: failure, batchID: batch.id))
                }
            }
        } while drainRequestedWhileActive
        return .drained(appliedBatchIDs: appliedBatchIDs)
    }

    private func satisfyLocalObligations() async throws {
        for batch in localObligationQueue.pendingBatches {
            try registerLocalEvidence(for: batch)
            guard let localBatchTransportAdapter else {
                throw SyncConvergenceLocalBatchTransportError.unavailable
            }
            try await localBatchTransportAdapter.acceptLocalBatch(batch)
            try localObligationQueue.removeBatches(withIDs: [batch.id])
            guard !localObligationQueue.contains(batch.id) else {
                throw SyncConvergenceLocalBatchTransportError.acceptanceNotDurable(batchID: batch.id)
            }
        }
    }

    private func makePlanningInput(for batch: SyncBatch) throws -> SyncConvergencePlanningInput {
        let queued = convergenceQueue.pendingBatches.enumerated().map {
            SyncConvergenceQueuedBatch(batch: $0.element, queuePosition: $0.offset)
        }
        let noteIDs = affectedNoteIDs(in: [batch] + convergenceQueue.pendingBatches)
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

    private func registerLocalEvidence(for batch: SyncBatch) throws {
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        try registerLocalBodyEvidence(for: batch, transaction: transaction)
        try registerLocalTitleEvidence(for: batch, transaction: transaction)
        try transaction.save()
    }

    private func registerLocalBodyEvidence(
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
                let resultHash = SyncBatchContentHash.sha256Hex(for: currentBody)
                let previousBody = try bodyBeforeApplying(change, currentBody: currentBody)
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
            let incorporatedRoots = try context.fetch(FetchDescriptor<IncorporatedSyncBatch>())
                .filter { incorporatedBatchIDs.contains($0.batchID) }
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
            let contradictions = try context.fetch(FetchDescriptor<IncorporationContradictionDiagnostic>())
                .filter { $0.noteID == noteID }
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

    private func affectedNoteIDs(in batches: [SyncBatch]) -> Set<UUID> {
        Set(batches.flatMap { $0.changes.map(Self.noteID(for:)) })
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
        case .unsupportedDigestFormat:
            kind = .unsupportedDigestFormat
        case .unexpected:
            kind = .unexpected
        }
        return SyncBatchDrainFailure(batchID: batchID, kind: kind)
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
            disposition = .reload(.authoritativeConvergencePresentation)
        case .none:
            disposition = .metadataOnly
        }

        let update = ActiveEditorSyncUpdate(
            id: request.incorporationIdentity.batchID,
            noteID: request.noteID,
            metadata: ActiveEditorMetadataUpdate(title: request.committedTitle),
            disposition: disposition
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
