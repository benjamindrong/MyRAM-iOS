import AnchoredSequenceCore
import Foundation
import XCTest
@testable import MyRAM

final class SyncBatchAnchoredPayloadTests: XCTestCase {
    private let noteID = UUID(uuidString: "17100000-0000-0000-0000-000000000001")!
    private let deviceID = UUID(uuidString: "17100000-0000-0000-0000-000000000002")!
    private let modifiedAt = Date(timeIntervalSince1970: 1_710)

    func testInsertProducesAllBoundaryAnchorsAndPreservesEvidence() throws {
        let empty = try state(text: "")
        let value = try state(text: "AB")

        let emptyChange = try inserted(offset: 0, text: "x", state: empty, counter: 10)
        let before = try inserted(offset: 0, text: "x", state: value, counter: 11)
        let between = try inserted(offset: 1, text: "x", state: value, counter: 12)
        let after = try inserted(offset: 2, text: "x", state: value, counter: 13)

        XCTAssertEqual(insertValue(emptyChange).payload.anchor, .empty)
        XCTAssertEqual(
            insertValue(before).payload.anchor,
            .before(try element(operation(1), 0))
        )
        XCTAssertEqual(
            insertValue(between).payload.anchor,
            try .between(
                left: element(operation(1), 0),
                right: element(operation(1), 1)
            )
        )
        XCTAssertEqual(
            insertValue(after).payload.anchor,
            .after(try element(operation(1), 1))
        )

        let evidence = insertValue(between)
        XCTAssertEqual(evidence.noteID, noteID)
        XCTAssertEqual(evidence.utf16Offset, 1)
        XCTAssertEqual(evidence.text, "x")
        XCTAssertEqual(evidence.modifiedAt, modifiedAt)
        XCTAssertEqual(evidence.baseContentHash, hash("AB"))
        XCTAssertEqual(evidence.payload.operationID, operation(12))
    }

    func testBootstrapBackedVisibleRunChainProducesExpectedAnchorsIncludingMidRun() throws {
        let bootstrap = try NoteSequenceStateBootstrapAdapter.makeInitialState(
            noteID: noteID,
            body: "ABCD"
        )
        let originalBootstrap = bootstrap
        XCTAssertEqual(bootstrap.runs.count, 1)
        let bootstrapRun = try XCTUnwrap(bootstrap.runs.first)
        let bootstrapOperationID = bootstrapRun.operationID
        let insertedOperationID = operation(172)
        let insertedRun = try run(
            insertedOperationID,
            left: element(bootstrapOperationID, 1),
            right: element(bootstrapOperationID, 2),
            text: "xy"
        )

        // The fragment chain crosses both run boundaries while retaining a mid-run gap.
        let assembled = try SyncTextSequenceState(
            runs: [bootstrapRun, insertedRun].sorted {
                SyncOperationIDCanonicalOrder.isOrderedBefore(
                    $0.operationID,
                    $1.operationID
                )
            },
            fragments: [
                try fragment(bootstrapOperationID, start: 0, length: 2),
                try fragment(insertedOperationID, start: 0, length: 2),
                try fragment(bootstrapOperationID, start: 2, length: 2)
            ]
        )
        let originalAssembled = assembled
        let captureCounter: UInt64 = 200
        let changes = try [0, 2, 3, 4, 6].map {
            try inserted(
                offset: $0,
                text: "z",
                state: assembled,
                counter: captureCounter
            )
        }

        XCTAssertEqual(assembled.visibleText, "ABxyCD")
        XCTAssertEqual(assembled.visibleUTF16Count, 6)
        XCTAssertEqual(assembled.tombstonedUTF16Count, 0)
        XCTAssertEqual(
            changes.map { insertValue($0).payload.anchor },
            [
                .before(try element(bootstrapOperationID, 0)),
                try .between(
                    left: element(bootstrapOperationID, 1),
                    right: element(insertedOperationID, 0)
                ),
                try .between(
                    left: element(insertedOperationID, 0),
                    right: element(insertedOperationID, 1)
                ),
                try .between(
                    left: element(insertedOperationID, 1),
                    right: element(bootstrapOperationID, 2)
                ),
                .after(try element(bootstrapOperationID, 3))
            ]
        )
        XCTAssertTrue(
            changes.allSatisfy {
                insertValue($0).payload.operationID == operation(captureCounter)
            }
        )
        XCTAssertEqual(assembled, originalAssembled)
        XCTAssertEqual(bootstrap, originalBootstrap)
    }

