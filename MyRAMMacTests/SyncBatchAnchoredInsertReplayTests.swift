import AnchoredSequenceCore
import Foundation
import XCTest
@testable import MyRAMMac

final class SyncBatchAnchoredInsertReplayTests: XCTestCase {
    private let noteID = UUID(uuidString: "17530000-0000-0000-0000-000000000001")!
    private let deviceID = UUID(uuidString: "17530000-0000-0000-0000-000000000002")!
    private let modifiedAt = Date(timeIntervalSince1970: 1_753)

    func testEmptyAndMidRunReplayReturnDerivedVisibleTextWithoutMutatingInput() throws {
        let empty = SyncTextSequenceState.empty
        let emptyChange = try change(
            state: empty,
            offset: 0,
            text: "A",
            counter: 10
        )

        let emptyResult = try SyncBatchAnchoredInsertReplay.applying(
            emptyChange,
            to: empty
        )

        XCTAssertEqual(emptyResult.visibleText, "A")
        XCTAssertEqual(emptyResult.sequenceState.visibleText, "A")
        XCTAssertEqual(emptyResult.sequenceState.visibleUTF16Count, 1)
        XCTAssertEqual(empty, .empty)

        let middleState = try state(text: "AB")
        let originalMiddleState = middleState
        let middleChange = try change(
            state: middleState,
            offset: 1,
            text: "x",
            counter: 11
        )

        let middleResult = try SyncBatchAnchoredInsertReplay.applying(
            middleChange,
            to: middleState
        )

        XCTAssertEqual(middleResult.visibleText, "AxB")
        XCTAssertEqual(middleResult.sequenceState.visibleUTF16Count, 3)
        XCTAssertEqual(middleResult.sequenceState.tombstonedUTF16Count, 0)
        XCTAssertEqual(middleState, originalMiddleState)
    }

    func testSameAnchorReplayConvergesAcrossArrivalOrders() throws {
        let base = try state(text: "AB")
        let first = try change(
            state: base,
            offset: 1,
            text: "x",
            counter: 11
        )
        let second = try change(
            state: base,
            offset: 1,
            text: "y",
            counter: 12
        )

        let firstThenSecond = try SyncBatchAnchoredInsertReplay.applying(
            second,
            to: SyncBatchAnchoredInsertReplay.applying(first, to: base).sequenceState
        )
        let secondThenFirst = try SyncBatchAnchoredInsertReplay.applying(
            first,
            to: SyncBatchAnchoredInsertReplay.applying(second, to: base).sequenceState
        )

        XCTAssertEqual(firstThenSecond.sequenceState, secondThenFirst.sequenceState)
        XCTAssertEqual(firstThenSecond.visibleText, "AyxB")
        XCTAssertEqual(secondThenFirst.visibleText, "AyxB")
        XCTAssertEqual(base.visibleText, "AB")
    }

    func testTombstonedAnchorParticipatesWithoutBecomingVisible() throws {
        let parent = operation(1)
        let hidden = operation(2)
        let hiddenElement = try element(hidden, 0)
        let value = try SyncTextSequenceState(
            runs: [
                try run(parent, text: "AB"),
                try run(
                    hidden,
                    left: element(parent, 0),
                    right: element(parent, 1),
                    text: "x"
                )
            ],
            fragments: [
                try fragment(parent, start: 0, length: 1),
                try fragment(
                    hidden,
                    start: 0,
                    length: 1,
                    visibility: .tombstone
                ),
                try fragment(parent, start: 1, length: 1)
            ]
        )
        let original = value
        let inserted = try change(
            state: value,
            offset: 1,
            text: "y",
            counter: 10
        )

        let result = try SyncBatchAnchoredInsertReplay.applying(inserted, to: value)

        XCTAssertEqual(result.visibleText, "AyB")
        XCTAssertEqual(result.sequenceState.tombstonedUTF16Count, 1)
        XCTAssertEqual(result.sequenceState.visibility(of: hiddenElement), .tombstone)
        XCTAssertEqual(value, original)
    }

