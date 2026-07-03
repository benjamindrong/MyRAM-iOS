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
        let incomingAffectedNoteIDs = Set(input.incomingBatch.changes.compactMap(\.noteID))
        let eligibleQueuedBatches = SyncConvergenceEvidenceSelector().selectEligibleQueuedBatches(
            input.queuedBatches,
            blockedNoteIDs: incomingAffectedNoteIDs
        )
        let plannerVisibleQueuedBatches = eligibleQueuedBatches + input.queuedBatches.filter {
            !$0.batch.affectedNoteIDs.isDisjoint(with: incomingAffectedNoteIDs)
        }

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
                    eligibleQueuedBatches: plannerVisibleQueuedBatches
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

        let historyResult = SyncConvergenceHistoryPolicy().plan(
            affectedNoteIDs: Set(notePlans.keys),
            currentStates: input.historyStates,
            retainedOperationAdditions: retainedAdditions,
            snapshotAdditions: snapshotAdditions,
            fullIncorporationEvidenceBytes: resultEvidence.reduce(0) { $0 + $1.canonicalEncodedByteCount }
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
            return SyncConvergencePlanValidator().validate(plan) ?? .planned(plan)
        case .deferred(let reason):
            return .deferred(reason)
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
            verdict: .ignoreOlder,
            resultingTitle: "",
            resultingWinningKey: identity.canonicalReplayKey,
            resultEvidence: evidence
        )
    }

    private func planBodyChanges(
        _ indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        noteID: UUID,
        current: SyncConvergenceProjectedNote?,
        input: SyncConvergencePlanningInput,
        eligibleQueuedBatches: [SyncConvergenceQueuedBatch]
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
        var operationIdentities: [OperationIdentityPayload] = []
        var retainedAdditions: [SyncConvergencePlannedBodyOperation] = []
        var snapshotAdditions: [SyncConvergenceSnapshotAddition] = []
        var orderedReconstructedIdentities: [OperationIdentityPayload] = []
        var reconstructedBaseBody: String?
        var reconstructedBaseHash: String?
        var reconstructedPreMergeBody: String?
        var reconstructedPreMergeHash: String?
        var sawReconstructed = false
        var sawLegacy = false

        for indexedChange in indexedChanges {
            let result = planBodyChange(
                indexedChange.change,
                operationIndex: indexedChange.operationIndex,
                current: workingNote,
                input: input,
                eligibleQueuedBatches: eligibleQueuedBatches
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
                operationIdentities.append(contentsOf: planned.operationIdentities)
                retainedAdditions.append(contentsOf: planned.retainedAdditions)
                snapshotAdditions.append(contentsOf: planned.snapshotAdditions)
                if case .reconstructedConflict(let bodyPlan) = planned.effect {
                    sawReconstructed = true
                    reconstructedBaseBody = reconstructedBaseBody ?? bodyPlan.reconstructedBaseBody
                    reconstructedBaseHash = reconstructedBaseHash ?? bodyPlan.reconstructedBaseHash
                    reconstructedPreMergeBody = reconstructedPreMergeBody ?? bodyPlan.projectedPreMergeCurrentBody
                    reconstructedPreMergeHash = reconstructedPreMergeHash ?? bodyPlan.projectedPreMergeCurrentHash
                    orderedReconstructedIdentities.append(contentsOf: bodyPlan.orderedOperationIdentities)
                }
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
        let evidence = SyncConvergenceResultEvidence(
            batchID: input.incomingBatch.id,
            noteID: noteID,
            kind: .body,
            preHash: initialHash,
            postHash: finalHash,
            canonicalReplayKey: operationIdentities.last?.canonicalReplayKey
        )
        let uniqueIdentities = operationIdentities.uniquedByIdentityKey()
        let routing: SyncConvergencePresentationRouting = sawReconstructed ? .wholeNoteFallback : .incremental
        let effect: SyncConvergenceBodyEffect
        if sawReconstructed {
            effect = .reconstructedConflict(ReconstructedConflictBodyPlan(
                noteID: noteID,
                reconstructedBaseBody: reconstructedBaseBody ?? initialBody,
                reconstructedBaseHash: reconstructedBaseHash ?? initialHash,
                projectedPreMergeCurrentBody: reconstructedPreMergeBody ?? initialBody,
                projectedPreMergeCurrentHash: reconstructedPreMergeHash ?? initialHash,
                orderedOperationIdentities: (orderedReconstructedIdentities + uniqueIdentities).uniquedByIdentityKey(),
                finalBody: workingNote.body,
                finalBodyHash: finalHash,
                retainedOperationAdditions: retainedAdditions,
                snapshotAdditions: snapshotAdditions,
                resultEvidence: evidence,
                presentationRouting: .wholeNoteFallback
            ))
        } else if sawLegacy {
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
            operationIdentities: uniqueIdentities,
            resultEvidence: evidence,
            retainedAdditions: retainedAdditions,
            snapshotAdditions: snapshotAdditions,
            routing: routing
        ))
    }

    private func unknownLegacyBodyNoop(
        _ indexedChanges: [(operationIndex: Int, change: SyncBatchChange)],
        noteID: UUID,
        batchID: UUID,
        input: SyncConvergencePlanningInput
    ) -> BodyPlanningResult {
        let emptyHash = SyncBatchContentHash.sha256Hex(for: "")
        let operations = indexedChanges.map { indexedChange in
            let identity = operationIdentity(
                for: indexedChange.change,
                in: input.incomingBatch,
                operationIndex: indexedChange.operationIndex,
                kind: indexedChange.change.operationKind
            )
            return SyncConvergencePlannedBodyOperation(
                noteID: noteID,
                kind: indexedChange.change.operationKind == "delete" ? .delete : .insert,
                utf16Offset: indexedChange.change.utf16OffsetForPlanning,
                utf16Length: indexedChange.change.utf16LengthForPlanning,
                text: indexedChange.change.textForPlanning,
                expectedText: indexedChange.change.expectedTextForPlanning,
                baseContentHash: nil,
                resultContentHash: emptyHash,
                operationIdentity: identity
            )
        }
        let identities = operations.map(\.operationIdentity)
        let evidence = SyncConvergenceResultEvidence(
            batchID: batchID,
            noteID: noteID,
            kind: .body,
            preHash: emptyHash,
            postHash: emptyHash,
            canonicalReplayKey: identities.last?.canonicalReplayKey
        )
        return .success(PlannedBodyResult(
            effect: .legacyPositional(LegacyBodyPlan(
                noteID: noteID,
                initialBody: "",
                operations: operations,
                finalBody: "",
                finalBodyHash: emptyHash,
                resultEvidence: evidence
            )),
            finalBody: "",
            operationIdentities: identities,
            resultEvidence: evidence,
            retainedAdditions: operations,
            snapshotAdditions: [],
            routing: .none
        ))
    }

    private func planBodyChange(
        _ change: SyncBatchChange,
        operationIndex: Int,
        current: SyncConvergenceProjectedNote,
        input: SyncConvergencePlanningInput,
        eligibleQueuedBatches: [SyncConvergenceQueuedBatch] = []
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
        guard let requiredBaseHash = baseHash else {
            return .failed(.invalidMergePlan(noteID: current.noteID))
        }

        let reconstruction = SyncBaseReconstructor().reconstruct(
            noteID: current.noteID,
            requiredBaseHash: requiredBaseHash,
            snapshots: input.retainedSnapshots,
            retainedOperations: input.retainedLocalOperations + input.retainedRemoteOperations
        )
        switch reconstruction {
        case .exactSnapshot(let base), .reconstructed(let base):
            let currentOperation = SyncConvergenceBodyOperation(change: change, identity: identity)
            let queuedOperations = queuedBodyOperations(
                from: eligibleQueuedBatches,
                noteID: current.noteID
            )
            let union = SyncOperationUnionBuilder().build(
                retained: input.retainedLocalOperations + input.retainedRemoteOperations,
                current: queuedOperations + [currentOperation],
                noteID: current.noteID,
                excludingIdentityKeys: base.consumedOperationIdentityKeys
            )
            switch union {
            case .success(let operations):
                return replayEngine.planReconstructed(
                    operations: operations,
                    base: base,
                    projectedCurrent: current,
                    batchID: input.incomingBatch.id
                )
            case .failure(let failure):
                return .failed(failure)
            }
        case .unavailable:
            return .deferred(.unreconstructableBase(
                noteID: current.noteID,
                batchID: input.incomingBatch.id,
                baseContentHash: requiredBaseHash
            ))
        case .failed(let failure):
            return .failed(failure)
        }
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
                if let expected = operation.resultContentHash, expected != SyncBatchContentHash.sha256Hex(for: body) {
                    return .failed(.corruptHistory(noteID: projectedCurrent.noteID))
                }
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

        let replayEngine = SyncOperationReplayEngine()
        let candidates = noteSnapshots.sorted { $0.generation > $1.generation }
        for snapshot in candidates {
            var body = snapshot.body
            var generation = snapshot.generation
            var consumedOperationIdentityKeys: Set<String> = []
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
            for retained in chain {
                guard retained.baseContentHash == SyncBatchContentHash.sha256Hex(for: body) else {
                    continue
                }
                let change = retained.syncBatchChange
                let identity = OperationIdentityPayload(
                    batchID: retained.batchID,
                    originDeviceID: retained.originDeviceID,
                    operationIndex: retained.operationIndex,
                    operationKind: retained.operationKind.rawValue,
                    canonicalReplayKey: retained.canonicalReplayKey
                )
                switch replayEngine.planDeclaredChainStep(
                    change,
                    identity: identity,
                    current: SyncConvergenceProjectedNote(
                        noteID: noteID,
                        folderID: nil,
                        title: "",
                        body: body,
                        createdAt: .distantPast,
                        modifiedAt: retained.canonicalReplayKey.modifiedAt
                    ),
                    batchID: retained.batchID
                ) {
                case .success(let result):
                    body = result.finalBody
                    generation += 1
                    if let expected = retained.resultContentHash,
                       expected != SyncBatchContentHash.sha256Hex(for: body) {
                        return .failed(.corruptHistory(noteID: noteID))
                    }
                    if SyncBatchContentHash.sha256Hex(for: body) == requiredBaseHash {
                        consumedOperationIdentityKeys.insert(retained.identityKey)
                        return .reconstructed(ReconstructedBase(
                            body: body,
                            contentHash: requiredBaseHash,
                            generation: generation,
                            consumedOperationIdentityKeys: consumedOperationIdentityKeys
                        ))
                    }
                    consumedOperationIdentityKeys.insert(retained.identityKey)
                case .deferred:
                    return .unavailable
                case .failed(let failure):
                    return .failed(failure)
                }
            }
        }
        return .unavailable
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
            if let existing = operations[key], existing != operation {
                return .failure(.inconsistentIncorporationState(noteID: noteID))
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
            let projectedOperationBytes = current.retainedOperationBytes + addedOperations.reduce(0) { $0 + $1.canonicalEncodedByteCount }
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

private struct SyncConvergencePlanValidator {
    func validate(_ plan: SyncConvergenceBatchPlan) -> SyncConvergencePlanningOutcome? {
        guard !plan.batchID.uuidString.isEmpty,
              !plan.originDeviceID.uuidString.isEmpty,
              plan.canonicalPayloadDigest.count == 64,
              plan.canonicalPayloadDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              plan.canonicalPayloadDigestFormatVersion == SyncConvergenceCanonicalBatchDigest.supportedFormatVersion else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        var seenIdentities: Set<String> = []
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
            seenIdentities.insert(key)
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

        for notePlan in plan.affectedNotePlans {
            guard notePlan.creationEffect != nil || notePlan.bodyEffect != nil || notePlan.titleEffect != nil else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
            }
            switch notePlan.bodyEffect {
            case .matchingBaseIncremental(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.initialBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.initialBody),
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.resultEvidence.kind == .body else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
            case .reconstructedConflict(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.reconstructedBaseHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.reconstructedBaseBody),
                      bodyPlan.projectedPreMergeCurrentHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.projectedPreMergeCurrentBody),
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.presentationRouting == .wholeNoteFallback,
                      bodyPlan.resultEvidence.kind == .body else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
            case .legacyPositional(let bodyPlan):
                guard bodyPlan.noteID == notePlan.noteID,
                      bodyPlan.finalBodyHash == SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody),
                      bodyPlan.resultEvidence.kind == .body else {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
            case nil:
                break
            }
            if let titleEffect = notePlan.titleEffect {
                do {
                    _ = try ValidatedCanonicalReplayKey(titleEffect.candidateCanonicalKey)
                    _ = try ValidatedCanonicalReplayKey(titleEffect.resultingWinningKey)
                } catch {
                    return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
                }
            }
        }
        return nil
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
}

private struct SyncConvergenceBodyOperation: Equatable {
    let change: SyncBatchChange
    let identity: OperationIdentityPayload
    let resultContentHash: String?

    var identityKey: String {
        "\(identity.batchIDLowercase)|\(identity.operationIndex)"
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

private extension SyncConvergenceResultEvidence {
    var canonicalEncodedByteCount: Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        do {
            try encoder.appendResultEvidence(self)
            return encoder.data.count
        } catch {
            return 0
        }
    }
}

private extension SyncConvergencePlannedBodyOperation {
    var canonicalEncodedByteCount: Int {
        var encoder = CanonicalPayloadDigestFormatV1()
        do {
            try encoder.appendPlannedOperation(self)
            return encoder.data.count
        } catch {
            return 0
        }
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