    func testInsertBesideTombstoneUsesVisibleNeighbors() throws {
        let parent = operation(1)
        let tombstone = operation(2)
        let value = try SyncTextSequenceState(
            runs: [
                try run(parent, text: "AB"),
                try run(
                    tombstone,
                    left: element(parent, 0),
                    right: element(parent, 1),
                    text: "x"
                )
            ],
            fragments: [
                try fragment(parent, start: 0),
                try fragment(tombstone, visibility: .tombstone),
                try fragment(parent, start: 1)
            ]
        )

        let change = try inserted(offset: 1, text: "y", state: value, counter: 10)

        XCTAssertEqual(
            insertValue(change).payload.anchor,
            try .between(
                left: element(tombstone, 0),
                right: element(parent, 1)
            )
        )
    }

    func testDeleteProducesOrderedSpansAcrossRunsAndTombstones() throws {
        let first = operation(1)
        let hidden = operation(2)
        let second = operation(3)
        let value = try SyncTextSequenceState(
            runs: [
                try run(first, text: "A"),
                try run(
                    hidden,
                    left: element(first, 0),
                    right: nil,
                    text: "x"
                ),
                try run(
                    second,
                    left: element(hidden, 0),
                    right: nil,
                    text: "B"
                )
            ],
            fragments: [
                try fragment(first),
                try fragment(hidden, visibility: .tombstone),
                try fragment(second)
            ]
        )

        let change = try deleted(
            offset: 0,
            length: 2,
            expectedText: "AB",
            state: value,
            counter: 10
        )

        let evidence = deleteValue(change)
        XCTAssertEqual(evidence.noteID, noteID)
        XCTAssertEqual(evidence.utf16Offset, 0)
        XCTAssertEqual(evidence.utf16Length, 2)
        XCTAssertEqual(evidence.expectedText, "AB")
        XCTAssertEqual(evidence.modifiedAt, modifiedAt)
        XCTAssertEqual(evidence.baseContentHash, hash("AB"))
        XCTAssertEqual(evidence.payload.operationID, operation(10))
        XCTAssertEqual(evidence.payload.deletedElementIDSpans, [
            try span(first),
            try span(second)
        ])
    }

    func testDeleteWithinOneRunProducesOneSpan() throws {
        let value = try state(text: "ABC")
        let change = try deleted(
            offset: 0,
            length: 3,
            expectedText: "ABC",
            state: value
        )

        XCTAssertEqual(
            deleteValue(change).payload.deletedElementIDSpans,
            [try span(operation(1), length: 3)]
        )
    }

    func testSurrogateSafeBoundariesSucceedAndSplitBoundariesFailExactly() throws {
        let value = try state(text: "A😀B")

        XCTAssertNoThrow(try inserted(offset: 1, text: "x", state: value))
        XCTAssertNoThrow(try inserted(offset: 3, text: "x", state: value))
        XCTAssertNoThrow(try deleted(
            offset: 1,
            length: 2,
            expectedText: "😀",
            state: value
        ))
        assertStateError(.visibleOffsetSplitsSurrogatePair(2)) {
            _ = try inserted(offset: 2, text: "x", state: value)
        }
        assertStateError(.visibleRangeSplitsSurrogatePair(2)) {
            _ = try deleted(offset: 1, length: 1, expectedText: nil, state: value)
        }
    }