    func testCompatibilityOffsetAndHashDoNotAffectReplay() throws {
        let value = try state(text: "AB")
        let valid = try change(
            state: value,
            offset: 1,
            text: "x",
            counter: 10
        )
        let expected = try SyncBatchAnchoredInsertReplay.applying(valid, to: value)

        for offset in [-1, Int.max] {
            let altered = try replacingOffset(offset, in: valid)
            XCTAssertEqual(
                try SyncBatchAnchoredInsertReplay.applying(altered, to: value),
                expected
            )
        }

        let matchingHash = SyncBatchContentHash.sha256Hex(for: value.visibleText)
        for hash in [matchingHash, "intentionally-wrong"] {
            let altered = try replacingBaseContentHash(hash, in: valid)
            XCTAssertEqual(
                try SyncBatchAnchoredInsertReplay.applying(altered, to: value),
                expected
            )
        }

        let hashless = try replacingBaseContentHash(nil, in: valid)
        XCTAssertEqual(
            try SyncBatchAnchoredInsertReplay.applying(hashless, to: value),
            expected
        )
    }

    func testCoreErrorsEscapeUnchangedAndPreserveInputState() throws {
        let value = try state(text: "AB")
        let original = value
        let valid = try change(
            state: value,
            offset: 1,
            text: "x",
            counter: 10
        )

        let missingElement = try element(operation(99), 0)
        let missingPayload = SyncTextInsertOperationPayload(
            operationID: valid.payload.operationID,
            anchor: .after(missingElement)
        )
        let missingChange = try replacingPayload(missingPayload, in: valid)
        assertReplayError(
            .missingAnchorDependency(missingElement),
            change: missingChange,
            state: value
        )
        XCTAssertEqual(value, original)

        let outOfBoundsElement = try element(operation(1), 2)
        let outOfBoundsPayload = SyncTextInsertOperationPayload(
            operationID: valid.payload.operationID,
            anchor: .after(outOfBoundsElement)
        )
        let outOfBoundsChange = try replacingPayload(outOfBoundsPayload, in: valid)
        assertReplayError(
            .anchorElementOutOfBounds(outOfBoundsElement),
            change: outOfBoundsChange,
            state: value
        )
        XCTAssertEqual(value, original)
    }

    private func state(text: String) throws -> SyncTextSequenceState {
        guard !text.isEmpty else { return .empty }
        let operationID = operation(1)
        return try SyncTextSequenceState(
            runs: [try run(operationID, text: text)],
            fragments: [
                try fragment(
                    operationID,
                    start: 0,
                    length: text.utf16.count
                )
            ]
        )
    }

    private func change(
        state: SyncTextSequenceState,
        offset: Int,
        text: String,
        counter: UInt64
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        let value = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: state.visibleText),
            operationID: operation(counter),
            state: state
        )
        guard case .noteBodyTextInsertedAnchored(let anchored) = value else {
            XCTFail("Expected anchored inserted change")
            throw TestError.unexpectedChange
        }
        return anchored
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
        start: Int,
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

    private func replacingOffset(
        _ offset: Int,
        in change: SyncBatchNoteBodyTextInsertedAnchoredChange
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        var object = try encodedObject(change)
        object["utf16Offset"] = offset
        return try decodeChange(object)
    }

    private func replacingBaseContentHash(
        _ hash: String?,
        in change: SyncBatchNoteBodyTextInsertedAnchoredChange
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        var object = try encodedObject(change)
        if let hash {
            object["baseContentHash"] = hash
        } else {
            object.removeValue(forKey: "baseContentHash")
        }
        return try decodeChange(object)
    }

    private func replacingPayload(
        _ payload: SyncTextInsertOperationPayload,
        in change: SyncBatchNoteBodyTextInsertedAnchoredChange
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        var object = try encodedObject(change)
        object["payload"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        )
        return try decodeChange(object)
    }

    private func encodedObject(
        _ change: SyncBatchNoteBodyTextInsertedAnchoredChange
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(change)
        )
        return try XCTUnwrap(object as? [String: Any])
    }

    private func decodeChange(
        _ object: [String: Any]
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        try JSONDecoder().decode(
            SyncBatchNoteBodyTextInsertedAnchoredChange.self,
            from: JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        )
    }

    private func assertReplayError(
        _ expected: SyncTextSequenceStateError,
        change: SyncBatchNoteBodyTextInsertedAnchoredChange,
        state: SyncTextSequenceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try SyncBatchAnchoredInsertReplay.applying(change, to: state)
            XCTFail("Expected replay failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private enum TestError: Error {
        case unexpectedChange
    }
}

