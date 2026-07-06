import Foundation

struct RetainedOperationCausalGraphValidator {
    func validate(_ input: IncrementalEditCausalValidationInput) -> IncrementalEditCausalValidationResult {
        guard input.anchorContentHash == SyncBatchContentHash.sha256Hex(for: input.anchorContent) else {
            return .recoveryRequired(.anchorHashMismatch)
        }

        guard identitiesAreValid(in: input.operations) else {
            return .recoveryRequired(.invalidOperationIdentity)
        }

        let replayKeys: [SyncConvergenceRetainedOperationIdentity: ValidatedCanonicalReplayKey]
        do {
            replayKeys = try validatedReplayKeys(for: input.operations)
        } catch {
            return .recoveryRequired(.invalidReplayKey)
        }

        guard explicitHashesArePresent(in: input.operations) else {
            return .recoveryRequired(.unreconstructableBase)
        }

        guard let normalizedOperations = normalizeDuplicateIdentities(input.operations) else {
            return .recoveryRequired(.invalidOperationIdentity)
        }

        if let batchHistoryFailure = validateBatchHistory(
            normalizedOperations: normalizedOperations,
            incorporatedOperationIdentities: input.incorporatedOperationIdentities,
            anchorContentHash: input.anchorContentHash
        ) {
            return .recoveryRequired(batchHistoryFailure)
        }

        let activeOperations = normalizedOperations
            .filter { !input.incorporatedOperationIdentities.contains(Self.identity(for: $0)) }
            .sorted {
                replayKeys[Self.identity(for: $0)]! < replayKeys[Self.identity(for: $1)]!
            }

        guard activeOperationsBelongToSingleNote(activeOperations) else {
            return .recoveryRequired(.unreconstructableBase)
        }

        let metadataNodes = activeOperations.map { operation in
            MetadataNode(
                operation: operation,
                identity: Self.identity(for: operation),
                replayKey: replayKeys[Self.identity(for: operation)]!,
                baseContentHash: operation.baseContentHash!,
                resultContentHash: operation.resultContentHash!
            )
        }

        return validateCausalGraph(nodes: metadataNodes, anchorContentHash: input.anchorContentHash)
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

    private func normalizeDuplicateIdentities(
        _ operations: [SyncConvergenceRetainedOperationRecord]
    ) -> [SyncConvergenceRetainedOperationRecord]? {
        var recordsByIdentity: [SyncConvergenceRetainedOperationIdentity: SyncConvergenceRetainedOperationRecord] = [:]

        for operation in operations {
            let identity = Self.identity(for: operation)
            if let existing = recordsByIdentity[identity], existing != operation {
                return nil
            }
            recordsByIdentity[identity] = operation
        }

        return Array(recordsByIdentity.values)
    }

    private func activeOperationsBelongToSingleNote(
        _ operations: [SyncConvergenceRetainedOperationRecord]
    ) -> Bool {
        Set(operations.map(\.noteID)).count <= 1
    }

    private func validateBatchHistory(
        normalizedOperations: [SyncConvergenceRetainedOperationRecord],
        incorporatedOperationIdentities: Set<SyncConvergenceRetainedOperationIdentity>,
        anchorContentHash: String
    ) -> IncrementalEditRecoveryReason? {
        let activeOperations = normalizedOperations.filter {
            !incorporatedOperationIdentities.contains(Self.identity(for: $0))
        }

        for operation in activeOperations.sorted(by: sameBatchSort) {
            guard let predecessor = retainedSameBatchPredecessor(
                for: operation,
                in: normalizedOperations
            ) else { continue }

            let predecessorIdentity = Self.identity(for: predecessor)

            if incorporatedOperationIdentities.contains(predecessorIdentity) {
                guard predecessor.resultContentHash == anchorContentHash,
                      operation.baseContentHash == anchorContentHash
                else {
                    return .unreconstructableBase
                }
            } else if operation.baseContentHash != predecessor.resultContentHash {
                return .missingCausalPredecessor
            }
        }

        return nil
    }

    private func validateCausalGraph(
        nodes: [MetadataNode],
        anchorContentHash: String
    ) -> IncrementalEditCausalValidationResult {
        let predecessorByIdentity = directionalPredecessors(for: nodes)

        let successorIdentitiesByPredecessor = Dictionary(grouping: predecessorByIdentity.keys) {
            predecessorByIdentity[$0]!.identity
        }
        let roots = nodes
            .filter { $0.baseContentHash == anchorContentHash && predecessorByIdentity[$0.identity] == nil }

        if successorIdentitiesByPredecessor.values.contains(where: { $0.count > 1 }) ||
            hasCrossBatchSameDeviceRootFork(roots: roots) {
            return .recoveryRequired(.ambiguousCausalChain)
        }

        for node in nodes where node.baseContentHash != anchorContentHash {
            guard predecessorByIdentity[node.identity] != nil else {
                return .recoveryRequired(.unreconstructableBase)
            }
        }

        let successorByPredecessor = successorIdentitiesByPredecessor.mapValues { identities in
            identities.sorted { lhs, rhs in
                canonicalIndex(for: lhs, in: nodes) < canonicalIndex(for: rhs, in: nodes)
            }.first!
        }
        let rootIdentities = roots.map(\.identity)

        let validatedNodes = nodes.map { node in
            ValidatedRetainedOperationNode(
                operation: node.operation,
                identity: node.identity,
                replayKey: node.replayKey,
                baseContentHash: node.baseContentHash,
                resultContentHash: node.resultContentHash,
                predecessorIdentity: predecessorByIdentity[node.identity]?.identity,
                successorIdentity: successorByPredecessor[node.identity]
            )
        }

        guard graphIsRooted(nodes: validatedNodes, rootIdentities: rootIdentities) else {
            return .recoveryRequired(.unreconstructableBase)
        }

        return .valid(
            RetainedOperationCausalGraph(
                anchorContentHash: anchorContentHash,
                rootIdentities: rootIdentities,
                nodes: validatedNodes
            )
        )
    }

    private func directionalPredecessors(
        for nodes: [MetadataNode]
    ) -> [SyncConvergenceRetainedOperationIdentity: MetadataNode] {
        let nodesByIdentity = Dictionary(uniqueKeysWithValues: nodes.map { ($0.identity, $0) })
        var predecessors: [SyncConvergenceRetainedOperationIdentity: MetadataNode] = [:]

        for node in nodes {
            if let sameBatchPredecessor = activeSameBatchPredecessor(for: node, in: nodesByIdentity) {
                predecessors[node.identity] = sameBatchPredecessor
                continue
            }

            let earlierMatches = nodes.filter { candidate in
                candidate.identity != node.identity &&
                candidate.operation.originDeviceID == node.operation.originDeviceID &&
                candidate.operation.noteID == node.operation.noteID &&
                candidate.resultContentHash == node.baseContentHash &&
                candidate.replayKey < node.replayKey
            }

            if let predecessor = earlierMatches.max(by: { $0.replayKey < $1.replayKey }) {
                predecessors[node.identity] = predecessor
            }
        }

        return predecessors
    }

    private func activeSameBatchPredecessor(
        for node: MetadataNode,
        in nodesByIdentity: [SyncConvergenceRetainedOperationIdentity: MetadataNode]
    ) -> MetadataNode? {
        nodesByIdentity.values
            .filter { candidate in
                candidate.identity != node.identity &&
                candidate.operation.batchID == node.operation.batchID &&
                candidate.operation.originDeviceID == node.operation.originDeviceID &&
                candidate.operation.noteID == node.operation.noteID &&
                candidate.operation.operationIndex < node.operation.operationIndex
            }
            .max { $0.operation.operationIndex < $1.operation.operationIndex }
    }

    private func retainedSameBatchPredecessor(
        for operation: SyncConvergenceRetainedOperationRecord,
        in operations: [SyncConvergenceRetainedOperationRecord]
    ) -> SyncConvergenceRetainedOperationRecord? {
        operations
            .filter { candidate in
                Self.identity(for: candidate) != Self.identity(for: operation) &&
                candidate.batchID == operation.batchID &&
                candidate.originDeviceID == operation.originDeviceID &&
                candidate.noteID == operation.noteID &&
                candidate.operationIndex < operation.operationIndex
            }
            .max { $0.operationIndex < $1.operationIndex }
    }

    private func hasCrossBatchSameDeviceRootFork(roots: [MetadataNode]) -> Bool {
        let rootsByDevice = Dictionary(grouping: roots) {
            $0.operation.originDeviceID
        }

        return rootsByDevice.values.contains { roots in
            Set(roots.map(\.operation.batchID)).count > 1
        }
    }

    private func graphIsRooted(
        nodes: [ValidatedRetainedOperationNode],
        rootIdentities: [SyncConvergenceRetainedOperationIdentity]
    ) -> Bool {
        guard nodes.isEmpty || !rootIdentities.isEmpty else {
            return false
        }

        let nodesByIdentity = Dictionary(uniqueKeysWithValues: nodes.map { ($0.identity, $0) })
        var visited = Set<SyncConvergenceRetainedOperationIdentity>()

        for rootIdentity in rootIdentities {
            guard let root = nodesByIdentity[rootIdentity],
                  root.predecessorIdentity == nil
            else {
                return false
            }

            var current: ValidatedRetainedOperationNode? = root
            while let node = current {
                guard node.predecessorIdentity != node.identity,
                      node.successorIdentity != node.identity,
                      !visited.contains(node.identity)
                else {
                    return false
                }
                visited.insert(node.identity)

                if let predecessorIdentity = node.predecessorIdentity,
                   nodesByIdentity[predecessorIdentity] == nil {
                    return false
                }

                if let successorIdentity = node.successorIdentity {
                    guard let successor = nodesByIdentity[successorIdentity],
                          successor.predecessorIdentity == node.identity
                    else {
                        return false
                    }
                    current = successor
                } else {
                    current = nil
                }
            }
        }

        return visited.count == nodes.count
    }

    private func sameBatchSort(
        _ lhs: SyncConvergenceRetainedOperationRecord,
        _ rhs: SyncConvergenceRetainedOperationRecord
    ) -> Bool {
        let lhsKey = sameBatchSortKey(lhs)
        let rhsKey = sameBatchSortKey(rhs)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.operationIndex < rhs.operationIndex
    }

    private func sameBatchSortKey(_ operation: SyncConvergenceRetainedOperationRecord) -> String {
        [
            operation.originDeviceID.uuidString.lowercased(),
            operation.noteID.uuidString.lowercased(),
            operation.batchID.uuidString.lowercased()
        ].joined(separator: "|")
    }

    private func canonicalIndex(
        for identity: SyncConvergenceRetainedOperationIdentity,
        in nodes: [MetadataNode]
    ) -> Int {
        nodes.firstIndex { $0.identity == identity }!
    }

    private struct MetadataNode: Equatable {
        let operation: SyncConvergenceRetainedOperationRecord
        let identity: SyncConvergenceRetainedOperationIdentity
        let replayKey: ValidatedCanonicalReplayKey
        let baseContentHash: String
        let resultContentHash: String
    }

}
