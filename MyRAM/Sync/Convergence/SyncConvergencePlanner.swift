import CryptoKit
import Foundation

struct SyncConvergencePlanner {
    func evidenceRequest(for batch: SyncBatch) -> SyncConvergenceEvidenceRequest {
        SyncConvergenceEvidenceSelector().request(for: batch)
    }

    func plan(input: SyncConvergencePlanningInput) -> SyncConvergencePlanningOutcome {
        let currentDigest: String
        do {
            currentDigest = try SyncConvergenceCanonicalBatchDigest.digest(
                for: input.incomingBatch,
                formatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion
            )
        } catch {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        if let duplicateOutcome = classifyDuplicate(input: input) {
            return duplicateOutcome
        }

        if let unsupported = input.incomingBatch.changes.firstUnsupportedReconciliation {
            return .deferred(.unsupportedReconciliation(noteID: unsupported.noteID, batchID: input.incomingBatch.id))
        }

        var noteStates = Dictionary(uniqueKeysWithValues: input.currentNotes.map { ($0.noteID, $0) })
        var notePlans: [UUID: PartialNotePlan] = [:]
        var operationIdentities: [OperationIdentityPayload] = []
        var resultEvidence: [SyncConvergenceResultEvidence] = []
        var retainedAdditions: [SyncConvergencePlannedBodyOperation] = []
        var snapshotAdditions: [SyncConvergenceSnapshotAddition] = []
        var routings: [UUID: SyncConvergencePresentationRouting] = [:]
        var processedBodyNoteIDs: Set<UUID> = []
        let queueSelection = SyncConvergenceEvidenceSelector().selectQueuedBatches(
            for: input.incomingBatch,
            queuedBatches: input.queuedBatches,
            candidateQueuePosition: input.candidateQueuePosition
        )

        for (operationIndex, change) in input.incomingBatch.changes.enumerated() {
            switch change {
            case .noteCreated(let created):
                let identity = operationIdentity(
                    for: change,
                    in: input.incomingBatch,
                    operationIndex: operationIndex,
                    kind: "creation"
                )
                let existing = noteStates[created.noteID]
                let initialHash = SyncBatchContentHash.sha256Hex(for: created.body)
                if let existing {
                    guard existing.title == created.title,
                          existing.body == created.body,
                          existing.folderID == created.folderID else {
                        return .failedBeforeCommit(.inconsistentIncorporationState(noteID: created.noteID))
                    }
                    let effect = creationEffect(
                        verdict: .idempotent,
                        change: created,
                        initialBodyHash: initialHash,
                        identity: identity
                    )
                    notePlans[created.noteID, default: PartialNotePlan(noteID: created.noteID)].creationEffect = effect
                } else {
                    let projected = SyncConvergenceProjectedNote(
                        noteID: created.noteID,
                        folderID: created.folderID,
                        title: created.title,
                        body: created.body,
                        createdAt: created.createdAt,
                        modifiedAt: created.modifiedAt
                    )
                    noteStates[created.noteID] = projected
                    notePlans[created.noteID, default: PartialNotePlan(noteID: created.noteID)].creationEffect = creationEffect(
                        verdict: .create,
                        change: created,
                        initialBodyHash: initialHash,
                        identity: identity
                    )
                }
                operationIdentities.append(identity)
                resultEvidence.append(
                    SyncConvergenceResultEvidence(
                        batchID: input.incomingBatch.id,
                        noteID: created.noteID,
                        kind: .creation,
                        preHash: nil,
                        postHash: initialHash,
                        canonicalReplayKey: identity.canonicalReplayKey
                    )
                )

            case .noteTitleChanged(let titleChange):
                let candidateIdentity = operationIdentity(
                    for: change,
                    in: input.incomingBatch,
                    operationIndex: operationIndex,
                    kind: "title"
                )
                guard let current = noteStates[titleChange.noteID] else {
                    let effect = unknownTitleNoopEffect(
                        change: titleChange,
                        identity: candidateIdentity,
                        batchID: input.incomingBatch.id
                    )
                    notePlans[titleChange.noteID, default: PartialNotePlan(noteID: titleChange.noteID)].titleEffect = effect
                    operationIdentities.append(candidateIdentity)
                    resultEvidence.append(effect.resultEvidence)
                    continue
                }
                let titleResult = SyncTitleWinnerPlanner().plan(
                    noteID: titleChange.noteID,
                    priorTitle: current.title,
                    persistedWinners: input.persistedTitleWinners.filter { $0.noteID == titleChange.noteID },
                    candidateTitle: titleChange.title,
                    candidateIdentity: candidateIdentity
                )
                switch titleResult {
                case .success(let effect):
                    if effect.verdict == SyncConvergenceTitleVerdict.apply ||
                        effect.verdict == SyncConvergenceTitleVerdict.idempotent {
                        noteStates[titleChange.noteID] = SyncConvergenceProjectedNote(
                            noteID: current.noteID,
                            folderID: current.folderID,
                            title: effect.resultingTitle,
                            body: current.body,
                            createdAt: current.createdAt,
                            modifiedAt: titleChange.modifiedAt
                        )
                    }
                    notePlans[titleChange.noteID, default: PartialNotePlan(noteID: titleChange.noteID)].titleEffect = effect
                    operationIdentities.append(candidateIdentity)
                    resultEvidence.append(effect.resultEvidence)
                case .failure(let failure):
                    return .failedBeforeCommit(failure)
                }

            case .noteBodyTextInserted, .noteBodyTextDeleted:
                guard let noteID = change.noteID else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
                }
                guard !processedBodyNoteIDs.contains(noteID) else {
                    continue
                }
                processedBodyNoteIDs.insert(noteID)
                let indexedChanges = input.incomingBatch.changes.enumerated()
                    .filter { _, candidate in
                        candidate.noteID == noteID && candidate.isBodyTextOperation
                    }
                    .map { (operationIndex: $0.offset, change: $0.element) }
                let bodyResult = planBodyChanges(
                    indexedChanges,
                    noteID: noteID,
                    current: noteStates[noteID],
                    input: input,
                    queueSelection: queueSelection
                )
                switch bodyResult {
                case .success(let planned):
                    let current = noteStates[noteID]
                    noteStates[noteID] = SyncConvergenceProjectedNote(
                        noteID: noteID,
                        folderID: current?.folderID,
                        title: current?.title ?? "",
                        body: planned.finalBody,
                        createdAt: current?.createdAt ?? input.incomingBatch.createdAt,
                        modifiedAt: change.modifiedAtForReplayOrdering
                    )
                    notePlans[noteID, default: PartialNotePlan(noteID: noteID)].bodyEffect = planned.effect
                    operationIdentities.append(contentsOf: planned.operationIdentities)
                    resultEvidence.append(planned.resultEvidence)
                    retainedAdditions.append(contentsOf: planned.retainedAdditions)
                    snapshotAdditions.append(contentsOf: planned.snapshotAdditions)
                    routings[noteID] = planned.routing
                case .deferred(let reason):
                    return .deferred(reason)
                case .failed(let failure):
                    return .failedBeforeCommit(failure)
                }

            case .noteBodyReconciled:
                break
            }
        }

        let plannedAffectedNoteIDs = Set(notePlans.keys)
        let projectedFullEvidenceBytes: Int
        do {
            projectedFullEvidenceBytes = try SyncConvergenceProjectedIncorporationEvidence(
                batch: input.incomingBatch,
                affectedNoteIDs: plannedAffectedNoteIDs,
                operationIdentities: operationIdentities,
                resultEvidence: resultEvidence
            ).canonicalEncodedByteCount()
        } catch {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        let historyResult = SyncConvergenceHistoryPolicy().plan(
            affectedNoteIDs: plannedAffectedNoteIDs,
            currentStates: input.historyStates,
            retainedOperationAdditions: retainedAdditions,
            snapshotAdditions: snapshotAdditions,
            fullIncorporationEvidenceBytes: projectedFullEvidenceBytes
        )
        switch historyResult {
        case .success(let historyPlan):
            let plan = SyncConvergenceBatchPlan(
                batchID: input.incomingBatch.id,
                originDeviceID: input.incomingBatch.originDeviceID,
                canonicalPayloadDigest: currentDigest,
                canonicalPayloadDigestFormatVersion: SyncConvergenceCanonicalBatchDigest.supportedFormatVersion,
                affectedNotePlans: notePlans.values
                    .map { $0.finalPlan() }
                    .sorted { $0.noteID.uuidString < $1.noteID.uuidString },
                incorporationEvidence: SyncConvergenceIncorporationPlan(
                    operationIdentities: operationIdentities,
                    resultEvidence: resultEvidence
                ),
                historyPlan: historyPlan,
                presentationPlan: SyncConvergencePresentationPlan(noteRoutings: routings)
            )
            return SyncConvergencePlanValidator().validate(
                plan,
                input: input,
                queueSelection: queueSelection,
                projectedFullIncorporationEvidenceBytes: projectedFullEvidenceBytes
            ) ?? .planned(plan)
        case .deferred(let reason):
            return .deferred(reason)
        case .failed(let failure):
            return .failedBeforeCommit(failure)
        }
    }

    private func classifyDuplicate(
        input: SyncConvergencePlanningInput
    ) -> SyncConvergencePlanningOutcome? {
        let records = (input.incorporatedBatches + input.incorporatedTombstones)
            .filter { $0.batchID == input.incomingBatch.id }
        guard !records.isEmpty else {
            return nil
        }
        var cleanupPlan = SyncConvergenceCleanupPlan(
            batchIDs: [],
            retryQueueCleanup: false,
            retryLegacyCleanup: false,
            retryPresentationRefresh: false
        )
        for record in records {
            guard input.supportedDigestFormatVersions.contains(record.canonicalPayloadDigestFormatVersion) else {
                return .failedBeforeCommit(.unsupportedDigestFormat(
                    noteID: record.noteID,
                    batchID: record.batchID,
                    formatVersion: record.canonicalPayloadDigestFormatVersion
                ))
            }
            let incomingDigest: String
            do {
                incomingDigest = try SyncConvergenceCanonicalBatchDigest.digest(
                    for: input.incomingBatch,
                    formatVersion: record.canonicalPayloadDigestFormatVersion
                )
            } catch SyncConvergenceCanonicalBatchDigest.Error.unsupportedFormatVersion(let version) {
                return .failedBeforeCommit(.unsupportedDigestFormat(
                    noteID: record.noteID,
                    batchID: record.batchID,
                    formatVersion: version
                ))
            } catch {
                return .failedBeforeCommit(.invalidMergePlan(noteID: record.noteID))
            }
            guard record.canonicalPayloadDigest == incomingDigest else {
                return .failedBeforeCommit(.inconsistentIncorporationState(noteID: record.noteID))
            }
            cleanupPlan = cleanupPlan.merging(record.cleanupPlan)
        }
        return .alreadyIncorporated(cleanupPlan)
    }

    private func creationEffect(
        verdict: SyncConvergenceCreationEffect.Verdict,
        change: SyncBatchNoteCreatedChange,
        initialBodyHash: String,
        identity: OperationIdentityPayload
    ) -> SyncConvergenceCreationEffect {
        SyncConvergenceCreationEffect(
            verdict: verdict,
            noteID: change.noteID,
            folderID: change.folderID,
            title: change.title,
            body: change.body,
            createdAt: change.createdAt,
            modifiedAt: change.modifiedAt,
            initialBodyHash: initialBodyHash,
            operationIdentity: identity,
            resultEvidence: SyncConvergenceResultEvidence(
                batchID: UUID(uuidString: identity.batchIDLowercase) ?? change.noteID,
                noteID: change.noteID,
                kind: .creation,
                preHash: nil,
                postHash: initialBodyHash,
                canonicalReplayKey: identity.canonicalReplayKey
            )
        )
    }

    private func unknownTitleNoopEffect(
        change: SyncBatchNoteTitleChangedChange,
        identity: OperationIdentityPayload,
        batchID: UUID
    ) -> SyncConvergenceTitleEffect {
        let evidence = SyncConvergenceResultEvidence(
            batchID: batchID,
            noteID: change.noteID,
            kind: .title,
            preHash: nil,
            postHash: nil,
            canonicalReplayKey: identity.canonicalReplayKey
        )
        return SyncConvergenceTitleEffect(
            priorTitle: "",
            priorWinningKey: nil,
            candidateTitle: change.title,
            candidateOperationIdentity: identity,
            candidateCanonicalKey: identity.canonicalReplayKey,
            verdict: .compatibilityNoopMissingNote,
            resultingTitle: "",
            resultingWinningKey: nil,
            resultEvidence: evidence
        )
    }

    private func planBodyChanges(
        _ indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        noteID: UUID,
        current: SyncConvergenceProjectedNote?,
        input: SyncConvergencePlanningInput,
        queueSelection: SyncConvergenceQueueSelection
    ) -> BodyPlanningResult {
        guard !indexedChanges.isEmpty else {
            return .failed(.invalidMergePlan(noteID: noteID))
        }
        var workingNote: SyncConvergenceProjectedNote
        if let current {
            workingNote = current
        } else if indexedChanges.allSatisfy({ $0.change.baseContentHash == nil }) {
            return unknownLegacyBodyNoop(
                indexedChanges,
                noteID: noteID,
                batchID: input.incomingBatch.id,
                input: input
            )
        } else {
            let declaredHash = indexedChanges.compactMap { $0.change.baseContentHash }.first ?? ""
            return .deferred(.unreconstructableBase(
                noteID: noteID,
                batchID: input.incomingBatch.id,
                baseContentHash: declaredHash
            ))
        }

        let initialBody = workingNote.body
        let initialHash = SyncBatchContentHash.sha256Hex(for: initialBody)
        var sequentialResults: [PlannedBodyResult] = []
        var idempotentIdentities: [OperationIdentityPayload] = []
        var sawLegacy = false
        let retainedByIdentityKey = Dictionary(
            (input.retainedLocalOperations + input.retainedRemoteOperations)
                .filter { $0.noteID == noteID }
                .map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for indexedChange in indexedChanges {
            let identity = operationIdentity(
                for: indexedChange.change,
                in: input.incomingBatch,
                operationIndex: indexedChange.operationIndex,
                kind: indexedChange.change.operationKind
            )
            // An operation already present in retained history was consumed as union
            // evidence by an earlier plan; identical evidence is idempotent and must
            // not apply a second time through the legacy or matching-base paths.
            if let retainedMatch = retainedByIdentityKey["\(identity.batchIDLowercase)|\(identity.operationIndex)"] {
                guard retainedMatch.syncBatchChange == indexedChange.change else {
                    return .failed(.inconsistentIncorporationState(noteID: noteID))
                }
                idempotentIdentities.append(identity)
                continue
            }
            let baseHash = indexedChange.change.baseContentHash
            let currentHash = SyncBatchContentHash.sha256Hex(for: workingNote.body)
            if let baseHash, baseHash != currentHash {
                return planReconstructedBodyChanges(
                    indexedChanges,
                    noteID: noteID,
                    requiredBaseHash: baseHash,
                    initialBody: initialBody,
                    current: workingNote,
                    input: input,
                    queueSelection: queueSelection
                )
            }
            let result = planSequentialBodyChange(
                indexedChange.change,
                operationIndex: indexedChange.operationIndex,
                current: workingNote,
                input: input
            )
            switch result {
            case .success(let planned):
                workingNote = SyncConvergenceProjectedNote(
                    noteID: workingNote.noteID,
                    folderID: workingNote.folderID,
                    title: workingNote.title,
                    body: planned.finalBody,
                    createdAt: workingNote.createdAt,
                    modifiedAt: indexedChange.change.modifiedAtForReplayOrdering
                )
                sequentialResults.append(planned)
                if case .legacyPositional = planned.effect {
                    sawLegacy = true
                }
            case .deferred(let reason):
                return .deferred(reason)
            case .failed(let failure):
                return .failed(failure)
            }
        }

        let finalHash = SyncBatchContentHash.sha256Hex(for: workingNote.body)
        let operationIdentities = (sequentialResults.flatMap(\.operationIdentities) + idempotentIdentities)
            .uniquedByIdentityKey()
        let retainedAdditions = sequentialResults.flatMap(\.retainedAdditions)
        let evidence = SyncConvergenceResultEvidence(
            batchID: input.incomingBatch.id,
            noteID: noteID,
            kind: .body,
            preHash: initialHash,
            postHash: finalHash,
            canonicalReplayKey: operationIdentities.last?.canonicalReplayKey
        )
        let routing: SyncConvergencePresentationRouting = .incremental
        let effect: SyncConvergenceBodyEffect
        if sawLegacy {
            effect = .legacyPositional(LegacyBodyPlan(
                noteID: noteID,
                initialBody: initialBody,
                operations: retainedAdditions,
                finalBody: workingNote.body,
                finalBodyHash: finalHash,
                resultEvidence: evidence
            ))
        } else {
            effect = .matchingBaseIncremental(MatchingBaseBodyPlan(
                noteID: noteID,
                initialBody: initialBody,
                initialBodyHash: initialHash,
                operations: retainedAdditions,
                finalBody: workingNote.body,
                finalBodyHash: finalHash,
                resultEvidence: evidence
            ))
        }

        return .success(PlannedBodyResult(
            effect: effect,
            finalBody: workingNote.body,
            operationIdentities: operationIdentities,
            resultEvidence: evidence,
            retainedAdditions: retainedAdditions,
            snapshotAdditions: [],
            routing: routing
        ))
    }

    private func planReconstructedBodyChanges(
        _ indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        noteID: UUID,
        requiredBaseHash: String,
        initialBody: String,
        current: SyncConvergenceProjectedNote,
        input: SyncConvergencePlanningInput,
        queueSelection: SyncConvergenceQueueSelection
    ) -> BodyPlanningResult {
        let reconstruction = SyncBaseReconstructor().reconstruct(
            noteID: noteID,
            requiredBaseHash: requiredBaseHash,
            snapshots: input.retainedSnapshots,
            retainedOperations: input.retainedLocalOperations + input.retainedRemoteOperations
        )
        let base: ReconstructedBase
        switch reconstruction {
        case .exactSnapshot(let reconstructed), .reconstructed(let reconstructed):
            base = reconstructed
        case .unavailable:
            return .deferred(.unreconstructableBase(
                noteID: noteID,
                batchID: input.incomingBatch.id,
                baseContentHash: requiredBaseHash
            ))
        case .failed(let failure):
            return .failed(failure)
        }

        let incomingOperations = indexedChanges.map {
            SyncConvergenceBodyOperation(
                change: $0.change,
                identity: operationIdentity(
                    for: $0.change,
                    in: input.incomingBatch,
                    operationIndex: $0.operationIndex,
                    kind: $0.change.operationKind
                )
            )
        }
        let queuedOperations = queuedBodyOperations(
            from: queueSelection.eligibleEvidenceBatches,
            noteID: noteID
        )
        let union = SyncOperationUnionBuilder().build(
            retained: input.retainedLocalOperations + input.retainedRemoteOperations,
            current: queuedOperations + incomingOperations,
            noteID: noteID,
            excludingIdentityKeys: base.consumedOperationIdentityKeys
        )
        switch union {
        case .success(let operations):
            return SyncOperationReplayEngine().planReconstructed(
                operations: operations,
                base: base,
                projectedCurrent: SyncConvergenceProjectedNote(
                    noteID: current.noteID,
                    folderID: current.folderID,
                    title: current.title,
                    body: initialBody,
                    createdAt: current.createdAt,
                    modifiedAt: current.modifiedAt
                ),
                batchID: input.incomingBatch.id
            )
        case .failure(let failure):
            return .failed(failure)
        }
    }

    private func unknownLegacyBodyNoop(
        _ indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        noteID: UUID,
        batchID: UUID,
        input: SyncConvergencePlanningInput
    ) -> BodyPlanningResult {
        let identities = indexedChanges.map { indexedChange in
            let identity = operationIdentity(
                for: indexedChange.change,
                in: input.incomingBatch,
                operationIndex: indexedChange.operationIndex,
                kind: indexedChange.change.operationKind
            )
            return identity
        }
        let evidence = SyncConvergenceResultEvidence(
            batchID: batchID,
            noteID: noteID,
            kind: .body,
            preHash: nil,
            postHash: nil,
            canonicalReplayKey: identities.last?.canonicalReplayKey
        )
        return .success(PlannedBodyResult(
            effect: .compatibilityNoopMissingNote(MissingNoteBodyNoopPlan(
                noteID: noteID,
                operationIdentities: identities,
                resultEvidence: evidence
            )),
            finalBody: "",
            operationIdentities: identities,
            resultEvidence: evidence,
            retainedAdditions: [],
            snapshotAdditions: [],
            routing: .none
        ))
    }

    private func planSequentialBodyChange(
        _ change: SyncBatchChange,
        operationIndex: Int,
        current: SyncConvergenceProjectedNote,
        input: SyncConvergencePlanningInput
    ) -> BodyPlanningResult {
        let replayEngine = SyncOperationReplayEngine()
        let identity = operationIdentity(for: change, in: input.incomingBatch, operationIndex: operationIndex, kind: change.operationKind)
        let currentHash = SyncBatchContentHash.sha256Hex(for: current.body)
        let baseHash = change.baseContentHash

        if baseHash == nil {
            return replayEngine.planLegacy(change, identity: identity, current: current, batchID: input.incomingBatch.id)
        }
        if baseHash == currentHash {
            return replayEngine.planMatchingBase(change, identity: identity, current: current, batchID: input.incomingBatch.id)
        }
        return .failed(.invalidMergePlan(noteID: current.noteID))
    }

    private func queuedBodyOperations(
        from queuedBatches: [SyncConvergenceQueuedBatch],
        noteID: UUID
    ) -> [SyncConvergenceBodyOperation] {
        queuedBatches.flatMap { queuedBatch in
            queuedBatch.batch.changes.enumerated().compactMap { operationIndex, change in
                guard change.noteID == noteID, change.isBodyTextOperation else {
                    return nil
                }
                return SyncConvergenceBodyOperation(
                    change: change,
                    identity: operationIdentity(
                        for: change,
                        in: queuedBatch.batch,
                        operationIndex: operationIndex,
                        kind: change.operationKind
                    )
                )
            }
        }
    }

    private func operationIdentity(
        for change: SyncBatchChange,
        in batch: SyncBatch,
        operationIndex: Int,
        kind: String
    ) -> OperationIdentityPayload {
        let replayKey = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: batch, change: change, operationIndex: operationIndex)
        )
        return OperationIdentityPayload(
            batchID: batch.id,
            originDeviceID: batch.originDeviceID,
            operationIndex: operationIndex,
            operationKind: kind,
            canonicalReplayKey: replayKey
        )
    }
}

