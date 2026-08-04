import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncTextSequenceStateTests: XCTestCase {
    func testPublicValuesConstructAVisibleRootState() throws {
        let operationID = operation(0)
        let origin = try SyncTextInsertionOrigin(
            leftElementID: nil,
            rightElementID: nil
        )
        let run = try SyncTextSequenceRun(
            operationID: operationID,
            origin: origin,
            text: "Hello"
        )
        let fragment = try SyncTextSequenceFragment(
            operationID: operationID,
            startOffset: 0,
            utf16Length: 5,
            visibility: .visible
        )
        let state = try SyncTextSequenceState(runs: [run], fragments: [fragment])

        XCTAssertEqual(state.visibleText, "Hello")
        XCTAssertEqual(state.visibleUTF16Count, 5)
        XCTAssertEqual(state.tombstonedUTF16Count, 0)
        XCTAssertEqual(
            try SyncTextElementIDSpan(
                operationID: operationID,
                startOffset: 0,
                utf16Length: 5
            ),
            try state.elementIDSpans(inVisibleUTF16Range: 0..<5).only
        )
    }

    func testEmptyStateHasNoMaterializedContent() {
        XCTAssertEqual(SyncTextSequenceState.empty.visibleText, "")
        XCTAssertEqual(SyncTextSequenceState.empty.visibleUTF16Count, 0)
        XCTAssertEqual(SyncTextSequenceState.empty.tombstonedUTF16Count, 0)
    }

    func testLocalInitializersRejectInvalidOriginsRunsAndRanges() throws {
        let element = try element(operation(0), 0)
        XCTAssertThrowsError(try SyncTextInsertionOrigin(
            leftElementID: element,
            rightElementID: element
        )) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                .identicalOriginEndpoints(element)
            )
        }
        XCTAssertThrowsError(try run(operation(0), text: ""))
        assertStateError(.negativeRangeOffset(-1)) {
            _ = try fragment(operation(0), start: -1, length: 1)
        }
        assertStateError(.nonpositiveRangeLength(0)) {
            _ = try SyncTextElementIDSpan(
                operationID: operation(0),
                startOffset: 0,
                utf16Length: 0
            )
        }
        assertStateError(.nonpositiveRangeLength(-1)) {
            _ = try fragment(operation(0), start: 0, length: -1)
        }
        assertStateError(.rangeOverflow(startOffset: Int.max - 1, utf16Length: 2)) {
            _ = try fragment(operation(0), start: Int.max - 1, length: 2)
        }
        assertStateError(.rangeOverflow(startOffset: Int.max, utf16Length: Int.max)) {
            _ = try SyncTextElementIDSpan(
                operationID: operation(0),
                startOffset: Int.max,
                utf16Length: Int.max
            )
        }
    }

    func testCanonicalOrderUsesRawUUIDBytesThenCounter() {
        let earlyFirstByte = operation(
            9,
            deviceID: "01000000-0000-0000-0000-0000000000ff"
        )
        let lateFirstByte = operation(
            0,
            deviceID: "02000000-0000-0000-0000-000000000000"
        )
        let earlyLastByte = operation(
            9,
            deviceID: "01000000-0000-0000-0000-000000000001"
        )
        let lateLastByte = operation(
            0,
            deviceID: "01000000-0000-0000-0000-0000000000fe"
        )

        XCTAssertTrue(SyncOperationIDCanonicalOrder.isOrderedBefore(
            earlyFirstByte,
            lateFirstByte
        ))
        XCTAssertTrue(SyncOperationIDCanonicalOrder.isOrderedBefore(
            earlyLastByte,
            lateLastByte
        ))
        XCTAssertTrue(SyncOperationIDCanonicalOrder.isOrderedBefore(
            operation(1),
            operation(2)
        ))
        XCTAssertFalse(SyncOperationIDCanonicalOrder.isOrderedBefore(
            operation(2),
            operation(1)
        ))
    }

    func testSameAnchorOrderUsesDescendingCounterThenRawUUIDByteTieBreak() {
        let earlyFirstByte = operation(
            5,
            deviceID: "01000000-0000-0000-0000-0000000000ff"
        )
        let lateFirstByte = operation(
            5,
            deviceID: "02000000-0000-0000-0000-000000000000"
        )
        let earlyLastByte = operation(
            5,
            deviceID: "01000000-0000-0000-0000-000000000001"
        )
        let lateLastByte = operation(
            5,
            deviceID: "01000000-0000-0000-0000-0000000000fe"
        )
        let higherCounterLaterDevice = operation(
            6,
            deviceID: "ff000000-0000-0000-0000-000000000000"
        )
        let lowerCounterEarlierDevice = operation(
            4,
            deviceID: "00000000-0000-0000-0000-000000000000"
        )
        let identicalLHS = operation(7)
        let identicalRHS = operation(7)

        XCTAssertTrue(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            higherCounterLaterDevice,
            lowerCounterEarlierDevice
        ))
        XCTAssertFalse(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            lowerCounterEarlierDevice,
            higherCounterLaterDevice
        ))
        XCTAssertTrue(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            earlyFirstByte,
            lateFirstByte
        ))
        XCTAssertTrue(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            earlyLastByte,
            lateLastByte
        ))
        XCTAssertFalse(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            identicalLHS,
            identicalRHS
        ))
        XCTAssertFalse(SyncOperationIDSameAnchorSiblingOrder.isOrderedBefore(
            identicalRHS,
            identicalLHS
        ))
    }

    func testSameAnchorSiblingOrderingIsIndependentOfInputPermutation() throws {
        let deviceA = "01000000-0000-0000-0000-000000000000"
        let deviceB = "02000000-0000-0000-0000-000000000000"
        let a1 = operation(1, deviceID: deviceA)
        let a3 = operation(3, deviceID: deviceA)
        let b2 = operation(2, deviceID: deviceB)
        let runs = try [
            run(a1, text: "1"),
            run(a3, text: "3"),
            run(b2, text: "2")
        ]
        let expected = [a3, b2, a1]

        for permutation in permutations([0, 1, 2]) {
            let ordered = SyncOperationIDSameAnchorSiblingOrder.orderedRunIndices(
                permutation,
                runs: runs
            )
            XCTAssertEqual(ordered.map { runs[$0].operationID }, expected)
        }
    }

    func testSameAnchorOrderDiffersFromCanonicalRunStorageWithoutChangingRunValidation() throws {
        let deviceA = "01000000-0000-0000-0000-000000000000"
        let deviceB = "02000000-0000-0000-0000-000000000000"
        let a1 = operation(1, deviceID: deviceA)
        let a3 = operation(3, deviceID: deviceA)
        let b2 = operation(2, deviceID: deviceB)
        let runs = try [
            run(a1, text: "1"),
            run(a3, text: "3"),
            run(b2, text: "2")
        ]
        let fragments = try [a3, b2, a1].map { try fragment($0) }
        let state = try SyncTextSequenceState(runs: runs, fragments: fragments)

        XCTAssertEqual(state.runs.map(\.operationID), [a1, a3, b2])
        XCTAssertEqual(state.fragments.map(\.operationID), [a3, b2, a1])
        XCTAssertEqual(state.visibleText, "321")

        assertStateError(.fragmentOrderNotMatchingOrigins) {
            _ = try SyncTextSequenceState(
                runs: runs,
                fragments: [fragment(a1), fragment(a3), fragment(b2)]
            )
        }

        assertStateError(.noncanonicalRunOrder(previous: a3, current: a1)) {
            _ = try SyncTextSequenceState(
                runs: [runs[1], runs[0], runs[2]],
                fragments: fragments
            )
        }
    }

    func testSameAnchorOrderedProjectionProducesDeterministicState() throws {
        let deviceA = "01000000-0000-0000-0000-000000000000"
        let deviceB = "02000000-0000-0000-0000-000000000000"
        let a1 = operation(1, deviceID: deviceA)
        let a3 = operation(3, deviceID: deviceA)
        let b2 = operation(2, deviceID: deviceB)
        let runs = try [
            run(a1, text: "1"),
            run(a3, text: "3"),
            run(b2, text: "2")
        ]
        let expectedOperationIDs = [a3, b2, a1]
        let orderedIndices = SyncOperationIDSameAnchorSiblingOrder.orderedRunIndices(
            [2, 0, 1],
            runs: runs
        )
        XCTAssertEqual(orderedIndices.map { runs[$0].operationID }, expectedOperationIDs)

        let expectedFragments = [
            try fragment(a3),
            try fragment(b2, visibility: .tombstone),
            try fragment(a1)
        ]
        let state = try SyncTextSequenceState(
            runs: runs,
            fragments: expectedFragments
        )

        XCTAssertEqual(state.runs, runs)
        XCTAssertEqual(state.fragments, expectedFragments)
        XCTAssertEqual(state.visibleText, "31")
        XCTAssertEqual(state.visibleUTF16Count, 2)
        XCTAssertEqual(state.tombstonedUTF16Count, 1)
    }

    func testNoncanonicalAndDuplicateRunArraysAreRejected() throws {
        let first = try run(operation(0), text: "a")
        let second = try run(operation(1), text: "b")

        assertStateError(.noncanonicalRunOrder(
            previous: second.operationID,
            current: first.operationID
        )) {
            _ = try SyncTextSequenceState(runs: [second, first], fragments: [])
        }
        assertStateError(.duplicateRun(first.operationID)) {
            _ = try SyncTextSequenceState(runs: [first, first], fragments: [])
        }
    }

    func testBeginningMiddleAndEndOriginsExpandIteratively() throws {
        let parentID = operation(0)
        let beginningID = operation(1)
        let middleID = operation(2)
        let endID = operation(3)
        let parent = try run(parentID, text: "ab")
        let beginning = try run(
            beginningID,
            left: nil,
            right: element(parentID, 0),
            text: "B"
        )
        let middle = try run(
            middleID,
            left: element(parentID, 0),
            right: element(parentID, 1),
            text: "M"
        )
        let end = try run(
            endID,
            left: element(parentID, 1),
            right: nil,
            text: "E"
        )
        let state = try SyncTextSequenceState(
            runs: [parent, beginning, middle, end],
            fragments: [
                fragment(beginningID),
                fragment(parentID, start: 0),
                fragment(middleID),
                fragment(parentID, start: 1),
                fragment(endID)
            ]
        )

        XCTAssertEqual(state.visibleText, "BaMbE")
    }

    func testSameAnchorSiblingSubtreesRemainContiguous() throws {
        let parentID = operation(0)
        let siblingAID = operation(1)
        let siblingBID = operation(2)
        let descendantAID = operation(3)
        let descendantBID = operation(4)
        let parent = try run(parentID, text: "ab")
        let siblingA = try run(
            siblingAID,
            left: element(parentID, 0),
            right: element(parentID, 1),
            text: "A"
        )
        let siblingB = try run(
            siblingBID,
            left: element(parentID, 0),
            right: element(parentID, 1),
            text: "B"
        )
        let descendantA = try run(
            descendantAID,
            left: element(siblingAID, 0),
            right: element(parentID, 1),
            text: "d"
        )
        let descendantB = try run(
            descendantBID,
            left: element(siblingBID, 0),
            right: element(parentID, 1),
            text: "e"
        )
        let expectedFragments = [
            try fragment(parentID, start: 0),
            try fragment(siblingBID),
            try fragment(descendantBID),
            try fragment(siblingAID),
            try fragment(descendantAID),
            try fragment(parentID, start: 1)
        ]
        let state = try SyncTextSequenceState(
            runs: [parent, siblingA, siblingB, descendantA, descendantB],
            fragments: expectedFragments
        )

        XCTAssertEqual(state.fragments, expectedFragments)
        XCTAssertEqual(state.visibleText, "aBeAdb")
    }

    func testFragmentProjectionRejectsSiblingOrderMismatchEvenWithEqualVisibleText() throws {
        let firstID = operation(0)
        let secondID = operation(1)
        let first = try run(firstID, text: "x")
        let second = try run(secondID, text: "x")

        assertStateError(.fragmentOrderNotMatchingOrigins) {
            _ = try SyncTextSequenceState(
                runs: [first, second],
                fragments: [fragment(firstID), fragment(secondID)]
            )
        }
    }

    func testUnknownSelfCyclicAndUnreachableOriginsAreDistinct() throws {
        let parentID = operation(0)
        let childID = operation(1)
        let unknown = try element(operation(99), 0)

        assertStateError(.unknownOrigin(unknown)) {
            _ = try SyncTextSequenceState(
                runs: [try run(parentID, left: unknown, text: "a")],
                fragments: []
            )
        }
        assertStateError(.selfOrigin(parentID)) {
            _ = try SyncTextSequenceState(
                runs: [try run(parentID, left: element(parentID, 0), text: "a")],
                fragments: []
            )
        }

        let cyclicA = try run(
            parentID,
            left: element(childID, 0),
            text: "a"
        )
        let cyclicB = try run(
            childID,
            left: element(parentID, 0),
            text: "b"
        )
        assertStateError(.cyclicOriginDependency) {
            _ = try SyncTextSequenceState(runs: [cyclicA, cyclicB], fragments: [])
        }

        let parent = try run(parentID, text: "ab")
        let unreachable = try run(
            childID,
            left: element(parentID, 0),
            right: nil,
            text: "x"
        )
        assertStateError(.unreachableOriginGap(childID)) {
            _ = try SyncTextSequenceState(runs: [parent, unreachable], fragments: [])
        }
    }

    func testSurrogateOriginsAcceptBeforeAndAfterButRejectInterior() throws {
        let parentID = operation(0)
        let beforeID = operation(1)
        let afterID = operation(2)
        let parent = try run(parentID, text: "😀")
        let before = try run(
            beforeID,
            left: nil,
            right: element(parentID, 0),
            text: "<"
        )
        let after = try run(
            afterID,
            left: element(parentID, 1),
            right: nil,
            text: ">"
        )
        let state = try SyncTextSequenceState(
            runs: [parent, before, after],
            fragments: [
                fragment(beforeID),
                fragment(parentID, length: 2),
                fragment(afterID)
            ]
        )
        XCTAssertEqual(state.visibleText, "<😀>")

        let invalidID = operation(3)
        let splitEndpoint = try element(parentID, 0)
        let invalid = try run(
            invalidID,
            left: splitEndpoint,
            right: element(parentID, 1),
            text: "!"
        )
        assertStateError(.originSplitsSurrogatePair(splitEndpoint)) {
            _ = try SyncTextSequenceState(
                runs: [parent, invalid],
                fragments: []
            )
        }
    }

    func testFragmentValidationRejectsUnknownOversizedSurrogateSplitAndMergeable() throws {
        let operationID = operation(0)
        let emoji = try run(operationID, text: "😀")

        assertStateError(.fragmentReferencesUnknownRun(operation(1))) {
            _ = try SyncTextSequenceState(
                runs: [emoji],
                fragments: [fragment(operation(1))]
            )
        }
        assertStateError(.fragmentRangeExceedsRun(operationID)) {
            _ = try SyncTextSequenceState(
                runs: [emoji],
                fragments: [fragment(operationID, length: 3)]
            )
        }
        assertStateError(.fragmentSplitsSurrogatePair(operationID, offset: 1)) {
            _ = try SyncTextSequenceState(
                runs: [emoji],
                fragments: [fragment(operationID, length: 1)]
            )
        }

        let text = try run(operationID, text: "ab")
        assertStateError(.mergeableAdjacentFragments(operationID)) {
            _ = try SyncTextSequenceState(
                runs: [text],
                fragments: [
                    fragment(operationID, start: 0),
                    fragment(operationID, start: 1)
                ]
            )
        }
    }

    func testVisibilityMaterializationAnchorsAndRangesAreSurrogateSafe() throws {
        let operationID = operation(0)
        let state = try SyncTextSequenceState(
            runs: [try run(operationID, text: "a😀b")],
            fragments: [
                fragment(operationID, start: 0, length: 1),
                fragment(operationID, start: 1, length: 2, visibility: .tombstone),
                fragment(operationID, start: 3, length: 1)
            ]
        )

        XCTAssertEqual(state.visibleText, "ab")
        XCTAssertEqual(state.visibleUTF16Count, 2)
        XCTAssertEqual(state.tombstonedUTF16Count, 2)
        XCTAssertEqual(state.visibility(of: try element(operationID, 1)), .tombstone)
        XCTAssertEqual(state.visibility(of: try element(operationID, 3)), .visible)
        XCTAssertNil(try state.leftElementID(beforeVisibleUTF16Offset: 0))
        XCTAssertEqual(
            try state.leftElementID(beforeVisibleUTF16Offset: 2),
            try element(operationID, 3)
        )
        XCTAssertEqual(
            state.tombstonedElementIDSpans,
            [try span(operationID, start: 1, length: 2)]
        )

        assertStateError(.visibleOffsetOutOfBounds(3)) {
            _ = try state.leftElementID(beforeVisibleUTF16Offset: 3)
        }

        let visibleEmoji = try SyncTextSequenceState(
            runs: [try run(operationID, text: "😀")],
            fragments: [fragment(operationID, length: 2)]
        )
        assertStateError(.visibleOffsetSplitsSurrogatePair(1)) {
            _ = try visibleEmoji.leftElementID(beforeVisibleUTF16Offset: 1)
        }
        assertStateError(.visibleRangeSplitsSurrogatePair(1)) {
            _ = try visibleEmoji.elementIDSpans(inVisibleUTF16Range: 0..<1)
        }
    }

    func testSelectedSpansDoNotCoalesceAcrossDescendantsOrVisibilityGaps() throws {
        let parentID = operation(0)
        let childID = operation(1)
        let state = try SyncTextSequenceState(
            runs: [
                try run(parentID, text: "ab"),
                try run(
                    childID,
                    left: element(parentID, 0),
                    right: element(parentID, 1),
                    text: "x"
                )
            ],
            fragments: [
                fragment(parentID, start: 0),
                fragment(childID, visibility: .tombstone),
                fragment(parentID, start: 1)
            ]
        )

        XCTAssertEqual(
            try state.elementIDSpans(inVisibleUTF16Range: 0..<2),
            [
                try span(parentID, start: 0),
                try span(parentID, start: 1)
            ]
        )
        XCTAssertEqual(
            state.tombstonedElementIDSpans,
            [try span(childID)]
        )
    }

    func testLargeSameAnchorSiblingSetUsesBoundedIterativeTraversalWork() throws {
        let runCount = 12_000
        var runs: [SyncTextSequenceRun] = []
        runs.reserveCapacity(runCount)
        for counter in 0..<runCount {
            runs.append(try run(operation(UInt64(counter)), text: "x"))
        }
        let fragments = try runs.reversed().map {
            try fragment($0.operationID)
        }

        let state = try SyncTextSequenceState(runs: runs, fragments: fragments)

        XCTAssertEqual(state.fragments.first?.operationID, operation(UInt64(runCount - 1)))
        XCTAssertEqual(state.fragments.last?.operationID, operation(0))
        XCTAssertEqual(state.visibleUTF16Count, runCount)
        XCTAssertEqual(state.visibleText.utf16.count, runCount)
        XCTAssertLessThanOrEqual(state.validationMetrics.processedFrames, runCount * 4 + 1)
        XCTAssertLessThanOrEqual(state.validationMetrics.gapIndexLookups, runCount * 2 + 1)
        XCTAssertLessThanOrEqual(state.validationMetrics.comparedSpans, runCount * 2)
    }

    func testDeepNestedChainUsesBoundedIterativeTraversalWork() throws {
        let runCount = 12_000
        var runs: [SyncTextSequenceRun] = []
        runs.reserveCapacity(runCount)
        for counter in 0..<runCount {
            let operationID = operation(UInt64(counter))
            let right = counter == 0
                ? nil
                : try element(operation(UInt64(counter - 1)), 0)
            runs.append(try run(operationID, left: nil, right: right, text: "x"))
        }
        let fragments = try runs.reversed().map {
            try fragment($0.operationID)
        }

        let state = try SyncTextSequenceState(runs: runs, fragments: fragments)

        XCTAssertEqual(state.visibleUTF16Count, runCount)
        XCTAssertLessThanOrEqual(state.validationMetrics.processedFrames, runCount * 4 + 1)
        XCTAssertLessThanOrEqual(state.validationMetrics.gapIndexLookups, runCount * 2 + 1)
        XCTAssertLessThanOrEqual(state.validationMetrics.comparedSpans, runCount * 2)
    }

    private func permutations<Element>(_ values: [Element]) -> [[Element]] {
        guard let first = values.first else { return [[]] }
        return permutations(Array(values.dropFirst())).flatMap { permutation in
            (0...permutation.count).map { index in
                var result = permutation
                result.insert(first, at: index)
                return result
            }
        }
    }

    private func operation(
        _ counter: UInt64,
        deviceID: String = "00000000-0000-0000-0000-000000000001"
    ) -> SyncOperationID {
        SyncOperationID(deviceID: UUID(uuidString: deviceID)!, localCounter: counter)
    }

    private func element(
        _ operationID: SyncOperationID,
        _ offset: Int
    ) throws -> SyncTextElementID {
        try SyncTextElementID(operationID: operationID, elementOffset: offset)
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
        length: Int = 1,
        visibility: SyncTextSequenceElementVisibility = .visible
    ) throws -> SyncTextSequenceFragment {
        try SyncTextSequenceFragment(
            operationID: operationID,
            startOffset: start,
            utf16Length: length,
            visibility: visibility
        )
    }

    private func span(
        _ operationID: SyncOperationID,
        start: Int = 0,
        length: Int = 1
    ) throws -> SyncTextElementIDSpan {
        try SyncTextElementIDSpan(
            operationID: operationID,
            startOffset: start,
            utf16Length: length
        )
    }

    private func assertStateError(
        _ expected: SyncTextSequenceStateError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
