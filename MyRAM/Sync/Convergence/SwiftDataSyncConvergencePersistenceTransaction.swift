import Foundation
import SwiftData

final class SwiftDataSyncConvergencePersistenceTransaction: SyncConvergencePersistenceTransaction {
    private let context: ModelContext
    private let saveContext: (ModelContext) throws -> Void

    init(
        context: ModelContext,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.saveContext = saveContext
    }

    func loadNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? {
        try fetchOne(Note.self, #Predicate { $0.id == id }).map {
            SyncConvergenceMutableNoteRecord(
                noteID: $0.id,
                folderID: $0.folder?.id,
                title: $0.title,
                body: $0.content,
                createdAt: $0.createdAt,
                modifiedAt: $0.modifiedAt,
                deletedAt: $0.deletedAt,
                richTextContentData: $0.richTextContentData
            )
        }
    }

    func insertNote(_ record: SyncConvergenceNewNoteRecord) throws {
        let destinationFolder = try folder(id: record.folderID)
        let note = Note(title: record.title, content: record.body)
        note.id = record.noteID
        note.createdAt = record.createdAt
        note.modifiedAt = record.modifiedAt
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: record.noteID,
            body: record.body
        )
        _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
            note,
            preparedState: prepared,
            in: context
        )
        note.folder = destinationFolder
    }

    func updateNote(_ record: SyncConvergenceUpdatedNoteRecord) throws {
        let noteID = record.noteID
        guard let note = try fetchOne(Note.self, #Predicate { $0.id == noteID }) else {
            throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: record.noteID)
        }
        let clearsRichText = note.content != record.body
        _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
            of: note,
            with: record.body,
            in: context
        )
        note.title = record.title
        if clearsRichText {
            // The merge only produces plain text; stale rich text from before the
            // merge would otherwise keep rendering in the editor over the top of it.
            note.richTextContentData = nil
        }
        note.modifiedAt = record.modifiedAt
        if let deletedAt = record.deletedAt {
            note.deletedAt = deletedAt
        }
    }

    func updateAnchoredNote(_ record: SyncConvergenceAnchoredUpdatedNoteRecord) throws {
        let noteID = record.noteID
        guard let note = try fetchOne(Note.self, #Predicate { $0.id == noteID }),
              note.content == record.expectedSnapshot.body else {
            throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: noteID)
        }
        if record.didChangeApplicationState {
            let clearsRichText = note.content != record.finalBody
            do {
                _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
                    of: note,
                    expected: record.expectedSnapshot,
                    newBody: record.finalBody,
                    finalState: record.finalState,
                    in: context
                )
            } catch {
                throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: noteID)
            }
            if clearsRichText { note.richTextContentData = nil }
        } else {
            guard record.finalState == record.expectedSnapshot.state,
                  record.finalBody == record.expectedSnapshot.body else {
                throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: noteID)
            }
            do {
                guard try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context) == record.expectedSnapshot else {
                    throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: noteID)
                }
            } catch let e as SyncConvergenceTransactionFailure { throw e }
            catch { throw SyncConvergenceTransactionFailure.staleAuthoritativeState(noteID: noteID) }
        }
        note.title = record.title
        note.modifiedAt = record.modifiedAt
        if let deletedAt = record.deletedAt { note.deletedAt = deletedAt }
    }

    func loadTitleWinner(noteID: UUID) throws -> SyncConvergenceTitleWinnerProjection? {
        try fetchOne(NoteTitleWinner.self, #Predicate { $0.noteID == noteID }).map {
            SyncConvergenceTitleWinnerProjection(
                noteID: $0.noteID,
                title: $0.title,
                canonicalReplayKey: try CanonicalReplayKeyPayload.decodeEvidenceData($0.canonicalReplayKeyPayloadData),
                operationIdentity: try OperationIdentityPayload.decodePayloadData($0.operationIdentityPayloadData)
            )
        }
    }

    func insertOrUpdateTitleWinner(_ record: SyncConvergenceTitleWinnerRecord) throws {
        let replayData = try record.canonicalReplayKey.encodedEvidenceData()
        let identityData = try record.operationIdentity.encodedPayloadData()
        let noteID = record.noteID
        if let existing = try fetchOne(NoteTitleWinner.self, #Predicate { $0.noteID == noteID }) {
            existing.title = record.title
            existing.canonicalReplayKeyPayloadData = replayData
            existing.operationIdentityPayloadData = identityData
            existing.setUpdatedAt(record.updatedAt)
        } else {
            context.insert(NoteTitleWinner(
                noteID: record.noteID,
                title: record.title,
                canonicalReplayKeyPayloadData: replayData,
                operationIdentityPayloadData: identityData,
                updatedAt: record.updatedAt
            ))
        }
    }

    func loadIncorporatedBatch(batchID: UUID) throws -> SyncConvergenceIncorporatedRootProjection? {
        try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }).map(fullRootProjection)
    }

    func loadIncorporatedBatchChildren(batchID: UUID) throws -> SyncConvergenceIncorporatedChildrenProjection {
        let identities = try fetch(IncorporatedBatchOperationIdentity.self, #Predicate { $0.batchID == batchID })
            .map(operationIdentityRecord)
        let effects = try fetch(IncorporatedBatchNoteEffect.self, #Predicate { $0.batchID == batchID })
            .map(noteEffectRecord)
        let results = try fetch(IncorporatedBatchResultEvidence.self, #Predicate { $0.batchID == batchID })
            .map(resultEvidenceRecord)
        return SyncConvergenceIncorporatedChildrenProjection(
            operationIdentities: identities,
            noteEffects: effects,
            resultEvidence: results
        )
    }

    func loadTombstone(batchID: UUID) throws -> SyncConvergenceIncorporatedTombstoneProjection? {
        try fetchOne(IncorporatedBatchTombstone.self, #Predicate { $0.batchID == batchID }).map(tombstoneProjection)
    }

    func insertIncorporatedBatch(_ record: SyncConvergenceIncorporatedBatchRecord) throws {
        guard let decodedState = try? SyncConvergencePostCommitState.decodePayloadData(record.postCommitStatePayloadData),
              decodedState.hasPendingWork == record.hasPendingPostCommitWork else {
            throw SyncConvergenceTransactionFailure.invalidMergePlan(noteID: nil)
        }
        context.insert(IncorporatedSyncBatch(
            batchID: record.batchID,
            originDeviceID: record.originDeviceID,
            createdAt: record.createdAt,
            batchSequence: record.batchSequence,
            schemaVersion: record.schemaVersion,
            committedAt: record.committedAt,
            canonicalPayloadDigest: record.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: record.canonicalPayloadDigestFormatVersion,
            committedResultDigest: record.committedResultDigest,
            committedResultDigestFormatVersion: record.committedResultDigestFormatVersion,
            affectedNotesPayloadData: record.affectedNotesPayloadData,
            authoritativeChildCount: record.authoritativeChildCount,
            authoritativeChildBytes: record.authoritativeChildBytes,
            authoritativeChildrenDigest: record.authoritativeChildrenDigest,
            postCommitWorkPayloadData: record.postCommitWorkPayloadData,
            postCommitStatePayloadData: record.postCommitStatePayloadData,
            hasPendingPostCommitWork: record.hasPendingPostCommitWork
        ))
    }

    func insertOperationIdentity(_ record: SyncConvergenceOperationIdentityRecord) throws {
        context.insert(IncorporatedBatchOperationIdentity(
            batchID: record.batchID,
            noteID: record.noteID,
            operationIndex: record.operationIndex,
            operationIdentityPayloadData: try record.operationIdentity.encodedPayloadData(),
            canonicalReplayKeyPayloadData: try record.operationIdentity.canonicalReplayKey.encodedEvidenceData()
        ))
    }

    func insertNoteEffect(_ record: SyncConvergenceNoteEffectRecord) throws {
        context.insert(IncorporatedBatchNoteEffect(
            batchID: record.batchID,
            noteID: record.noteID,
            preBodyHash: record.preBodyHash,
            postBodyHash: record.postBodyHash,
            preTitleKeyPayloadData: try record.preTitleKey?.encodedEvidenceData(),
            postTitleKeyPayloadData: try record.postTitleKey?.encodedEvidenceData()
        ))
    }

    func insertResultEvidence(_ record: SyncConvergenceResultEvidenceRecord) throws {
        context.insert(IncorporatedBatchResultEvidence(
            batchID: record.evidence.batchID,
            noteID: record.evidence.noteID,
            resultKindRaw: record.evidence.kind.rawValue,
            resultEvidencePayloadData: try SyncConvergenceStableEncoding.encode(record.evidence)
        ))
    }

    func loadRetainedOperation(
        identity: SyncConvergenceRetainedOperationIdentity
    ) throws -> SyncConvergenceRetainedOperationProjection? {
        let batchID = identity.batchID
        let operationIndex = identity.operationIndex
        return try fetchOne(RetainedBodyOperation.self, #Predicate {
            $0.batchID == batchID && $0.operationIndex == operationIndex
        }).map { model in
            guard let source = SyncConvergenceRetainedOperationSource(rawValue: model.sourceRaw) else {
                throw SyncConvergenceTransactionFailure.corruptHistory(noteID: model.noteID)
            }
            return try SyncConvergenceRetainedOperationProjection(operation: retainedRecord(model), source: source)
        }
    }

    func insertRetainedOperation(_ record: SyncConvergenceRetainedOperationRecord) throws {
        try insertRetainedOperation(record, source: .remote)
    }

    func insertRetainedOperation(
        _ record: SyncConvergenceRetainedOperationRecord,
        source: SyncConvergenceRetainedOperationSource
    ) throws {
        context.insert(RetainedBodyOperation(
            noteID: record.noteID,
            batchID: record.batchID,
            originDeviceID: record.originDeviceID,
            operationIndex: record.operationIndex,
            operationKindRaw: record.operationKind.rawValue,
            utf16Offset: record.utf16Offset,
            utf16Length: record.utf16Length,
            text: record.text,
            expectedText: record.expectedText,
            baseContentHash: record.baseContentHash,
            resultContentHash: record.resultContentHash,
            modifiedAt: record.modifiedAt,
            canonicalReplayKeyPayloadData: try record.canonicalReplayKey.encodedEvidenceData(),
            sourceRaw: source.rawValue
        ))
    }

    func loadExplicitDeleteProvenance(
        identity: SyncConvergenceRetainedOperationIdentity
    ) throws -> ExplicitDeleteProvenanceProjection? {
        let batchID = identity.batchID
        let operationIndex = identity.operationIndex
        return try fetchOne(ExplicitDeleteProvenance.self, #Predicate {
            $0.batchID == batchID && $0.operationIndex == operationIndex
        }).map(explicitDeleteProvenanceProjection)
    }

    func insertExplicitDeleteProvenance(_ record: ExplicitDeleteProvenanceRecord) throws {
        let canonicalData = try record.canonicalPayloadData()
        let batchID = record.batchID
        let operationIndex = record.operationIndex
        if let existing = try fetchOne(ExplicitDeleteProvenance.self, #Predicate {
            $0.batchID == batchID && $0.operationIndex == operationIndex
        }) {
            guard existing.canonicalRecordPayloadData == canonicalData else {
                throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: record.noteID)
            }
            return
        }
        context.insert(try ExplicitDeleteProvenance(record: record, canonicalRecordPayloadData: canonicalData))
    }

    func compactExplicitDeleteProvenance(
        identity: SyncConvergenceRetainedOperationIdentity,
        using snapshot: SyncConvergenceSnapshotRecord
    ) throws -> ExplicitDeleteProvenanceCompactionResult {
        let batchID = identity.batchID
        let operationIndex = identity.operationIndex
        guard let existing = try fetchOne(ExplicitDeleteProvenance.self, #Predicate {
            $0.batchID == batchID && $0.operationIndex == operationIndex
        }) else {
            return .retainedFull(.occurrenceNotFound)
        }
        let projection = try explicitDeleteProvenanceProjection(existing)
        let result = ExplicitDeleteProvenanceCompactor().compact(
            record: projection.record,
            baseSnapshot: snapshot
        )
        if case .compacted(let compacted) = result, compacted != projection.record {
            try existing.replace(with: compacted, canonicalRecordPayloadData: compacted.canonicalPayloadData())
        }
        return result
    }

    func loadSnapshot(noteID: UUID, generation: Int) throws -> SyncConvergenceSnapshotProjection? {
        try fetchOne(NoteContentSnapshot.self, #Predicate {
            $0.noteID == noteID && $0.generation == generation
        }).map {
            SyncConvergenceSnapshotProjection(snapshot: SyncConvergenceSnapshotRecord(
                noteID: $0.noteID,
                contentHash: $0.contentHash,
                body: $0.body,
                generation: $0.generation,
                createdAt: $0.createdAt
            ))
        }
    }

    func loadHighestSnapshotGeneration(noteID: UUID) throws -> Int? {
        try fetch(NoteContentSnapshot.self, #Predicate { $0.noteID == noteID })
            .map(\.generation)
            .max()
    }

    func insertSnapshot(_ record: SyncConvergenceSnapshotRecord) throws {
        context.insert(NoteContentSnapshot(
            noteID: record.noteID,
            contentHash: record.contentHash,
            body: record.body,
            generation: record.generation,
            createdAt: record.createdAt
        ))
    }

    func save() throws {
        try saveContext(context)
    }

    func rollback() {
        context.rollback()
    }

    /// Replaces completed, protection-free full incorporation records with their
    /// permanent fixed-size duplicate identity. The tombstone and every deletion
    /// are committed by the same save, so a failed save retains the full record.
    func compactCompletedIncorporationHistory(
        affecting noteIDs: Set<UUID>,
        protectedBatchIDs: Set<UUID>
    ) throws -> Set<UUID> {
        guard !noteIDs.isEmpty else { return [] }
        do {
            let affectedEffects = try context.fetch(FetchDescriptor<IncorporatedBatchNoteEffect>())
                .filter { noteIDs.contains($0.noteID) }
            let candidateIDs = Set(affectedEffects.map(\.batchID)).subtracting(protectedBatchIDs)
            var compacted: Set<UUID> = []
            for batchID in candidateIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let root = try fetchOne(IncorporatedSyncBatch.self, #Predicate { $0.batchID == batchID }) else {
                    throw SyncConvergenceTransactionFailure.corruptHistory(noteID: nil)
                }
                let state = try SyncConvergencePostCommitState.decodePayloadData(root.postCommitStatePayloadData)
                guard state == .none, root.hasPendingPostCommitWork == false else { continue }

                let retained = try fetch(RetainedBodyOperation.self, #Predicate { $0.batchID == batchID })
                let provenance = try fetch(ExplicitDeleteProvenance.self, #Predicate { $0.batchID == batchID })
                let incorporationBlocking = try context.fetch(FetchDescriptor<IncorporationBlockingReference>())
                    .filter { $0.batchID == batchID || $0.blockingBatchID == batchID }
                let diagnosticBlocking = try fetch(ConvergenceBlockingBatchReference.self, #Predicate { $0.blockingBatchID == batchID })
                let contradictions = try fetch(IncorporationContradictionDiagnostic.self, #Predicate { $0.batchID == batchID })
                guard retained.isEmpty, provenance.isEmpty, incorporationBlocking.isEmpty,
                      diagnosticBlocking.isEmpty, contradictions.isEmpty else { continue }

                let effects = try fetch(IncorporatedBatchNoteEffect.self, #Predicate { $0.batchID == batchID })
                let identities = try fetch(IncorporatedBatchOperationIdentity.self, #Predicate { $0.batchID == batchID })
                let results = try fetch(IncorporatedBatchResultEvidence.self, #Predicate { $0.batchID == batchID })
                let affected = try validateCompactionEvidence(
                    root: root,
                    effects: effects,
                    identities: identities,
                    results: results
                )
                let activeEpisodes = try context.fetch(FetchDescriptor<ReconciliationEpisode>())
                    .contains { affected.contains($0.noteID) && $0.completedAtBitPattern == nil }
                guard !activeEpisodes else { continue }

                let ordering = try CommittedAtOrderingPayload(
                    batchID: root.batchID,
                    committedAt: root.committedAt
                ).encodedEvidenceData()
                if let existing = try fetchOne(IncorporatedBatchTombstone.self, #Predicate { $0.batchID == batchID }) {
                    try existing.validateForPersistence()
                    guard existing.originDeviceID == root.originDeviceID,
                          existing.schemaVersion == root.schemaVersion,
                          existing.canonicalPayloadDigest == root.canonicalPayloadDigest,
                          existing.canonicalPayloadDigestFormatVersion == root.canonicalPayloadDigestFormatVersion,
                          existing.committedResultDigest == root.committedResultDigest,
                          existing.committedResultDigestFormatVersion == root.committedResultDigestFormatVersion,
                          existing.committedAtOrderingPayloadData == ordering else {
                        throw SyncConvergenceTransactionFailure.inconsistentIncorporationState(noteID: affected.first)
                    }
                } else {
                    let tombstone = try IncorporatedBatchTombstone.makeValidated(
                        batchID: root.batchID,
                        originDeviceID: root.originDeviceID,
                        canonicalPayloadDigest: root.canonicalPayloadDigest,
                        canonicalPayloadDigestFormatVersion: root.canonicalPayloadDigestFormatVersion,
                        schemaVersion: root.schemaVersion,
                        committedResultDigest: root.committedResultDigest,
                        committedResultDigestFormatVersion: root.committedResultDigestFormatVersion,
                        committedAtOrderingPayloadData: ordering
                    )
                    try tombstone.validateForPersistence()
                    context.insert(tombstone)
                }
                identities.forEach(context.delete)
                effects.forEach(context.delete)
                results.forEach(context.delete)
                context.delete(root)
                compacted.insert(batchID)
            }
            guard !compacted.isEmpty else { return [] }
            try saveContext(context)
            return compacted
        } catch {
            context.rollback()
            throw error
        }
    }

    private func validateCompactionEvidence(
        root: IncorporatedSyncBatch,
        effects: [IncorporatedBatchNoteEffect],
        identities: [IncorporatedBatchOperationIdentity],
        results: [IncorporatedBatchResultEvidence]
    ) throws -> Set<UUID> {
        try SyncConvergencePersistenceValidation.validate(root)
        let declared = try SyncConvergenceAffectedNotesPayloadV1
            .decodeData(root.affectedNotesPayloadData)
            .noteIDs
        var projections: [(kind: String, key: String, bytes: Data)] = []
        var resultKinds: [UUID: [String]] = [:]
        for result in results {
            let evidence = try SyncConvergenceStableEncoding.decode(
                SyncConvergenceResultEvidence.self,
                from: result.resultEvidencePayloadData
            )
            guard evidence.batchID == root.batchID,
                  evidence.noteID == result.noteID,
                  evidence.kind.rawValue == result.resultKindRaw,
                  result.payloadUTF8ByteCount == result.resultEvidencePayloadData.count else {
                throw SyncConvergenceTransactionFailure.corruptHistory(noteID: result.noteID)
            }
            resultKinds[result.noteID, default: []].append(result.resultKindRaw)
            var encoder = CanonicalPayloadDigestFormatV1()
            try encoder.appendResultEvidence(evidence)
            projections.append(("result", "\(result.noteID.uuidString.lowercased())|\(result.resultKindRaw)", encoder.data))
        }
        for effect in effects {
            try SyncConvergencePersistenceValidation.validate(effect)
            let kinds = resultKinds[effect.noteID] ?? []
            guard SyncConvergenceNoteEffectKindMembership.validate(kinds) else {
                throw SyncConvergenceTransactionFailure.corruptHistory(noteID: effect.noteID)
            }
            var encoder = CanonicalPayloadDigestFormatV1()
            try encoder.appendProjectedNoteEffect(batchID: root.batchID, noteID: effect.noteID, kinds: kinds)
            projections.append(("note-effect", effect.noteID.uuidString.lowercased(), encoder.data))
        }
        for identity in identities {
            try SyncConvergencePersistenceValidation.validate(identity)
            let payload = try OperationIdentityPayload.decodePayloadData(identity.operationIdentityPayloadData)
            guard payload.batchIDLowercase == root.batchID.uuidString.lowercased(),
                  identity.payloadUTF8ByteCount == identity.operationIdentityPayloadData.count
                    + identity.canonicalReplayKeyPayloadData.count else {
                throw SyncConvergenceTransactionFailure.corruptHistory(noteID: identity.noteID)
            }
            var encoder = CanonicalPayloadDigestFormatV1()
            try encoder.appendOperationIdentity(payload)
            projections.append(("operation", "\(payload.batchIDLowercase)|\(payload.operationIndex)", encoder.data))
        }
        let authoritative = Set(effects.map(\.noteID)).union(results.map(\.noteID))
        guard !authoritative.isEmpty,
              authoritative == declared,
              resultKinds.keys.allSatisfy({ authoritative.contains($0) }) else {
            throw SyncConvergenceTransactionFailure.corruptHistory(noteID: declared.first)
        }
        projections.sort { lhs, rhs in
            lhs.kind == rhs.kind ? lhs.key < rhs.key : lhs.kind < rhs.kind
        }
        let bytes = projections.reduce(0) { $0 + $1.bytes.count }
        let digest = CanonicalDigestEncoderV1.digest(
            data: projections.reduce(into: Data()) { $0.append($1.bytes) }
        )
        guard root.authoritativeChildCount == projections.count,
              root.authoritativeChildBytes == bytes,
              root.authoritativeChildrenDigest == digest else {
            throw SyncConvergenceTransactionFailure.corruptHistory(noteID: authoritative.first)
        }
        return authoritative
    }

    private func folder(id: UUID?) throws -> Folder? {
        guard let id else { return nil }
        return try fetchOne(Folder.self, #Predicate { $0.id == id })
    }

    private func fullRootProjection(_ root: IncorporatedSyncBatch) throws -> SyncConvergenceIncorporatedRootProjection {
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

    private func tombstoneProjection(_ tombstone: IncorporatedBatchTombstone) throws -> SyncConvergenceIncorporatedTombstoneProjection {
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

    private func operationIdentityRecord(
        _ model: IncorporatedBatchOperationIdentity
    ) throws -> SyncConvergenceOperationIdentityRecord {
        SyncConvergenceOperationIdentityRecord(
            batchID: model.batchID,
            noteID: model.noteID,
            operationIndex: model.operationIndex,
            operationIdentity: try OperationIdentityPayload.decodePayloadData(model.operationIdentityPayloadData)
        )
    }

    private func noteEffectRecord(_ model: IncorporatedBatchNoteEffect) throws -> SyncConvergenceNoteEffectRecord {
        SyncConvergenceNoteEffectRecord(
            batchID: model.batchID,
            noteID: model.noteID,
            preBodyHash: model.preBodyHash,
            postBodyHash: model.postBodyHash,
            preTitleKey: try model.preTitleKeyPayloadData.map(CanonicalReplayKeyPayload.decodeEvidenceData),
            postTitleKey: try model.postTitleKeyPayloadData.map(CanonicalReplayKeyPayload.decodeEvidenceData)
        )
    }

    private func resultEvidenceRecord(_ model: IncorporatedBatchResultEvidence) throws -> SyncConvergenceResultEvidenceRecord {
        SyncConvergenceResultEvidenceRecord(
            evidence: try SyncConvergenceStableEncoding.decode(
                SyncConvergenceResultEvidence.self,
                from: model.resultEvidencePayloadData
            )
        )
    }

    private func retainedRecord(_ model: RetainedBodyOperation) throws -> SyncConvergenceRetainedOperationRecord {
        guard let kind = SyncConvergencePlannedBodyOperation.Kind(rawValue: model.operationKindRaw) else {
            throw SyncConvergenceTransactionFailure.corruptHistory(noteID: model.noteID)
        }
        return SyncConvergenceRetainedOperationRecord(
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
            canonicalReplayKey: try CanonicalReplayKeyPayload.decodeEvidenceData(model.canonicalReplayKeyPayloadData),
            modifiedAt: model.modifiedAt
        )
    }

    private func explicitDeleteProvenanceProjection(
        _ model: ExplicitDeleteProvenance
    ) throws -> ExplicitDeleteProvenanceProjection {
        try SyncConvergencePersistenceValidation.validate(model)
        let record = try SyncConvergenceStableEncoding.decode(
            ExplicitDeleteProvenanceRecord.self,
            from: model.canonicalRecordPayloadData
        )
        guard record.canonicalReplayKey == (try CanonicalReplayKeyPayload.decodeEvidenceData(model.canonicalReplayKeyPayloadData)) else {
            throw SyncConvergenceTransactionFailure.corruptHistory(noteID: model.noteID)
        }
        return ExplicitDeleteProvenanceProjection(
            record: record,
            canonicalPayloadData: model.canonicalRecordPayloadData
        )
    }

    private func fetch<Model: PersistentModel>(
        _ type: Model.Type,
        _ predicate: Predicate<Model>
    ) throws -> [Model] {
        try context.fetch(FetchDescriptor<Model>(predicate: predicate))
    }

    private func fetchOne<Model: PersistentModel>(
        _ type: Model.Type,
        _ predicate: Predicate<Model>
    ) throws -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
