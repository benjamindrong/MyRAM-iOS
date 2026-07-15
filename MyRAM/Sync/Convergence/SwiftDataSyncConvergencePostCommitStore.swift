import Foundation
import SwiftData

final class SwiftDataSyncConvergencePostCommitStore: SyncConvergencePostCommitStateStore {
    private let context: ModelContext
    private let container: ModelContainer

    #if DEBUG
    enum TestOnlySaveSite {
        case backfill
        case compareAndSet
    }

    enum TestOnlyPostSaveMutation {
        case contradictoryIndex
        case selfConsistentUnexpectedState
    }

    private(set) var testOnlyLastCandidateFetchCount = 0
    private(set) var testOnlyLastBackfillSaveCount = 0
    var testOnlyFailNextSaveAt: TestOnlySaveSite?
    var testOnlyPostSaveMutation: TestOnlyPostSaveMutation?
    #endif

    init(context: ModelContext) {
        self.context = context
        container = context.container
    }

    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState {
        let identityBatchID = identity.batchID
        if let modelRoot = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == identityBatchID }) {
            guard modelRoot.matches(identity) else { return .inconsistent }
            let root = try rootProjection(modelRoot)
            do {
                let state = try decodeAndValidatePostCommitState(modelRoot)
                let workPayload = try decodeWorkPayload(root: root, state: state)
                return .fullRoot(SyncConvergencePostCommitFullRootState(
                    root: root,
                    postCommitState: state,
                    postCommitStatePayloadData: root.postCommitStatePayloadData,
                    postCommitWorkPayload: workPayload,
                    postCommitWorkPayloadData: root.postCommitWorkPayloadData
                ))
            } catch {
                if let failure = error as? SyncConvergencePostCommitFailure {
                    throw failure
                }
                throw SyncConvergencePostCommitFailure.malformedPostCommitState(batchID: identity.batchID)
            }
        }

        if let tombstone = try loadTombstone(batchID: identity.batchID) {
            return tombstone.matches(identity) ? .tombstone(tombstone) : .inconsistent
        }

        return .missing
    }

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? {
        try fetchOne(Note.self, #Predicate { $0.id == id }).map {
            SyncConvergenceMutableNoteRecord(
                noteID: $0.id,
                folderID: $0.folder?.id,
                title: $0.title,
                body: $0.content,
                createdAt: $0.createdAt,
                modifiedAt: $0.modifiedAt
            )
        }
    }

    func compareAndSetPostCommitState(
        expectedRoot: SyncConvergencePostCommitRootSnapshot,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState {
        let identity = expectedRoot.root.persistedIdentity
        let batchID = identity.batchID
        guard let root = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }) else {
            throw SyncConvergencePostCommitFailure.missingAuthoritativeIncorporation(batchID: identity.batchID)
        }
        let currentSnapshot = try rootProjection(root)
        guard currentSnapshot == expectedRoot.root,
              root.matches(identity),
              root.postCommitStatePayloadData == expectedPayloadData else {
            throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: identity.batchID)
        }
        _ = try decodeAndValidatePostCommitState(root)

        let originalWorkPayloadData = root.postCommitWorkPayloadData
        let encodedState = try SyncConvergenceStableEncoding.encode(newState)
        root.postCommitStatePayloadData = encodedState
        root.hasPendingPostCommitWork = newState.hasPendingWork
        do {
            #if DEBUG
            try testOnlyThrowIfRequested(at: .compareAndSet)
            #endif
            try context.save()
        } catch {
            context.rollback()
            throw SyncConvergencePostCommitFailure.persistence
        }

        let identityBatchID = identity.batchID
        guard let reloadedModel = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == identityBatchID }) else {
            throw SyncConvergencePostCommitFailure.persistence
        }
        #if DEBUG
        try testOnlyApplyPostSaveMutationIfRequested(to: reloadedModel, expectedState: newState)
        #endif
        let reloaded = try rootProjection(reloadedModel)
        let reloadedState = try decodeAndValidatePostCommitState(reloadedModel)
        guard reloaded.matches(identity),
              reloadedState == newState,
              reloaded.postCommitStatePayloadData == encodedState,
              reloadedModel.hasPendingPostCommitWork == newState.hasPendingWork,
              reloaded.postCommitWorkPayloadData == originalWorkPayloadData,
              reloaded == SyncConvergenceIncorporatedRootProjection(
                batchID: currentSnapshot.batchID,
                originDeviceID: expectedRoot.root.originDeviceID,
                createdAt: expectedRoot.root.createdAt,
                batchSequence: expectedRoot.root.batchSequence,
                schemaVersion: expectedRoot.root.schemaVersion,
                committedAt: expectedRoot.root.committedAt,
                canonicalPayloadDigest: expectedRoot.root.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: expectedRoot.root.canonicalPayloadDigestFormatVersion,
                committedResultDigest: expectedRoot.root.committedResultDigest,
                committedResultDigestFormatVersion: expectedRoot.root.committedResultDigestFormatVersion,
                committedAtOrderingPayloadData: expectedRoot.root.committedAtOrderingPayloadData,
                affectedNotesPayloadData: expectedRoot.root.affectedNotesPayloadData,
                authoritativeChildCount: expectedRoot.root.authoritativeChildCount,
                authoritativeChildBytes: expectedRoot.root.authoritativeChildBytes,
                authoritativeChildrenDigest: expectedRoot.root.authoritativeChildrenDigest,
                postCommitWorkPayloadData: originalWorkPayloadData,
                postCommitStatePayloadData: encodedState
              )
        else {
            throw SyncConvergencePostCommitFailure.persistence
        }
        return SyncConvergencePostCommitFullRootState(
            root: reloaded,
            postCommitState: reloadedState,
            postCommitStatePayloadData: encodedState,
            postCommitWorkPayload: try reloaded.postCommitWorkPayloadData.map(SyncConvergencePostCommitWorkPayloadV1.decodePayloadData),
            postCommitWorkPayloadData: reloaded.postCommitWorkPayloadData
        )
    }

    private func decodeWorkPayload(
        root: SyncConvergenceIncorporatedRootProjection,
        state: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitWorkPayloadV1? {
        guard let data = root.postCommitWorkPayloadData else {
            if state == .none { return nil }
            throw SyncConvergencePostCommitFailure.missingPostCommitWorkPayload(batchID: root.batchID)
        }
        do {
            let payload = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(data)
            try payload.validateCurrentState(state)
            try validateWorkPayload(payload, againstAuthoritativeRowsFor: root)
            return payload
        } catch let failure as SyncConvergencePostCommitFailure {
            throw failure
        } catch SyncConvergencePostCommitWorkPayloadError.contradictoryState {
            throw SyncConvergencePostCommitFailure.contradictoryPostCommitWorkPayload(batchID: root.batchID)
        } catch {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: root.batchID)
        }
    }

    private func loadRoot(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection? {
        try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }).map(rootProjection)
    }

    private func rootProjection(_ root: IncorporatedSyncBatch) throws -> SyncConvergenceIncorporatedRootProjection {
        let committedAtOrderingPayload = CommittedAtOrderingPayload(batchID: root.batchID, committedAt: root.committedAt)
        try committedAtOrderingPayload.validate(against: root)
        return SyncConvergenceIncorporatedRootProjection(
            batchID: root.batchID,
            originDeviceID: root.originDeviceID,
            createdAt: root.createdAt,
            batchSequence: root.batchSequence,
            schemaVersion: root.schemaVersion,
            committedAt: root.committedAt,
            canonicalPayloadDigest: root.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: root.canonicalPayloadDigestFormatVersion,
            committedResultDigest: root.committedResultDigest,
            committedResultDigestFormatVersion: root.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: try committedAtOrderingPayload.encodedEvidenceData(),
            affectedNotesPayloadData: root.affectedNotesPayloadData,
            authoritativeChildCount: root.authoritativeChildCount,
            authoritativeChildBytes: root.authoritativeChildBytes,
            authoritativeChildrenDigest: root.authoritativeChildrenDigest,
            postCommitWorkPayloadData: root.postCommitWorkPayloadData,
            postCommitStatePayloadData: root.postCommitStatePayloadData
        )
    }

    private func validateWorkPayload(
        _ payload: SyncConvergencePostCommitWorkPayloadV1,
        againstAuthoritativeRowsFor root: SyncConvergenceIncorporatedRootProjection
    ) throws {
        for entry in payload.presentationEntries {
            for operation in entry.incrementalOperations {
                try validateWorkOperation(
                    operation,
                    entryNoteID: entry.noteID,
                    root: root
                )
            }
        }
    }

    private func validateWorkOperation(
        _ operation: SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload,
        entryNoteID: UUID,
        root: SyncConvergenceIncorporatedRootProjection
    ) throws {
        let operationIndex = operation.operationIndex
        let row = try authoritativeIdentityRow(
            batchID: root.batchID,
            operationIndex: operationIndex
        )
        let identityKey = SyncConvergenceKey.batchOperationIdentity(batchID: root.batchID, operationIndex: operationIndex)
        guard row.batchID == root.batchID,
              row.noteID == entryNoteID,
              row.operationIndex == operationIndex,
              row.payloadUTF8ByteCount == row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: root.batchID)
        }
        let authoritativeReplayKey = try CanonicalReplayKeyPayload.decodeEvidenceData(row.canonicalReplayKeyPayloadData)
        let authoritativeIdentity = try OperationIdentityPayload.decodePayloadData(row.operationIdentityPayloadData)
        guard row.identityKey == identityKey,
              authoritativeIdentity.canonicalReplayKey == authoritativeReplayKey,
              authoritativeReplayKey.batchIDLowercase == root.batchID.uuidString.lowercased(),
              authoritativeReplayKey.originDeviceIDLowercase == root.originDeviceID.uuidString.lowercased(),
              authoritativeReplayKey.batchIDLowercase == authoritativeIdentity.batchIDLowercase,
              authoritativeReplayKey.originDeviceIDLowercase == authoritativeIdentity.originDeviceIDLowercase,
              authoritativeReplayKey.operationIndex == authoritativeIdentity.operationIndex,
              authoritativeIdentity.operationIndex == operationIndex,
              authoritativeIdentity.operationKind == operation.kind.rawValue,
              authoritativeIdentity == operation.operationIdentity else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: root.batchID)
        }
    }

    private func authoritativeIdentityRow(
        batchID: UUID,
        operationIndex: Int
    ) throws -> IncorporatedBatchOperationIdentity {
        let rows = try fetchIdentityRows(batchID: batchID, operationIndex: operationIndex)
        guard rows.count == 1, let row = rows.first else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: batchID)
        }
        return row
    }

    private func fetchIdentityRows(
        batchID: UUID,
        operationIndex: Int
    ) throws -> [IncorporatedBatchOperationIdentity] {
        let descriptor = FetchDescriptor<IncorporatedBatchOperationIdentity>(
            predicate: #Predicate {
                $0.batchID == batchID && $0.operationIndex == operationIndex
            }
        )
        return try context.fetch(descriptor)
    }

    private func loadTombstone(batchID: UUID) throws -> SyncConvergenceIncorporatedTombstoneProjection? {
        try fetchOne(IncorporatedBatchTombstone.self, #Predicate { $0.batchID == batchID }).map { tombstone in
            _ = try tombstone.canonicalTombstonePayloadV1()
            return SyncConvergenceIncorporatedTombstoneProjection(
                batchID: tombstone.batchID,
                originDeviceID: tombstone.originDeviceID,
                canonicalPayloadDigest: tombstone.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: tombstone.canonicalPayloadDigestFormatVersion,
                schemaVersion: tombstone.schemaVersion,
                committedResultDigest: tombstone.committedResultDigest,
                committedResultDigestFormatVersion: tombstone.committedResultDigestFormatVersion,
                committedAtOrderingPayloadData: tombstone.committedAtOrderingPayloadData,
                tombstoneFormatVersion: tombstone.tombstoneFormatVersion
            )
        }
    }

    private func fetchOne<T: PersistentModel>(_ model: T.Type, _ predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

extension SwiftDataSyncConvergencePostCommitStore: SyncConvergencePendingPostCommitSource {
    func loadPendingPostCommitRequests() throws -> [SyncConvergencePostCommitRequest] {
        #if DEBUG
        testOnlyLastCandidateFetchCount = 0
        testOnlyLastBackfillSaveCount = 0
        let isolatedStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        isolatedStore.testOnlyFailNextSaveAt = testOnlyFailNextSaveAt
        defer {
            testOnlyLastCandidateFetchCount = isolatedStore.testOnlyLastCandidateFetchCount
            testOnlyLastBackfillSaveCount = isolatedStore.testOnlyLastBackfillSaveCount
            testOnlyFailNextSaveAt = isolatedStore.testOnlyFailNextSaveAt
        }
        return try isolatedStore.loadPendingPostCommitRequestsInCurrentContext()
        #else
        let isolatedStore = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        return try isolatedStore.loadPendingPostCommitRequestsInCurrentContext()
        #endif
    }

    private func loadPendingPostCommitRequestsInCurrentContext() throws -> [SyncConvergencePostCommitRequest] {
        #if DEBUG
        testOnlyLastCandidateFetchCount = 0
        testOnlyLastBackfillSaveCount = 0
        #endif

        let descriptor = FetchDescriptor<IncorporatedSyncBatch>(
            predicate: #Predicate {
                $0.hasPendingPostCommitWork == true ||
                $0.hasPendingPostCommitWork == nil
            },
            sortBy: [
                SortDescriptor(\.committedAt)
            ]
        )
        let candidates = try context.fetch(descriptor)
            .sorted {
                if $0.committedAt != $1.committedAt { return $0.committedAt < $1.committedAt }
                return $0.batchID.uuidString < $1.batchID.uuidString
            }

        #if DEBUG
        testOnlyLastCandidateFetchCount = candidates.count
        #endif

        var backfillAssignments: [(IncorporatedSyncBatch, Bool)] = []
        var requests: [SyncConvergencePostCommitRequest] = []
        for root in candidates {
            let projection = try rootProjection(root)
            let state = try decodeAndValidatePostCommitState(root)
            if root.hasPendingPostCommitWork == nil {
                backfillAssignments.append((root, state.hasPendingWork))
            }
            if state != .none {
                requests.append(try postCommitRequest(root: projection, state: state))
            }
        }

        guard !backfillAssignments.isEmpty else { return requests }
        // The public loader uses a dedicated context; this guard proves phase one stayed read-only.
        guard !context.hasChanges else {
            throw SyncConvergencePostCommitFailure.persistence
        }
        for (root, hasPendingWork) in backfillAssignments {
            root.hasPendingPostCommitWork = hasPendingWork
        }
        do {
            #if DEBUG
            try testOnlyThrowIfRequested(at: .backfill)
            #endif
            try context.save()
            #if DEBUG
            testOnlyLastBackfillSaveCount = 1
            #endif
            return requests
        } catch {
            context.rollback()
            throw SyncConvergencePostCommitFailure.persistence
        }
    }

    func loadPostCommitStatus(forBatchID batchID: UUID) throws -> SyncConvergencePersistedPostCommitStatus {
        guard let root = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }) else {
            guard let tombstone = try loadTombstone(batchID: batchID) else {
                return .missing
            }
            return .tombstone(SyncConvergencePostCommitRequest(
                sourceBatchID: tombstone.batchID,
                affectedNoteIDs: [],
                cleanupPlan: SyncConvergenceCleanupPlan(
                    batchIDs: [tombstone.batchID],
                    retryQueueCleanup: true,
                    retryLegacyCleanup: false,
                    retryPresentationRefresh: false
                ),
                presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:]),
                persistedIncorporationIdentity: tombstone.persistedIdentity
            ))
        }
        let projection = try rootProjection(root)
        let state = try decodeAndValidatePostCommitState(root)
        guard state != .none else {
            return .completed(projection.persistedIdentity)
        }
        return try .pending(postCommitRequest(root: projection, state: state))
    }

    private func postCommitRequest(
        root: SyncConvergenceIncorporatedRootProjection,
        state: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitRequest {
        _ = try decodeWorkPayload(root: root, state: state)
        return SyncConvergencePostCommitRequest(
            sourceBatchID: root.batchID,
            affectedNoteIDs: try SyncConvergenceAffectedNotesPayloadV1.decodeData(root.affectedNotesPayloadData).noteIDs,
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: state.queueCleanupPending ? [root.batchID] : [],
                retryQueueCleanup: state.queueCleanupPending,
                retryLegacyCleanup: state.legacyCleanupPending,
                retryPresentationRefresh: state.presentationRefreshPending
            ),
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:]),
            persistedIncorporationIdentity: root.persistedIdentity
        )
    }

    private func decodeAndValidatePostCommitState(_ root: IncorporatedSyncBatch) throws -> SyncConvergencePostCommitState {
        do {
            let state = try SyncConvergencePostCommitState.decodePayloadData(root.postCommitStatePayloadData)
            if let indexed = root.hasPendingPostCommitWork, indexed != state.hasPendingWork {
                throw SyncConvergencePostCommitFailure.contradictoryPostCommitIndex(batchID: root.batchID)
            }
            return state
        } catch let failure as SyncConvergencePostCommitFailure {
            throw failure
        } catch {
            throw SyncConvergencePostCommitFailure.malformedPostCommitState(batchID: root.batchID)
        }
    }

    #if DEBUG
    private func testOnlyThrowIfRequested(at site: TestOnlySaveSite) throws {
        guard testOnlyFailNextSaveAt == site else { return }
        testOnlyFailNextSaveAt = nil
        throw TestOnlyInjectedPersistenceError()
    }

    private func testOnlyApplyPostSaveMutationIfRequested(
        to root: IncorporatedSyncBatch,
        expectedState: SyncConvergencePostCommitState
    ) throws {
        guard let mutation = testOnlyPostSaveMutation else { return }
        testOnlyPostSaveMutation = nil
        switch mutation {
        case .contradictoryIndex:
            root.hasPendingPostCommitWork = !expectedState.hasPendingWork
        case .selfConsistentUnexpectedState:
            let unexpectedState = expectedState == .none
                ? SyncConvergencePostCommitState(
                    queueCleanupPending: true,
                    legacyCleanupPending: false,
                    presentationRefreshPending: false
                )
                : SyncConvergencePostCommitState.none
            root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(unexpectedState)
            root.hasPendingPostCommitWork = unexpectedState.hasPendingWork
        }
    }
    #endif
}