enum SyncConvergenceCanonicalBatchDigest {
    static let supportedFormatVersion = 1

    enum Error: Swift.Error, Equatable {
        case unsupportedFormatVersion(Int)
        case invalidPayload(String)
    }

    static func digest(for batch: SyncBatch, formatVersion: Int = supportedFormatVersion) throws -> String {
        let bytes = try canonicalBytes(for: batch, formatVersion: formatVersion)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalBytes(for batch: SyncBatch, formatVersion: Int = supportedFormatVersion) throws -> Data {
        guard formatVersion == supportedFormatVersion else {
            throw Error.unsupportedFormatVersion(formatVersion)
        }
        var encoder = CanonicalPayloadDigestFormatV1()
        try encoder.appendBatch(batch)
        return encoder.data
    }
}

private struct CanonicalPayloadDigestFormatV1 {
    private enum Domain {
        static let batch: UInt32 = 0x4d595231
        static let absent: UInt8 = 0x00
        static let present: UInt8 = 0x01
        static let legacyOrder: UInt32 = 0x00000001
        static let sequencedOrder: UInt32 = 0x00000002
        static let creation: UInt32 = 0x00000001
        static let title: UInt32 = 0x00000002
        static let insert: UInt32 = 0x00000003
        static let delete: UInt32 = 0x00000004
        static let reconciliation: UInt32 = 0x00000005
    }

