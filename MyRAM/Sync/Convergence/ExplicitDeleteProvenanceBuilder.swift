import Foundation

struct ExplicitDeleteProvenanceBuilder {
    func build(
        graph: RetainedOperationCausalGraph,
        node: ValidatedRetainedOperationNode,
        preDeleteBody: String
    ) -> ExplicitDeleteProvenanceBuildResult {
        guard graph.nodes.contains(where: { $0.identity == node.identity && $0 == node }) else {
            return .recoveryRequired(.nodeAbsentFromGraph)
        }
        guard node.operation.operationKind == .delete else {
            return .recoveryRequired(.operationIsNotDelete)
        }
        guard node.operation.batchID == node.identity.batchID,
              node.operation.operationIndex == node.identity.operationIndex,
              node.operation.canonicalReplayKey == node.replayKey.payload,
              node.operation.canonicalReplayKey.batchIDLowercase == node.identity.batchID.uuidString.lowercased(),
              node.operation.canonicalReplayKey.operationIndex == node.identity.operationIndex
        else {
            return .recoveryRequired(.invalidOperationIdentity)
        }
        guard node.operation.canonicalReplayKey == node.replayKey.payload else {
            return .recoveryRequired(.invalidReplayKey)
        }
        guard let expectedText = node.operation.expectedText,
              let utf16Length = node.operation.utf16Length,
              utf16Length > 0,
              utf16Length == expectedText.utf16.count
        else {
            return .recoveryRequired(.missingDeletePayload)
        }
        guard node.operation.baseContentHash == node.baseContentHash,
              node.operation.resultContentHash == node.resultContentHash
        else {
            return .recoveryRequired(.baseHashMismatch)
        }
        guard SyncBatchContentHash.sha256Hex(for: preDeleteBody) == node.baseContentHash else {
            return .recoveryRequired(.baseHashMismatch)
        }
        guard let deletedRange = preDeleteBody.stringRange(
            utf16Offset: node.operation.utf16Offset,
            utf16Length: utf16Length
        ) else {
            return .recoveryRequired(.invalidUTF16Range)
        }
        guard String(preDeleteBody[deletedRange]) == expectedText else {
            return .recoveryRequired(.deletedTextMismatch)
        }

        var resultBody = preDeleteBody
        resultBody.removeSubrange(deletedRange)
        guard SyncBatchContentHash.sha256Hex(for: resultBody) == node.resultContentHash else {
            return .recoveryRequired(.resultHashMismatch)
        }

        let descriptor = ExplicitDeleteOccurrenceDescriptor(
            deletedText: expectedText,
            leftContext: preDeleteBody.leftContext(before: deletedRange.lowerBound),
            rightContext: preDeleteBody.rightContext(after: deletedRange.upperBound)
        )
        let occurrences = ExplicitDeleteOccurrenceEnumerator.fullOccurrences(
            in: preDeleteBody,
            descriptor: descriptor
        )
        guard let ordinal = occurrences.firstIndex(where: { $0.utf16Range.lowerBound == node.operation.utf16Offset }) else {
            return .recoveryRequired(.occurrenceNotFound)
        }

        let createdAt = node.operation.modifiedAt
        let createdAtBitPattern = SyncConvergenceDateBits.bitPattern(for: createdAt)
        let draft = ExplicitDeleteProvenanceRecord(
            formatVersion: ExplicitDeleteProvenanceConstants.formatVersion,
            tier: .full,
            noteID: node.operation.noteID,
            batchID: node.identity.batchID,
            operationIndex: node.identity.operationIndex,
            originDeviceID: node.operation.originDeviceID,
            canonicalReplayKey: node.replayKey.payload,
            baseContentHash: node.baseContentHash,
            resultContentHash: node.resultContentHash,
            deletedText: expectedText,
            deletedTextDigest: ExplicitDeleteProvenanceDigest.canonicalDigest(for: expectedText),
            deletedUTF16Length: utf16Length,
            leftContext: descriptor.leftContext,
            leftContextDigest: ExplicitDeleteProvenanceDigest.canonicalDigest(for: descriptor.leftContext),
            leftContextUTF16Length: descriptor.leftContext.utf16.count,
            rightContext: descriptor.rightContext,
            rightContextDigest: ExplicitDeleteProvenanceDigest.canonicalDigest(for: descriptor.rightContext),
            rightContextUTF16Length: descriptor.rightContext.utf16.count,
            originalUTF16Offset: node.operation.utf16Offset,
            occurrenceOrdinal: ordinal,
            createdAt: createdAt,
            createdAtBitPattern: createdAtBitPattern,
            payloadByteCount: 0,
            baseSnapshotGeneration: nil
        )

        do {
            return .record(try draft.withCanonicalPayloadByteCount())
        } catch {
            return .recoveryRequired(.corruptPersistedProvenance)
        }
    }
}

