import XCTest
@testable import MyRAM

final class IncrementalEditIntegrationTests: XCTestCase {
    func testBadAnchorShortCircuitsBeforeInvalidIdentity() {
        let operation = retainedOperation(operationIndex: -1, base: "A", result: "AB")

        let result = validate(anchor: "A", anchorHash: hash("wrong"), operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.anchorHashMismatch))
    }

    func testInvalidRetainedIdentityShortCircuitsBeforeReplayValidation() {
        let operation = retainedOperation(
            operationIndex: -1,
            replayKey: replayKey(operationIndex: -1).replacingForTest(version: 99),
            base: "A",
            result: "AB"
        )

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.invalidOperationIdentity))
    }

    func testInvalidReplayKeyReturnsRecovery() {
        let operation = retainedOperation(
            replayKey: replayKey().replacingForTest(version: 99),
            base: "A",
            result: "AB"
        )

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.invalidReplayKey))
    }

    func testNilBaseContentHashReturnsUnreconstructableBase() {
        let operation = retainedOperation(result: "AB", baseHash: .explicit(nil))

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testNilResultContentHashReturnsUnreconstructableBase() {
        let operation = retainedOperation(base: "A", resultHash: .explicit(nil))

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testDirectAnchorOperationWithExplicitHashesReachesValidGraph() throws {
        let operation = retainedOperation(base: "A", result: "AB")

        let result = validate(anchor: "A", operations: [operation])

        let graph = try validGraph(from: result)
        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: operation)])
        XCTAssertEqual(graph.nodes.map(\.baseContentHash), [hash("A")])
        XCTAssertEqual(graph.nodes.map(\.resultContentHash), [hash("AB")])
    }

    func testSameDeviceChainWithExplicitHashesReachesValidGraph() throws {
        let first = retainedOperation(operationIndex: 0, base: "A", result: "AB")
        let second = retainedOperation(operationIndex: 1, base: "AB", result: "ABC")

        let result = validate(anchor: "A", operations: [second, first])

        let graph = try validGraph(from: result)
        XCTAssertEqual(
            Set<SyncConvergenceRetainedOperationIdentity>(graph.nodes.map(\.identity)),
            [identity(for: first), identity(for: second)]
        )
    }

    func testConcurrentChainsDescendingFromSameExplicitAnchorAreValid() throws {
        let first = retainedOperation(
            batchID: myr152UUID(201),
            originDeviceID: myr152UUID(301),
            operationIndex: 0,
            replayKey: replayKey(batchID: myr152UUID(201), originDeviceID: myr152UUID(301)),
            base: "A",
            result: "AB"
        )
        let second = retainedOperation(
            batchID: myr152UUID(202),
            originDeviceID: myr152UUID(302),
            operationIndex: 0,
            replayKey: replayKey(batchID: myr152UUID(202), originDeviceID: myr152UUID(302)),
            base: "A",
            result: "AC"
        )

        let result = validate(anchor: "A", operations: [second, first])

        let graph = try validGraph(from: result)
        XCTAssertEqual(
            Set<SyncConvergenceRetainedOperationIdentity>(graph.nodes.map(\.identity)),
            [identity(for: first), identity(for: second)]
        )
    }

    func testUnknownBaseReturnsUnreconstructableBase() {
        let operation = retainedOperation(result: "AB", baseHash: .explicit(hash("unknown")))

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
    }

    func testMissingSameDevicePredecessorReturnsMissingCausalPredecessor() {
        let root = retainedOperation(operationIndex: 0, base: "A", result: "AB")
        let dependent = retainedOperation(operationIndex: 2, result: "ABCD", baseHash: .explicit(hash("ABC")))

        let result = validate(anchor: "A", operations: [root, dependent])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testMultipleValidPredecessorsReturnAmbiguousCausalChain() {
        let first = retainedOperation(batchID: myr152UUID(211), operationIndex: 0, base: "A", result: "AB")
        let second = retainedOperation(batchID: myr152UUID(212), operationIndex: 0, base: "A", result: "AB")
        let dependent = retainedOperation(batchID: myr152UUID(213), operationIndex: 0, base: "AB", result: "ABC")

        let result = validate(anchor: "A", operations: [first, second, dependent])

        XCTAssertEqual(result, .recoveryRequired(.ambiguousCausalChain))
    }

    func testResultHashMismatchLeavesDependentBaseUnreconstructable() {
        let first = retainedOperation(operationIndex: 0, base: "A", resultHash: .explicit(hash("AX")))
        let dependent = retainedOperation(operationIndex: 1, base: "AB", result: "ABC")

        let result = validate(anchor: "A", operations: [first, dependent])

        XCTAssertEqual(result, .recoveryRequired(.missingCausalPredecessor))
    }

    func testRetainedResultHashMismatchReturnsRecovery() {
        let operation = retainedOperation(base: "A", result: "AB", resultHash: .explicit(hash("AX")))

        let result = validate(anchor: "A", operations: [operation])

        XCTAssertEqual(result, .recoveryRequired(.retainedResultHashMismatch))
    }

    func testDuplicateFilteringIsNonFatalForIndependentRemainingOperation() throws {
        let duplicate = retainedOperation(operationIndex: 0, base: "A", result: "AB")
        let remaining = retainedOperation(operationIndex: 1, base: "A", result: "AC")

        let result = validate(
            anchor: "A",
            operations: [duplicate, remaining],
            incorporated: [identity(for: duplicate)]
        )

        let graph = try validGraph(from: result)
        XCTAssertEqual(graph.nodes.map(\.identity), [identity(for: remaining)])
    }

    func testDuplicateFilteringCanMakeRemainingDependencyUnreconstructable() {
        let duplicate = retainedOperation(operationIndex: 0, base: "A", result: "AB")
        let remaining = retainedOperation(operationIndex: 1, base: "AB", result: "ABC")

        let result = validate(
            anchor: "A",
            operations: [duplicate, remaining],
            incorporated: [identity(for: duplicate)]
        )

        XCTAssertEqual(result, .recoveryRequired(.unreconstructableBase))
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

    private func retainedOperation(
        noteID: UUID = myr152UUID(100),
        batchID: UUID = myr152UUID(200),
        originDeviceID: UUID = myr152UUID(300),
        operationIndex: Int = 0,
        replayKey: CanonicalReplayKeyPayload? = nil,
        base: String = "A",
        result: String = "AB",
        baseHash: HashOverride = .derived,
        resultHash: HashOverride = .derived
    ) -> SyncConvergenceRetainedOperationRecord {
        let insertedText = result.hasPrefix(base) ? String(result.dropFirst(base.count)) : "B"
        let insertionOffset = result.hasPrefix(base) ? base.utf16.count : 1
        return SyncConvergenceRetainedOperationRecord(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: operationIndex,
            operationKind: .insert,
            utf16Offset: insertionOffset,
            utf16Length: nil,
            text: insertedText,
            expectedText: nil,
            baseContentHash: baseHash.resolve(default: hash(base)),
            resultContentHash: resultHash.resolve(default: hash(result)),
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
        operationIndex: Int = 0
    ) -> CanonicalReplayKeyPayload {
        CanonicalReplayKeyPayload(
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSinceReferenceDate: 10)),
            originDeviceIDLowercase: originDeviceID.uuidString.lowercased(),
            batchOrderKind: .sequenced,
            legacyCreatedAtBitPattern: nil,
            sequence: 1,
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

    private enum TestFailure: Error {
        case unexpectedRecovery
    }

    private enum HashOverride {
        case derived
        case explicit(String?)

        func resolve(default derivedHash: String) -> String? {
            switch self {
            case .derived:
                return derivedHash
            case .explicit(let hash):
                return hash
            }
        }
    }
}

private func myr152UUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