    private(set) var data = Data()

    mutating func appendBatch(_ batch: SyncBatch) throws {
        appendUInt32(Domain.batch)
        appendUInt32(UInt32(SyncConvergenceCanonicalBatchDigest.supportedFormatVersion))
        try appendUUID(batch.id)
        try appendUUID(batch.originDeviceID)
        appendUInt64(SyncConvergenceDateBits.bitPattern(for: batch.createdAt))
        appendOptionalUInt64(batch.batchSequence)
        appendUInt64(UInt64(batch.changes.count))
        for (index, change) in batch.changes.enumerated() {
            appendUInt64(UInt64(index))
            switch change {
            case .noteCreated(let created):
                appendUInt32(Domain.creation)
                try appendUUID(created.noteID)
                appendString(created.title)
                appendString(created.body)
                try appendOptionalUUID(created.folderID)
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: created.createdAt))
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: created.modifiedAt))
            case .noteTitleChanged(let titleChange):
                appendUInt32(Domain.title)
                try appendUUID(titleChange.noteID)
                appendString(titleChange.title)
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: titleChange.modifiedAt))
            case .noteBodyTextInserted(let insert):
                appendUInt32(Domain.insert)
                try appendUUID(insert.noteID)
                try appendInt(insert.utf16Offset, field: "utf16Offset")
                appendString(insert.text)
                appendOptionalString(insert.baseContentHash)
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: insert.modifiedAt))
            case .noteBodyTextDeleted(let delete):
                appendUInt32(Domain.delete)
                try appendUUID(delete.noteID)
                try appendInt(delete.utf16Offset, field: "utf16Offset")
                try appendInt(delete.utf16Length, field: "utf16Length")
                appendOptionalString(delete.expectedText)
                appendOptionalString(delete.baseContentHash)
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: delete.modifiedAt))
            case .noteBodyReconciled(let reconciliation):
                appendUInt32(Domain.reconciliation)
                try appendUUID(reconciliation.noteID)
                appendString(reconciliation.replacementBody)
                appendString(reconciliation.replacementContentHash)
                appendUInt64(SyncConvergenceDateBits.bitPattern(for: reconciliation.modifiedAt))
            }
        }
    }

    mutating func appendOperationIdentity(_ identity: OperationIdentityPayload) throws {
        guard identity.version == OperationIdentityPayload.supportedVersion else {
            throw SyncConvergenceCanonicalBatchDigest.Error.invalidPayload("operationIdentity.version")
        }
        appendString(identity.operationKind)
        try appendUUIDString(identity.batchIDLowercase, field: "batchIDLowercase")
        try appendUUIDString(identity.originDeviceIDLowercase, field: "originDeviceIDLowercase")
        try appendInt(identity.operationIndex, field: "operationIndex")
        try appendReplayKey(identity.canonicalReplayKey)
    }

    mutating func appendReplayKey(_ payload: CanonicalReplayKeyPayload) throws {
        try payload.validate()
        appendUInt32(UInt32(payload.version))
        appendUInt64(payload.modifiedAtBitPattern)
        try appendUUIDString(payload.originDeviceIDLowercase, field: "originDeviceIDLowercase")
        switch payload.batchOrderKind {
        case .legacy:
            appendUInt32(Domain.legacyOrder)
            appendUInt64(payload.legacyCreatedAtBitPattern ?? 0)
        case .sequenced:
            appendUInt32(Domain.sequencedOrder)
            appendUInt64(payload.sequence ?? 0)
        }
        try appendUUIDString(payload.batchIDLowercase, field: "batchIDLowercase")
        try appendInt(payload.operationIndex, field: "operationIndex")
    }

    mutating func appendResultEvidence(_ evidence: SyncConvergenceResultEvidence) throws {
        appendString(evidence.kind.rawValue)
        try appendUUID(evidence.batchID)
        try appendUUID(evidence.noteID)
        appendOptionalString(evidence.preHash)
        appendOptionalString(evidence.postHash)
        if let canonicalReplayKey = evidence.canonicalReplayKey {
            appendUInt8(Domain.present)
            try appendReplayKey(canonicalReplayKey)
        } else {
            appendUInt8(Domain.absent)
        }
    }

    mutating func appendProjectedIncorporationRoot(
        batch: SyncBatch,
        affectedNoteIDs: Set<UUID>,
        operationIdentityCount: Int,
        noteEffectCount: Int,
        resultEvidenceCount: Int
    ) throws {
        appendString("incorporation-root-v1")
        try appendUUID(batch.id)
        try appendUUID(batch.originDeviceID)
        appendUInt64(SyncConvergenceDateBits.bitPattern(for: batch.createdAt))
        appendOptionalUInt64(batch.batchSequence)
        appendUInt64(UInt64(affectedNoteIDs.count))
        for noteID in affectedNoteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try appendUUID(noteID)
        }
        try appendInt(operationIdentityCount, field: "operationIdentityCount")
        try appendInt(noteEffectCount, field: "noteEffectCount")
        try appendInt(resultEvidenceCount, field: "resultEvidenceCount")
    }

    mutating func appendProjectedNoteEffect(batchID: UUID, noteID: UUID, kinds: [String]) throws {
        appendString("incorporation-note-effect-v1")
        try appendUUID(batchID)
        try appendUUID(noteID)
        appendUInt64(UInt64(kinds.count))
        for kind in kinds.sorted() {
            appendString(kind)
        }
    }

    mutating func appendPlannedOperation(_ operation: SyncConvergencePlannedBodyOperation) throws {
        appendString(operation.kind.rawValue)
        try appendUUID(operation.noteID)
        try appendInt(operation.utf16Offset, field: "utf16Offset")
        try appendOptionalInt(operation.utf16Length)
        appendOptionalString(operation.text)
        appendOptionalString(operation.expectedText)
        appendOptionalString(operation.baseContentHash)
        appendString(operation.resultContentHash)
        try appendOperationIdentity(operation.operationIdentity)
    }

    private mutating func appendOptionalUUID(_ uuid: UUID?) throws {
        if let uuid {
            appendUInt8(Domain.present)
            try appendUUID(uuid)
        } else {
            appendUInt8(Domain.absent)
        }
    }

    private mutating func appendOptionalString(_ value: String?) {
        if let value {
            appendUInt8(Domain.present)
            appendString(value)
        } else {
            appendUInt8(Domain.absent)
        }
    }

    private mutating func appendOptionalInt(_ value: Int?) throws {
        if let value {
            appendUInt8(Domain.present)
            try appendInt(value, field: "optionalInt")
        } else {
            appendUInt8(Domain.absent)
        }
    }

    private mutating func appendOptionalUInt64(_ value: UInt64?) {
        if let value {
            appendUInt8(Domain.present)
            appendUInt64(value)
        } else {
            appendUInt8(Domain.absent)
        }
    }

    private mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8)
        appendUInt64(UInt64(bytes.count))
        data.append(bytes)
    }

    private mutating func appendUUID(_ uuid: UUID) throws {
        try appendUUIDString(uuid.uuidString.lowercased(), field: "uuid")
    }

    private mutating func appendUUIDString(_ value: String, field: String) throws {
        guard let uuid = UUID(uuidString: value) else {
            throw SyncConvergenceCanonicalBatchDigest.Error.invalidPayload(field)
        }
        var uuidValue = uuid.uuid
        withUnsafeBytes(of: &uuidValue) { data.append(contentsOf: $0) }
    }

    private mutating func appendInt(_ value: Int, field: String) throws {
        guard value >= 0 else {
            throw SyncConvergenceCanonicalBatchDigest.Error.invalidPayload(field)
        }
        appendUInt64(UInt64(value))
    }

    private mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    private mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