    func testInvalidRangesAndEmptyInsertFailExactly() throws {
        let value = try state(text: "AB")

        XCTAssertThrowsError(try inserted(offset: 0, text: "", state: value)) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadAdapterError,
                .emptyInsertedText
            )
        }
        assertStateError(.negativeRangeOffset(-1)) {
            _ = try deleted(offset: -1, length: 1, expectedText: nil, state: value)
        }
        assertStateError(.nonpositiveRangeLength(0)) {
            _ = try deleted(offset: 0, length: 0, expectedText: nil, state: value)
        }
        assertStateError(.nonpositiveRangeLength(-1)) {
            _ = try deleted(offset: 0, length: -1, expectedText: nil, state: value)
        }
        assertStateError(.rangeOverflow(startOffset: Int.max, utf16Length: 1)) {
            _ = try deleted(
                offset: Int.max,
                length: 1,
                expectedText: nil,
                state: value
            )
        }
        assertStateError(.invalidVisibleRange(1..<3)) {
            _ = try deleted(offset: 1, length: 2, expectedText: nil, state: value)
        }
    }

    func testEvidenceValidationRejectsHashLengthAndTextMismatch() throws {
        let value = try state(text: "AB")

        XCTAssertThrowsError(try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 0,
            text: "x",
            modifiedAt: modifiedAt,
            baseContentHash: "wrong",
            operationID: operation(10),
            state: value
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadAdapterError,
                .mismatchedBaseContentHash(
                    expected: "wrong",
                    actual: hash("AB")
                )
            )
        }
        XCTAssertThrowsError(try deleted(
            offset: 0,
            length: 2,
            expectedText: "A",
            state: value
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadAdapterError,
                .expectedTextUTF16LengthMismatch(declared: 2, actual: 1)
            )
        }
        XCTAssertThrowsError(try deleted(
            offset: 0,
            length: 2,
            expectedText: "ZZ",
            state: value
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadAdapterError,
                .expectedTextMismatch(noteID: noteID)
            )
        }
    }

    func testInsertAndDeleteAdaptersDoNotMutateStateOnSuccessOrFailure() throws {
        let value = try state(text: "AB")
        let original = value

        _ = try inserted(offset: 1, text: "x", state: value)
        XCTAssertEqual(value, original)

        XCTAssertThrowsError(try inserted(offset: 3, text: "x", state: value))
        XCTAssertEqual(value, original)

        _ = try deleted(
            offset: 0,
            length: 2,
            expectedText: "AB",
            state: value
        )
        XCTAssertEqual(value, original)

        XCTAssertThrowsError(try deleted(
            offset: 0,
            length: 2,
            expectedText: "ZZ",
            state: value
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadAdapterError,
                .expectedTextMismatch(noteID: noteID)
            )
        }
        XCTAssertEqual(value, original)
    }

    func testAnchoredChangesAndBatchesRoundTripDirectly() throws {
        let value = try state(text: "AB")
        let insert = try inserted(offset: 1, text: "x", state: value)
        let delete = try deleted(
            offset: 0,
            length: 2,
            expectedText: "AB",
            state: value
        )

        for change in [insert, delete] {
            XCTAssertEqual(
                try roundTrip(change, as: SyncBatchChange.self),
                change
            )
            let batch = makeBatch(changes: [change])
            XCTAssertEqual(try roundTrip(batch, as: SyncBatch.self), batch)
        }
    }

    func testMalformedCorePayloadStillFailsDuringDirectDecode() throws {
        let change = try deleted(
            offset: 0,
            length: 1,
            expectedText: "A",
            state: state(text: "A")
        )
        let encoded = try JSONEncoder().encode(change)
        let json = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: #""startOffset":0"#, with: #""startOffset":-1"#)

        XCTAssertThrowsError(
            try JSONDecoder().decode(SyncBatchChange.self, from: Data(json.utf8))
        ) {
            XCTAssertEqual(
                $0 as? SyncTextSequenceStateError,
                .negativeRangeOffset(-1)
            )
        }
    }

    func testPolicyClassifiesLegacyAnchoredAndMixedBatches() throws {
        let metadata = makeBatch(changes: [
            .noteTitleChanged(.init(
                noteID: noteID,
                title: "Title",
                modifiedAt: modifiedAt
            ))
        ])
        let legacyInsert = makeBatch(changes: [
            .noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 0,
                text: "A",
                modifiedAt: modifiedAt
            ))
        ])
        let legacyDelete = makeBatch(changes: [
            .noteBodyTextDeleted(.init(
                noteID: noteID,
                utf16Offset: 0,
                utf16Length: 1,
                expectedText: "A",
                modifiedAt: modifiedAt
            ))
        ])
        let anchoredInsert = makeBatch(changes: [
            try inserted(offset: 0, text: "A", state: state(text: ""))
        ])
        let anchoredDelete = makeBatch(changes: [
            try deleted(
                offset: 0,
                length: 1,
                expectedText: "A",
                state: state(text: "A")
            )
        ])

        XCTAssertEqual(metadata.bodyOperationRepresentation, .none)
        XCTAssertEqual(legacyInsert.bodyOperationRepresentation, .legacy)
        XCTAssertEqual(legacyDelete.bodyOperationRepresentation, .legacy)
        XCTAssertEqual(anchoredInsert.bodyOperationRepresentation, .anchored)
        XCTAssertNoThrow(try SyncBatchAnchoredPayloadPolicy.validateApply(metadata))
        XCTAssertNoThrow(try SyncBatchAnchoredPayloadPolicy.validateApply(legacyInsert))
        XCTAssertNoThrow(try SyncBatchAnchoredPayloadPolicy.validateApply(legacyDelete))
        assertPolicyError(
            .anchoredPayloadDisabled(boundary: .apply, noteID: noteID)
        ) {
            try SyncBatchAnchoredPayloadPolicy.validateApply(anchoredInsert)
        }
        assertPolicyError(
            .anchoredPayloadDisabled(boundary: .apply, noteID: noteID)
        ) {
            try SyncBatchAnchoredPayloadPolicy.validateApply(anchoredDelete)
        }

        for changes in [
            [legacyInsert.changes[0], anchoredInsert.changes[0]],
            [anchoredInsert.changes[0], legacyInsert.changes[0]]
        ] {
            let mixed = makeBatch(changes: changes)
            XCTAssertEqual(mixed.bodyOperationRepresentation, .mixed)
            assertPolicyError(.mixedBodyOperationRepresentations(boundary: .apply)) {
                try SyncBatchAnchoredPayloadPolicy.validateApply(mixed)
            }
        }
    }

    func testEveryNamedBoundaryReportsItsOwnBoundary() throws {
        let batch = makeBatch(changes: [
            try inserted(offset: 0, text: "A", state: state(text: ""))
        ])
        let cases: [
            (
                SyncBatchAnchoredPayloadPolicyError.Boundary,
                (SyncBatch) throws -> Void
            )
        ] = [
            (.transportEncode, SyncBatchAnchoredPayloadPolicy.validateTransportEncode),
            (.outboundController, SyncBatchAnchoredPayloadPolicy.validateOutbound),
            (.inboundController, SyncBatchAnchoredPayloadPolicy.validateInbound),
            (.durableQueue, SyncBatchAnchoredPayloadPolicy.validateDurableAdmission),
            (.convergence, SyncBatchAnchoredPayloadPolicy.validateConvergence),
            (.recovery, SyncBatchAnchoredPayloadPolicy.validateRecovery),
            (.offsetReplay, SyncBatchAnchoredPayloadPolicy.validateOffsetReplay),
            (.apply, SyncBatchAnchoredPayloadPolicy.validateApply)
        ]

        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
        for (boundary, validate) in cases {
            assertPolicyError(
                .anchoredPayloadDisabled(boundary: boundary, noteID: noteID)
            ) {
                try validate(batch)
            }
        }
    }

    func testTransportEncoderRejectsBeforeProducingBytes() throws {
        let batch = makeBatch(changes: [
            try inserted(offset: 0, text: "A", state: state(text: ""))
        ])

        assertPolicyError(
            .anchoredPayloadDisabled(boundary: .transportEncode, noteID: noteID)
        ) {
            _ = try MultipeerSyncMessageCoding.encodeBatch(batch)
        }
    }

    func testSharedPreflightRejectsBeforeBodyProvider() throws {
        let batch = makeBatch(changes: [
            try inserted(offset: 0, text: "A", state: state(text: ""))
        ])
        var bodyProviderCalled = false

        assertPolicyError(
            .anchoredPayloadDisabled(boundary: .apply, noteID: noteID)
        ) {
            try SyncBatchPreflight(
                bodyHashCapabilityEnabled: false
            ).validate(batch: batch) { _ in
                bodyProviderCalled = true
                return ""
            }
        }
        XCTAssertFalse(bodyProviderCalled)
    }

    private func inserted(
        offset: Int,
        text: String,
        state: SyncTextSequenceState,
        counter: UInt64 = 10
    ) throws -> SyncBatchChange {
        try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: modifiedAt,
            baseContentHash: hash(state.visibleText),
            operationID: operation(counter),
            state: state
        )
    }

    private func deleted(
        offset: Int,
        length: Int,
        expectedText: String?,
        state: SyncTextSequenceState,
        counter: UInt64 = 10
    ) throws -> SyncBatchChange {
        try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
            noteID: noteID,
            utf16Offset: offset,
            utf16Length: length,
            expectedText: expectedText,
            modifiedAt: modifiedAt,
            baseContentHash: hash(state.visibleText),
            operationID: operation(counter),
            state: state
        )
    }

    private func insertValue(
        _ change: SyncBatchChange
    ) -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        guard case .noteBodyTextInsertedAnchored(let value) = change else {
            XCTFail("Expected anchored insert")
            fatalError("Expected anchored insert")
        }
        return value
    }

    private func deleteValue(
        _ change: SyncBatchChange
    ) -> SyncBatchNoteBodyTextDeletedAnchoredChange {
        guard case .noteBodyTextDeletedAnchored(let value) = change else {
            XCTFail("Expected anchored delete")
            fatalError("Expected anchored delete")
        }
        return value
    }

    private func makeBatch(changes: [SyncBatchChange]) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: "17100000-0000-0000-0000-000000000003")!,
            originDeviceID: deviceID,
            createdAt: modifiedAt,
            batchSequence: 1,
            changes: changes
        )
    }

    private func state(text: String) throws -> SyncTextSequenceState {
        guard !text.isEmpty else {
            return try SyncTextSequenceState(runs: [], fragments: [])
        }
        let operationID = operation(1)
        return try SyncTextSequenceState(
            runs: [try run(operationID, text: text)],
            fragments: [
                try fragment(
                    operationID,
                    length: text.utf16.count
                )
            ]
        )
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
        start: Int = 0,
        length: Int = 1
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

    private func hash(_ text: String) -> String {
        SyncBatchContentHash.sha256Hex(for: text)
    }

    private func roundTrip<T: Codable>(
        _ value: T,
        as type: T.Type
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func assertStateError(
        _ expected: SyncTextSequenceStateError,
        action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action()) {
            XCTAssertEqual($0 as? SyncTextSequenceStateError, expected)
        }
    }

    private func assertPolicyError(
        _ expected: SyncBatchAnchoredPayloadPolicyError,
        action: () throws -> Void
    ) {
        XCTAssertThrowsError(try action()) {
            XCTAssertEqual($0 as? SyncBatchAnchoredPayloadPolicyError, expected)
        }
    }
}

