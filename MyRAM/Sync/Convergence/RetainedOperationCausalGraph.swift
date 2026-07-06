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

        let activeOperations = normalizedOperations
            .filter { !input.incorporatedOperationIdentities.contains(Self.identity(for: $0)) }
            .sorted {
                replayKeys[Self.identity(for: $0)]! < replayKeys[Self.identity(for: $1)]!
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

    private func validateCausalGraph(
        nodes: [MetadataNode],
        anchorContentHash: String
    ) -> IncrementalEditCausalValidationResult {
        let predecessorCandidatesByIdentity = predecessorCandidates(for: nodes, anchorContentHash: anchorContentHash)

        if hasAmbiguousJoin(predecessorCandidatesByIdentity) ||
            hasNonAnchorFork(nodes: nodes, anchorContentHash: anchorContentHash) ||
            hasCrossBatchSameDeviceAnchorFork(nodes: nodes, anchorContentHash: anchorContentHash) {
            return .recoveryRequired(.ambiguousCausalChain)
        }

        if hasSameBatchSequencingFault(nodes: nodes, anchorContentHash: anchorContentHash) {
            return .recoveryRequired(.missingCausalPredecessor)
        }

        let predecessorByIdentity = predecessorCandidatesByIdentity.compactMapValues(\.first)
        let successorIdentitiesByPredecessor = Dictionary(grouping: predecessorByIdentity.keys) {
            predecessorByIdentity[$0]!.identity
        }

        if successorIdentitiesByPredecessor.values.contains(where: { $0.count > 1 }) {
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
        let roots = nodes
            .filter { $0.baseContentHash == anchorContentHash }
            .map(\.identity)

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

        return .valid(
            RetainedOperationCausalGraph(
                anchorContentHash: anchorContentHash,
                rootIdentities: roots,
                nodes: validatedNodes
            )
        )
    }

    private func predecessorCandidates(
        for nodes: [MetadataNode],
        anchorContentHash: String
    ) -> [SyncConvergenceRetainedOperationIdentity: [MetadataNode]] {
        var nodesByDeviceAndResult: [DeviceHash: [MetadataNode]] = [:]
        for node in nodes {
            nodesByDeviceAndResult[
                DeviceHash(deviceID: node.operation.originDeviceID, hash: node.resultContentHash),
                default: []
            ].append(node)
        }

        var candidates: [SyncConvergenceRetainedOperationIdentity: [MetadataNode]] = [:]
        for node in nodes where node.baseContentHash != anchorContentHash {
            candidates[node.identity] = nodesByDeviceAndResult[
                DeviceHash(deviceID: node.operation.originDeviceID, hash: node.baseContentHash),
                default: []
            ]
        }
        return candidates
    }

    private func hasAmbiguousJoin(
        _ predecessorCandidatesByIdentity: [SyncConvergenceRetainedOperationIdentity: [MetadataNode]]
    ) -> Bool {
        predecessorCandidatesByIdentity.values.contains { $0.count > 1 }
    }

    private func hasNonAnchorFork(nodes: [MetadataNode], anchorContentHash: String) -> Bool {
        let successorsByDeviceAndBase = Dictionary(grouping: nodes) {
            DeviceHash(deviceID: $0.operation.originDeviceID, hash: $0.baseContentHash)
        }

        return successorsByDeviceAndBase.contains { key, successors in
            key.hash != anchorContentHash && successors.count > 1
        }
    }

    private func hasCrossBatchSameDeviceAnchorFork(nodes: [MetadataNode], anchorContentHash: String) -> Bool {
        let rootsByDevice = Dictionary(grouping: nodes.filter { $0.baseContentHash == anchorContentHash }) {
            $0.operation.originDeviceID
        }

        return rootsByDevice.values.contains { roots in
            Set(roots.map(\.operation.batchID)).count > 1
        }
    }

    private func hasSameBatchSequencingFault(nodes: [MetadataNode], anchorContentHash: String) -> Bool {
        let groups = Dictionary(grouping: nodes) { node in
            SameBatchNoteKey(
                batchID: node.operation.batchID,
                originDeviceID: node.operation.originDeviceID,
                noteID: node.operation.noteID
            )
        }

        for group in groups.values {
            let ordered = group.sorted { $0.operation.operationIndex < $1.operation.operationIndex }
            guard ordered.count > 1 else { continue }

            for index in ordered.indices.dropFirst() {
                let previous = ordered[ordered.index(before: index)]
                let current = ordered[index]
                if current.operation.operationIndex != previous.operation.operationIndex + 1 ||
                    current.baseContentHash != previous.resultContentHash ||
                    current.baseContentHash == anchorContentHash {
                    return true
                }
            }
        }

        return false
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

    private struct DeviceHash: Hashable {
        let deviceID: UUID
        let hash: String
    }

    private struct SameBatchNoteKey: Hashable {
        let batchID: UUID
        let originDeviceID: UUID
        let noteID: UUID
    }
}