struct SyncConvergenceEvidenceSelector {
    func request(for batch: SyncBatch) -> SyncConvergenceEvidenceRequest {
        let noteIDs = Set(batch.changes.compactMap(\.noteID))
        let requiredHashes = Set(batch.changes.compactMap(\.baseContentHash))
        return SyncConvergenceEvidenceRequest(
            batchID: batch.id,
            affectedNoteIDs: noteIDs,
            requiredBaseHashes: requiredHashes,
            includeQueuedSuccessors: true,
            includeOutgoingProtectionEvidence: true
        )
    }

    func selectEligibleQueuedBatches(
        _ queuedBatches: [SyncConvergenceQueuedBatch],
        blockedNoteIDs: Set<UUID>
    ) -> [SyncConvergenceQueuedBatch] {
        queuedBatches
            .filter { $0.batch.affectedNoteIDs.isDisjoint(with: blockedNoteIDs) }
            .sorted {
                if $0.queuePosition != $1.queuePosition { return $0.queuePosition < $1.queuePosition }
                return $0.batch.id.uuidString < $1.batch.id.uuidString
            }
    }

    func selectQueuedBatches(
        for candidateBatch: SyncBatch,
        queuedBatches: [SyncConvergenceQueuedBatch],
        candidateQueuePosition: Int? = nil
    ) -> SyncConvergenceQueueSelection {
        let candidateNoteIDs = candidateBatch.affectedNoteIDs
        let ordered = queuedBatches.sorted(by: deterministicQueueOrder)
        // A live newest arrival follows every durable queue entry; a queued-drain caller
        // must supply the candidate's durable position rather than relying on inference.
        let candidatePosition = candidateQueuePosition
            ?? ordered.first { $0.batch.id == candidateBatch.id }.map(\.queuePosition)
            ?? Int.max
        let candidateQueuedBatch = SyncConvergenceQueuedBatch(batch: candidateBatch, queuePosition: candidatePosition)
        var blockedNoteIDs = candidateNoteIDs
        var eligibleEvidence: [SyncConvergenceQueuedBatch] = []
        var eligibleDisjoint: [SyncConvergenceQueuedBatch] = []
        var blocked: [SyncConvergenceQueuedBatch] = []

        for queued in ordered {
            if queued.batch.id == candidateBatch.id {
                continue
            }
            let noteIDs = queued.batch.affectedNoteIDs
            if queued.queuePosition < candidatePosition && !noteIDs.isDisjoint(with: candidateNoteIDs) {
                // A queued batch is atomic: it may serve as union evidence only when the
                // candidate can consume it completely — every affected note covered by
                // the candidate and every change a body-text operation. Anything else
                // must incorporate as its own candidate; splicing part of it out would
                // be partial incorporation, so it blocks instead.
                let fullyConsumable = noteIDs.isSubset(of: candidateNoteIDs)
                    && queued.batch.changes.allSatisfy(\.isBodyTextOperation)
                if fullyConsumable {
                    eligibleEvidence.append(queued)
                } else {
                    blocked.append(queued)
                    blockedNoteIDs.formUnion(noteIDs)
                }
                continue
            }
            if noteIDs.isDisjoint(with: blockedNoteIDs) {
                eligibleDisjoint.append(queued)
            } else {
                blocked.append(queued)
                blockedNoteIDs.formUnion(noteIDs)
            }
        }

        return SyncConvergenceQueueSelection(
            candidateBatch: candidateQueuedBatch,
            eligibleEvidenceBatches: eligibleEvidence,
            eligibleDisjointBatches: eligibleDisjoint,
            blockedBatches: blocked,
            blockedNoteIDs: blockedNoteIDs
        )
    }

    private func deterministicQueueOrder(
        _ lhs: SyncConvergenceQueuedBatch,
        _ rhs: SyncConvergenceQueuedBatch
    ) -> Bool {
        if lhs.queuePosition != rhs.queuePosition { return lhs.queuePosition < rhs.queuePosition }
        return lhs.batch.id.uuidString < rhs.batch.id.uuidString
    }
}

private struct SyncOperationReplayEngine {
    func planLegacy(
        _ change: SyncBatchChange,
        identity: OperationIdentityPayload,
        current: SyncConvergenceProjectedNote,
        batchID: UUID
    ) -> BodyPlanningResult {
        replaySingle(change, identity: identity, body: current.body, noteID: current.noteID, mode: .legacyPositional).map { replay in
            let finalHash = replay.resultEvidence.postHash ?? SyncBatchContentHash.sha256Hex(for: replay.finalBody)
            let operation = replay.retainedAdditions[0]
            let evidence = SyncConvergenceResultEvidence(
                batchID: batchID,
                noteID: current.noteID,
                kind: .body,
                preHash: SyncBatchContentHash.sha256Hex(for: current.body),
                postHash: finalHash,
                canonicalReplayKey: identity.canonicalReplayKey
            )
            return PlannedBodyResult(
                effect: .legacyPositional(LegacyBodyPlan(
                    noteID: current.noteID,
                    initialBody: current.body,
                    operations: [operation],
                    finalBody: replay.finalBody,
                    finalBodyHash: finalHash,
                    resultEvidence: evidence
                )),
                finalBody: replay.finalBody,
                operationIdentities: [identity],
                resultEvidence: evidence,
                retainedAdditions: [operation],
                snapshotAdditions: [],
                routing: .incremental
            )
        }
    }

    func planMatchingBase(
        _ change: SyncBatchChange,
        identity: OperationIdentityPayload,
        current: SyncConvergenceProjectedNote,
        batchID: UUID
    ) -> BodyPlanningResult {
        replaySingle(change, identity: identity, body: current.body, noteID: current.noteID, mode: .legacyPositional).map { replay in
            let initialHash = SyncBatchContentHash.sha256Hex(for: current.body)
            let finalHash = replay.resultEvidence.postHash ?? SyncBatchContentHash.sha256Hex(for: replay.finalBody)
            let operation = replay.retainedAdditions[0]
            let evidence = SyncConvergenceResultEvidence(
                batchID: batchID,
                noteID: current.noteID,
                kind: .body,
                preHash: initialHash,
                postHash: finalHash,
                canonicalReplayKey: identity.canonicalReplayKey
            )
            return PlannedBodyResult(
                effect: .matchingBaseIncremental(MatchingBaseBodyPlan(
                    noteID: current.noteID,
                    initialBody: current.body,
                    initialBodyHash: initialHash,
                    operations: [operation],
                    finalBody: replay.finalBody,
                    finalBodyHash: finalHash,
                    resultEvidence: evidence
                )),
                finalBody: replay.finalBody,
                operationIdentities: [identity],
                resultEvidence: evidence,
                retainedAdditions: [operation],
                snapshotAdditions: [],
                routing: .incremental
            )
        }
    }

    func planDeclaredChainStep(
        _ change: SyncBatchChange,
        identity: OperationIdentityPayload,
        current: SyncConvergenceProjectedNote,
        batchID: UUID
    ) -> BodyPlanningResult {
        replaySingle(change, identity: identity, body: current.body, noteID: current.noteID, mode: .reconstructingDeclaredChain).map { replay in
            let initialHash = SyncBatchContentHash.sha256Hex(for: current.body)
            let finalHash = replay.resultEvidence.postHash ?? SyncBatchContentHash.sha256Hex(for: replay.finalBody)
            let operation = replay.retainedAdditions[0]
            let evidence = SyncConvergenceResultEvidence(
                batchID: batchID,
                noteID: current.noteID,
                kind: .body,
                preHash: initialHash,
                postHash: finalHash,
                canonicalReplayKey: identity.canonicalReplayKey
            )
            return PlannedBodyResult(
                effect: .matchingBaseIncremental(MatchingBaseBodyPlan(
                    noteID: current.noteID,
                    initialBody: current.body,
                    initialBodyHash: initialHash,
                    operations: [operation],
                    finalBody: replay.finalBody,
                    finalBodyHash: finalHash,
                    resultEvidence: evidence
                )),
                finalBody: replay.finalBody,
                operationIdentities: [identity],
                resultEvidence: evidence,
                retainedAdditions: [operation],
                snapshotAdditions: [],
                routing: .incremental
            )
        }
    }

    func planReconstructed(
        operations: [SyncConvergenceBodyOperation],
        base: ReconstructedBase,
        projectedCurrent: SyncConvergenceProjectedNote,
        batchID: UUID
    ) -> BodyPlanningResult {
        var body = base.body
        var plannedOperations: [SyncConvergencePlannedBodyOperation] = []
        for operation in operations {
            switch replaySingle(
                operation.change,
                identity: operation.identity,
                body: body,
                noteID: projectedCurrent.noteID,
                mode: .replayingConflictUnion
            ) {
            case .success(let replay):
                body = replay.finalBody
                plannedOperations.append(contentsOf: replay.retainedAdditions)
            case .deferred(let reason):
                return .deferred(reason)
            case .failed(let failure):
                return .failed(failure)
            }
        }
        let finalHash = SyncBatchContentHash.sha256Hex(for: body)
        let currentHash = SyncBatchContentHash.sha256Hex(for: projectedCurrent.body)
        let evidence = SyncConvergenceResultEvidence(
            batchID: batchID,
            noteID: projectedCurrent.noteID,
            kind: .body,
            preHash: currentHash,
            postHash: finalHash,
            canonicalReplayKey: operations.last?.identity.canonicalReplayKey
        )
        let snapshot = SyncConvergenceSnapshotAddition(
            noteID: projectedCurrent.noteID,
            contentHash: finalHash,
            body: body,
            generation: base.generation + 1
        )
        return .success(PlannedBodyResult(
            effect: .reconstructedConflict(ReconstructedConflictBodyPlan(
                noteID: projectedCurrent.noteID,
                reconstructedBaseBody: base.body,
                reconstructedBaseHash: base.contentHash,
                projectedPreMergeCurrentBody: projectedCurrent.body,
                projectedPreMergeCurrentHash: currentHash,
                orderedOperationIdentities: operations.map(\.identity),
                finalBody: body,
                finalBodyHash: finalHash,
                retainedOperationAdditions: plannedOperations,
                snapshotAdditions: [snapshot],
                resultEvidence: evidence,
                presentationRouting: .wholeNoteFallback
            )),
            finalBody: body,
            operationIdentities: operations.map(\.identity),
            resultEvidence: evidence,
            retainedAdditions: plannedOperations,
            snapshotAdditions: [snapshot],
            routing: .wholeNoteFallback
        ))
    }