// MYR-178 Slice 1 anchorless compatibility decision tests
extension SyncBatchAnchoredPayloadTests {
    func testMYR178MatchingDeclaredHashProducesPositiveEligibility() {
        let body = "A😀B"
        let change: SyncBatchChange = .noteBodyTextInserted(.init(
            noteID: noteID,
            utf16Offset: 1,
            text: "x",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: body)
        ))

        let decision = SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
            change: change,
            authoritativeBody: body
        )

        guard case .eligible(let eligibility) = decision else {
            return XCTFail("Expected positive anchorless replay eligibility")
        }
        XCTAssertEqual(eligibility.change, change)
        XCTAssertEqual(
            eligibility.authoritativeBodyHash,
            SyncBatchContentHash.sha256Hex(for: body)
        )
        XCTAssertEqual(body, "A😀B")
    }

    func testMYR178MismatchedDeclaredHashProducesDistinctDivergence() {
        let body = "authoritative"
        let change: SyncBatchChange = .noteBodyTextDeleted(.init(
            noteID: noteID,
            utf16Offset: 0,
            utf16Length: 4,
            expectedText: "auth",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "different")
        ))
        let actualHash = SyncBatchContentHash.sha256Hex(for: body)

        XCTAssertEqual(
            SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                change: change,
                authoritativeBody: body
            ),
            .divergentBase(
                noteID: noteID,
                declaredBaseContentHash: SyncBatchContentHash.sha256Hex(for: "different"),
                authoritativeBodyHash: actualHash
            )
        )
    }

    func testMYR178HashlessPositionalPlausibilityNeverAuthorizesReplay() {
        let body = "A😀B expected substring"
        let plausibleChanges: [SyncBatchChange] = [
            .noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 0,
                text: "x",
                modifiedAt: modifiedAt
            )),
            .noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 999,
                text: "x",
                modifiedAt: modifiedAt
            )),
            .noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 2,
                text: "x",
                modifiedAt: modifiedAt
            )),
            .noteBodyTextDeleted(.init(
                noteID: noteID,
                utf16Offset: 5,
                utf16Length: 8,
                expectedText: "expected",
                modifiedAt: modifiedAt
            ))
        ]

        for change in plausibleChanges {
            XCTAssertEqual(
                SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                    change: change,
                    authoritativeBody: body
                ),
                .unavailableEvidence(noteID: noteID)
            )
        }
    }

    func testMYR178ClassificationIsDeterministicAndSideEffectFree() {
        let body = "stable"
        let originalBody = body
        let change: SyncBatchChange = .noteBodyTextInserted(.init(
            noteID: noteID,
            utf16Offset: 0,
            text: "x",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: body)
        ))

        let first = SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
            change: change,
            authoritativeBody: body
        )
        for _ in 0..<20 {
            XCTAssertEqual(
                SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                    change: change,
                    authoritativeBody: body
                ),
                first
            )
        }
        XCTAssertEqual(body, originalBody)
        XCTAssertEqual(change, change)
    }
}
