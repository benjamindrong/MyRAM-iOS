import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncTextMarkStateTests: XCTestCase {
    func testStateCanonicalizesInputAndStableEncodingAcrossPermutations() throws {
        let sequence = try rootState(text: "ABC")
        let start = try sequence.operationAnchor(atVisibleUTF16Offset: 0)
        let end = try sequence.operationAnchor(atVisibleUTF16Offset: 3)
        let first = try mark(
            operation(2),
            clock: 2,
            key: .bold,
            assignment: .enabled,
            start: start,
            end: end
        )
        let second = try mark(
            operation(1),
            clock: 1,
            key: .italic,
            assignment: .enabled,
            start: start,
            end: end
        )

        let lhs = try SyncTextMarkState(operations: [first, second])
        let rhs = try SyncTextMarkState(operations: [second, first])

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.operations.map(\.operationID), [second.operationID, first.operationID])
        XCTAssertEqual(try encoded(lhs), try encoded(rhs))
    }

    func testDuplicateIdentityIsIdempotentButConflictingContentFailsClosed() throws {
        let sequence = try rootState(text: "AB")
        let start = try sequence.operationAnchor(atVisibleUTF16Offset: 0)
        let end = try sequence.operationAnchor(atVisibleUTF16Offset: 2)
        let value = try mark(
            operation(1),
            clock: 1,
            key: .bold,
            assignment: .enabled,
            start: start,
            end: end
        )

        XCTAssertEqual(
            try SyncTextMarkState(operations: [value, value]).operations,
            [value]
        )

        let conflicting = try mark(
            operation(1),
            clock: 1,
            key: .italic,
            assignment: .enabled,
            start: start,
            end: end
        )
        XCTAssertThrowsError(
            try SyncTextMarkState(operations: [value, conflicting])
        ) { error in
            XCTAssertEqual(
                error as? SyncTextMarkStateError,
                .conflictingDuplicateOperationIdentity(operation(1))
            )
        }
    }

    func testLogicalClockStartsAtOneAndFailsClosedAtUInt64Max() throws {
        XCTAssertEqual(try SyncTextMarkState.empty.nextLogicalClock(), 1)

        let sequence = try rootState(text: "A")
        let value = try mark(
            operation(1),
            clock: UInt64.max,
            key: .bold,
            assignment: .enabled,
            start: try sequence.operationAnchor(atVisibleUTF16Offset: 0),
            end: try sequence.operationAnchor(atVisibleUTF16Offset: 1)
        )
        let state = try SyncTextMarkState(operations: [value])

        XCTAssertThrowsError(try state.nextLogicalClock()) { error in
            XCTAssertEqual(
                error as? SyncTextMarkStateError,
                .logicalClockOverflow
            )
        }
    }

    func testPairedValidationRejectsForeignReversedAndZeroWidthRanges() throws {
        let sequence = try rootState(text: "ABC")
        let validStart = try sequence.operationAnchor(atVisibleUTF16Offset: 1)
        let validEnd = try sequence.operationAnchor(atVisibleUTF16Offset: 2)
        let foreign = SyncOperationAnchor.after(
            try SyncTextElementID(
                operationID: operation(99),
                elementOffset: 0
            )
        )

        let foreignState = try SyncTextMarkState(operations: [
            mark(
                operation(1),
                clock: 1,
                key: .bold,
                assignment: .enabled,
                start: foreign,
                end: validEnd
            )
        ])
        XCTAssertThrowsError(try foreignState.validating(against: sequence))

        let reversed = try SyncTextMarkState(operations: [
            mark(
                operation(2),
                clock: 1,
                key: .bold,
                assignment: .enabled,
                start: validEnd,
                end: validStart
            )
        ])
        XCTAssertThrowsError(try reversed.validating(against: sequence))

        let zero = try SyncTextMarkState(operations: [
            mark(
                operation(3),
                clock: 1,
                key: .bold,
                assignment: .enabled,
                start: validStart,
                end: validStart
            )
        ])
        XCTAssertThrowsError(try zero.validating(against: sequence))
    }

    func testTombstonedEndpointsRemainValid() throws {
        let root = operation(0)
        let run = try SyncTextSequenceRun(
            operationID: root,
            origin: SyncTextInsertionOrigin(
                leftElementID: nil,
                rightElementID: nil
            ),
            text: "ABC"
        )
        let sequence = try SyncTextSequenceState(
            runs: [run],
            fragments: [
                try SyncTextSequenceFragment(
                    operationID: root,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                try SyncTextSequenceFragment(
                    operationID: root,
                    startOffset: 1,
                    utf16Length: 1,
                    visibility: .tombstone
                ),
                try SyncTextSequenceFragment(
                    operationID: root,
                    startOffset: 2,
                    utf16Length: 1,
                    visibility: .visible
                )
            ]
        )
        let start = try SyncOperationAnchor.between(
            left: element(root, 0),
            right: element(root, 1)
        )
        let end = try SyncOperationAnchor.between(
            left: element(root, 1),
            right: element(root, 2)
        )
        let state = try SyncTextMarkState(operations: [
            mark(
                operation(1),
                clock: 1,
                key: .underline,
                assignment: .enabled,
                start: start,
                end: end
            )
        ])

        XCTAssertNoThrow(try state.validating(against: sequence))
    }

    func testConcurrentSetClearUsesClockThenCanonicalOperationIdentity() throws {
        let sequence = try rootState(text: "AB")
        let start = try sequence.operationAnchor(atVisibleUTF16Offset: 0)
        let end = try sequence.operationAnchor(atVisibleUTF16Offset: 2)
        let lowID = operation(
            1,
            deviceID: "00000000-0000-0000-0000-000000000001"
        )
        let highID = operation(
            1,
            deviceID: "00000000-0000-0000-0000-000000000002"
        )
        let set = try mark(
            lowID,
            clock: 5,
            key: .bold,
            assignment: .enabled,
            start: start,
            end: end
        )
        let clear = try mark(
            highID,
            clock: 5,
            key: .bold,
            assignment: .clear,
            start: start,
            end: end
        )
        let tied = try SyncTextMarkState(operations: [set, clear])
        XCTAssertEqual(
            try tied.visibleProjection(in: sequence).first?.assignments[.bold],
            .clear
        )

        let laterSet = try mark(
            operation(10),
            clock: 6,
            key: .bold,
            assignment: .enabled,
            start: start,
            end: end
        )
        let later = try SyncTextMarkState(operations: [set, clear, laterSet])
        XCTAssertEqual(
            try later.visibleProjection(in: sequence).first?.assignments[.bold],
            .enabled
        )
    }

    func testOuterBoundaryRootsAndDescendantsStayOutsideWhileInteriorDescendantsInherit() throws {
        let root = operation(0)
        var sequence = try rootState(operationID: root, text: "ABCD")
        let start = try sequence.operationAnchor(atVisibleUTF16Offset: 1)
        let interior = try sequence.operationAnchor(atVisibleUTF16Offset: 2)
        let end = try sequence.operationAnchor(atVisibleUTF16Offset: 3)

        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(10),
                anchor: start
            ),
            insertedText: "S"
        )
        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(11),
                anchor: start
            ),
            insertedText: "T"
        )
        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(12),
                anchor: end
            ),
            insertedText: "E"
        )
        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(13),
                anchor: interior
            ),
            insertedText: "I"
        )
        let interiorElement = try element(operation(13), 0)
        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(14),
                anchor: try SyncOperationAnchor.between(
                    left: interiorElement,
                    right: element(root, 2)
                )
            ),
            insertedText: "D"
        )
        let startElement = try element(operation(10), 0)
        sequence = try sequence.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: operation(15),
                anchor: try SyncOperationAnchor.between(
                    left: startElement,
                    right: element(root, 1)
                )
            ),
            insertedText: "s"
        )

        let covered = try sequence.markRangeElementIDs(
            startAnchor: start,
            endAnchor: end
        )

        XCTAssertTrue(covered.contains(try element(root, 1)))
        XCTAssertTrue(covered.contains(try element(root, 2)))
        XCTAssertTrue(covered.contains(interiorElement))
        XCTAssertTrue(covered.contains(try element(operation(14), 0)))
        XCTAssertFalse(covered.contains(try element(operation(10), 0)))
        XCTAssertFalse(covered.contains(try element(operation(11), 0)))
        XCTAssertFalse(covered.contains(try element(operation(12), 0)))
        XCTAssertFalse(covered.contains(try element(operation(15), 0)))
    }

    func testCanonicalDraftOrderingRejectsSameKeyOverlap() throws {
        let sequence = try rootState(text: "ABCD")
        let zero = try sequence.operationAnchor(atVisibleUTF16Offset: 0)
        let one = try sequence.operationAnchor(atVisibleUTF16Offset: 1)
        let two = try sequence.operationAnchor(atVisibleUTF16Offset: 2)
        let four = try sequence.operationAnchor(atVisibleUTF16Offset: 4)

        let ordered = try SyncTextMarkCanonicalEmissionOrder.ordered(
            [
                try SyncTextMarkOperationDraft(
                    key: .italic,
                    assignment: .enabled,
                    startAnchor: one,
                    endAnchor: two
                ),
                try SyncTextMarkOperationDraft(
                    key: .bold,
                    assignment: .enabled,
                    startAnchor: one,
                    endAnchor: two
                ),
                try SyncTextMarkOperationDraft(
                    key: .bold,
                    assignment: .clear,
                    startAnchor: zero,
                    endAnchor: one
                )
            ],
            against: sequence
        )
        XCTAssertEqual(ordered.map(\.key), [.bold, .bold, .italic])
        XCTAssertEqual(ordered.map(\.assignment), [.clear, .enabled, .enabled])

        XCTAssertThrowsError(
            try SyncTextMarkCanonicalEmissionOrder.ordered(
                [
                    try SyncTextMarkOperationDraft(
                        key: .bold,
                        assignment: .enabled,
                        startAnchor: zero,
                        endAnchor: two
                    ),
                    try SyncTextMarkOperationDraft(
                        key: .bold,
                        assignment: .clear,
                        startAnchor: one,
                        endAnchor: four
                    )
                ],
                against: sequence
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncTextMarkStateError,
                .overlappingDraftRanges(.bold)
            )
        }
    }

    func testCanonicalFontSizeValidationUsesFrozenBounds() throws {
        let sequence = try rootState(text: "A")
        let start = try sequence.operationAnchor(atVisibleUTF16Offset: 0)
        let end = try sequence.operationAnchor(atVisibleUTF16Offset: 1)

        XCTAssertNoThrow(
            try SyncTextMarkOperationDraft(
                key: .fontSize,
                assignment: .fontSizeMilliPoints(11_000),
                startAnchor: start,
                endAnchor: end
            )
        )
        XCTAssertNoThrow(
            try SyncTextMarkOperationDraft(
                key: .fontSize,
                assignment: .fontSizeMilliPoints(40_000),
                startAnchor: start,
                endAnchor: end
            )
        )
        XCTAssertThrowsError(
            try SyncTextMarkOperationDraft(
                key: .fontSize,
                assignment: .fontSizeMilliPoints(10_999),
                startAnchor: start,
                endAnchor: end
            )
        )
        XCTAssertThrowsError(
            try SyncTextMarkOperationDraft(
                key: .fontSize,
                assignment: .fontSizeMilliPoints(40_001),
                startAnchor: start,
                endAnchor: end
            )
        )
    }

    private func encoded(_ state: SyncTextMarkState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private func mark(
        _ operationID: SyncOperationID,
        clock: UInt64,
        key: SyncTextMarkKey,
        assignment: SyncTextMarkAssignment,
        start: SyncOperationAnchor,
        end: SyncOperationAnchor
    ) throws -> SyncTextMarkOperation {
        try SyncTextMarkOperation(
            operationID: operationID,
            logicalClock: clock,
            key: key,
            assignment: assignment,
            startAnchor: start,
            endAnchor: end
        )
    }

    private func rootState(
        operationID: SyncOperationID? = nil,
        text: String
    ) throws -> SyncTextSequenceState {
        let id = operationID ?? operation(0)
        let run = try SyncTextSequenceRun(
            operationID: id,
            origin: SyncTextInsertionOrigin(
                leftElementID: nil,
                rightElementID: nil
            ),
            text: text
        )
        return try SyncTextSequenceState(
            runs: [run],
            fragments: [
                try SyncTextSequenceFragment(
                    operationID: id,
                    startOffset: 0,
                    utf16Length: text.utf16.count,
                    visibility: .visible
                )
            ]
        )
    }

    private func operation(
        _ counter: UInt64,
        deviceID: String = "00000000-0000-0000-0000-000000000001"
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
        try SyncTextElementID(
            operationID: operationID,
            elementOffset: offset
        )
    }
}
