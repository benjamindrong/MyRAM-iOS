import Foundation

struct ExplicitDeleteProvenanceValidator {
    func validate(
        record: ExplicitDeleteProvenanceRecord,
        graph: RetainedOperationCausalGraph,
        node: ValidatedRetainedOperationNode,
        candidateBaseBody: String
    ) -> ExplicitDeleteProvenanceValidationResult {
        guard graph.nodes.contains(where: { $0.identity == node.identity && $0 == node }) else {
            return .recoveryRequired(.nodeAbsentFromGraph)
        }
        guard node.operation.operationKind == .delete else {
            return .recoveryRequired(.operationIsNotDelete)
        }
        guard record.noteID == node.operation.noteID,
              record.identity == node.identity,
              record.originDeviceID == node.operation.originDeviceID
        else {
            return .recoveryRequired(.invalidOperationIdentity)
        }
        guard record.canonicalReplayKey == node.replayKey.payload,
              record.canonicalReplayKey == node.operation.canonicalReplayKey
        else {
            return .recoveryRequired(.invalidReplayKey)
        }
        guard record.baseContentHash == node.baseContentHash,
              record.resultContentHash == node.resultContentHash
        else {
            return .recoveryRequired(.baseHashMismatch)
        }
        return validate(record: record, candidateBaseBody: candidateBaseBody)
    }

    func validate(
        record: ExplicitDeleteProvenanceRecord,
        candidateBaseBody: String
    ) -> ExplicitDeleteProvenanceValidationResult {
        guard record.formatVersion == ExplicitDeleteProvenanceConstants.formatVersion else {
            return .recoveryRequired(.unsupportedFormatVersion(record.formatVersion))
        }
        guard record.operationIndex >= 0,
              record.canonicalReplayKey.batchIDLowercase == record.batchID.uuidString.lowercased(),
              record.canonicalReplayKey.originDeviceIDLowercase == record.originDeviceID.uuidString.lowercased(),
              record.canonicalReplayKey.operationIndex == record.operationIndex
        else {
            return .recoveryRequired(.invalidOperationIdentity)
        }
        do {
            try record.canonicalReplayKey.validate()
            try SyncConvergenceDateAuthority.validate(
                date: record.createdAt,
                bitPattern: record.createdAtBitPattern,
                field: "createdAt"
            )
            try SyncConvergenceContractValidation.validateSHA256HexDigest(
                record.baseContentHash,
                field: "baseContentHash"
            )
            try SyncConvergenceContractValidation.validateSHA256HexDigest(
                record.resultContentHash,
                field: "resultContentHash"
            )
            try SyncConvergenceContractValidation.validateSHA256HexDigest(
                record.deletedTextDigest,
                field: "deletedTextDigest"
            )
            try SyncConvergenceContractValidation.validateSHA256HexDigest(
                record.leftContextDigest,
                field: "leftContextDigest"
            )
            try SyncConvergenceContractValidation.validateSHA256HexDigest(
                record.rightContextDigest,
                field: "rightContextDigest"
            )
        } catch {
            return .recoveryRequired(.corruptPersistedProvenance)
        }
        guard record.deletedUTF16Length > 0,
              record.leftContextUTF16Length >= 0,
              record.rightContextUTF16Length >= 0,
              record.occurrenceOrdinal >= 0
        else {
            return .recoveryRequired(.missingDeletePayload)
        }
        guard SyncBatchContentHash.sha256Hex(for: candidateBaseBody) == record.baseContentHash else {
            return .recoveryRequired(.baseHashMismatch)
        }

        let occurrences: [ExplicitDeleteOccurrence]
        switch record.tier {
        case .full:
            guard let deletedText = record.deletedText,
                  let leftContext = record.leftContext,
                  let rightContext = record.rightContext
            else {
                return .recoveryRequired(.malformedContextEvidence)
            }
            guard deletedText.utf16.count == record.deletedUTF16Length,
                  leftContext.utf16.count == record.leftContextUTF16Length,
                  rightContext.utf16.count == record.rightContextUTF16Length,
                  ExplicitDeleteProvenanceDigest.canonicalDigest(for: deletedText) == record.deletedTextDigest,
                  ExplicitDeleteProvenanceDigest.canonicalDigest(for: leftContext) == record.leftContextDigest,
                  ExplicitDeleteProvenanceDigest.canonicalDigest(for: rightContext) == record.rightContextDigest
            else {
                return .recoveryRequired(.malformedContextEvidence)
            }
            occurrences = ExplicitDeleteOccurrenceEnumerator.fullOccurrences(
                in: candidateBaseBody,
                descriptor: ExplicitDeleteOccurrenceDescriptor(
                    deletedText: deletedText,
                    leftContext: leftContext,
                    rightContext: rightContext
                )
            )
        case .compacted:
            guard record.deletedText == nil,
                  record.leftContext == nil,
                  record.rightContext == nil,
                  record.baseSnapshotGeneration != nil
            else {
                return .recoveryRequired(.malformedContextEvidence)
            }
            occurrences = ExplicitDeleteOccurrenceEnumerator.compactedOccurrences(
                in: candidateBaseBody,
                deletedUTF16Length: record.deletedUTF16Length,
                leftContextUTF16Length: record.leftContextUTF16Length,
                rightContextUTF16Length: record.rightContextUTF16Length,
                deletedTextDigest: record.deletedTextDigest,
                leftContextDigest: record.leftContextDigest,
                rightContextDigest: record.rightContextDigest
            )
        }

        guard occurrences.indices.contains(record.occurrenceOrdinal) else {
            return .recoveryRequired(.occurrenceNotFound)
        }
        let occurrence = occurrences[record.occurrenceOrdinal]
        guard occurrence.deletedText.utf16.count == record.deletedUTF16Length,
              ExplicitDeleteProvenanceDigest.canonicalDigest(for: occurrence.deletedText) == record.deletedTextDigest,
              ExplicitDeleteProvenanceDigest.canonicalDigest(for: occurrence.leftContext) == record.leftContextDigest,
              ExplicitDeleteProvenanceDigest.canonicalDigest(for: occurrence.rightContext) == record.rightContextDigest
        else {
            return .recoveryRequired(.deletedTextMismatch)
        }
        guard let stringRange = candidateBaseBody.stringRange(
            utf16Offset: occurrence.utf16Range.lowerBound,
            utf16Length: occurrence.utf16Range.count
        ) else {
            return .recoveryRequired(.invalidUTF16Range)
        }

        var resultBody = candidateBaseBody
        resultBody.removeSubrange(stringRange)
        guard SyncBatchContentHash.sha256Hex(for: resultBody) == record.resultContentHash else {
            return .recoveryRequired(.resultHashMismatch)
        }

        return .valid(ValidatedExplicitDeleteOccurrence(
            record: record,
            utf16Range: occurrence.utf16Range,
            resolvedDeletedText: occurrence.deletedText,
            resolvedLeftContext: occurrence.leftContext,
            resolvedRightContext: occurrence.rightContext
        ))
    }
}