    private func replaySingle(
        _ change: SyncBatchChange,
        identity: OperationIdentityPayload,
        body: String,
        noteID: UUID,
        mode: SyncOperationReplayMode
    ) -> BodyPlanningResult {
        switch change {
        case .noteBodyTextInserted(let insert):
            if mode == .reconstructingDeclaredChain, let baseContentHash = insert.baseContentHash,
               baseContentHash != SyncBatchContentHash.sha256Hex(for: body) {
                return .failed(.corruptHistory(noteID: noteID))
            }
            guard !insert.text.isEmpty else {
                let hash = SyncBatchContentHash.sha256Hex(for: body)
                return .success(PlannedBodyResult.singleNoop(
                    noteID: noteID,
                    body: body,
                    hash: hash,
                    identity: identity,
                    kind: .insert,
                    offset: insert.utf16Offset,
                    text: insert.text,
                    baseContentHash: insert.baseContentHash
                ))
            }
            let safeOffset = body.syncBatchSafeInsertionOffset(fallingForwardFrom: insert.utf16Offset)
            let finalBody = body.syncBatchInserting(insert.text, atUTF16Offset: safeOffset)
            let finalHash = SyncBatchContentHash.sha256Hex(for: finalBody)
            return .success(PlannedBodyResult.single(
                noteID: noteID,
                initialBody: body,
                finalBody: finalBody,
                finalHash: finalHash,
                operation: SyncConvergencePlannedBodyOperation(
                    noteID: noteID,
                    kind: .insert,
                    utf16Offset: safeOffset,
                    utf16Length: nil,
                    text: insert.text,
                    expectedText: nil,
                    baseContentHash: insert.baseContentHash,
                    resultContentHash: finalHash,
                    operationIdentity: identity
                )
            ))
        case .noteBodyTextDeleted(let delete):
            if mode == .reconstructingDeclaredChain, let baseContentHash = delete.baseContentHash,
               baseContentHash != SyncBatchContentHash.sha256Hex(for: body) {
                return .failed(.corruptHistory(noteID: noteID))
            }
            guard delete.utf16Length > 0 else {
                let hash = SyncBatchContentHash.sha256Hex(for: body)
                return .success(PlannedBodyResult.singleNoop(
                    noteID: noteID,
                    body: body,
                    hash: hash,
                    identity: identity,
                    kind: .delete,
                    offset: delete.utf16Offset,
                    length: delete.utf16Length,
                    expectedText: delete.expectedText,
                    baseContentHash: delete.baseContentHash
                ))
            }
            guard let range = body.syncBatchSafeUTF16Range(location: delete.utf16Offset, length: delete.utf16Length),
                  let swiftRange = Range(range, in: body) else {
                if mode == .reconstructingDeclaredChain {
                    return .failed(.corruptHistory(noteID: noteID))
                }
                let hash = SyncBatchContentHash.sha256Hex(for: body)
                return .success(PlannedBodyResult.singleNoop(
                    noteID: noteID,
                    body: body,
                    hash: hash,
                    identity: identity,
                    kind: .delete,
                    offset: delete.utf16Offset,
                    length: delete.utf16Length,
                    expectedText: delete.expectedText,
                    baseContentHash: delete.baseContentHash
                ))
            }
            let actual = String(body[swiftRange])
            if let expectedText = delete.expectedText, expectedText != actual {
                if mode == .reconstructingDeclaredChain {
                    return .failed(.corruptHistory(noteID: noteID))
                }
                let hash = SyncBatchContentHash.sha256Hex(for: body)
                return .success(PlannedBodyResult.singleNoop(
                    noteID: noteID,
                    body: body,
                    hash: hash,
                    identity: identity,
                    kind: .delete,
                    offset: delete.utf16Offset,
                    length: delete.utf16Length,
                    expectedText: delete.expectedText,
                    baseContentHash: delete.baseContentHash
                ))
            }
            var finalBody = body
            finalBody.removeSubrange(swiftRange)
            let finalHash = SyncBatchContentHash.sha256Hex(for: finalBody)
            return .success(PlannedBodyResult.single(
                noteID: noteID,
                initialBody: body,
                finalBody: finalBody,
                finalHash: finalHash,
                operation: SyncConvergencePlannedBodyOperation(
                    noteID: noteID,
                    kind: .delete,
                    utf16Offset: delete.utf16Offset,
                    utf16Length: delete.utf16Length,
                    text: nil,
                    expectedText: delete.expectedText,
                    baseContentHash: delete.baseContentHash,
                    resultContentHash: finalHash,
                    operationIdentity: identity
                )
            ))
        default:
            return .failed(.invalidMergePlan(noteID: noteID))
        }
    }
}

private enum SyncOperationReplayMode: Equatable {
    case legacyPositional
    case reconstructingDeclaredChain
    case replayingConflictUnion
}

private struct SyncBaseReconstructor {
    func reconstruct(
        noteID: UUID,
        requiredBaseHash: String,
        snapshots: [SyncConvergenceRetainedSnapshot],
        retainedOperations: [SyncConvergenceRetainedOperation]
    ) -> SyncBaseReconstructionResult {
        let noteSnapshots = snapshots.filter { $0.noteID == noteID }
        if let exact = noteSnapshots.first(where: { $0.contentHash == requiredBaseHash }) {
            return .exactSnapshot(ReconstructedBase(
                body: exact.body,
                contentHash: exact.contentHash,
                generation: exact.generation,
                consumedOperationIdentityKeys: []
            ))
        }

        let chainResult = sortRetainedOperations(retainedOperations
            .filter { $0.noteID == noteID }
        )
        let chain: [SyncConvergenceRetainedOperation]
        switch chainResult {
        case .success(let sorted):
            chain = sorted
        case .failure(let failure):
            return .failed(failure)
        }

        let replayEngine = SyncOperationReplayEngine()
        let candidates = noteSnapshots.sorted { $0.generation > $1.generation }
        for snapshot in candidates {
            switch searchChain(
                snapshotBody: snapshot.body,
                snapshotGeneration: snapshot.generation,
                chain: chain,
                requiredBaseHash: requiredBaseHash,
                noteID: noteID,
                replayEngine: replayEngine
            ) {
            case .found(let base):
                return .reconstructed(base)
            case .corrupt(let failure):
                return .failed(failure)
            case .notFound:
                continue
            }
        }
        return .unavailable
    }

    private enum ChainSearchResult {
        case found(ReconstructedBase)
        case corrupt(SyncConvergenceTransactionFailure)
        case notFound
    }

    // Bounded, target-directed, iterative reconstruction search.
    //
    // States are distinct reconstructed body hashes, each expanded at most once with
    // a deterministic predecessor, so duplicate-result operations and insert/delete
    // cycles can never re-explore a body. Because any successor that repeats an
    // already-visited body hash is pruned, no operation can usefully apply twice on
    // any explored path, which removes per-path consumed-set state entirely. Total
    // work is polynomial: at most `maxExpandedStates` expansions, each against the
    // base-hash-indexed claiming operations for the current body plus the nil-base
    // candidate list. Exceeding the cap returns .notFound, which defers the batch as
    // unreconstructable — the fail-safe outcome; the search never guesses.
    private static let maxExpandedStates = 4_096

    private func searchChain(
        snapshotBody: String,
        snapshotGeneration: Int,
        chain: [SyncConvergenceRetainedOperation],
        requiredBaseHash: String,
        noteID: UUID,
        replayEngine: SyncOperationReplayEngine
    ) -> ChainSearchResult {
        struct SearchState {
            let body: String
            let bodyHash: String
            let generation: Int
            let parentIndex: Int?
            let consumedKey: String?
        }

        var claimingByBaseHash: [String: [SyncConvergenceRetainedOperation]] = [:]
        var nilBaseCandidates: [SyncConvergenceRetainedOperation] = []
        for retained in chain {
            if let base = retained.baseContentHash {
                claimingByBaseHash[base, default: []].append(retained)
            } else if retained.resultContentHash != nil {
                // A nil-base legacy step makes no claim about position; it joins the
                // chain only when strict replay proves its declared result.
                nilBaseCandidates.append(retained)
            }
            // Neither base nor result evidence: never guessed into a chain.
        }

        var states = [SearchState(
            body: snapshotBody,
            bodyHash: SyncBatchContentHash.sha256Hex(for: snapshotBody),
            generation: snapshotGeneration,
            parentIndex: nil,
            consumedKey: nil
        )]
        var visitedBodyHashes: Set<String> = [states[0].bodyHash]
        var index = 0
        while index < states.count, index < Self.maxExpandedStates {
            let state = states[index]
            let claiming = claimingByBaseHash[state.bodyHash] ?? []
            for retained in claiming + nilBaseCandidates {
                let claimsCurrentPosition = retained.baseContentHash != nil
                let identity = OperationIdentityPayload(
                    batchID: retained.batchID,
                    originDeviceID: retained.originDeviceID,
                    operationIndex: retained.operationIndex,
                    operationKind: retained.operationKind.rawValue,
                    canonicalReplayKey: retained.canonicalReplayKey
                )
                switch replayEngine.planDeclaredChainStep(
                    retained.syncBatchChange,
                    identity: identity,
                    current: SyncConvergenceProjectedNote(
                        noteID: noteID,
                        folderID: nil,
                        title: "",
                        body: state.body,
                        createdAt: .distantPast,
                        modifiedAt: retained.canonicalReplayKey.modifiedAt
                    ),
                    batchID: retained.batchID
                ) {
                case .success(let result):
                    let finalHash = SyncBatchContentHash.sha256Hex(for: result.finalBody)
                    if let expected = retained.resultContentHash, expected != finalHash {
                        if claimsCurrentPosition {
                            // The operation claimed this exact body and contradicted
                            // its own declared result: present-but-contradictory.
                            return .corrupt(.corruptHistory(noteID: noteID))
                        }
                        // A nil-base step whose result does not match does not extend
                        // this chain; it may belong to another branch.
                        continue
                    }
                    if finalHash == requiredBaseHash {
                        var consumed: Set<String> = [retained.identityKey]
                        var cursor: Int? = index
                        while let current = cursor {
                            if let key = states[current].consumedKey {
                                consumed.insert(key)
                            }
                            cursor = states[current].parentIndex
                        }
                        return .found(ReconstructedBase(
                            body: result.finalBody,
                            contentHash: requiredBaseHash,
                            generation: state.generation + 1,
                            consumedOperationIdentityKeys: consumed
                        ))
                    }
                    guard visitedBodyHashes.insert(finalHash).inserted else {
                        continue
                    }
                    states.append(SearchState(
                        body: result.finalBody,
                        bodyHash: finalHash,
                        generation: state.generation + 1,
                        parentIndex: index,
                        consumedKey: retained.identityKey
                    ))
                case .deferred:
                    continue
                case .failed(let failure):
                    if claimsCurrentPosition {
                        return .corrupt(failure)
                    }
                    // A nil-base step that cannot replay from this body does not
                    // extend this chain; it may belong to another branch.
                    continue
                }
            }
            index += 1
        }
        return .notFound
    }

