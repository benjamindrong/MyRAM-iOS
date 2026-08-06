@testable import AnchoredSequenceCore
import Foundation
import XCTest

final class SyncTextSequenceDeletionRemediationTests: XCTestCase {
    private let deviceID = UUID(
        uuidString: "17600000-0000-0000-0000-000000000002"
    )!

    func testMultiRunCaptureAndIncorporationTargetsExactIdentities() throws {
        let base = operation(0)
        let inserted = operation(1)
        let initial = try rootState(base, text: "AB")
        let insert = SyncTextInsertOperationPayload(
            operationID: inserted,
            anchor: .after(try element(base, 1))
        )
        let state = try initial.incorporating(
            insert: insert,
            insertedText: "CD"
        )
        XCTAssertEqual(state.visibleText, "ABCD")

        let payload = try state.deleteOperationPayload(
            operationID: operation(100),
            inVisibleUTF16Range: 1..<3
        )
        XCTAssertEqual(
            payload.deletedElementIDSpans,
            [
                try span(base, start: 1, length: 1),
                try span(inserted, start: 0, length: 1)
            ]
        )

        let result = try state.incorporating(delete: payload)

        XCTAssertEqual(result.runs, state.runs)
        XCTAssertEqual(result.visibleText, "AD")
        XCTAssertEqual(result.visibleUTF16Count, 2)
        XCTAssertEqual(result.tombstonedUTF16Count, 2)
        XCTAssertEqual(result.visibility(of: try element(base, 1)), .tombstone)
        XCTAssertEqual(result.visibility(of: try element(inserted, 0)), .tombstone)
        XCTAssertEqual(result.visibility(of: try element(base, 0)), .visible)
        XCTAssertEqual(result.visibility(of: try element(inserted, 1)), .visible)
    }

    func testDeletionRejectsUpperBoundarySplittingSurrogatePair() throws {
        let base = operation(0)
        let state = try rootState(base, text: "😀A")
        let splitting = try span(base, start: 0, length: 1)
        let payload = try deletePayload(
            operation(100),
            spans: [splitting]
        )

        assertError(
            .deleteTargetSplitsSurrogatePair(splitting, offset: 1),
            payload: payload,
            state: state
        )
    }

    func testFullRunDeletionRetainsRunAndAllElementIdentities() throws {
        let base = operation(0)
        let state = try rootState(base, text: "AB")
        let payload = try deletePayload(
            operation(100),
            spans: [try span(base, start: 0, length: 2)]
        )

        let result = try state.incorporating(delete: payload)

        XCTAssertEqual(result.runs, state.runs)
        XCTAssertEqual(result.visibleText, "")
        XCTAssertEqual(result.visibleUTF16Count, 0)
        XCTAssertEqual(result.tombstonedUTF16Count, 2)
        XCTAssertEqual(result.fragments.count, 1)
        XCTAssertEqual(result.fragments.first?.visibility, .tombstone)
        XCTAssertEqual(result.visibility(of: try element(base, 0)), .tombstone)
        XCTAssertEqual(result.visibility(of: try element(base, 1)), .tombstone)
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

    private func rootState(
        _ operationID: SyncOperationID,
        text: String
    ) throws -> SyncTextSequenceState {
        try SyncTextSequenceState(
            runs: [
                try SyncTextSequenceRun(
                    operationID: operationID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: nil,
                        rightElementID: nil
                    ),
                    text: text
                )
            ],
            fragments: [
                try SyncTextSequenceFragment(
                    operationID: operationID,
                    startOffset: 0,
                    utf16Length: text.utf16.count,
                    visibility: .visible
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
