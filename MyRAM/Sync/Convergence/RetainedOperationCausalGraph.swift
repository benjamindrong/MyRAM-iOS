import Foundation

struct RetainedOperationCausalGraphValidator {
    func validate(_ input: IncrementalEditCausalValidationInput) -> IncrementalEditCausalValidationResult {
        guard input.anchorContentHash == SyncBatchContentHash.sha256Hex(for: input.anchorContent) else {
            return .recoveryRequired(.anchorHashMismatch)
        }

        let activeOperations = input.operations.filter {
            !input.incorporatedOperationIdentities.contains(Self.identity(for: $0))
        }

        guard identitiesAreValid(in: activeOperations) else {
            return .recoveryRequired(.invalidOperationIdentity)
        }

        let replayKeys: [SyncConvergenceRetainedOperationIdentity: ValidatedCanonicalReplayKey]
        do {
            replayKeys = try validatedReplayKeys(for: activeOperations)
        } catch {
            return .recoveryRequired(.invalidReplayKey)
        }

        guard explicitHashesArePresent(in: activeOperations) else {
            return .recoveryRequired(.unreconstructableBase)
        }

        let nodes = activeOperations.map { operation in
            let identity = Self.identity(for: operation)
            return ValidatedRetainedOperationNode(
                operation: operation,
                identity: identity,
                replayKey: replayKeys[identity]!,
                baseContentHash: operation.baseContentHash!,
                resultContentHash: operation.resultContentHash!
            )
        }

        return validateCausalGraph(
            nodes: nodes,
            anchorContent: input.anchorContent,
            anchorContentHash: input.anchorContentHash
        )
    }

    private static func identity(
        for operation: SyncConvergenceRetainedOperationRecord
    ) -> SyncConvergenceRetainedOperationIdentity {
        SyncConvergenceRetainedOperationIdentity(
            batchID: operation.batchID,
            operationIndex: operation.operationIndex
        )
    }

    private func identitiesAreValid(in operations: [SyncConvergenceRetainedOperationRecord]) -> Bool {
        for operation in operations {
            guard operation.operationIndex >= 0,
                  operation.canonicalReplayKey.batchIDLowercase == operation.batchID.uuidString.lowercased(),
                  operation.canonicalReplayKey.originDeviceIDLowercase == operation.originDeviceID.uuidString.lowercased(),
                  operation.canonicalReplayKey.operationIndex == operation.operationIndex
            else {
                return false
            }
        }
        return true
    }

    private func validatedReplayKeys(
        for operations: [SyncConvergenceRetainedOperationRecord]
    ) throws -> [SyncConvergenceRetainedOperationIdentity: ValidatedCanonicalReplayKey] {
        var replayKeys: [SyncConvergenceRetainedOperationIdentity: ValidatedCanonicalReplayKey] = [:]
        for operation in operations {
            replayKeys[Self.identity(for: operation)] = try ValidatedCanonicalReplayKey(operation.canonicalReplayKey)
        }
        return replayKeys
    }

    private func explicitHashesArePresent(in operations: [SyncConvergenceRetainedOperationRecord]) -> Bool {
        operations.allSatisfy {
            $0.baseContentHash != nil && $0.resultContentHash != nil
        }
    }