struct ExplicitDeleteProvenanceCompactor {
    func compact(
        record: ExplicitDeleteProvenanceRecord,
        baseSnapshot: SyncConvergenceSnapshotRecord?
    ) -> ExplicitDeleteProvenanceCompactionResult {
        guard record.tier == .full else {
            return .compacted(record)
        }
        guard let baseSnapshot else {
            return .retainedFull(.missingSnapshot)
        }
        guard baseSnapshot.noteID == record.noteID,
              baseSnapshot.contentHash == record.baseContentHash,
              SyncBatchContentHash.sha256Hex(for: baseSnapshot.body) == record.baseContentHash
        else {
            return .retainedFull(.snapshotHashMismatch)
        }
        switch ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: baseSnapshot.body) {
        case .valid:
            let compactedDraft = record.compacted(snapshotGeneration: baseSnapshot.generation)
            do {
                let compacted = try compactedDraft.withCanonicalPayloadByteCount()
                switch ExplicitDeleteProvenanceValidator().validate(record: compacted, candidateBaseBody: baseSnapshot.body) {
                case .valid:
                    return .compacted(compacted)
                case .recoveryRequired(let failure):
                    return .recoveryRequired(failure)
                }
            } catch {
                return .recoveryRequired(.corruptPersistedProvenance)
            }
        case .recoveryRequired(let failure):
            return .recoveryRequired(failure)
        }
    }
}

extension ExplicitDeleteProvenanceRecord {
    func withPayloadByteCount(_ payloadByteCount: Int) -> Self {
        Self(
            formatVersion: formatVersion,
            tier: tier,
            noteID: noteID,
            batchID: batchID,
            operationIndex: operationIndex,
            originDeviceID: originDeviceID,
            canonicalReplayKey: canonicalReplayKey,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            deletedText: deletedText,
            deletedTextDigest: deletedTextDigest,
            deletedUTF16Length: deletedUTF16Length,
            leftContext: leftContext,
            leftContextDigest: leftContextDigest,
            leftContextUTF16Length: leftContextUTF16Length,
            rightContext: rightContext,
            rightContextDigest: rightContextDigest,
            rightContextUTF16Length: rightContextUTF16Length,
            originalUTF16Offset: originalUTF16Offset,
            occurrenceOrdinal: occurrenceOrdinal,
            createdAt: createdAt,
            createdAtBitPattern: createdAtBitPattern,
            payloadByteCount: payloadByteCount,
            baseSnapshotGeneration: baseSnapshotGeneration
        )
    }

    func withCanonicalPayloadByteCount() throws -> Self {
        var candidate = withPayloadByteCount(0)
        while true {
            let byteCount = try candidate.canonicalPayloadData().count
            let updated = candidate.withPayloadByteCount(byteCount)
            if updated.payloadByteCount == candidate.payloadByteCount {
                return updated
            }
            candidate = updated
        }
    }

    func compacted(snapshotGeneration: Int) -> Self {
        Self(
            formatVersion: formatVersion,
            tier: .compacted,
            noteID: noteID,
            batchID: batchID,
            operationIndex: operationIndex,
            originDeviceID: originDeviceID,
            canonicalReplayKey: canonicalReplayKey,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            deletedText: nil,
            deletedTextDigest: deletedTextDigest,
            deletedUTF16Length: deletedUTF16Length,
            leftContext: nil,
            leftContextDigest: leftContextDigest,
            leftContextUTF16Length: leftContextUTF16Length,
            rightContext: nil,
            rightContextDigest: rightContextDigest,
            rightContextUTF16Length: rightContextUTF16Length,
            originalUTF16Offset: originalUTF16Offset,
            occurrenceOrdinal: occurrenceOrdinal,
            createdAt: createdAt,
            createdAtBitPattern: createdAtBitPattern,
            payloadByteCount: 0,
            baseSnapshotGeneration: snapshotGeneration
        )
    }
}

struct ExplicitDeleteOccurrenceDescriptor: Equatable {
    let deletedText: String
    let leftContext: String
    let rightContext: String
}

struct ExplicitDeleteOccurrence: Equatable {
    let utf16Range: Range<Int>
    let deletedText: String
    let leftContext: String
    let rightContext: String
}

enum ExplicitDeleteOccurrenceEnumerator {
    static func fullOccurrences(
        in body: String,
        descriptor: ExplicitDeleteOccurrenceDescriptor
    ) -> [ExplicitDeleteOccurrence] {
        matchingTextOccurrences(in: body, deletedText: descriptor.deletedText).filter {
            $0.leftContext == descriptor.leftContext && $0.rightContext == descriptor.rightContext
        }
    }

