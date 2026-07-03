import Foundation

struct SyncConvergencePlanner {
    func evidenceRequest(for batch: SyncBatch) -> SyncConvergenceEvidenceRequest {
        SyncConvergenceEvidenceSelector().request(for: batch)
    }

    func plan(input: SyncConvergencePlanningInput) -> SyncConvergencePlanningOutcome {
        let digest = SyncConvergenceCanonicalBatchDigest.digest(for: input.incomingBatch)
        if let duplicateOutcome = classifyDuplicate(input: input, digest: digest) {
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
                guard let current = noteStates[titleChange.noteID] else {
                    return .deferred(.unreconstructableBase(
                        noteID: titleChange.noteID,
                        batchID: input.incomingBatch.id,
                        baseContentHash: ""
                    ))
                }
                let candidateIdentity = operationIdentity(
                    for: change,
                    in: input.incomingBatch,
                    operationIndex: operationIndex,
                    kind: "title"
                )
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
                guard let current = noteStates[noteID] else {
                    return .deferred(.unreconstructableBase(noteID: noteID, batchID: input.incomingBatch.id, baseContentHash: ""))
                }
                let bodyResult = planBodyChange(
                    change,
                    operationIndex: operationIndex,
                    current: current,
                    input: input
                )
                switch bodyResult {
                case .success(let planned):
                    noteStates[noteID] = SyncConvergenceProjectedNote(
                        noteID: current.noteID,
                        folderID: current.folderID,
                        title: current.title,
                        body: planned.finalBody,
                        createdAt: current.createdAt,
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
            fullIncorporationEvidenceBytes: resultEvidence.reduce(0) { $0 + $1.estimatedByteCount }
        )
        switch historyResult {
        case .success(let historyPlan):
            let plan = SyncConvergenceBatchPlan(
                batchID: input.incomingBatch.id,
                originDeviceID: input.incomingBatch.originDeviceID,
                canonicalPayloadDigest: digest,
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
        input: SyncConvergencePlanningInput,
        digest: String
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
            guard record.canonicalPayloadDigest == digest else {
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
    private func planBodyChange(
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
            let union = SyncOperationUnionBuilder().build(
                retained: input.retainedLocalOperations + input.retainedRemoteOperations,
                current: [currentOperation],
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

    static func digest(for batch: SyncBatch) -> String {
        let payload = CanonicalPayload(batch: batch)
        let data = (try? SyncConvergenceStableEncoding.encode(payload)) ?? Data()
        return SyncBatchContentHash.sha256Hex(for: String(decoding: data, as: UTF8.self))
    }

    private struct CanonicalPayload: Encodable {
        let id: String
        let originDeviceID: String
        let createdAtBitPattern: UInt64
        let batchSequence: UInt64?
        let changes: [CanonicalChange]

        init(batch: SyncBatch) {
            self.id = batch.id.uuidString.lowercased()
            self.originDeviceID = batch.originDeviceID.uuidString.lowercased()
            self.createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: batch.createdAt)
            self.batchSequence = batch.batchSequence
            self.changes = batch.changes.enumerated().map { CanonicalChange(index: $0.offset, change: $0.element) }
        }
    }

    private struct CanonicalChange: Encodable {
        let index: Int
        let kind: String
        let noteID: String
        let title: String?
        let body: String?
        let folderID: String?
        let utf16Offset: Int?
        let utf16Length: Int?
        let text: String?
        let expectedText: String?
        let baseContentHash: String?
        let replacementContentHash: String?
        let modifiedAtBitPattern: UInt64
        let createdAtBitPattern: UInt64?

        init(index: Int, change: SyncBatchChange) {
            self.index = index
            switch change {
            case .noteCreated(let created):
                kind = "noteCreated"
                noteID = created.noteID.uuidString.lowercased()
                title = created.title
                body = created.body
                folderID = created.folderID?.uuidString.lowercased()
                utf16Offset = nil
                utf16Length = nil
                text = nil
                expectedText = nil
                baseContentHash = nil
                replacementContentHash = nil
                modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: created.modifiedAt)
                createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: created.createdAt)
            case .noteTitleChanged(let titleChange):
                kind = "noteTitleChanged"
                noteID = titleChange.noteID.uuidString.lowercased()
                title = titleChange.title
                body = nil
                folderID = nil
                utf16Offset = nil
                utf16Length = nil
                text = nil
                expectedText = nil
                baseContentHash = nil
                replacementContentHash = nil
                modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: titleChange.modifiedAt)
                createdAtBitPattern = nil
            case .noteBodyTextInserted(let insert):
                kind = "noteBodyTextInserted"
                noteID = insert.noteID.uuidString.lowercased()
                title = nil
                body = nil
                folderID = nil
                utf16Offset = insert.utf16Offset
                utf16Length = nil
                text = insert.text
                expectedText = nil
                baseContentHash = insert.baseContentHash
                replacementContentHash = nil
                modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: insert.modifiedAt)
                createdAtBitPattern = nil
            case .noteBodyTextDeleted(let delete):
                kind = "noteBodyTextDeleted"
                noteID = delete.noteID.uuidString.lowercased()
                title = nil
                body = nil
                folderID = nil
                utf16Offset = delete.utf16Offset
                utf16Length = delete.utf16Length
                text = nil
                expectedText = delete.expectedText
                baseContentHash = delete.baseContentHash
                replacementContentHash = nil
                modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: delete.modifiedAt)
                createdAtBitPattern = nil
            case .noteBodyReconciled(let reconciliation):
                kind = "noteBodyReconciled"
                noteID = reconciliation.noteID.uuidString.lowercased()
                title = nil
                body = reconciliation.replacementBody
                folderID = nil
                utf16Offset = nil
                utf16Length = nil
                text = nil
                expectedText = nil
                baseContentHash = nil
                replacementContentHash = reconciliation.replacementContentHash
                modifiedAtBitPattern = SyncConvergenceDateBits.bitPattern(for: reconciliation.modifiedAt)
                createdAtBitPattern = nil
            }
        }
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
        replaySingle(change, identity: identity, body: current.body, noteID: current.noteID, authoritative: false).map { replay in
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
        replaySingle(change, identity: identity, body: current.body, noteID: current.noteID, authoritative: false).map { replay in
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
                authoritative: true
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
        authoritative: Bool
    ) -> BodyPlanningResult {
        switch change {
        case .noteBodyTextInserted(let insert):
            if authoritative, let baseContentHash = insert.baseContentHash,
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
            if authoritative, let baseContentHash = delete.baseContentHash,
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
                if authoritative {
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
                if authoritative {
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
            let chain = retainedOperations
                .filter { $0.noteID == noteID }
                .sorted(by: compareRetainedOperations)
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
                switch replayEngine.planMatchingBase(
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

    private func compareRetainedOperations(
        _ lhs: SyncConvergenceRetainedOperation,
        _ rhs: SyncConvergenceRetainedOperation
    ) -> Bool {
        do {
            return try ValidatedCanonicalReplayKey(lhs.canonicalReplayKey) <
                ValidatedCanonicalReplayKey(rhs.canonicalReplayKey)
        } catch {
            return lhs.operationIndex < rhs.operationIndex
        }
    }
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
        return .success(operations.values.sorted { lhs, rhs in
            do {
                return try ValidatedCanonicalReplayKey(lhs.identity.canonicalReplayKey) <
                    ValidatedCanonicalReplayKey(rhs.identity.canonicalReplayKey)
            } catch {
                return lhs.identity.operationIndex < rhs.identity.operationIndex
            }
        })
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
            let projectedOperationBytes = current.retainedOperationBytes + addedOperations.reduce(0) { $0 + $1.estimatedByteCount }
            let projectedFullEvidenceBytes = current.fullIncorporationEvidenceBytes + fullIncorporationEvidenceBytes

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
              plan.canonicalPayloadDigestFormatVersion == SyncConvergenceCanonicalBatchDigest.supportedFormatVersion else {
            return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
        }

        var seenIdentities: Set<String> = []
        for identity in plan.incorporationEvidence.operationIdentities {
            let key = "\(identity.batchIDLowercase)|\(identity.operationIndex)"
            guard !seenIdentities.contains(key) else {
                return .failedBeforeCommit(.invalidMergePlan(noteID: nil))
            }
            seenIdentities.insert(key)
        }

        for notePlan in plan.affectedNotePlans {
            if case .matchingBaseIncremental(let bodyPlan) = notePlan.bodyEffect,
               bodyPlan.finalBodyHash != SyncBatchContentHash.sha256Hex(for: bodyPlan.finalBody) {
                return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
            }
            if case .reconstructedConflict(let bodyPlan) = notePlan.bodyEffect,
               bodyPlan.reconstructedBaseHash != SyncBatchContentHash.sha256Hex(for: bodyPlan.reconstructedBaseBody) {
                return .failedBeforeCommit(.invalidMergePlan(noteID: notePlan.noteID))
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
    var estimatedByteCount: Int {
        kind.rawValue.utf8.count + (preHash?.utf8.count ?? 0) + (postHash?.utf8.count ?? 0) + 64
    }
}

private extension SyncConvergencePlannedBodyOperation {
    var estimatedByteCount: Int {
        (text?.utf8.count ?? 0) + (expectedText?.utf8.count ?? 0) + (baseContentHash?.utf8.count ?? 0) + 64
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
