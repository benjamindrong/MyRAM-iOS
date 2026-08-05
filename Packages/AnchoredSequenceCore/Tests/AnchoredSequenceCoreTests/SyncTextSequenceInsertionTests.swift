import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncTextSequenceInsertionTests: XCTestCase {
    func testIncorporatingInsertIntoEmptyStateCreatesVisibleRootWithoutMutatingInput() throws {
        let payload = insertPayload(operation(1), anchor: .empty)
        let original = SyncTextSequenceState.empty

        let replacement = try original.incorporating(
            insert: payload,
            insertedText: "Hello"
        )

        XCTAssertEqual(replacement.runs, [try run(operation(1), text: "Hello")])
        XCTAssertEqual(replacement.fragments, [try fragment(operation(1), length: 5)])
        XCTAssertEqual(replacement.visibleText, "Hello")
        XCTAssertEqual(replacement.visibleUTF16Count, 5)
        XCTAssertEqual(replacement.tombstonedUTF16Count, 0)
        assertUnchanged(original, from: .empty)
    }

    func testIncorporatingSupportsLeadingMidRunAndTrailingInsertion() throws {
        let baseOperation = operation(0)
        let base = try rootState(operationID: baseOperation, text: "ABC")
        let first = try element(baseOperation, 0)
        let second = try element(baseOperation, 1)
        let final = try element(baseOperation, 2)

        let leading = try base.incorporating(
            insert: insertPayload(operation(1), anchor: .before(first)),
            insertedText: "L"
        )
        let middle = try base.incorporating(
            insert: insertPayload(
                operation(1),
                anchor: try .between(left: first, right: second)
            ),
            insertedText: "M"
        )
        let trailing = try base.incorporating(
            insert: insertPayload(operation(1), anchor: .after(final)),
            insertedText: "T"
        )

        XCTAssertEqual(leading.visibleText, "LABC")
        XCTAssertEqual(middle.visibleText, "AMBC")
        XCTAssertEqual(middle.fragments, [
            try fragment(baseOperation, start: 0, length: 1),
            try fragment(operation(1), length: 1),
            try fragment(baseOperation, start: 1, length: 2)
        ])
        XCTAssertEqual(trailing.visibleText, "ABCT")
        assertUnchanged(base, from: try rootState(operationID: baseOperation, text: "ABC"))
    }

    func testIncorporatingCrossRunInsertionPreservesBothEndpoints() throws {
        let baseOperation = operation(0)
        let firstInsertOperation = operation(1)
        let secondInsertOperation = operation(2)
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let firstInsert = try element(firstInsertOperation, 0)

        let base = try rootState(operationID: baseOperation, text: "AB")
        let withFirstInsert = try base.incorporating(
            insert: insertPayload(
                firstInsertOperation,
                anchor: try .between(left: left, right: right)
            ),
            insertedText: "X"
        )
        let replacement = try withFirstInsert.incorporating(
            insert: insertPayload(
                secondInsertOperation,
                anchor: try .between(left: firstInsert, right: right)
            ),
            insertedText: "Y"
        )

        XCTAssertEqual(replacement.visibleText, "AXYB")
        let insertedRun = try XCTUnwrap(
            replacement.runs.first(where: { $0.operationID == secondInsertOperation })
        )
        XCTAssertEqual(insertedRun.origin.leftElementID, firstInsert)
        XCTAssertEqual(insertedRun.origin.rightElementID, right)
        assertUnchanged(
            withFirstInsert,
            from: try base.incorporating(
                insert: insertPayload(
                    firstInsertOperation,
                    anchor: try .between(left: left, right: right)
                ),
                insertedText: "X"
            )
        )
    }

    func testIncorporatingUsesTombstonedAnchorsAndPreservesVisibilityByIdentity() throws {
        let baseOperation = operation(0)
        let baseRun = try run(baseOperation, text: "ABC")
        let original = try SyncTextSequenceState(
            runs: [baseRun],
            fragments: [
                try fragment(baseOperation, start: 0, length: 1),
                try fragment(baseOperation, start: 1, length: 1, visibility: .tombstone),
                try fragment(baseOperation, start: 2, length: 1)
            ]
        )
        let tombstoned = try element(baseOperation, 1)
        let right = try element(baseOperation, 2)

        let replacement = try original.incorporating(
            insert: insertPayload(
                operation(1),
                anchor: try .between(left: tombstoned, right: right)
            ),
            insertedText: "X"
        )

        XCTAssertEqual(replacement.visibleText, "AXC")
        XCTAssertEqual(replacement.visibleUTF16Count, 3)
        XCTAssertEqual(replacement.tombstonedUTF16Count, 1)
        XCTAssertEqual(replacement.visibility(of: tombstoned), .tombstone)
        XCTAssertEqual(replacement.visibility(of: try element(operation(1), 0)), .visible)
        XCTAssertEqual(replacement.fragments, [
            try fragment(baseOperation, start: 0, length: 1),
            try fragment(baseOperation, start: 1, length: 1, visibility: .tombstone),
            try fragment(operation(1), length: 1),
            try fragment(baseOperation, start: 2, length: 1)
        ])
        assertUnchanged(original, from: try SyncTextSequenceState(
            runs: [baseRun],
            fragments: [
                try fragment(baseOperation, start: 0, length: 1),
                try fragment(baseOperation, start: 1, length: 1, visibility: .tombstone),
                try fragment(baseOperation, start: 2, length: 1)
            ]
        ))
    }

    func testIncorporatingSameAnchorInsertionsConvergesAcrossAllPermutations() throws {
        let baseOperation = operation(0)
        let operations = [operation(1), operation(2), operation(3)]
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let anchor = try SyncOperationAnchor.between(left: left, right: right)
        let expectedRuns = [
            try run(baseOperation, text: "AB"),
            try run(operation(1), left: left, right: right, text: "1"),
            try run(operation(2), left: left, right: right, text: "2"),
            try run(operation(3), left: left, right: right, text: "3")
        ]
        let expectedFragments = [
            try fragment(baseOperation, start: 0, length: 1),
            try fragment(operation(3), length: 1),
            try fragment(operation(2), length: 1),
            try fragment(operation(1), length: 1),
            try fragment(baseOperation, start: 1, length: 1)
        ]
        var completedStates: [SyncTextSequenceState] = []

        for permutation in permutations(operations) {
            var state = try rootState(operationID: baseOperation, text: "AB")
            for operationID in permutation {
                state = try state.incorporating(
                    insert: insertPayload(operationID, anchor: anchor),
                    insertedText: String(operationID.localCounter)
                )
            }
            XCTAssertEqual(state.runs, expectedRuns)
            XCTAssertEqual(state.fragments, expectedFragments)
            XCTAssertEqual(state.visibleText, "A321B")
            XCTAssertEqual(state.visibleUTF16Count, 5)
            XCTAssertEqual(state.tombstonedUTF16Count, 0)
            completedStates.append(state)
        }

        XCTAssertEqual(completedStates.count, 6)
        for state in completedStates.dropFirst() {
            XCTAssertEqual(state, completedStates[0])
        }
    }

    func testPackageGeneratedSiblingBoundaryPayloadRoundTripsWithoutRewriting() throws {
        let baseOperation = operation(0)
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let sharedAnchor = try SyncOperationAnchor.between(left: left, right: right)
        var original = try rootState(operationID: baseOperation, text: "AB")
        for sibling in [operation(1), operation(2)] {
            original = try original.incorporating(
                insert: insertPayload(sibling, anchor: sharedAnchor),
                insertedText: String(sibling.localCounter)
            )
        }
        XCTAssertEqual(original.visibleText, "A21B")

        let incomingOperation = operation(10)
        let payload = try original.insertOperationPayload(
            operationID: incomingOperation,
            atVisibleUTF16Offset: 2
        )
        let expectedAnchor = try SyncOperationAnchor.between(
            left: element(operation(2), 0),
            right: right
        )
        XCTAssertEqual(payload.anchor, expectedAnchor)

        let replacement = try original.incorporating(
            insert: payload,
            insertedText: "X"
        )

        XCTAssertEqual(replacement.visibleText, "A2X1B")
        let insertedRun = try XCTUnwrap(
            replacement.runs.first(where: { $0.operationID == incomingOperation })
        )
        XCTAssertEqual(insertedRun.origin.leftElementID, payload.anchor.leftElementID)
        XCTAssertEqual(insertedRun.origin.rightElementID, payload.anchor.rightElementID)
        XCTAssertEqual(original.visibleText, "A21B")
    }

    func testCanonicalSiblingBoundaryPayloadConvergesAcrossEquivalentStatesAndPeerReplay() throws {
        let baseOperation = operation(0)
        let operations = [operation(1), operation(2), operation(3)]
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let sharedAnchor = try SyncOperationAnchor.between(left: left, right: right)
        var equivalentStates: [SyncTextSequenceState] = []

        for permutation in permutations(operations) {
            var state = try rootState(operationID: baseOperation, text: "AB")
            for operationID in permutation {
                state = try state.incorporating(
                    insert: insertPayload(operationID, anchor: sharedAnchor),
                    insertedText: String(operationID.localCounter)
                )
            }
            equivalentStates.append(state)
        }

        for state in equivalentStates.dropFirst() {
            XCTAssertEqual(state, equivalentStates[0])
        }

        let incomingOperation = operation(10)
        let payloads = try equivalentStates.map {
            try $0.insertOperationPayload(
                operationID: incomingOperation,
                atVisibleUTF16Offset: 3
            )
        }
        let expectedAnchor = try SyncOperationAnchor.between(
            left: element(operation(2), 0),
            right: right
        )
        XCTAssertTrue(payloads.allSatisfy { $0.anchor == expectedAnchor })

        let canonicalPayload = try XCTUnwrap(payloads.first)
        let completed = try equivalentStates.map {
            try $0.incorporating(insert: canonicalPayload, insertedText: "X")
        }
        XCTAssertEqual(completed[0].visibleText, "A32X1B")
        for state in completed.dropFirst() {
            XCTAssertEqual(state, completed[0])
        }

        var reconstructedPeer = try rootState(operationID: baseOperation, text: "AB")
        for operationID in operations.reversed() {
            reconstructedPeer = try reconstructedPeer.incorporating(
                insert: insertPayload(operationID, anchor: sharedAnchor),
                insertedText: String(operationID.localCounter)
            )
        }
        let peerResult = try reconstructedPeer.incorporating(
            insert: canonicalPayload,
            insertedText: "X"
        )
        XCTAssertEqual(peerResult, completed[0])
        XCTAssertEqual(peerResult.visibleUTF16Count, completed[0].visibleUTF16Count)
        XCTAssertEqual(peerResult.tombstonedUTF16Count, completed[0].tombstonedUTF16Count)
    }

    func testCanonicalCaptureUsesTrailingTombstonedDescendantExitGap() throws {
        let baseOperation = operation(0)
        let parentOperation = operation(2)
        let childOperation = operation(99)
        let siblingOperation = operation(1)
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let sharedAnchor = try SyncOperationAnchor.between(left: left, right: right)
        let parentElement = try element(parentOperation, 0)
        let childElement = try element(childOperation, 0)

        let runs = [
            try run(baseOperation, text: "AB"),
            try run(siblingOperation, left: left, right: right, text: "S"),
            try run(parentOperation, left: left, right: right, text: "P"),
            try run(childOperation, left: parentElement, right: right, text: "C")
        ]
        let original = try SyncTextSequenceState(
            runs: runs,
            fragments: [
                try fragment(baseOperation, start: 0, length: 1),
                try fragment(parentOperation, length: 1),
                try fragment(childOperation, length: 1, visibility: .tombstone),
                try fragment(siblingOperation, length: 1),
                try fragment(baseOperation, start: 1, length: 1)
            ]
        )
        XCTAssertEqual(original.visibleText, "APSB")

        let payload = try original.insertOperationPayload(
            operationID: operation(100),
            atVisibleUTF16Offset: 2
        )
        XCTAssertEqual(
            payload.anchor,
            try .between(left: childElement, right: right)
        )
        let replacement = try original.incorporating(
            insert: payload,
            insertedText: "X"
        )
        XCTAssertEqual(replacement.visibleText, "APXSB")
        XCTAssertEqual(replacement.visibility(of: childElement), .tombstone)
        XCTAssertEqual(replacement.tombstonedUTF16Count, 1)
    }

    func testIncorporatingDescendantAfterDependenciesPreservesSubtreeContiguity() throws {
        let baseOperation = operation(0)
        let siblingOperation = operation(1)
        let parentOperation = operation(2)
        let childOperation = operation(99)
        let left = try element(baseOperation, 0)
        let right = try element(baseOperation, 1)
        let sharedAnchor = try SyncOperationAnchor.between(left: left, right: right)
        let base = try rootState(operationID: baseOperation, text: "AB")

        let withParent = try base.incorporating(
            insert: insertPayload(parentOperation, anchor: sharedAnchor),
            insertedText: "P"
        )
        let withChild = try withParent.incorporating(
            insert: insertPayload(
                childOperation,
                anchor: try .between(
                    left: element(parentOperation, 0),
                    right: right
                )
            ),
            insertedText: "C"
        )
        let replacement = try withChild.incorporating(
            insert: insertPayload(siblingOperation, anchor: sharedAnchor),
            insertedText: "S"
        )

        XCTAssertEqual(replacement.visibleText, "APCSB")
        XCTAssertEqual(
            replacement.fragments.map(\.operationID),
            [baseOperation, parentOperation, childOperation, siblingOperation, baseOperation]
        )
    }

    func testIncorporatingChildBeforeParentReturnsMissingDependencyWithoutMutation() throws {
        let baseOperation = operation(0)
        let missingParent = operation(10)
        let childOperation = operation(11)
        let original = try rootState(operationID: baseOperation, text: "AB")
        let missingEndpoint = try element(missingParent, 0)
        let right = try element(baseOperation, 1)
        let payload = insertPayload(
            childOperation,
            anchor: try .between(left: missingEndpoint, right: right)
        )

        assertStateError(.missingAnchorDependency(missingEndpoint)) {
            _ = try original.incorporating(insert: payload, insertedText: "C")
        }
        assertUnchanged(
            original,
            from: try rootState(operationID: baseOperation, text: "AB")
        )
    }

    func testIncorporatingDistinguishesMissingOperationFromOutOfBoundsElement() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "A")
        let missing = try element(operation(20), 0)
        let outOfBounds = try element(baseOperation, 1)

        assertStateError(.missingAnchorDependency(missing)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .before(missing)),
                insertedText: "M"
            )
        }
        assertStateError(.anchorElementOutOfBounds(outOfBounds)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .before(outOfBounds)),
                insertedText: "O"
            )
        }
        assertStateError(.missingAnchorDependency(missing)) {
            _ = try original.incorporating(
                insert: insertPayload(
                    operation(1),
                    anchor: try .between(left: missing, right: outOfBounds)
                ),
                insertedText: "L"
            )
        }
        let validLeft = try element(baseOperation, 0)
        assertStateError(.missingAnchorDependency(missing)) {
            _ = try original.incorporating(
                insert: insertPayload(
                    operation(1),
                    anchor: try .between(left: validLeft, right: missing)
                ),
                insertedText: "R"
            )
        }
        assertUnchanged(
            original,
            from: try rootState(operationID: baseOperation, text: "A")
        )
    }

    func testIncorporatingRejectsSelfReferentialAnchorWithoutMutation() throws {
        let baseOperation = operation(0)
        let incomingOperation = operation(1)
        let missingOperation = operation(50)
        let original = try rootState(operationID: baseOperation, text: "A")
        let incomingEndpoint = try element(incomingOperation, 0)
        let missingEndpoint = try element(missingOperation, 0)
        let expected = SyncTextSequenceStateError.selfOrigin(incomingOperation)
        let mixedAnchors = [
            try SyncOperationAnchor.between(
                left: missingEndpoint,
                right: incomingEndpoint
            ),
            try SyncOperationAnchor.between(
                left: incomingEndpoint,
                right: missingEndpoint
            )
        ]

        for anchor in mixedAnchors {
            assertStateError(expected) {
                _ = try original.incorporating(
                    insert: insertPayload(incomingOperation, anchor: anchor),
                    insertedText: "X"
                )
            }
            assertUnchanged(
                original,
                from: try rootState(operationID: baseOperation, text: "A")
            )
        }
    }

    func testIncorporatingDistinguishesReversedAndNonDurableBetweenEndpoints() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "ABC")
        let first = try element(baseOperation, 0)
        let second = try element(baseOperation, 1)
        let third = try element(baseOperation, 2)

        assertStateError(.betweenAnchorEndpointsReversed(left: third, right: first)) {
            _ = try original.incorporating(
                insert: insertPayload(
                    operation(1),
                    anchor: try .between(left: third, right: first)
                ),
                insertedText: "R"
            )
        }
        assertStateError(.anchorGapNotDurable(left: first, right: third)) {
            _ = try original.incorporating(
                insert: insertPayload(
                    operation(1),
                    anchor: try .between(left: first, right: third)
                ),
                insertedText: "N"
            )
        }
        XCTAssertNoThrow(try original.incorporating(
            insert: insertPayload(
                operation(1),
                anchor: try .between(left: first, right: second)
            ),
            insertedText: "A"
        ))
    }

    func testIncorporatingRejectsNonDurableOneSidedClaims() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "ABC")
        let first = try element(baseOperation, 0)
        let second = try element(baseOperation, 1)
        let third = try element(baseOperation, 2)

        assertStateError(.anchorGapNotDurable(left: nil, right: second)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .before(second)),
                insertedText: "B"
            )
        }
        assertStateError(.anchorGapNotDurable(left: second, right: nil)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .after(second)),
                insertedText: "A"
            )
        }
        XCTAssertNoThrow(try original.incorporating(
            insert: insertPayload(operation(1), anchor: .before(first)),
            insertedText: "L"
        ))
        XCTAssertNoThrow(try original.incorporating(
            insert: insertPayload(operation(1), anchor: .after(third)),
            insertedText: "T"
        ))
    }

    func testIncorporatingEmptyRootGapInsertionsConvergesAcrossAllPermutations() throws {
        let operations = [operation(1), operation(2), operation(3)]
        let expectedRuns = [
            try run(operation(1), text: "1"),
            try run(operation(2), text: "2"),
            try run(operation(3), text: "3")
        ]
        let expectedFragments = [
            try fragment(operation(3), length: 1),
            try fragment(operation(2), length: 1),
            try fragment(operation(1), length: 1)
        ]
        var completedStates: [SyncTextSequenceState] = []

        for permutation in permutations(operations) {
            var state = SyncTextSequenceState.empty
            for operationID in permutation {
                state = try state.incorporating(
                    insert: insertPayload(operationID, anchor: .empty),
                    insertedText: String(operationID.localCounter)
                )
            }
            XCTAssertEqual(state.runs, expectedRuns)
            XCTAssertEqual(state.fragments, expectedFragments)
            XCTAssertEqual(state.visibleText, "321")
            XCTAssertEqual(state.visibleUTF16Count, 3)
            XCTAssertEqual(state.tombstonedUTF16Count, 0)
            completedStates.append(state)
        }

        XCTAssertEqual(completedStates.count, 6)
        for state in completedStates.dropFirst() {
            XCTAssertEqual(state, completedStates[0])
        }
    }

    func testIncorporatingUsesRoleSpecificSurrogatePairBoundaries() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "😀")
        let firstCodeUnit = try element(baseOperation, 0)
        let finalCodeUnit = try element(baseOperation, 1)

        let leading = try original.incorporating(
            insert: insertPayload(operation(1), anchor: .before(firstCodeUnit)),
            insertedText: "L"
        )
        let trailing = try original.incorporating(
            insert: insertPayload(operation(1), anchor: .after(finalCodeUnit)),
            insertedText: "T"
        )
        XCTAssertEqual(leading.visibleText, "L😀")
        XCTAssertEqual(trailing.visibleText, "😀T")

        assertStateError(.originSplitsSurrogatePair(firstCodeUnit)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .after(firstCodeUnit)),
                insertedText: "X"
            )
        }
        assertStateError(.originSplitsSurrogatePair(finalCodeUnit)) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .before(finalCodeUnit)),
                insertedText: "X"
            )
        }
        assertUnchanged(
            original,
            from: try rootState(operationID: baseOperation, text: "😀")
        )
    }

    func testIncorporatingRejectsDuplicateOperationAndEmptyInsertedText() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "A")

        assertStateError(.duplicateRun(baseOperation)) {
            _ = try original.incorporating(
                insert: insertPayload(baseOperation, anchor: .empty),
                insertedText: "D"
            )
        }
        assertStateError(.emptyRunText(baseOperation)) {
            _ = try original.incorporating(
                insert: insertPayload(baseOperation, anchor: .empty),
                insertedText: ""
            )
        }
        assertStateError(.emptyRunText(operation(1))) {
            _ = try original.incorporating(
                insert: insertPayload(operation(1), anchor: .empty),
                insertedText: ""
            )
        }
        assertUnchanged(
            original,
            from: try rootState(operationID: baseOperation, text: "A")
        )
    }

    func testIncorporatingMissingAndImpossibleEndpointsNeverUseUnknownOrigin() throws {
        let baseOperation = operation(0)
        let original = try rootState(operationID: baseOperation, text: "A")
        let missing = try element(operation(40), 0)
        let impossible = try element(baseOperation, 5)
        var observed: [SyncTextSequenceStateError] = []

        for endpoint in [missing, impossible] {
            do {
                _ = try original.incorporating(
                    insert: insertPayload(operation(1), anchor: .before(endpoint)),
                    insertedText: "X"
                )
                XCTFail("Expected endpoint failure")
            } catch let error as SyncTextSequenceStateError {
                observed.append(error)
            }
        }

        XCTAssertEqual(observed, [
            .missingAnchorDependency(missing),
            .anchorElementOutOfBounds(impossible)
        ])
        XCTAssertFalse(observed.contains(.unknownOrigin(missing)))
        XCTAssertFalse(observed.contains(.unknownOrigin(impossible)))
    }

    func testLargeSameAnchorIncorporationUsesIterativeProjection() throws {
        let runCount = 12_000
        var runs: [SyncTextSequenceRun] = []
        runs.reserveCapacity(runCount)
        for counter in 0..<runCount {
            runs.append(try run(operation(UInt64(counter)), text: "x"))
        }
        let fragments = try runs.reversed().map {
            try fragment($0.operationID, length: 1)
        }
        let original = try SyncTextSequenceState(runs: runs, fragments: fragments)
        let incomingOperation = operation(UInt64(runCount))

        let replacement = try original.incorporating(
            insert: insertPayload(incomingOperation, anchor: .empty),
            insertedText: "y"
        )

        XCTAssertEqual(replacement.runs.count, runCount + 1)
        XCTAssertEqual(replacement.fragments.count, runCount + 1)
        XCTAssertEqual(replacement.fragments.first?.operationID, incomingOperation)
        XCTAssertEqual(replacement.fragments.last?.operationID, operation(0))
        XCTAssertEqual(replacement.visibleUTF16Count, runCount + 1)
        XCTAssertEqual(replacement.tombstonedUTF16Count, 0)
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.processedFrames,
            (runCount + 1) * 4 + 1
        )
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.gapIndexLookups,
            (runCount + 1) * 2 + 1
        )
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.comparedSpans,
            (runCount + 1) * 2
        )
        XCTAssertEqual(original.runs, runs)
        XCTAssertEqual(original.fragments, fragments)
        XCTAssertEqual(original.visibleUTF16Count, runCount)
    }

    func testLargeCanonicalAnchorResolutionUsesBoundedLinearWork() throws {
        let runCount = 12_000
        var runs: [SyncTextSequenceRun] = []
        runs.reserveCapacity(runCount)
        for counter in 0..<runCount {
            runs.append(try run(operation(UInt64(counter)), text: "x"))
        }
        let fragments = try runs.reversed().map {
            try fragment($0.operationID, length: 1)
        }
        let state = try SyncTextSequenceState(runs: runs, fragments: fragments)

        let result = try state.operationAnchorWithMetrics(
            atVisibleUTF16Offset: runCount / 2
        )

        XCTAssertNotEqual(result.anchor, .empty)
        XCTAssertEqual(result.metrics.indexedRuns, runCount)
        XCTAssertLessThanOrEqual(result.metrics.declaredOrigins, runCount)
        XCTAssertLessThanOrEqual(result.metrics.visitedFragments, runCount)
        XCTAssertLessThanOrEqual(result.metrics.durableGapChecks, 2)
    }

    func testDeepChainIncorporationUsesIterativeProjection() throws {
        let runCount = 12_000
        var runs: [SyncTextSequenceRun] = []
        runs.reserveCapacity(runCount)
        for counter in 0..<runCount {
            let operationID = operation(UInt64(counter))
            let right = counter == 0
                ? nil
                : try element(operation(UInt64(counter - 1)), 0)
            runs.append(try run(operationID, right: right, text: "x"))
        }
        let fragments = try runs.reversed().map {
            try fragment($0.operationID, length: 1)
        }
        let original = try SyncTextSequenceState(runs: runs, fragments: fragments)
        let incomingOperation = operation(UInt64(runCount))
        let previousFirst = try element(operation(UInt64(runCount - 1)), 0)

        let replacement = try original.incorporating(
            insert: insertPayload(incomingOperation, anchor: .before(previousFirst)),
            insertedText: "y"
        )

        XCTAssertEqual(replacement.runs.count, runCount + 1)
        XCTAssertEqual(replacement.fragments.count, runCount + 1)
        XCTAssertEqual(replacement.fragments.first?.operationID, incomingOperation)
        XCTAssertEqual(replacement.fragments.last?.operationID, operation(0))
        XCTAssertEqual(replacement.visibleUTF16Count, runCount + 1)
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.processedFrames,
            (runCount + 1) * 4 + 1
        )
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.gapIndexLookups,
            (runCount + 1) * 2 + 1
        )
        XCTAssertLessThanOrEqual(
            replacement.validationMetrics.comparedSpans,
            (runCount + 1) * 2
        )
        XCTAssertEqual(original.runs, runs)
        XCTAssertEqual(original.fragments, fragments)
        XCTAssertEqual(original.visibleUTF16Count, runCount)
    }

    private func operation(
        _ counter: UInt64,
        deviceID: String = "01000000-0000-0000-0000-000000000000"
    ) -> SyncOperationID {
        SyncOperationID(
            deviceID: UUID(uuidString: deviceID)!,
            localCounter: counter
        )
    }

    private func element(
        _ operationID: SyncOperationID,
        _ offset: Int
    ) throws -> SyncTextElementID {
        try SyncTextElementID(operationID: operationID, elementOffset: offset)
    }

    private func insertPayload(
        _ operationID: SyncOperationID,
        anchor: SyncOperationAnchor
    ) -> SyncTextInsertOperationPayload {
        SyncTextInsertOperationPayload(operationID: operationID, anchor: anchor)
    }

    private func run(
        _ operationID: SyncOperationID,
        left: SyncTextElementID? = nil,
        right: SyncTextElementID? = nil,
        text: String
    ) throws -> SyncTextSequenceRun {
        try SyncTextSequenceRun(
            operationID: operationID,
            origin: SyncTextInsertionOrigin(
                leftElementID: left,
                rightElementID: right
            ),
            text: text
        )
    }

    private func fragment(
        _ operationID: SyncOperationID,
        start: Int = 0,
        length: Int,
        visibility: SyncTextSequenceElementVisibility = .visible
    ) throws -> SyncTextSequenceFragment {
        try SyncTextSequenceFragment(
            operationID: operationID,
            startOffset: start,
            utf16Length: length,
            visibility: visibility
        )
    }

    private func rootState(
        operationID: SyncOperationID,
        text: String
    ) throws -> SyncTextSequenceState {
        try SyncTextSequenceState(
            runs: [try run(operationID, text: text)],
            fragments: [try fragment(
                operationID,
                length: text.utf16.count
            )]
        )
    }

    private func assertStateError(
        _ expected: SyncTextSequenceStateError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SyncTextSequenceStateError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertUnchanged(
        _ actual: SyncTextSequenceState,
        from expected: SyncTextSequenceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.runs, expected.runs, file: file, line: line)
        XCTAssertEqual(actual.fragments, expected.fragments, file: file, line: line)
        XCTAssertEqual(actual.visibleText, expected.visibleText, file: file, line: line)
        XCTAssertEqual(
            actual.visibleUTF16Count,
            expected.visibleUTF16Count,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.tombstonedUTF16Count,
            expected.tombstonedUTF16Count,
            file: file,
            line: line
        )
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let selected = remaining.remove(at: index)
            return permutations(remaining).map { [selected] + $0 }
        }
    }
}