final class SyncBatchAnchoredDeleteReplayTests: XCTestCase {
    private let noteID = UUID(uuidString: "17620000-0000-0000-0000-000000000001")!
    private let deviceID = UUID(uuidString: "17620000-0000-0000-0000-000000000002")!
    private let modifiedAt = Date(timeIntervalSince1970: 1_762)

    func testIdentityOnlyReplayIgnoresCompatibilityMetadataAndPreservesInput() throws {
        let value = try state(text: "ABCDE")
        let original = value
        let valid = try deleteChange(
            state: value,
            offset: 1,
            length: 2,
            expectedText: "BC",
            counter: 10
        )
        let expected = try SyncBatchAnchoredDeleteReplay.applying(valid, to: value)

        XCTAssertEqual(expected.visibleText, "ADE")
        XCTAssertEqual(expected.sequenceState.visibleUTF16Count, 3)
        XCTAssertEqual(expected.sequenceState.tombstonedUTF16Count, 2)
        XCTAssertEqual(value, original)

        let alteredChanges = [
            try replacingCompatibilityMetadata(
                offset: -1,
                length: Int.max,
                expectedText: "not-the-target",
                baseContentHash: "intentionally-wrong",
                in: valid
            ),
            try replacingCompatibilityMetadata(
                offset: Int.max,
                length: 1,
                expectedText: nil,
                baseContentHash: nil,
                in: valid
            )
        ]

        for altered in alteredChanges {
            let result = try SyncBatchAnchoredDeleteReplay.applying(altered, to: value)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(result.sequenceState.runs, expected.sequenceState.runs)
            XCTAssertEqual(result.sequenceState.fragments, expected.sequenceState.fragments)
            XCTAssertEqual(result.visibleText, expected.visibleText)
            XCTAssertEqual(
                result.sequenceState.visibleUTF16Count,
                expected.sequenceState.visibleUTF16Count
            )
            XCTAssertEqual(
                result.sequenceState.tombstonedUTF16Count,
                expected.sequenceState.tombstonedUTF16Count
            )
            XCTAssertEqual(value, original)
        }
    }

    func testRepeatedAndPartiallyRepeatedReplayIsIdempotent() throws {
        let value = try state(text: "ABCDE")
        let original = value
        let partial = try deleteChange(
            state: value,
            offset: 2,
            length: 1,
            expectedText: "C",
            counter: 10
        )
        let complete = try deleteChange(
            state: value,
            offset: 1,
            length: 3,
            expectedText: "BCD",
            counter: 11
        )

        let partialResult = try SyncBatchAnchoredDeleteReplay.applying(partial, to: value)
        XCTAssertEqual(partialResult.visibleText, "ABDE")
        XCTAssertEqual(value, original)

        let partialState = partialResult.sequenceState
        let originalPartialState = partialState
        let completeResult = try SyncBatchAnchoredDeleteReplay.applying(
            complete,
            to: partialState
        )
        XCTAssertEqual(completeResult.visibleText, "AE")
        XCTAssertEqual(completeResult.sequenceState.tombstonedUTF16Count, 3)
        XCTAssertEqual(partialState, originalPartialState)

        let completeState = completeResult.sequenceState
        let originalCompleteState = completeState
        let repeated = try SyncBatchAnchoredDeleteReplay.applying(
            complete,
            to: completeState
        )
        XCTAssertEqual(repeated, completeResult)
        XCTAssertEqual(completeState, originalCompleteState)
        XCTAssertEqual(value, original)
    }