    private func validateCausalGraph(
        nodes: [ValidatedRetainedOperationNode],
        anchorContent: String,
        anchorContentHash: String
    ) -> IncrementalEditCausalValidationResult {
        var nodesByResult: [DeviceHash: [ValidatedRetainedOperationNode]] = [:]
        for node in nodes {
            nodesByResult[DeviceHash(deviceID: node.operation.originDeviceID, hash: node.resultContentHash), default: []]
                .append(node)
        }

        for node in nodes {
            let predecessorKey = DeviceHash(deviceID: node.operation.originDeviceID, hash: node.baseContentHash)
            let predecessors = nodesByResult[predecessorKey, default: []]
            if predecessors.count > 1 {
                return .recoveryRequired(.ambiguousCausalChain)
            }
        }

        var reachable = Set<SyncConvergenceRetainedOperationIdentity>()
        var visitedCount = -1
        while visitedCount != reachable.count {
            visitedCount = reachable.count
            for node in nodes {
                guard !reachable.contains(node.identity) else { continue }
                if node.baseContentHash == anchorContentHash {
                    reachable.insert(node.identity)
                    continue
                }
                let predecessorKey = DeviceHash(deviceID: node.operation.originDeviceID, hash: node.baseContentHash)
                if let predecessor = nodesByResult[predecessorKey]?.first,
                   reachable.contains(predecessor.identity) {
                    reachable.insert(node.identity)
                }
            }
        }

        for node in nodes where !reachable.contains(node.identity) {
            if sameDeviceHasAnchorRoot(for: node, in: nodes, anchorContentHash: anchorContentHash) {
                return .recoveryRequired(.missingCausalPredecessor)
            }
            return .recoveryRequired(.unreconstructableBase)
        }

        if retainedResultHashMismatchExists(
            in: nodes,
            anchorContent: anchorContent,
            anchorContentHash: anchorContentHash
        ) {
            return .recoveryRequired(.retainedResultHashMismatch)
        }

        return .valid(RetainedOperationCausalGraph(anchorContentHash: anchorContentHash, nodes: nodes))
    }

    private func sameDeviceHasAnchorRoot(
        for node: ValidatedRetainedOperationNode,
        in nodes: [ValidatedRetainedOperationNode],
        anchorContentHash: String
    ) -> Bool {
        nodes.contains {
            $0.operation.originDeviceID == node.operation.originDeviceID &&
            $0.baseContentHash == anchorContentHash
        }
    }

    private func retainedResultHashMismatchExists(
        in nodes: [ValidatedRetainedOperationNode],
        anchorContent: String,
        anchorContentHash: String
    ) -> Bool {
        var knownContentByHash = [anchorContentHash: anchorContent]
        let orderedNodes = nodes.sorted { $0.replayKey < $1.replayKey }
        var progressed = true

        while progressed {
            progressed = false
            for node in orderedNodes where knownContentByHash[node.resultContentHash] == nil {
                guard let baseContent = knownContentByHash[node.baseContentHash],
                      let resultContent = replay(node.operation, against: baseContent)
                else {
                    continue
                }
                guard SyncBatchContentHash.sha256Hex(for: resultContent) == node.resultContentHash else {
                    return true
                }
                knownContentByHash[node.resultContentHash] = resultContent
                progressed = true
            }
        }

        return false
    }

    private func replay(_ operation: SyncConvergenceRetainedOperationRecord, against content: String) -> String? {
        switch operation.operationKind {
        case .insert:
            guard let text = operation.text,
                  operation.utf16Offset >= 0,
                  operation.utf16Offset <= content.utf16.count,
                  let index = String.Index(utf16Offset: operation.utf16Offset, in: content)
            else {
                return nil
            }
            var result = content
            result.insert(contentsOf: text, at: index)
            return result

        case .delete:
            guard let length = operation.utf16Length,
                  length >= 0,
                  operation.utf16Offset >= 0,
                  operation.utf16Offset + length <= content.utf16.count,
                  let lower = String.Index(utf16Offset: operation.utf16Offset, in: content),
                  let upper = String.Index(utf16Offset: operation.utf16Offset + length, in: content)
            else {
                return nil
            }
            var result = content
            result.removeSubrange(lower..<upper)
            return result
        }
    }

    private struct DeviceHash: Hashable {
        let deviceID: UUID
        let hash: String
    }
}

private extension String.Index {
    init?(utf16Offset: Int, in string: String) {
        guard let utf16Index = string.utf16.index(
            string.utf16.startIndex,
            offsetBy: utf16Offset,
            limitedBy: string.utf16.endIndex
        ) else {
            return nil
        }
        self.init(utf16Index, within: string)
    }
}
