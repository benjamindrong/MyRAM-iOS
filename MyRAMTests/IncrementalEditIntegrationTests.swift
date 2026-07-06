import XCTest
@testable import MyRAM

final class IncrementalEditIntegrationTests: XCTestCase {
    func testEmptyInputWithVerifiedAnchorReturnsEmptyGraph() throws {
        let graph = try validGraph(from: validate(anchor: "A", operations: []))

        XCTAssertEqual(graph.anchorContentHash, hash("A"))
        XCTAssertEqual(graph.rootIdentities, [])
        XCTAssertEqual(graph.nodes, [])
    }

    func testBadAnchorShortCircuitsBeforeInvalidIdentity() {
        let operation = retainedOperation(operationIndex: -1, base: "A", resultHash: "result")

        let result = validate(anchor: "A", anchorHash: hash("wrong"), operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.anchorHashMismatch))
    }

    func testInvalidRetainedIdentityShortCircuitsBeforeReplayValidation() {
        let operation = retainedOperation(
            operationIndex: -1,
            replayKey: replayKey(operationIndex: -1).replacingForTest(version: 99),
            base: "A",
            resultHash: "result"
        )

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.invalidOperationIdentity))
    }

    func testInvalidReplayKeyPrecedesMissingHashes() {
        let operation = retainedOperation(
            replayKey: replayKey().replacingForTest(version: 99),
            baseHash: nil,
            resultHash: nil
        )

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.invalidReplayKey))
    }

    func testNilBaseContentHashReturnsUnreconstructableBase() {
        let operation = retainedOperation(baseHash: nil, resultHash: "result")

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testNilResultContentHashReturnsUnreconstructableBase() {
        let operation = retainedOperation(base: "A", resultHash: nil)

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testDirectAnchorOperationWithExplicitHashesReachesValidGraph() throws {
        let operation = retainedOperation(base: "A", resultHash: "declared-result")

        let graph = try validGraph(from: validate(anchor: "A", operations: [operation]))

        assertGraph(
            graph,
            roots: [identity(for: operation)],
            nodes: [
                ExpectedNode(
                    identity: identity(for: operation),
                    base: hash("A"),
                    result: "declared-result",
                    predecessor: nil,
                    successor: nil
                )
            ]
        )
    }

    func testSameDeviceChainWithExplicitHashesReachesValidGraph() throws {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 1, baseHash: "first", resultHash: "second")

        let graph = try validGraph(from: validate(anchor: "A", operations: [second, first]))

        assertGraph(
            graph,
            roots: [identity(for: first)],
            nodes: [
                ExpectedNode(identity: identity(for: first), base: hash("A"), result: "first", predecessor: nil, successor: identity(for: second)),
                ExpectedNode(identity: identity(for: second), base: "first", result: "second", predecessor: identity(for: first), successor: nil)
            ]
        )
    }

    func testConcurrentAnchorRootsFromDifferentDevicesAreValid() throws {
        let first = retainedOperation(
            batchID: myr152UUID(201),
            originDeviceID: myr152UUID(301),
            replayKey: replayKey(batchID: myr152UUID(201), originDeviceID: myr152UUID(301), sequence: 1),
            base: "A",
            resultHash: "first"
        )
        let second = retainedOperation(
            batchID: myr152UUID(202),
            originDeviceID: myr152UUID(302),
            replayKey: replayKey(batchID: myr152UUID(202), originDeviceID: myr152UUID(302), sequence: 2),
            base: "A",
            resultHash: "second"
        )

        let graph = try validGraph(from: validate(anchor: "A", operations: [second, first]))

        assertGraph(
            graph,
            roots: [identity(for: first), identity(for: second)],
            nodes: [
                ExpectedNode(identity: identity(for: first), base: hash("A"), result: "first", predecessor: nil, successor: nil),
                ExpectedNode(identity: identity(for: second), base: hash("A"), result: "second", predecessor: nil, successor: nil)
            ]
        )
    }

    func testPR1LinkageOnlyBoundaryAllowsArbitraryDirectRootResultHash() throws {
        let operation = retainedOperation(base: "A", resultHash: "not-the-hash-of-AB")

        let graph = try validGraph(from: validate(anchor: "A", operations: [operation]))

        XCTAssertEqual(graph.nodes.map(\.resultContentHash), ["not-the-hash-of-AB"])
    }

    func testPR1LinkageOnlyBoundaryDoesNotEvaluateDeleteExpectedText() throws {
        let operation = retainedOperation(
            kind: .delete,
            utf16Offset: 0,
            utf16Length: 1,
            text: nil,
            expectedText: "not-present",
            base: "A",
            resultHash: "declared-delete-result"
        )

        let graph = try validGraph(from: validate(anchor: "A", operations: [operation]))

        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: operation)])
    }

    func testPR1LinkageOnlyBoundaryUsesDeclaredResultHashForSuccessorLinkage() throws {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "declared-link")
        let second = retainedOperation(operationIndex: 1, baseHash: "declared-link", resultHash: "second")

        let graph = try validGraph(from: validate(anchor: "A", operations: [second, first]))

        XCTAssertEqual(graph.nodes[0].successorIdentity, identity(for: second))
        XCTAssertEqual(graph.nodes[1].predecessorIdentity, identity(for: first))
    }

    func testUnknownBaseReturnsUnreconstructableBase() {
        let operation = retainedOperation(baseHash: "unknown", resultHash: "result")

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testSelfLoopReturnsUnreconstructableBaseAcrossPermutations() {
        let operation = retainedOperation(baseHash: "X", resultHash: "X")

        let original = validate(anchor: "A", operations: [operation])
        let permuted = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(original, .recoveryRequired(.unreconstructableBase))
        XCTAssertEqual(original, permuted)
    }

    func testTwoNodeClosedCycleReturnsUnreconstructableBaseAcrossPermutations() {
        let first = retainedOperation(batchID: myr152UUID(250), replayKey: replayKey(batchID: myr152UUID(250), sequence: 1), baseHash: "Y", resultHash: "X")
        let second = retainedOperation(batchID: myr152UUID(251), replayKey: replayKey(batchID: myr152UUID(251), sequence: 2), baseHash: "X", resultHash: "Y")

        let original = validate(anchor: "A", operations: [first, second])
        let permuted = validate(anchor: "A", operations: [second, first])

        XCTAssertEqual(original, .recoveryRequired(.unreconstructableBase))
        XCTAssertEqual(original, permuted)
    }

    func testNonemptyGraphWithoutAnchorRootCannotBeValid() {
        let operation = retainedOperation(baseHash: "X", resultHash: "X")

        let result = validate(anchor: "A", operations: [operation])

        guard case .recoveryRequired(.unreconstructableBase) = result else {
            return XCTFail("Expected unrooted nonempty graph recovery, got \(result)")
        }
    }

    func testUnrelatedUnknownBaseBatchDoesNotInheritMissingPredecessorDiagnosis() {
        let root = retainedOperation(batchID: myr152UUID(210), operationIndex: 0, base: "A", resultHash: "first")
        let unrelated = retainedOperation(
            batchID: myr152UUID(211),
            operationIndex: 0,
            replayKey: replayKey(batchID: myr152UUID(211), operationIndex: 0, sequence: 2),
            baseHash: "unknown",
            resultHash: "other"
        )

        let result = validate(anchor: "A", operations: [root, unrelated])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testSameDeviceForkReturnsAmbiguousCausalChain() {
        let first = retainedOperation(batchID: myr152UUID(260), replayKey: replayKey(batchID: myr152UUID(260), sequence: 1), base: "A", resultHash: "first")
        let second = retainedOperation(batchID: myr152UUID(261), replayKey: replayKey(batchID: myr152UUID(261), sequence: 2), baseHash: "first", resultHash: "second")
        let third = retainedOperation(batchID: myr152UUID(262), replayKey: replayKey(batchID: myr152UUID(262), sequence: 3), baseHash: "first", resultHash: "third")

        let result = validate(anchor: "A", operations: [third, first, second])

        XCTAssertEqual(result, .recoveryRequired(.ambiguousCausalChain))
    }

    func testSameBatchAnchorRestartWithoutGapReturnsMissingCausalPredecessor() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let result = validate(anchor: "A", operations: [second, first])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testSameBatchIndexGapAnchorRestartReturnsMissingCausalPredecessor() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 2, base: "A", resultHash: "second")

        let result = validate(anchor: "A", operations: [second, first])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testLoneIndexOneOperationReturnsMissingCausalPredecessor() {
        let operation = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testLoneIndexTwoOperationReturnsMissingCausalPredecessor() {
        let operation = retainedOperation(operationIndex: 2, base: "A", resultHash: "third")

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testValidNoOpDeclaredSameBatchLinkageIsAccepted() throws {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: hash("A"))
        let second = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let graph = try validGraph(from: validate(anchor: "A", operations: [second, first]))

        assertGraph(
            graph,
            roots: [identity(for: first)],
            nodes: [
                ExpectedNode(identity: identity(for: first), base: hash("A"), result: hash("A"), predecessor: nil, successor: identity(for: second)),
                ExpectedNode(identity: identity(for: second), base: hash("A"), result: "second", predecessor: identity(for: first), successor: nil)
            ]
        )
    }

    func testInvalidSameBatchRestartStillReturnsMissingCausalPredecessor() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let result = validate(anchor: "A", operations: [second, first])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testCrossBatchSameDeviceAnchorForkReturnsAmbiguousCausalChain() {
        let first = retainedOperation(batchID: myr152UUID(221), operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(
            batchID: myr152UUID(222),
            operationIndex: 0,
            replayKey: replayKey(batchID: myr152UUID(222), sequence: 2),
            base: "A",
            resultHash: "second"
        )

        let result = validate(anchor: "A", operations: [second, first])

        XCTAssertEqual(result, .recoveryRequired(.ambiguousCausalChain))
    }

    func testAmbiguousJoinReturnsAmbiguousCausalChain() {
        let first = retainedOperation(batchID: myr152UUID(231), operationIndex: 0, base: "A", resultHash: "shared")
        let second = retainedOperation(batchID: myr152UUID(232), operationIndex: 0, base: "A", resultHash: "shared")
        let dependent = retainedOperation(batchID: myr152UUID(233), operationIndex: 0, baseHash: "shared", resultHash: "dependent")

        let result = validate(anchor: "A", operations: [dependent, second, first])

        XCTAssertEqual(result, .recoveryRequired(.ambiguousCausalChain))
    }

    func testEquivalentInInputDuplicateIsCoalesced() throws {
        let operation = retainedOperation(base: "A", resultHash: "first")

        let graph = try validGraph(from: validate(anchor: "A", operations: [operation, operation]))

        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: operation)])
    }

    func testConflictingDuplicateIdentityReturnsInvalidOperationIdentity() {
        let first = retainedOperation(base: "A", resultHash: "first")
        let second = retainedOperation(base: "A", resultHash: "conflicting")

        let result = validate(anchor: "A", operations: [first, second])

        XCTAssertEqual(result, .recoveryRequired(.invalidOperationIdentity))
    }

    func testMalformedIncorporatedRecordIsValidatedBeforeFiltering() {
        let operation = retainedOperation(operationIndex: -1, base: "A", resultHash: "first")

        let result = validate(
            anchor: "A",
            operations: [operation],
            incorporated: [identity(for: operation)]
        )

        XCTAssertEqual(result, .recoveryRequired(.invalidOperationIdentity))
    }

    func testIncorporatedPredecessorNotRepresentedByAnchorReturnsUnreconstructableBase() {
        let incorporated = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let remaining = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let result = validate(
            anchor: "A",
            operations: [incorporated, remaining],
            incorporated: [identity(for: incorporated)]
        )

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testIncorporatedPredecessorRepresentedByAnchorAllowsActiveRoot() throws {
        let incorporated = retainedOperation(operationIndex: 0, baseHash: "old", resultHash: hash("A"))
        let remaining = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let graph = try validGraph(
            from: validate(anchor: "A", operations: [incorporated, remaining], incorporated: [identity(for: incorporated)])
        )

        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: remaining)])
        XCTAssertEqual(graph.rootIdentities, [identity(for: remaining)])
    }

    func testIncorporatedPredecessorIdentityWithoutRecordReturnsMissingCausalPredecessor() {
        let operation = retainedOperation(operationIndex: 1, base: "A", resultHash: "second")

        let result = validate(
            anchor: "A",
            operations: [operation],
            incorporated: [SyncConvergenceRetainedOperationIdentity(batchID: operation.batchID, operationIndex: 0)]
        )

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testDifferentDeviceRemainingRootAfterIncorporatedRecordRemainsValid() throws {
        let incorporated = retainedOperation(
            batchID: myr152UUID(270),
            originDeviceID: myr152UUID(370),
            replayKey: replayKey(batchID: myr152UUID(270), originDeviceID: myr152UUID(370), sequence: 1),
            base: "A",
            resultHash: "first"
        )
        let remaining = retainedOperation(
            batchID: myr152UUID(271),
            originDeviceID: myr152UUID(371),
            replayKey: replayKey(batchID: myr152UUID(271), originDeviceID: myr152UUID(371), sequence: 2),
            base: "A",
            resultHash: "second"
        )

        let graph = try validGraph(
            from: validate(anchor: "A", operations: [incorporated, remaining], incorporated: [identity(for: incorporated)])
        )

        XCTAssertEqual(graph.rootIdentities, [identity(for: remaining)])
        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: remaining)])
    }

    func testDependencyOnFilteredIncorporatedOperationReturnsUnreconstructableBase() {
        let incorporated = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let remaining = retainedOperation(operationIndex: 1, baseHash: "first", resultHash: "second")

        let result = validate(
            anchor: "A",
            operations: [incorporated, remaining],
            incorporated: [identity(for: incorporated)]
        )

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testBatchHistoryFaultPrecedesGraphAmbiguityAcrossPermutations() {
        let batchFault = retainedOperation(operationIndex: 1, base: "A", resultHash: "batch-fault")
        let root = retainedOperation(
            batchID: myr152UUID(280),
            replayKey: replayKey(batchID: myr152UUID(280), sequence: 2),
            base: "A",
            resultHash: "first"
        )
        let forkA = retainedOperation(
            batchID: myr152UUID(281),
            replayKey: replayKey(batchID: myr152UUID(281), sequence: 3),
            baseHash: "first",
            resultHash: "fork-a"
        )
        let forkB = retainedOperation(
            batchID: myr152UUID(282),
            replayKey: replayKey(batchID: myr152UUID(282), sequence: 4),
            baseHash: "first",
            resultHash: "fork-b"
        )

        let original = validate(anchor: "A", operations: [batchFault, root, forkA, forkB])
        let permuted = validate(anchor: "A", operations: [forkB, root, forkA, batchFault])

        XCTAssertEqual(original, .recoveryRequired(.missingCausalPredecessor))
        XCTAssertEqual(original, permuted)
    }

    func testValidResultIsEqualAcrossInputPermutations() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 1, baseHash: "first", resultHash: "second")
        let third = retainedOperation(
            batchID: myr152UUID(240),
            originDeviceID: myr152UUID(340),
            replayKey: replayKey(batchID: myr152UUID(240), originDeviceID: myr152UUID(340), sequence: 2),
            base: "A",
            resultHash: "third"
        )

        let original = validate(anchor: "A", operations: [first, second, third])
        let permuted = validate(anchor: "A", operations: [third, second, first])

        XCTAssertEqual(original, permuted)
    }

    func testGraphFaultResultIsEqualAcrossInputPermutations() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: "first")
        let second = retainedOperation(operationIndex: 1, baseHash: "first", resultHash: "second")
        let third = retainedOperation(operationIndex: 2, baseHash: "first", resultHash: "third")

        let original = validate(anchor: "A", operations: [first, second, third])
        let permuted = validate(anchor: "A", operations: [third, second, first])

        XCTAssertEqual(original, permuted)
    }

    func testRecoveryShapeCannotCarryPartialOutput() {
        let result = validate(anchor: "A", anchorHash: hash("wrong"), operations: [])

        switch result {
        case .recoveryRequired(let reason):
            XCTAssertEqual(reason, .anchorHashMismatch)
        case .valid:
            XCTFail("Recovery must not expose a valid causal graph")
        }
    }

    private func validate(
        anchor: String,
        anchorHash: String? = nil,
        operations: [SyncConvergenceRetainedOperationRecord],
        incorporated: Set<SyncConvergenceRetainedOperationIdentity> = []
    ) -> IncrementalEditCausalValidationResult {
        RetainedOperationCausalGraphValidator().validate(
            IncrementalEditCausalValidationInput(
                anchorContent: anchor,
                anchorContentHash: anchorHash ?? hash(anchor),
                operations: operations,
                incorporatedOperationIdentities: incorporated
            )
        )
    }

    private func validGraph(
        from result: IncrementalEditCausalValidationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RetainedOperationCausalGraph {
        guard case .valid(let graph) = result else {
            XCTFail("Expected valid causal graph, got \(result)", file: file, line: line)
            throw TestFailure.unexpectedRecovery
        }
        return graph
    }

    private func assertGraph(
        _ graph: RetainedOperationCausalGraph,
        roots: [SyncConvergenceRetainedOperationIdentity],
        nodes expectedNodes: [ExpectedNode],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(graph.rootIdentities, roots, file: file, line: line)
        XCTAssertEqual(graph.nodes.map(\.identity), expectedNodes.map(\.identity), file: file, line: line)
        XCTAssertEqual(graph.nodes.map(\.baseContentHash), expectedNodes.map(\.base), file: file, line: line)
        XCTAssertEqual(graph.nodes.map(\.resultContentHash), expectedNodes.map(\.result), file: file, line: line)
        XCTAssertEqual(graph.nodes.map(\.predecessorIdentity), expectedNodes.map(\.predecessor), file: file, line: line)
        XCTAssertEqual(graph.nodes.map(\.successorIdentity), expectedNodes.map(\.successor), file: file, line: line)
    }

    private func retainedOperation(
        noteID: UUID = myr152UUID(100),
        batchID: UUID = myr152UUID(200),
        originDeviceID: UUID = myr152UUID(300),
        operationIndex: Int = 0,
        replayKey: CanonicalReplayKeyPayload? = nil,
        kind: SyncConvergencePlannedBodyOperation.Kind = .insert,
        utf16Offset: Int = 0,
        utf16Length: Int? = nil,
        text: String? = "x",
        expectedText: String? = nil,
        base: String? = nil,
        baseHash: String? = nil,
        resultHash: String?
    ) -> SyncConvergenceRetainedOperationRecord {
        SyncConvergenceRetainedOperationRecord(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: operationIndex,
            operationKind: kind,
            utf16Offset: utf16Offset,
            utf16Length: utf16Length,
            text: text,
            expectedText: expectedText,
            baseContentHash: base.map(hash) ?? baseHash,
            resultContentHash: resultHash,
            canonicalReplayKey: replayKey ?? self.replayKey(
                batchID: batchID,
                originDeviceID: originDeviceID,
                operationIndex: operationIndex
            ),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
    }

    private func replayKey(
        batchID: UUID = myr152UUID(200),
        originDeviceID: UUID = myr152UUID(300),
        operationIndex: Int = 0,
        sequence: UInt64 = 1
    ) -> CanonicalReplayKeyPayload {
        CanonicalReplayKeyPayload(
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSinceReferenceDate: Double(sequence))),
            originDeviceIDLowercase: originDeviceID.uuidString.lowercased(),
            batchOrderKind: .sequenced,
            legacyCreatedAtBitPattern: nil,
            sequence: sequence,
            batchIDLowercase: batchID.uuidString.lowercased(),
            operationIndex: operationIndex
        )
    }

    private func identity(
        for operation: SyncConvergenceRetainedOperationRecord
    ) -> SyncConvergenceRetainedOperationIdentity {
        SyncConvergenceRetainedOperationIdentity(
            batchID: operation.batchID,
            operationIndex: operation.operationIndex
        )
    }

    private func hash(_ content: String) -> String {
        SyncBatchContentHash.sha256Hex(for: content)
    }

    private struct ExpectedNode {
        let identity: SyncConvergenceRetainedOperationIdentity
        let base: String
        let result: String
        let predecessor: SyncConvergenceRetainedOperationIdentity?
        let successor: SyncConvergenceRetainedOperationIdentity?
    }

    private enum TestFailure: Error {
        case unexpectedRecovery
    }
}

private func myr152UUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