    func testInsertDeleteReplayConvergesAcrossArrivalOrders() throws {
        let base = try state(text: "AB")
        let original = base
        let inserted = try insertChange(
            state: base,
            offset: 1,
            text: "x",
            counter: 10
        )
        let deleted = try deleteChange(
            state: base,
            offset: 0,
            length: 1,
            expectedText: "A",
            counter: 11
        )

        let insertFirst = try SyncBatchAnchoredInsertReplay.applying(inserted, to: base)
        let insertFirstState = insertFirst.sequenceState
        let originalInsertFirstState = insertFirstState
        let insertThenDelete = try SyncBatchAnchoredDeleteReplay.applying(
            deleted,
            to: insertFirstState
        )

        let deleteFirst = try SyncBatchAnchoredDeleteReplay.applying(deleted, to: base)
        let deleteFirstState = deleteFirst.sequenceState
        let originalDeleteFirstState = deleteFirstState
        let deleteThenInsert = try SyncBatchAnchoredInsertReplay.applying(
            inserted,
            to: deleteFirstState
        )

        XCTAssertEqual(insertThenDelete.sequenceState, deleteThenInsert.sequenceState)
        XCTAssertEqual(insertThenDelete.visibleText, "xB")
        XCTAssertEqual(deleteThenInsert.visibleText, "xB")
        XCTAssertEqual(insertThenDelete.sequenceState.visibleUTF16Count, 2)
        XCTAssertEqual(insertThenDelete.sequenceState.tombstonedUTF16Count, 1)
        XCTAssertEqual(base, original)
        XCTAssertEqual(insertFirstState, originalInsertFirstState)
        XCTAssertEqual(deleteFirstState, originalDeleteFirstState)
    }

    func testInsertionCanUseDeletedAnchor() throws {
        let base = try state(text: "AB")
        let original = base
        let inserted = try insertChange(
            state: base,
            offset: 1,
            text: "x",
            counter: 10
        )
        let deleted = try deleteChange(
            state: base,
            offset: 0,
            length: 1,
            expectedText: "A",
            counter: 11
        )
        let anchorElement = try element(operation(1), 0)

        let deletedResult = try SyncBatchAnchoredDeleteReplay.applying(deleted, to: base)
        let deletedState = deletedResult.sequenceState
        let originalDeletedState = deletedState
        let result = try SyncBatchAnchoredInsertReplay.applying(inserted, to: deletedState)

        XCTAssertEqual(result.visibleText, "xB")
        XCTAssertEqual(result.sequenceState.visibility(of: anchorElement), .tombstone)
        XCTAssertEqual(deletedState, originalDeletedState)
        XCTAssertEqual(base, original)
    }

    func testCoreErrorsEscapeUnchangedAndPreserveInputState() throws {
        let value = try state(text: "A😀B")
        let original = value
        let valid = try deleteChange(
            state: value,
            offset: 1,
            length: 2,
            expectedText: "😀",
            counter: 10
        )

        let missingOperation = operation(99)
        try assertReplayError(
            .missingDeleteDependency(missingOperation),
            payload: SyncTextDeleteOperationPayload(
                operationID: valid.payload.operationID,
                deletedElementIDSpans: [
                    try span(missingOperation, start: 0, length: 1)
                ]
            ),
            change: valid,
            state: value
        )

        let outOfBounds = try span(operation(1), start: 0, length: 5)
        try assertReplayError(
            .deleteTargetRangeExceedsRun(outOfBounds),
            payload: SyncTextDeleteOperationPayload(
                operationID: valid.payload.operationID,
                deletedElementIDSpans: [outOfBounds]
            ),
            change: valid,
            state: value
        )

        let lowerSplit = try span(operation(1), start: 2, length: 1)
        try assertReplayError(
            .deleteTargetSplitsSurrogatePair(lowerSplit, offset: 2),
            payload: SyncTextDeleteOperationPayload(
                operationID: valid.payload.operationID,
                deletedElementIDSpans: [lowerSplit]
            ),
            change: valid,
            state: value
        )

        let upperSplit = try span(operation(1), start: 1, length: 1)
        try assertReplayError(
            .deleteTargetSplitsSurrogatePair(upperSplit, offset: 2),
            payload: SyncTextDeleteOperationPayload(
                operationID: valid.payload.operationID,
                deletedElementIDSpans: [upperSplit]
            ),
            change: valid,
            state: value
        )

        XCTAssertEqual(value, original)
    }