    static func compactedOccurrences(
        in body: String,
        deletedUTF16Length: Int,
        leftContextUTF16Length: Int,
        rightContextUTF16Length: Int,
        deletedTextDigest: String,
        leftContextDigest: String,
        rightContextDigest: String
    ) -> [ExplicitDeleteOccurrence] {
        guard deletedUTF16Length > 0,
              leftContextUTF16Length >= 0,
              rightContextUTF16Length >= 0
        else {
            return []
        }

        let totalUTF16Length = body.utf16.count
        var occurrences: [ExplicitDeleteOccurrence] = []
        var start = body.startIndex
        while start <= body.endIndex {
            let lowerOffset = body.utf16Offset(of: start)
            guard lowerOffset + deletedUTF16Length <= totalUTF16Length else {
                break
            }
            defer {
                if start < body.endIndex {
                    start = body.index(after: start)
                } else {
                    start = body.endIndex
                }
            }

            guard min(ExplicitDeleteProvenanceConstants.contextUTF16CodeUnits, lowerOffset) == leftContextUTF16Length,
                  min(
                    ExplicitDeleteProvenanceConstants.contextUTF16CodeUnits,
                    totalUTF16Length - lowerOffset - deletedUTF16Length
                  ) == rightContextUTF16Length,
                  let range = body.stringRange(
                    utf16Offset: lowerOffset,
                    utf16Length: deletedUTF16Length
                  )
            else {
                continue
            }

            let deletedText = String(body[range])
            let left = body.leftContext(before: range.lowerBound)
            let right = body.rightContext(after: range.upperBound)
            guard ExplicitDeleteProvenanceDigest.canonicalDigest(for: deletedText) == deletedTextDigest,
                  ExplicitDeleteProvenanceDigest.canonicalDigest(for: left) == leftContextDigest,
                  ExplicitDeleteProvenanceDigest.canonicalDigest(for: right) == rightContextDigest
            else {
                continue
            }

            occurrences.append(ExplicitDeleteOccurrence(
                utf16Range: lowerOffset..<(lowerOffset + deletedUTF16Length),
                deletedText: deletedText,
                leftContext: left,
                rightContext: right
            ))
        }
        return occurrences
    }

    static func matchingTextOccurrences(in body: String, deletedText: String) -> [ExplicitDeleteOccurrence] {
        guard !deletedText.isEmpty else { return [] }
        var occurrences: [ExplicitDeleteOccurrence] = []
        var searchStart = body.startIndex
        while searchStart < body.endIndex,
              let range = body.range(of: deletedText, range: searchStart..<body.endIndex) {
            let lowerOffset = body.utf16Offset(of: range.lowerBound)
            let upperOffset = body.utf16Offset(of: range.upperBound)
            occurrences.append(ExplicitDeleteOccurrence(
                utf16Range: lowerOffset..<upperOffset,
                deletedText: String(body[range]),
                leftContext: body.leftContext(before: range.lowerBound),
                rightContext: body.rightContext(after: range.upperBound)
            ))
            searchStart = body.index(after: range.lowerBound)
        }
        return occurrences
    }
}

extension String {
    func stringRange(utf16Offset: Int, utf16Length: Int) -> Range<String.Index>? {
        guard utf16Offset >= 0,
              utf16Length >= 0,
              utf16Offset <= utf16.count,
              utf16Offset + utf16Length <= utf16.count,
              let utf16Start = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex),
              let utf16End = utf16.index(utf16Start, offsetBy: utf16Length, limitedBy: utf16.endIndex),
              let start = String.Index(utf16Start, within: self),
              let end = String.Index(utf16End, within: self)
        else {
            return nil
        }
        return start..<end
    }

    func leftContext(before index: String.Index) -> String {
        let utf16Index = index.samePosition(in: utf16)!
        let available = utf16.distance(from: utf16.startIndex, to: utf16Index)
        var lower = utf16.index(
            utf16Index,
            offsetBy: -min(ExplicitDeleteProvenanceConstants.contextUTF16CodeUnits, available)
        )
        while String.Index(lower, within: self) == nil && lower < utf16Index {
            lower = utf16.index(after: lower)
        }
        let start = String.Index(lower, within: self)!
        return String(self[start..<index])
    }

    func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index.samePosition(in: utf16)!)
    }

    func rightContext(after index: String.Index) -> String {
        let utf16Index = index.samePosition(in: utf16)!
        let remaining = utf16.distance(from: utf16Index, to: utf16.endIndex)
        var upper = utf16.index(
            utf16Index,
            offsetBy: min(ExplicitDeleteProvenanceConstants.contextUTF16CodeUnits, remaining)
        )
        while String.Index(upper, within: self) == nil && upper > utf16Index {
            upper = utf16.index(before: upper)
        }
        let end = String.Index(upper, within: self)!
        return String(self[index..<end])
    }
}