    private func sortRetainedOperations(
        _ operations: [SyncConvergenceRetainedOperation]
    ) -> RetainedOperationSortResult {
        do {
            let validated = try operations.map { operation in
                (operation, try ValidatedCanonicalReplayKey(operation.canonicalReplayKey))
            }
            return .success(validated.sorted { $0.1 < $1.1 }.map(\.0))
        } catch {
            return .failure(.corruptHistory(noteID: operations.first?.noteID))
        }
    }
}

private enum RetainedOperationSortResult {
    case success([SyncConvergenceRetainedOperation])
    case failure(SyncConvergenceTransactionFailure)
}

enum SyncBaseReconstructionResult: Equatable {
    case exactSnapshot(ReconstructedBase)
    case reconstructed(ReconstructedBase)
    case unavailable
    case failed(SyncConvergenceTransactionFailure)
}

struct ReconstructedBase: Equatable {
    let body: String
    let contentHash: String
    let generation: Int
    let consumedOperationIdentityKeys: Set<String>
}

private struct SyncOperationUnionBuilder {
    func build(
        retained: [SyncConvergenceRetainedOperation],
        current: [SyncConvergenceBodyOperation],
        noteID: UUID,
        excludingIdentityKeys excludedIdentityKeys: Set<String> = []
    ) -> OperationUnionResult {
        var operations: [String: SyncConvergenceBodyOperation] = [:]
        for retainedOperation in retained where retainedOperation.noteID == noteID {
            guard !excludedIdentityKeys.contains(retainedOperation.identityKey) else { continue }
            let operation = SyncConvergenceBodyOperation(retained: retainedOperation)
            let key = operation.identityKey
            if let existing = operations[key], existing != operation {
                return .failure(.inconsistentIncorporationState(noteID: noteID))
            }
            operations[key] = operation
        }
        for operation in current {
            guard !excludedIdentityKeys.contains(operation.identityKey) else { continue }
            let key = operation.identityKey
            if let existing = operations[key] {
                // A current operation re-presenting a retained identity is idempotent when
                // the transport evidence matches; only contradictory evidence fails closed.
                // Keep the retained entry, which carries the richer result-hash evidence.
                guard existing.isEquivalentEvidence(to: operation) else {
                    return .failure(.inconsistentIncorporationState(noteID: noteID))
                }
                continue
            }
            operations[key] = operation
        }
        do {
            let validated = try operations.values.map { operation in
                (operation, try ValidatedCanonicalReplayKey(operation.identity.canonicalReplayKey))
            }
            return .success(validated.sorted { $0.1 < $1.1 }.map(\.0))
        } catch {
            return .failure(.corruptHistory(noteID: noteID))
        }
    }
}

private enum OperationUnionResult {
    case success([SyncConvergenceBodyOperation])
    case failure(SyncConvergenceTransactionFailure)
}

private struct SyncTitleWinnerPlanner {
    func plan(
        noteID: UUID,
        priorTitle: String,
        persistedWinners: [SyncConvergenceTitleWinnerProjection],
        candidateTitle: String,
        candidateIdentity: OperationIdentityPayload
    ) -> TitlePlanningResult {
        let persistedWinner: SyncConvergenceTitleWinnerProjection?
        switch validateSingleAuthority(persistedWinners, noteID: noteID) {
        case .success(let winner):
            persistedWinner = winner
        case .failure(let failure):
            return .failure(failure)
        }

        if let persistedWinner,
           persistedWinner.operationIdentity == candidateIdentity,
           persistedWinner.title != candidateTitle {
            return .failure(.inconsistentIncorporationState(noteID: noteID))
        }

        let verdict: SyncConvergenceTitleVerdict
        let resultingTitle: String
        let resultingWinningKey: CanonicalReplayKeyPayload
        if let persistedWinner {
            do {
                let priorKey = try ValidatedCanonicalReplayKey(persistedWinner.canonicalReplayKey)
                let candidateKey = try ValidatedCanonicalReplayKey(candidateIdentity.canonicalReplayKey)
                if persistedWinner.operationIdentity == candidateIdentity {
                    verdict = .idempotent
                    resultingTitle = persistedWinner.title
                    resultingWinningKey = persistedWinner.canonicalReplayKey
                } else if candidateKey < priorKey {
                    verdict = .ignoreOlder
                    resultingTitle = persistedWinner.title
                    resultingWinningKey = persistedWinner.canonicalReplayKey
                } else {
                    verdict = .apply
                    resultingTitle = candidateTitle
                    resultingWinningKey = candidateIdentity.canonicalReplayKey
                }
            } catch {
                return .failure(.corruptHistory(noteID: noteID))
            }
        } else {
            verdict = .apply
            resultingTitle = candidateTitle
            resultingWinningKey = candidateIdentity.canonicalReplayKey
        }

        return .success(SyncConvergenceTitleEffect(
            priorTitle: priorTitle,
            priorWinningKey: persistedWinner?.canonicalReplayKey,
            candidateTitle: candidateTitle,
            candidateOperationIdentity: candidateIdentity,
            candidateCanonicalKey: candidateIdentity.canonicalReplayKey,
            verdict: verdict,
            resultingTitle: resultingTitle,
            resultingWinningKey: resultingWinningKey,
            resultEvidence: SyncConvergenceResultEvidence(
                batchID: UUID(uuidString: candidateIdentity.batchIDLowercase) ?? noteID,
                noteID: noteID,
                kind: .title,
                preHash: nil,
                postHash: nil,
                canonicalReplayKey: resultingWinningKey
            )
        ))
    }

    private func validateSingleAuthority(
        _ winners: [SyncConvergenceTitleWinnerProjection],
        noteID: UUID
    ) -> TitleAuthorityResult {
        guard let first = winners.first else {
            return .success(nil)
        }
        for winner in winners.dropFirst() where winner != first {
            return .failure(.inconsistentIncorporationState(noteID: noteID))
        }
        return .success(first)
    }
}

private enum TitlePlanningResult {
    case success(SyncConvergenceTitleEffect)
    case failure(SyncConvergenceTransactionFailure)
}

private enum TitleAuthorityResult {
    case success(SyncConvergenceTitleWinnerProjection?)
    case failure(SyncConvergenceTransactionFailure)
}

private struct SyncConvergenceHistoryPolicy {
    private enum Limits {
        static let softSnapshots = 8
        static let hardSnapshots = 12
        static let softRetainedOperations = 512
        static let hardRetainedOperations = 768
        static let softSnapshotBytes = 1_048_576
        static let hardSnapshotBytes = 1_572_864
        static let softOperationBytes = 1_048_576
        static let hardOperationBytes = 1_572_864
        static let softFullEvidenceBytes = 262_144
        static let hardFullEvidenceBytes = 524_288
        static let softEvidenceBytes = 65_536
        static let hardEvidenceBytes = 131_072
        static let softCompletedEpisodes = 3
        static let hardCompletedEpisodes = 5
        static let activeEpisodes = 1
    }

    func plan(
        affectedNoteIDs: Set<UUID>,
        currentStates: [SyncConvergenceHistoryAccountingProjection],
        retainedOperationAdditions: [SyncConvergencePlannedBodyOperation],
        snapshotAdditions: [SyncConvergenceSnapshotAddition],
        fullIncorporationEvidenceBytes: Int
    ) -> HistoryPlanningResult {
        var pressureNotes: Set<UUID> = []
        for noteID in affectedNoteIDs {
            let current = currentStates.first { $0.noteID == noteID } ?? .empty(noteID: noteID)
            let addedSnapshots = snapshotAdditions.filter { $0.noteID == noteID }
            let addedOperations = retainedOperationAdditions.filter { $0.noteID == noteID }
            let projectedSnapshotCount = current.snapshotCount + addedSnapshots.count
            let projectedOperationCount = current.retainedOperationCount + addedOperations.count
            let projectedSnapshotBytes = current.snapshotBytes + addedSnapshots.reduce(0) { $0 + $1.body.utf8.count }
            let addedOperationBytes: Int
            do {
                addedOperationBytes = try addedOperations.reduce(0) { try $0 + $1.canonicalEncodedByteCount() }
            } catch {
                // Capacity enforcement must fail closed: an unencodable payload can
                // never be charged as zero bytes.
                return .failed(.invalidMergePlan(noteID: noteID))
            }
            let projectedOperationBytes = current.retainedOperationBytes + addedOperationBytes
            let projectedFullEvidenceBytes = current.fullIncorporationEvidenceBytes + fullIncorporationEvidenceBytes
            let addsBoundedEvidence = !addedSnapshots.isEmpty ||
                !addedOperations.isEmpty ||
                fullIncorporationEvidenceBytes > 0

            if projectedSnapshotCount > Limits.hardSnapshots ||
                projectedOperationCount > Limits.hardRetainedOperations ||
                projectedSnapshotBytes > Limits.hardSnapshotBytes ||
                projectedOperationBytes > Limits.hardOperationBytes ||
                projectedFullEvidenceBytes > Limits.hardFullEvidenceBytes ||
                current.diagnosticEvidenceBytes > Limits.hardEvidenceBytes ||
                current.cleanupEvidenceBytes > Limits.hardEvidenceBytes ||
                current.reconciliationEvidenceBytes > Limits.hardEvidenceBytes ||
                current.completedReconciliationEpisodeCount > Limits.hardCompletedEpisodes ||
                current.activeReconciliationEpisodeCount > Limits.activeEpisodes {
                return .deferred(.historyPressure(noteID: noteID, blockingBatchID: nil))
            }

            if projectedSnapshotCount > Limits.softSnapshots ||
                projectedOperationCount > Limits.softRetainedOperations ||
                projectedSnapshotBytes > Limits.softSnapshotBytes ||
                projectedOperationBytes > Limits.softOperationBytes ||
                projectedFullEvidenceBytes > Limits.softFullEvidenceBytes ||
                current.diagnosticEvidenceBytes > Limits.softEvidenceBytes ||
                current.cleanupEvidenceBytes > Limits.softEvidenceBytes ||
                current.reconciliationEvidenceBytes > Limits.softEvidenceBytes ||
                current.completedReconciliationEpisodeCount > Limits.softCompletedEpisodes {
                pressureNotes.insert(noteID)
                if addsBoundedEvidence {
                    return .deferred(.historyPressure(noteID: noteID, blockingBatchID: nil))
                }
            }
        }

        return .success(SyncConvergenceHistoryPlan(
            retainedOperationAdditions: retainedOperationAdditions,
            snapshotAdditions: snapshotAdditions,
            pressureNotes: pressureNotes
        ))
    }
}

