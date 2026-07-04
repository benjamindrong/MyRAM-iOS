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
                return .fullRoot(SyncConvergencePostCommitFullRootState(
                    root: root,
                    postCommitState: state,
                    postCommitStatePayloadData: root.postCommitStatePayloadData
                ))
            } catch {
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
        identity: SyncConvergencePersistedIncorporationIdentity,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState {
        let batchID = identity.batchID
        guard let root = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }) else {
            throw SyncConvergencePostCommitFailure.missingAuthoritativeIncorporation(batchID: identity.batchID)
        }
        guard root.matches(identity), root.postCommitStatePayloadData == expectedPayloadData else {
            throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: identity.batchID)
        }

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
              reloaded.postCommitStatePayloadData == encodedState
        else {
            throw SyncConvergencePostCommitFailure.persistence
        }
        return SyncConvergencePostCommitFullRootState(
            root: reloaded,
            postCommitState: newState,
            postCommitStatePayloadData: encodedState
        )
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
                postCommitStatePayloadData: root.postCommitStatePayloadData
            )
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
