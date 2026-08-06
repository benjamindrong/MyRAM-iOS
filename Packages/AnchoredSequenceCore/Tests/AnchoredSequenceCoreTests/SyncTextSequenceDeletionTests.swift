@testable import AnchoredSequenceCore
import Foundation
import XCTest

final class SyncTextSequenceDeletionTests: XCTestCase {
    private let deviceID = UUID(
        uuidString: "17600000-0000-0000-0000-000000000001"
    )!

    func testMiddleDeletionCreatesTombstoneWithoutChangingRuns() throws {
        let base = operation(0)
        let state = try rootState(base, text: "ABCD")
        let original = state
        let payload = try deletePayload(
            operation(100),
            spans: [span(base, start: 1, length: 2)]
        )

        let result = try state.incorporating(delete: payload)

        XCTAssertEqual(result.runs, state.runs)
        XCTAssertEqual(
            result.fragments,
            [
                try fragment(base, start: 0, length: 1),
                try fragment(base, start: 1, length: 2, visibility: .tombstone),
                try fragment(base, start: 3, length: 1)
            ]
        )
        XCTAssertEqual(result.visibleText, "AD")
        XCTAssertEqual(result.visibleUTF16Count, 2)
        XCTAssertEqual(result.tombstonedUTF16Count, 2)
        XCTAssertEqual(state, original)
    }

    func testRepeatedAndPartiallyRepeatedDeletionIsIdempotent() throws {
        let base = operation(0)
        let state = try rootState(base, text: "ABCD")
        let firstPayload = try deletePayload(
            operation(100),
            spans: [span(base, start: 1, length: 2)]
        )
        let first = try state.incorporating(delete: firstPayload)

        let repeated = try first.incorporating(delete: firstPayload)
        XCTAssertEqual(repeated, first)

        let extendingPayload = try deletePayload(
            operation(101),
            spans: [span(base, start: 1, length: 3)]
        )
        let extended = try first.incorporating(delete: extendingPayload)
        XCTAssertEqual(extended.visibleText, "A")
        XCTAssertEqual(extended.visibleUTF16Count, 1)
        XCTAssertEqual(extended.tombstonedUTF16Count, 3)

        XCTAssertEqual(
            try extended.incorporating(delete: extendingPayload),
            extended
        )
    }

    func testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder() throws {
        let base = operation(0)
        let inserted = operation(1)
        let state = try rootState(base, text: "AB")
        let deletedElement = try element(base, 1)
        let delete = try deletePayload(
            operation(100),
            spans: [span(base, start: 1, length: 1)]
        )
        let insert = SyncTextInsertOperationPayload(
            operationID: inserted,
            anchor: .after(deletedElement)
        )

        let insertThenDelete = try state
            .incorporating(insert: insert, insertedText: "x")
            .incorporating(delete: delete)
        let deleteThenInsert = try state
            .incorporating(delete: delete)
            .incorporating(insert: insert, insertedText: "x")

        XCTAssertEqual(insertThenDelete, deleteThenInsert)
        XCTAssertEqual(insertThenDelete.visibleText, "Ax")
        XCTAssertEqual(insertThenDelete.visibleUTF16Count, 2)
        XCTAssertEqual(insertThenDelete.tombstonedUTF16Count, 1)
        XCTAssertEqual(
            insertThenDelete.visibility(of: deletedElement),
            .tombstone
        )
        XCTAssertEqual(
            insertThenDelete.visibility(of: try element(inserted, 0)),
            .visible
        )
    }

    func testCapturedIdentityDeletionIgnoresLaterInsertedIdentity() throws {
        let base = operation(0)
        let inserted = operation(1)
        let state = try rootState(base, text: "AB")
        let delete = try state.deleteOperationPayload(
            operationID: operation(100),
            inVisibleUTF16Range: 0..<1
        )
        let insert = SyncTextInsertOperationPayload(
            operationID: inserted,
            anchor: .before(try element(base, 0))
        )

        let result = try state
            .incorporating(insert: insert, insertedText: "x")
            .incorporating(delete: delete)

        XCTAssertEqual(result.visibleText, "xB")
        XCTAssertEqual(
            result.visibility(of: try element(inserted, 0)),
            .visible
        )
        XCTAssertEqual(
            result.visibility(of: try element(base, 0)),
            .tombstone
        )
    }

    func testDeletionErrorsAreExactAndLeaveInputUnchanged() throws {
        let base = operation(0)
        let state = try rootState(base, text: "AB")
        let original = state
        let missing = operation(99)
        let missingPayload = try deletePayload(
            operation(100),
            spans: [span(missing, start: 0, length: 1)]
        )
        assertError(
            .missingDeleteDependency(missing),
            payload: missingPayload,
            state: state
        )

        let outOfBounds = try span(base, start: 1, length: 2)
        assertError(
            .deleteTargetRangeExceedsRun(outOfBounds),
            payload: try deletePayload(operation(101), spans: [outOfBounds]),
            state: state
        )

        let unicodeState = try rootState(base, text: "😀A")
        let splitting = try span(base, start: 1, length: 1)
        assertError(
            .deleteTargetSplitsSurrogatePair(splitting, offset: 1),
            payload: try deletePayload(operation(102), spans: [splitting]),
            state: unicodeState
        )

        XCTAssertEqual(state, original)
    }