#if DEBUG
private struct TestOnlyInjectedPersistenceError: Error {}
#endif

private extension IncorporatedSyncBatch {
    func matches(_ identity: SyncConvergencePersistedIncorporationIdentity) -> Bool {
        batchID == identity.batchID &&
        canonicalPayloadDigest == identity.canonicalPayloadDigest &&
        canonicalPayloadDigestFormatVersion == identity.canonicalPayloadDigestFormatVersion &&
        committedResultDigest == identity.committedResultDigest &&
        committedResultDigestFormatVersion == identity.committedResultDigestFormatVersion
    }
}

private extension SyncConvergenceIncorporatedRootProjection {
    func matches(_ identity: SyncConvergencePersistedIncorporationIdentity) -> Bool {
        batchID == identity.batchID &&
        canonicalPayloadDigest == identity.canonicalPayloadDigest &&
        canonicalPayloadDigestFormatVersion == identity.canonicalPayloadDigestFormatVersion &&
        committedResultDigest == identity.committedResultDigest &&
        committedResultDigestFormatVersion == identity.committedResultDigestFormatVersion
    }
}

private extension SyncConvergenceIncorporatedTombstoneProjection {
    func matches(_ identity: SyncConvergencePersistedIncorporationIdentity) -> Bool {
        batchID == identity.batchID &&
        canonicalPayloadDigest == identity.canonicalPayloadDigest &&
        canonicalPayloadDigestFormatVersion == identity.canonicalPayloadDigestFormatVersion &&
        committedResultDigest == identity.committedResultDigest &&
        committedResultDigestFormatVersion == identity.committedResultDigestFormatVersion
    }
}

private extension SyncConvergenceIncorporatedRootProjection {
    var persistedIdentity: SyncConvergencePersistedIncorporationIdentity {
        SyncConvergencePersistedIncorporationIdentity(
            batchID: batchID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion
        )
    }
}

private extension SyncConvergenceIncorporatedTombstoneProjection {
    var persistedIdentity: SyncConvergencePersistedIncorporationIdentity {
        SyncConvergencePersistedIncorporationIdentity(
            batchID: batchID,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: canonicalPayloadDigestFormatVersion,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: committedResultDigestFormatVersion
        )
    }
}