struct SyncConvergencePlanValidator {
    func validate(
        _ plan: SyncConvergenceBatchPlan,
        input: SyncConvergencePlanningInput,
        queueSelection: SyncConvergenceQueueSelection,
        projectedFullIncorporationEvidenceBytes: Int
    ) -> SyncConvergencePlanningOutcome? {
        guard !plan.batchID.uuidString.isEmpty,
              !plan.originDeviceID.uuidString.isEmpty,
              plan.batchID == input.incomingBatch.id,
              plan.originDeviceID == input.incomingBatch.originDeviceID,
              plan.canonicalPayloadDigest.count == 64,
              plan.canonicalPayloadDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              plan.canonicalPayloadDigestFormatVersion == SyncConvergenceCanonicalBatchDigest.supportedFormatVersion else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        guard let recomputedDigest = try? SyncConvergenceCanonicalBatchDigest.digest(
            for: input.incomingBatch,
            formatVersion: plan.canonicalPayloadDigestFormatVersion
        ), recomputedDigest == plan.canonicalPayloadDigest else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        let sourceAffectedNoteIDs = Set(input.incomingBatch.changes.compactMap(\.noteID))
        let plannedNoteIDs = Set(plan.affectedNotePlans.map(\.noteID))
        guard plannedNoteIDs == sourceAffectedNoteIDs else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        guard queueSelection.blockedBatches.allSatisfy({
            !$0.batch.affectedNoteIDs.isDisjoint(with: queueSelection.blockedNoteIDs)
        }) else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        var seenIdentities: Set<String> = []
        var presentIncomingIndexes: Set<Int> = []
        let blockedBatchIDsLowercase = Set(queueSelection.blockedBatches.map { $0.batch.id.uuidString.lowercased() })
        for identity in plan.incorporationEvidence.operationIdentities {
            do {
                try identity.validate()
                _ = try ValidatedCanonicalReplayKey(identity.canonicalReplayKey)
            } catch {
                return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
            }
            let key = "\(identity.batchIDLowercase)|\(identity.operationIndex)"
            guard !seenIdentities.contains(key) else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
            }
            // A blocked queued successor must never contribute evidence to this plan.
            guard !blockedBatchIDsLowercase.contains(identity.batchIDLowercase) else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
            }
            if UUID(uuidString: identity.batchIDLowercase) == input.incomingBatch.id {
                guard input.incomingBatch.changes.indices.contains(identity.operationIndex),
                      input.incomingBatch.changes[identity.operationIndex].operationKind == identity.operationKind else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
                }
                presentIncomingIndexes.insert(identity.operationIndex)
            }
            seenIdentities.insert(key)
        }
        // Every source operation must be represented exactly once; a dropped incoming
        // operation is an invalid plan even when its note remains represented.
        guard presentIncomingIndexes == Set(input.incomingBatch.changes.indices) else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        var resultEvidenceKeys: Set<String> = []
        for evidence in plan.incorporationEvidence.resultEvidence {
            let key = "\(evidence.batchID.uuidString.lowercased())|\(evidence.noteID.uuidString.lowercased())|\(evidence.kind.rawValue)"
            guard !resultEvidenceKeys.contains(key) else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: evidence.noteID))
            }
            resultEvidenceKeys.insert(key)
            if let canonicalReplayKey = evidence.canonicalReplayKey {
                do {
                    _ = try ValidatedCanonicalReplayKey(canonicalReplayKey)
                } catch {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: evidence.noteID))
                }
            }
        }

        let plannedIdentityKeys = seenIdentities
        var expectedRetainedAdditions: [SyncConvergencePlannedBodyOperation] = []
        var expectedSnapshotAdditions: [SyncConvergenceSnapshotAddition] = []
        var expectedResultEvidence: [SyncConvergenceResultEvidence] = []
        for notePlan in plan.affectedNotePlans {
            guard notePlan.creationEffect != nil || notePlan.bodyEffect != nil || notePlan.titleEffect != nil else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
            }
            let routing = plan.presentationPlan.noteRoutings[notePlan.noteID]
            if let creationEffect = notePlan.creationEffect {
                guard creationEffect.noteID == notePlan.noteID,
                      creationEffect.resultEvidence.kind == .creation,
                      creationEffect.resultEvidence.noteID == notePlan.noteID,
                      creationEffect.resultEvidence.batchID == plan.batchID,
                      creationEffect.resultEvidence.preHash == nil,
                      creationEffect.resultEvidence.postHash == creationEffect.initialBodyHash else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedResultEvidence.append(creationEffect.resultEvidence)
            }
            switch notePlan.bodyEffect {
            case .matchingBaseIncremental(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.initialBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.initialBody),
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.resultEvidence.kind == .body,
                      bodyPlan.resultEvidence.noteID == notePlan.noteID,
                      bodyPlan.resultEvidence.batchID == plan.batchID,
                      bodyPlan.resultEvidence.preHash == bodyPlan.initialBodyHash,
                      bodyPlan.resultEvidence.postHash == bodyPlan.finalBodyHash,
                      routing == .incremental,
                      bodyPlan.operations.allSatisfy({ $0.noteID == notePlan.noteID }),
                      bodyPlan.operations.allSatisfy({ plannedIdentityKeys.contains($0.operationIdentity.planIdentityKey) }) else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedRetainedAdditions.append(contentsOf: bodyPlan.operations)
                expectedResultEvidence.append(bodyPlan.resultEvidence)
            case .reconstructedConflict(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.reconstructedBaseHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.reconstructedBaseBody),
                      bodyPlan.projectedPreMergeCurrentHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.projectedPreMergeCurrentBody),
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.presentationRouting == .wholeNoteFallback,
                      bodyPlan.resultEvidence.kind == .body,
                      bodyPlan.resultEvidence.noteID == notePlan.noteID,
                      bodyPlan.resultEvidence.batchID == plan.batchID,
                      bodyPlan.resultEvidence.preHash == bodyPlan.projectedPreMergeCurrentHash,
                      bodyPlan.resultEvidence.postHash == bodyPlan.finalBodyHash,
                      routing == .wholeNoteFallback,
                      bodyPlan.retainedOperationAdditions.allSatisfy({ $0.noteID == notePlan.noteID }) else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                // The deterministic union order is load-bearing: ordered identities
                // must be strictly ascending under the one canonical comparator.
                do {
                    let orderedKeys = try bodyPlan.orderedOperationIdentities.map {
                        try ValidatedCanonicalReplayKey($0.canonicalReplayKey)
                    }
                    guard zip(orderedKeys, orderedKeys.dropFirst()).allSatisfy({ $0 < $1 }) else {
                        return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                    }
                } catch {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedRetainedAdditions.append(contentsOf: bodyPlan.retainedOperationAdditions)
                expectedSnapshotAdditions.append(contentsOf: bodyPlan.snapshotAdditions)
                expectedResultEvidence.append(bodyPlan.resultEvidence)
            case .legacyPositional(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.resultEvidence.kind == .body,
                      bodyPlan.resultEvidence.noteID == notePlan.noteID,
                      bodyPlan.resultEvidence.batchID == plan.batchID,
                      bodyPlan.resultEvidence.preHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.initialBody),
                      bodyPlan.resultEvidence.postHash == bodyPlan.finalBodyHash,
                      routing == .incremental,
                      bodyPlan.operations.allSatisfy({ $0.noteID == notePlan.noteID }) else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedRetainedAdditions.append(contentsOf: bodyPlan.operations)
                expectedResultEvidence.append(bodyPlan.resultEvidence)
            case .compatibilityNoopMissingNote(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.resultEvidence.kind == .body,
                      bodyPlan.resultEvidence.noteID == notePlan.noteID,
                      bodyPlan.resultEvidence.batchID == plan.batchID,
                      bodyPlan.resultEvidence.preHash == nil,
                      bodyPlan.resultEvidence.postHash == nil,
                      routing == SyncConvergencePresentationRouting.none else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedResultEvidence.append(bodyPlan.resultEvidence)
            case nil:
                guard routing == nil else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
            }
            if let titleEffect = notePlan.titleEffect {
                do {
                    _ = try ValidatedCanonicalReplayKey(titleEffect.candidateCanonicalKey)
                    if let resultingWinningKey = titleEffect.resultingWinningKey {
                        _ = try ValidatedCanonicalReplayKey(resultingWinningKey)
                    }
                } catch {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                if titleEffect.verdict == .compatibilityNoopMissingNote,
                   titleEffect.resultingWinningKey != nil {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                if titleEffect.verdict == .ignoreOlder,
                   titleEffect.priorWinningKey == nil {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                guard titleEffect.resultEvidence.kind == .title,
                      titleEffect.resultEvidence.noteID == notePlan.noteID,
                      titleEffect.resultEvidence.batchID == plan.batchID,
                      titleEffect.resultEvidence.preHash == nil,
                      titleEffect.resultEvidence.postHash == nil else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
                expectedResultEvidence.append(titleEffect.resultEvidence)
            }
        }
        // Incorporation result-evidence rows must be exactly the rows owned by the
        // planned effects: no orphan, altered, or missing row may survive validation.
        let sortEvidence: (SyncConvergenceResultEvidence, SyncConvergenceResultEvidence) -> Bool = {
            ($0.noteID.uuidString, $0.kind.rawValue) < ($1.noteID.uuidString, $1.kind.rawValue)
        }
        guard plan.incorporationEvidence.resultEvidence.sorted(by: sortEvidence)
            == expectedResultEvidence.sorted(by: sortEvidence) else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        // History additions must be exactly the operations and snapshots the body
        // effects produced; a compatibility no-op contributes no note-state history.
        let sortByIdentity: (SyncConvergencePlannedBodyOperation, SyncConvergencePlannedBodyOperation) -> Bool = {
            $0.operationIdentity.planIdentityKey < $1.operationIdentity.planIdentityKey
        }
        guard plan.historyPlan.retainedOperationAdditions.sorted(by: sortByIdentity)
            == expectedRetainedAdditions.sorted(by: sortByIdentity) else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        let sortSnapshots: (SyncConvergenceSnapshotAddition, SyncConvergenceSnapshotAddition) -> Bool = {
            ($0.noteID.uuidString, $0.contentHash) < ($1.noteID.uuidString, $1.contentHash)
        }
        guard plan.historyPlan.snapshotAdditions.sorted(by: sortSnapshots)
            == expectedSnapshotAdditions.sorted(by: sortSnapshots) else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        // Independently recompute the projected incorporation evidence bytes from the
        // completed plan; an encoding failure or total mismatch fails closed.
        guard let recomputedEvidenceBytes = try? SyncConvergenceProjectedIncorporationEvidence(
            batch: input.incomingBatch,
            affectedNoteIDs: plannedNoteIDs,
            operationIdentities: plan.incorporationEvidence.operationIdentities,
            resultEvidence: plan.incorporationEvidence.resultEvidence
        ).canonicalEncodedByteCount(),
        recomputedEvidenceBytes == projectedFullIncorporationEvidenceBytes else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }
        return nil
    }
}