    func testPreflightUsesSerializedFirstFailureAndNeverPartiallyDeletes() throws {
        let base = operation(0)
        let missing = operation(99)
        let state = try rootState(base, text: "AB")
        let original = state
        let valid = try span(base, start: 0, length: 1)
        let invalid = try span(missing, start: 0, length: 1)
        let payload = try deletePayload(
            operation(100),
            spans: [valid, invalid]
        )

        assertError(
            .missingDeleteDependency(missing),
            payload: payload,
            state: state
        )
        XCTAssertEqual(state, original)

        let boundsFirst = try span(base, start: 1, length: 2)
        let secondPayload = try deletePayload(
            operation(101),
            spans: [boundsFirst, invalid]
        )
        assertError(
            .deleteTargetRangeExceedsRun(boundsFirst),
            payload: secondPayload,
            state: state
        )
        XCTAssertEqual(state, original)
    }

    func testCaptureExcludesExistingTombstones() throws {
        let base = operation(0)
        let state = try SyncTextSequenceState(
            runs: [try run(base, text: "ABC")],
            fragments: [
                try fragment(base, start: 0, length: 1),
                try fragment(base, start: 1, length: 1, visibility: .tombstone),
                try fragment(base, start: 2, length: 1)
            ]
        )

        let payload = try state.deleteOperationPayload(
            operationID: operation(100),
            inVisibleUTF16Range: 0..<2
        )

        XCTAssertEqual(
            payload.deletedElementIDSpans,
            [
                try span(base, start: 0, length: 1),
                try span(base, start: 2, length: 1)
            ]
        )
    }

    func testLargeFragmentedDeletionUsesBoundedIterativeWork() throws {
        let base = operation(0)
        let count = 2_000
        let text = String(repeating: "a", count: count)
        let fragments = try (0..<count).map { index in
            try fragment(
                base,
                start: index,
                length: 1,
                visibility: index.isMultiple(of: 2) ? .visible : .tombstone
            )
        }
        let state = try SyncTextSequenceState(
            runs: [try run(base, text: text)],
            fragments: fragments
        )
        let targets = try stride(from: 0, to: count, by: 2).map {
            try span(base, start: $0, length: 1)
        }
        let payload = try deletePayload(operation(100), spans: targets)

        let result = try state.incorporatingDeleteWithMetrics(payload)

        XCTAssertEqual(result.state.visibleText, "")
        XCTAssertEqual(result.state.visibleUTF16Count, 0)
        XCTAssertEqual(result.state.tombstonedUTF16Count, count)
        XCTAssertEqual(result.state.fragments.count, 1)
        XCTAssertEqual(result.metrics.preflightedSpans, count / 2)
        XCTAssertEqual(result.metrics.visitedFragments, count)
        XCTAssertEqual(result.metrics.targetIntersections, count / 2)
        XCTAssertEqual(result.metrics.emittedFragments, 1)
    }

    private func operation(_ counter: UInt64) -> SyncOperationID {
        SyncOperationID(deviceID: deviceID, localCounter: counter)
    }

    private func element(
        _ operationID: SyncOperationID,
        _ offset: Int
    ) throws -> SyncTextElementID {
        try SyncTextElementID(
            operationID: operationID,
            elementOffset: offset
        )
    }

    private func span(
        _ operationID: SyncOperationID,
        start: Int,
        length: Int
    ) throws -> SyncTextElementIDSpan {
        try SyncTextElementIDSpan(
            operationID: operationID,
            startOffset: start,
            utf16Length: length
        )
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
        _ operationID: SyncOperationID,
        text: String
    ) throws -> SyncTextSequenceState {
        try SyncTextSequenceState(
            runs: [try run(operationID, text: text)],
            fragments: [
                try fragment(
                    operationID,
                    length: text.utf16.count
                )
            ]
        )
    }

    private func deletePayload(
        _ operationID: SyncOperationID,
        spans: [SyncTextElementIDSpan]
    ) throws -> SyncTextDeleteOperationPayload {
        try SyncTextDeleteOperationPayload(
            operationID: operationID,
            deletedElementIDSpans: spans
        )
    }

    private func assertError(
        _ expected: SyncTextSequenceStateError,
        payload: SyncTextDeleteOperationPayload,
        state: SyncTextSequenceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let original = state
        XCTAssertThrowsError(
            try state.incorporating(delete: payload),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                expected,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(state, original, file: file, line: line)
    }
}
