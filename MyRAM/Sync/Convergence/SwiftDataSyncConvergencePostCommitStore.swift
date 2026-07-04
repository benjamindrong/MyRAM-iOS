import Foundation
import SwiftData

final class SwiftDataSyncConvergencePostCommitStore: SyncConvergencePostCommitStateStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState {
        if let root = try loadRoot(batchID: identity.batchID) {
            guard root.matches(identity) else { return .inconsistent }
            do {
                let state = try SyncConvergenceStableEncoding.decode(
                    SyncConvergencePostCommitState.self,
                    from: root.postCommitStatePayloadData
                )
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
        let currentSnapshot = try loadRoot(batchID: batchID)
        guard currentSnapshot == expectedRoot.root,
              root.matches(identity),
              root.postCommitStatePayloadData == expectedPayloadData else {
            throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: identity.batchID)
        }

        let originalWorkPayloadData = root.postCommitWorkPayloadData
        let encodedState = try SyncConvergenceStableEncoding.encode(newState)
        root.postCommitStatePayloadData = encodedState
        do {
            try context.save()
        } catch {
            context.rollback()
            throw SyncConvergencePostCommitFailure.persistence
        }

        guard let reloaded = try loadRoot(batchID: identity.batchID),
              reloaded.matches(identity),
              reloaded.postCommitStatePayloadData == encodedState,
              reloaded.postCommitWorkPayloadData == originalWorkPayloadData,
              reloaded == SyncConvergenceIncorporatedRootProjection(
                batchID: currentSnapshot?.batchID ?? expectedRoot.root.batchID,
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
            postCommitState: newState,
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
            try validateWorkPayload(payload, againstAuthoritativeRowsFor: root.batchID)
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
        try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }).map { root in
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
    }

    private func validateWorkPayload(
        _ payload: SyncConvergencePostCommitWorkPayloadV1,
        againstAuthoritativeRowsFor batchID: UUID
    ) throws {
        for entry in payload.presentationEntries {
            for operation in entry.incrementalOperations {
                try validateWorkOperation(
                    operation,
                    entryNoteID: entry.noteID,
                    rootBatchID: batchID
                )
            }
        }
    }

    private func validateWorkOperation(
        _ operation: SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload,
        entryNoteID: UUID,
        rootBatchID: UUID
    ) throws {
        let operationIndex = operation.operationIndex
        let identityKey = SyncConvergenceKey.batchOperationIdentity(
            batchID: rootBatchID,
            operationIndex: operationIndex
        )
        guard let row = try fetchOne(
            IncorporatedBatchOperationIdentity.self,
            #Predicate { $0.identityKey == identityKey }
        ) else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: rootBatchID)
        }
        guard row.batchID == rootBatchID,
              row.noteID == entryNoteID,
              row.operationIndex == operationIndex,
              row.payloadUTF8ByteCount == row.operationIdentityPayloadData.count + row.canonicalReplayKeyPayloadData.count else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: rootBatchID)
        }
        let authoritativeReplayKey = try CanonicalReplayKeyPayload.decodeEvidenceData(row.canonicalReplayKeyPayloadData)
        let authoritativeIdentity = try OperationIdentityPayload.decodePayloadData(row.operationIdentityPayloadData)
        guard authoritativeIdentity.canonicalReplayKey == authoritativeReplayKey,
              authoritativeReplayKey.batchIDLowercase == rootBatchID.uuidString.lowercased(),
              authoritativeReplayKey.batchIDLowercase == authoritativeIdentity.batchIDLowercase,
              authoritativeReplayKey.originDeviceIDLowercase == authoritativeIdentity.originDeviceIDLowercase,
              authoritativeReplayKey.operationIndex == authoritativeIdentity.operationIndex,
              authoritativeIdentity == operation.operationIdentity else {
            throw SyncConvergencePostCommitFailure.malformedPostCommitWorkPayload(batchID: rootBatchID)
        }
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