extension OperationIdentityPayload {
    var planIdentityKey: String {
        "\(batchIDLowercase)|\(operationIndex)"
    }
}

private struct PartialNotePlan {
    let noteID: UUID
    var creationEffect: SyncConvergenceCreationEffect?
    var bodyEffect: SyncConvergenceBodyEffect?
    var titleEffect: SyncConvergenceTitleEffect?

    func finalPlan() -> SyncConvergenceNotePlan {
        SyncConvergenceNotePlan(
            noteID: noteID,
            creationEffect: creationEffect,
            bodyEffect: bodyEffect,
            titleEffect: titleEffect
        )
    }
}

private enum BodyPlanningResult {
    case success(PlannedBodyResult)
    case deferred(SyncConvergenceDeferredReason)
    case failed(SyncConvergenceTransactionFailure)

    func map(_ transform: (PlannedBodyResult) -> PlannedBodyResult) -> BodyPlanningResult {
        switch self {
        case .success(let result):
            return .success(transform(result))
        case .deferred(let reason):
            return .deferred(reason)
        case .failed(let failure):
            return .failed(failure)
        }
    }
}

private struct PlannedBodyResult {
    let effect: SyncConvergenceBodyEffect
    let finalBody: String
    let operationIdentities: [OperationIdentityPayload]
    let resultEvidence: SyncConvergenceResultEvidence
    let retainedAdditions: [SyncConvergencePlannedBodyOperation]
    let snapshotAdditions: [SyncConvergenceSnapshotAddition]
    let routing: SyncConvergencePresentationRouting

    static func single(
        noteID: UUID,
        initialBody: String,
        finalBody: String,
        finalHash: String,
        operation: SyncConvergencePlannedBodyOperation
    ) -> PlannedBodyResult {
        let evidence = SyncConvergenceResultEvidence(
            batchID: UUID(uuidString: operation.operationIdentity.batchIDLowercase) ?? noteID,
            noteID: noteID,
            kind: .body,
            preHash: SyncBatchContentHash.sha256Hex(for: initialBody),
            postHash: finalHash,
            canonicalReplayKey: operation.operationIdentity.canonicalReplayKey
        )
        return PlannedBodyResult(
            effect: .legacyPositional(LegacyBodyPlan(
                noteID: noteID,
                initialBody: initialBody,
                operations: [operation],
                finalBody: finalBody,
                finalBodyHash: finalHash,
                resultEvidence: evidence
            )),
            finalBody: finalBody,
            operationIdentities: [operation.operationIdentity],
            resultEvidence: evidence,
            retainedAdditions: [operation],
            snapshotAdditions: [],
            routing: .incremental
        )
    }

    static func singleNoop(
        noteID: UUID,
        body: String,
        hash: String,
        identity: OperationIdentityPayload,
        kind: SyncConvergencePlannedBodyOperation.Kind,
        offset: Int,
        length: Int? = nil,
        text: String? = nil,
        expectedText: String? = nil,
        baseContentHash: String?
    ) -> PlannedBodyResult {
        let operation = SyncConvergencePlannedBodyOperation(
            noteID: noteID,
            kind: kind,
            utf16Offset: offset,
            utf16Length: length,
            text: text,
            expectedText: expectedText,
            baseContentHash: baseContentHash,
            resultContentHash: hash,
            operationIdentity: identity
        )
        return single(noteID: noteID, initialBody: body, finalBody: body, finalHash: hash, operation: operation)
    }
}

private enum HistoryPlanningResult {
    case success(SyncConvergenceHistoryPlan)
    case deferred(SyncConvergenceDeferredReason)
    case failed(SyncConvergenceTransactionFailure)
}

private struct SyncConvergenceBodyOperation: Equatable {
    let change: SyncBatchChange
    let identity: OperationIdentityPayload
    let resultContentHash: String?

    var identityKey: String {
        "\(identity.batchIDLowercase)|\(identity.operationIndex)"
    }

    func isEquivalentEvidence(to other: SyncConvergenceBodyOperation) -> Bool {
        change == other.change && identity == other.identity
    }

    init(change: SyncBatchChange, identity: OperationIdentityPayload, resultContentHash: String? = nil) {
        self.change = change
        self.identity = identity
        self.resultContentHash = resultContentHash
    }

    init(retained: SyncConvergenceRetainedOperation) {
        self.change = retained.syncBatchChange
        self.identity = OperationIdentityPayload(
            batchID: retained.batchID,
            originDeviceID: retained.originDeviceID,
            operationIndex: retained.operationIndex,
            operationKind: retained.operationKind.rawValue,
            canonicalReplayKey: retained.canonicalReplayKey
        )
        self.resultContentHash = retained.resultContentHash
    }
}

private extension SyncConvergenceRetainedOperation {
    var identityKey: String {
        "\(batchID.uuidString.lowercased())|\(operationIndex)"
    }

    var syncBatchChange: SyncBatchChange {
        switch operationKind {
        case .insert:
            return .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                noteID: noteID,
                utf16Offset: utf16Offset,
                text: text ?? "",
                modifiedAt: canonicalReplayKey.modifiedAt,
                baseContentHash: baseContentHash
            ))
        case .delete:
            return .noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                noteID: noteID,
                utf16Offset: utf16Offset,
                utf16Length: utf16Length ?? 0,
                expectedText: expectedText,
                modifiedAt: canonicalReplayKey.modifiedAt,
                baseContentHash: baseContentHash
            ))
        }
    }
}

private extension SyncBatch {
    var affectedNoteIDs: Set<UUID> {
        Set(changes.compactMap(\.noteID))
    }
}

private extension SyncBatchChange {
    var noteID: UUID? {
        switch self {
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

    var baseContentHash: String? {
        switch self {
        case .noteBodyTextInserted(let change):
            return change.baseContentHash
        case .noteBodyTextDeleted(let change):
            return change.baseContentHash
        default:
            return nil
        }
    }

    var operationKind: String {
        switch self {
        case .noteCreated:
            return "creation"
        case .noteTitleChanged:
            return "title"
        case .noteBodyTextInserted:
            return "insert"
        case .noteBodyTextDeleted:
            return "delete"
        case .noteBodyReconciled:
            return "reconciliation"
        }
    }

    var isBodyTextOperation: Bool {
        switch self {
        case .noteBodyTextInserted, .noteBodyTextDeleted:
            return true
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
            return false
        }
    }

    var utf16OffsetForPlanning: Int {
        switch self {
        case .noteBodyTextInserted(let change):
            return change.utf16Offset
        case .noteBodyTextDeleted(let change):
            return change.utf16Offset
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled:
            return 0
        }
    }

    var utf16LengthForPlanning: Int? {
        switch self {
        case .noteBodyTextDeleted(let change):
            return change.utf16Length
        case .noteCreated, .noteTitleChanged, .noteBodyTextInserted, .noteBodyReconciled:
            return nil
        }
    }

    var textForPlanning: String? {
        switch self {
        case .noteBodyTextInserted(let change):
            return change.text
        case .noteCreated, .noteTitleChanged, .noteBodyTextDeleted, .noteBodyReconciled:
            return nil
        }
    }

    var expectedTextForPlanning: String? {
        switch self {
        case .noteBodyTextDeleted(let change):
            return change.expectedText
        case .noteCreated, .noteTitleChanged, .noteBodyTextInserted, .noteBodyReconciled:
            return nil
        }
    }
}

private extension Array where Element == SyncBatchChange {
    var firstUnsupportedReconciliation: SyncBatchNoteBodyReconciledChange? {
        for change in self {
            if case .noteBodyReconciled(let reconciliation) = change {
                return reconciliation
            }
        }
        return nil
    }
}

extension SyncConvergenceResultEvidence {
    // Throwing by contract: these encoders are the normative persistence encoding.
    // An encoding failure must fail the plan closed, never undercharge as zero bytes.
    func canonicalEncodedByteCount() throws -> Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        try encoder.appendResultEvidence(self)
        return encoder.data.count
    }
}

struct SyncConvergenceProjectedIncorporationEvidence {
    let batch: SyncBatch
    let affectedNoteIDs: Set<UUID>
    let operationIdentities: [OperationIdentityPayload]
    let resultEvidence: [SyncConvergenceResultEvidence]

    func canonicalEncodedByteCount() throws -> Int {
        var total = try rootByteCount()
        for identity in operationIdentities {
            total += try operationIdentityByteCount(identity)
        }
        for count in try noteEffectByteCounts() {
            total += count
        }
        for evidence in resultEvidence {
            total += try evidence.canonicalEncodedByteCount()
        }
        return total
    }

    private func rootByteCount() throws -> Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        try encoder.appendProjectedIncorporationRoot(
            batch: batch,
            affectedNoteIDs: affectedNoteIDs,
            operationIdentityCount: operationIdentities.count,
            noteEffectCount: affectedNoteIDs.count,
            resultEvidenceCount: resultEvidence.count
        )
        return encoder.data.count
    }

    private func operationIdentityByteCount(_ identity: OperationIdentityPayload) throws -> Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        try encoder.appendOperationIdentity(identity)
        return encoder.data.count
    }

    private func noteEffectByteCounts() throws -> [Int] {
        try affectedNoteIDs.map { noteID in
            var encoder = CanonicalPayloadDigestFormatV1()
            let kinds = resultEvidence
                .filter { $0.noteID == noteID }
                .map(\.kind.rawValue)
            try encoder.appendProjectedNoteEffect(batchID: batch.id, noteID: noteID, kinds: kinds)
            return encoder.data.count
        }
    }
}

extension SyncConvergencePlannedBodyOperation {
    func canonicalEncodedByteCount() throws -> Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        try encoder.appendPlannedOperation(self)
        return encoder.data.count
    }
}

private extension Array where Element == OperationIdentityPayload {
    func uniquedByIdentityKey() -> [OperationIdentityPayload] {
        var seen: Set<String> = []
        return filter { identity in
            let key = "\(identity.batchIDLowercase)|\(identity.operationIndex)"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private extension SyncConvergenceCleanupPlan {
    func merging(_ other: SyncConvergenceCleanupPlan) -> SyncConvergenceCleanupPlan {
        SyncConvergenceCleanupPlan(
            batchIDs: batchIDs.union(other.batchIDs),
            retryQueueCleanup: retryQueueCleanup || other.retryQueueCleanup,
            retryLegacyCleanup: retryLegacyCleanup || other.retryLegacyCleanup,
            retryPresentationRefresh: retryPresentationRefresh || other.retryPresentationRefresh
        )
    }
}