    func testMultiSpanFailureIsAtomic() throws {
        let value = try state(text: "AB")
        let original = value
        let valid = try deleteChange(
            state: value,
            offset: 0,
            length: 1,
            expectedText: "A",
            counter: 10
        )
        let missingOperation = operation(99)
        let payload = try SyncTextDeleteOperationPayload(
            operationID: valid.payload.operationID,
            deletedElementIDSpans: [
                try span(operation(1), start: 0, length: 1),
                try span(missingOperation, start: 0, length: 1)
            ]
        )

        try assertReplayError(
            .missingDeleteDependency(missingOperation),
            payload: payload,
            change: valid,
            state: value
        )
        XCTAssertEqual(value, original)
        XCTAssertEqual(value.visibleText, "AB")
        XCTAssertEqual(value.tombstonedUTF16Count, 0)
    }

    func testCapabilityRemainsDisabled() {
        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    private func state(text: String) throws -> SyncTextSequenceState {
        guard !text.isEmpty else { return .empty }
        let operationID = operation(1)
        return try SyncTextSequenceState(
            runs: [try run(operationID, text: text)],
            fragments: [
                try fragment(
                    operationID,
                    start: 0,
                    length: text.utf16.count
                )
            ]
        )
    }

    private func deleteChange(
        state: SyncTextSequenceState,
        offset: Int,
        length: Int,
        expectedText: String?,
        counter: UInt64
    ) throws -> SyncBatchNoteBodyTextDeletedAnchoredChange {
        let value = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
            noteID: noteID,
            utf16Offset: offset,
            utf16Length: length,
            expectedText: expectedText,
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: state.visibleText),
            operationID: operation(counter),
            state: state
        )
        guard case .noteBodyTextDeletedAnchored(let anchored) = value else {
            XCTFail("Expected anchored deleted change")
            throw TestError.unexpectedChange
        }
        return anchored
    }

    private func insertChange(
        state: SyncTextSequenceState,
        offset: Int,
        text: String,
        counter: UInt64
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        let value = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: state.visibleText),
            operationID: operation(counter),
            state: state
        )
        guard case .noteBodyTextInsertedAnchored(let anchored) = value else {
            XCTFail("Expected anchored inserted change")
            throw TestError.unexpectedChange
        }
        return anchored
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
        text: String
    ) throws -> SyncTextSequenceRun {
        try SyncTextSequenceRun(
            operationID: operationID,
            origin: SyncTextInsertionOrigin(
                leftElementID: nil,
                rightElementID: nil
            ),
            text: text
        )
    }

    private func fragment(
        _ operationID: SyncOperationID,
        start: Int,
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

    private func replacingCompatibilityMetadata(
        offset: Int,
        length: Int,
        expectedText: String?,
        baseContentHash: String?,
        in change: SyncBatchNoteBodyTextDeletedAnchoredChange
    ) throws -> SyncBatchNoteBodyTextDeletedAnchoredChange {
        var object = try encodedObject(change)
        object["utf16Offset"] = offset
        object["utf16Length"] = length
        if let expectedText {
            object["expectedText"] = expectedText
        } else {
            object.removeValue(forKey: "expectedText")
        }
        if let baseContentHash {
            object["baseContentHash"] = baseContentHash
        } else {
            object.removeValue(forKey: "baseContentHash")
        }
        return try decodeChange(object)
    }

    private func replacingPayload(
        _ payload: SyncTextDeleteOperationPayload,
        in change: SyncBatchNoteBodyTextDeletedAnchoredChange
    ) throws -> SyncBatchNoteBodyTextDeletedAnchoredChange {
        var object = try encodedObject(change)
        object["payload"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        )
        return try decodeChange(object)
    }

    private func encodedObject(
        _ change: SyncBatchNoteBodyTextDeletedAnchoredChange
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(change)
        )
        return try XCTUnwrap(object as? [String: Any])
    }

    private func decodeChange(
        _ object: [String: Any]
    ) throws -> SyncBatchNoteBodyTextDeletedAnchoredChange {
        try JSONDecoder().decode(
            SyncBatchNoteBodyTextDeletedAnchoredChange.self,
            from: JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        )
    }

    private func assertReplayError(
        _ expected: SyncTextSequenceStateError,
        payload: SyncTextDeleteOperationPayload,
        change: SyncBatchNoteBodyTextDeletedAnchoredChange,
        state: SyncTextSequenceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let altered = try replacingPayload(payload, in: change)
        do {
            _ = try SyncBatchAnchoredDeleteReplay.applying(altered, to: state)
            XCTFail("Expected replay failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private enum TestError: Error {
        case unexpectedChange
    }
}
