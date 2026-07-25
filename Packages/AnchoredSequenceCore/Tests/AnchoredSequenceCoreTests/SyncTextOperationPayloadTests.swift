import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncTextOperationPayloadTests: XCTestCase {
    private let insertFixture = #"{"anchor":{"kind":"between","leftElementID":{"elementOffset":0,"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":1}},"rightElementID":{"elementOffset":1,"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":2}}},"formatVersion":1,"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":10}}"#
    private let deleteFixture = #"{"deletedElementIDSpans":[{"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":1},"startOffset":0,"utf16Length":1},{"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":1},"startOffset":1,"utf16Length":1}],"formatVersion":1,"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":11}}"#

    func testAnchorFactoriesEncodeTheFourExactShapes() throws {
        let left = try element(operation(1), 0)
        let right = try element(operation(2), 1)
        let cases: [(SyncOperationAnchor, String)] = [
            (.empty, #"{"kind":"empty"}"#),
            (.before(right), elementJSON(kind: "before", right: right)),
            (
                try .between(left: left, right: right),
                elementJSON(kind: "between", left: left, right: right)
            ),
            (.after(left), elementJSON(kind: "after", left: left))
        ]

        for (anchor, expectedJSON) in cases {
            let encoded = try encoded(anchor)
            XCTAssertEqual(encoded, Data(expectedJSON.utf8))
            XCTAssertEqual(try JSONDecoder().decode(SyncOperationAnchor.self, from: encoded), anchor)
        }
    }

    func testBetweenFactoryRejectsIdenticalEndpoints() throws {
        let endpoint = try element(operation(1), 0)

        XCTAssertThrowsError(try SyncOperationAnchor.between(
            left: endpoint,
            right: endpoint
        )) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                .identicalOriginEndpoints(endpoint)
            )
        }
    }

    func testExactInsertV1FixtureEncodesAndDecodes() throws {
        let payload = SyncTextInsertOperationPayload(
            operationID: operation(10),
            anchor: try .between(
                left: element(operation(1), 0),
                right: element(operation(2), 1)
            )
        )
        let expected = Data(insertFixture.utf8)

        XCTAssertEqual(try encoded(payload), expected)
        XCTAssertEqual(
            try JSONDecoder().decode(SyncTextInsertOperationPayload.self, from: expected),
            payload
        )
    }

    func testExactDeleteV1FixturePreservesAdjacentSpans() throws {
        let payload = try SyncTextDeleteOperationPayload(
            operationID: operation(11),
            deletedElementIDSpans: [
                span(operation(1), start: 0),
                span(operation(1), start: 1)
            ]
        )
        let expected = Data(deleteFixture.utf8)

        XCTAssertEqual(try encoded(payload), expected)
        XCTAssertEqual(
            try JSONDecoder().decode(SyncTextDeleteOperationPayload.self, from: expected),
            payload
        )
    }

    func testInsertAndDeleteVersionMatrices() throws {
        try assertVersionMatrix(
            fixture: insertFixture,
            type: SyncTextInsertOperationPayload.self
        )
        try assertVersionMatrix(
            fixture: deleteFixture,
            type: SyncTextDeleteOperationPayload.self
        )
    }

    func testUnexpectedPayloadKeysRejectLexicographicallyFirstKey() {
        let malformed = insertFixture.replacingOccurrences(
            of: #"{"anchor""#,
            with: #"{"zzz":0,"aaa":0,"anchor""#
        )

        assertDecodingError(
            Data(malformed.utf8),
            as: SyncTextInsertOperationPayload.self,
            expectedCase: .dataCorrupted,
            codingPath: ["aaa"]
        )
    }

    func testUnexpectedAnchorAndSpanKeysReportFullNestedPaths() {
        let malformedAnchor = insertFixture.replacingOccurrences(
            of: #"{"kind":"between""#,
            with: #"{"extra":0,"kind":"between""#
        )
        assertDecodingError(
            Data(malformedAnchor.utf8),
            as: SyncTextInsertOperationPayload.self,
            expectedCase: .dataCorrupted,
            codingPath: ["anchor", "extra"]
        )

        let malformedSpan = deleteFixture.replacingOccurrences(
            of: #"{"operationID":{"deviceID""#,
            with: #"{"extra":0,"operationID":{"deviceID""#,
            maxReplacements: 1
        )
        assertDecodingError(
            Data(malformedSpan.utf8),
            as: SyncTextDeleteOperationPayload.self,
            expectedCase: .dataCorrupted,
            codingPath: ["deletedElementIDSpans", "Index 0", "extra"]
        )
    }

    func testEstablishedIdentityCodecsContinueIgnoringUnknownNestedKeys() throws {
        let withUnknownIdentityKey = insertFixture.replacingOccurrences(
            of: #""localCounter":10}"#,
            with: #""localCounter":10,"legacyUnknown":true}"#
        )

        XCTAssertNoThrow(try JSONDecoder().decode(
            SyncTextInsertOperationPayload.self,
            from: Data(withUnknownIdentityKey.utf8)
        ))
    }

    func testAnchorKindRepresentationFailuresHaveExactCasesAndPaths() {
        assertDecodingError(
            Data(#"{}"#.utf8),
            as: SyncOperationAnchor.self,
            expectedCase: .keyNotFound,
            codingPath: [],
            missingKey: "kind"
        )
        assertDecodingError(
            Data(#"{"kind":null}"#.utf8),
            as: SyncOperationAnchor.self,
            expectedCase: .valueNotFound,
            codingPath: ["kind"]
        )
        assertDecodingError(
            Data(#"{"kind":1}"#.utf8),
            as: SyncOperationAnchor.self,
            expectedCase: .typeMismatch,
            codingPath: ["kind"]
        )
    }

    func testUnknownAndContradictoryAnchorShapesUsePayloadErrors() throws {
        XCTAssertThrowsError(try decodeAnchor(#"{"kind":"unknown"}"#)) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .unsupportedAnchorKind(rawValue: "unknown")
            )
        }
        XCTAssertThrowsError(try decodeAnchor(#"{"kind":"before"}"#)) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .invalidAnchorShape(
                    kind: .before,
                    hasLeftElementID: false,
                    hasRightElementID: false
                )
            )
        }

        let left = try element(operation(1), 0)
        let contradictory = elementJSON(kind: "empty", left: left)
        XCTAssertThrowsError(try decodeAnchor(contradictory)) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .invalidAnchorShape(
                    kind: .empty,
                    hasLeftElementID: true,
                    hasRightElementID: false
                )
            )
        }
    }

    func testAnyExplicitNullEndpointIsValueNotFoundAtEndpointPath() {
        for (json, expectedPath) in [
            (#"{"kind":"empty","leftElementID":null}"#, ["leftElementID"]),
            (#"{"kind":"after","rightElementID":null}"#, ["rightElementID"])
        ] {
            assertDecodingError(
                Data(json.utf8),
                as: SyncOperationAnchor.self,
                expectedCase: .valueNotFound,
                codingPath: expectedPath
            )
        }
    }

    func testMalformedPresentEndpointPreservesIdentityError() {
        let malformed = #"{"kind":"after","leftElementID":{"elementOffset":-1,"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":1}}}"#

        XCTAssertThrowsError(try decodeAnchor(malformed)) { error in
            XCTAssertEqual(
                error as? SyncSequenceIdentityError,
                .negativeElementOffset(-1)
            )
        }
    }

    func testDecodedBetweenAnchorPreservesIdenticalEndpointError() throws {
        let endpoint = try element(operation(1), 0)
        let malformed = elementJSON(
            kind: "between",
            left: endpoint,
            right: endpoint
        )

        XCTAssertThrowsError(try decodeAnchor(malformed)) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                .identicalOriginEndpoints(endpoint)
            )
        }
    }

    func testDecodedSpanPreservesValidatedInitializerErrors() {
        assertSpanError(start: -1, length: 1, expected: .negativeRangeOffset(-1))
        assertSpanError(start: 0, length: 0, expected: .nonpositiveRangeLength(0))
        assertSpanError(start: 0, length: -1, expected: .nonpositiveRangeLength(-1))
        assertSpanError(
            start: Int.max,
            length: 1,
            expected: .rangeOverflow(startOffset: Int.max, utf16Length: 1)
        )
    }

    func testDeletePayloadRejectsEmptyDuplicateOverlapAndDecreasingSpans() throws {
        XCTAssertThrowsError(try SyncTextDeleteOperationPayload(
            operationID: operation(10),
            deletedElementIDSpans: []
        )) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .emptyDeletedElementIDSpans
            )
        }

        let first = try span(operation(1), start: 0, length: 2)
        let later = try span(operation(1), start: 2)
        XCTAssertThrowsError(try deletePayload([first, first])) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .duplicateDeletedElementIDSpan(first)
            )
        }

        let overlap = try span(operation(1), start: 1, length: 2)
        XCTAssertThrowsError(try deletePayload([first, overlap])) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .overlappingDeletedElementIDSpans(
                    previous: first,
                    current: overlap
                )
            )
        }

        XCTAssertThrowsError(try deletePayload([later, first])) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .noncanonicalDeletedElementIDSpanOrder(
                    previous: later,
                    current: first
                )
            )
        }
    }

    func testCompleteArrayDuplicateDetectionPrecedesOrderFailure() throws {
        let zero = try span(operation(1), start: 0)
        let two = try span(operation(1), start: 2)

        XCTAssertThrowsError(try deletePayload([zero, two, zero])) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .duplicateDeletedElementIDSpan(zero)
            )
        }
    }

    func testAdjacentAndInterleavedSpansRemainValidAndOrdered() throws {
        let spans = [
            try span(operation(1), start: 0),
            try span(operation(2), start: 0),
            try span(operation(1), start: 1)
        ]

        let payload = try deletePayload(spans)

        XCTAssertEqual(payload.deletedElementIDSpans, spans)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SyncTextDeleteOperationPayload.self,
                from: encoded(payload)
            ),
            payload
        )
    }

    func testRootStateDerivesBeforeBetweenAndAfterAnchorsWithoutMutation() throws {
        let runID = operation(1)
        let state = try state(
            runs: [run(runID, text: "ab")],
            fragments: [fragment(runID, length: 2)]
        )
        let original = state

        XCTAssertEqual(
            try state.operationAnchor(atVisibleUTF16Offset: 0),
            .before(try element(runID, 0))
        )
        XCTAssertEqual(
            try state.operationAnchor(atVisibleUTF16Offset: 1),
            try .between(left: element(runID, 0), right: element(runID, 1))
        )
        XCTAssertEqual(
            try state.operationAnchor(atVisibleUTF16Offset: 2),
            .after(try element(runID, 1))
        )
        XCTAssertEqual(
            try state.insertOperationPayload(
                operationID: operation(10),
                atVisibleUTF16Offset: 1
            ).anchor,
            try .between(left: element(runID, 0), right: element(runID, 1))
        )
        XCTAssertEqual(state, original)
    }

    func testEmptyAndFullyTombstonedStatesUseDifferentAnchors() throws {
        XCTAssertEqual(
            try SyncTextSequenceState.empty.operationAnchor(atVisibleUTF16Offset: 0),
            .empty
        )

        let runID = operation(1)
        let tombstoned = try state(
            runs: [run(runID, text: "😀")],
            fragments: [fragment(runID, length: 2, visibility: .tombstone)]
        )
        XCTAssertEqual(
            try tombstoned.operationAnchor(atVisibleUTF16Offset: 0),
            .after(try element(runID, 1))
        )
    }

    func testLeadingInternalAndTrailingTombstonesUseCanonicalBias() throws {
        let runID = operation(1)
        let leadingAndTrailing = try state(
            runs: [run(runID, text: "abc")],
            fragments: [
                fragment(runID, start: 0, visibility: .tombstone),
                fragment(runID, start: 1),
                fragment(runID, start: 2, visibility: .tombstone)
            ]
        )
        XCTAssertEqual(
            try leadingAndTrailing.operationAnchor(atVisibleUTF16Offset: 0),
            try .between(left: element(runID, 0), right: element(runID, 1))
        )
        XCTAssertEqual(
            try leadingAndTrailing.operationAnchor(atVisibleUTF16Offset: 1),
            .after(try element(runID, 2))
        )

        let internalTombstone = try state(
            runs: [run(runID, text: "abc")],
            fragments: [
                fragment(runID, start: 0),
                fragment(runID, start: 1, visibility: .tombstone),
                fragment(runID, start: 2)
            ]
        )
        XCTAssertEqual(
            try internalTombstone.operationAnchor(atVisibleUTF16Offset: 1),
            try .between(left: element(runID, 1), right: element(runID, 2))
        )
    }

    func testAnchorsCrossOperationOwnedRunBoundaries() throws {
        let parentID = operation(1)
        let childID = operation(2)
        let value = try state(
            runs: [
                run(parentID, text: "ab"),
                run(
                    childID,
                    left: element(parentID, 0),
                    right: element(parentID, 1),
                    text: "x"
                )
            ],
            fragments: [
                fragment(parentID, start: 0),
                fragment(childID),
                fragment(parentID, start: 1)
            ]
        )

        XCTAssertEqual(
            try value.operationAnchor(atVisibleUTF16Offset: 1),
            try .between(left: element(parentID, 0), right: element(childID, 0))
        )
        XCTAssertEqual(
            try value.operationAnchor(atVisibleUTF16Offset: 2),
            try .between(left: element(childID, 0), right: element(parentID, 1))
        )
    }

    func testSupplementaryScalarAnchorAndDeletionBoundariesAreSafe() throws {
        let runID = operation(1)
        let value = try state(
            runs: [run(runID, text: "a😀b")],
            fragments: [fragment(runID, length: 4)]
        )

        XCTAssertEqual(
            try value.operationAnchor(atVisibleUTF16Offset: 1),
            try .between(left: element(runID, 0), right: element(runID, 1))
        )
        XCTAssertEqual(
            try value.operationAnchor(atVisibleUTF16Offset: 3),
            try .between(left: element(runID, 2), right: element(runID, 3))
        )
        assertStateError(.visibleOffsetSplitsSurrogatePair(2)) {
            _ = try value.operationAnchor(atVisibleUTF16Offset: 2)
        }

        let payload = try value.deleteOperationPayload(
            operationID: operation(10),
            inVisibleUTF16Range: 1..<3
        )
        XCTAssertEqual(payload.deletedElementIDSpans, [
            try span(runID, start: 1, length: 2)
        ])
        assertStateError(.visibleRangeSplitsSurrogatePair(2)) {
            _ = try value.deleteOperationPayload(
                operationID: operation(10),
                inVisibleUTF16Range: 1..<2
            )
        }
    }

    func testDeleteFactoryPreservesCompactMultiRunStructuralOrder() throws {
        let parentID = operation(1)
        let childID = operation(2)
        let value = try state(
            runs: [
                run(parentID, text: "ab"),
                run(
                    childID,
                    left: element(parentID, 0),
                    right: element(parentID, 1),
                    text: "x"
                )
            ],
            fragments: [
                fragment(parentID, start: 0),
                fragment(childID),
                fragment(parentID, start: 1)
            ]
        )

        let payload = try value.deleteOperationPayload(
            operationID: operation(10),
            inVisibleUTF16Range: 0..<3
        )

        XCTAssertEqual(payload.deletedElementIDSpans, [
            try span(parentID, start: 0),
            try span(childID, start: 0),
            try span(parentID, start: 1)
        ])
    }

    func testTombstonedDescendantKeepsAdjacentParentSpansSeparate() throws {
        let parentID = operation(1)
        let childID = operation(2)
        let value = try state(
            runs: [
                run(parentID, text: "ab"),
                run(
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
        let original = value

        let payload = try value.deleteOperationPayload(
            operationID: operation(10),
            inVisibleUTF16Range: 0..<2
        )

        XCTAssertEqual(payload.deletedElementIDSpans, [
            try span(parentID, start: 0),
            try span(parentID, start: 1)
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(
                SyncTextDeleteOperationPayload.self,
                from: encoded(payload)
            ),
            payload
        )
        XCTAssertEqual(value, original)
    }

    func testEmptyDeleteRangeIsRejectedAfterStateValidation() throws {
        let runID = operation(1)
        let value = try state(
            runs: [run(runID, text: "a")],
            fragments: [fragment(runID)]
        )

        XCTAssertThrowsError(try value.deleteOperationPayload(
            operationID: operation(10),
            inVisibleUTF16Range: 0..<0
        )) { error in
            XCTAssertEqual(
                error as? SyncTextOperationPayloadError,
                .emptyDeletedElementIDSpans
            )
        }
    }

    func testLargeContiguousDeletionProducesOneSpan() throws {
        let runID = operation(1)
        let length = 65_536
        let value = try state(
            runs: [run(runID, text: String(repeating: "x", count: length))],
            fragments: [fragment(runID, length: length)]
        )

        let payload = try value.deleteOperationPayload(
            operationID: operation(10),
            inVisibleUTF16Range: 0..<length
        )

        XCTAssertEqual(payload.deletedElementIDSpans, [
            try span(runID, start: 0, length: length)
        ])
    }

    private func operation(_ counter: UInt64) -> SyncOperationID {
        SyncOperationID(
            deviceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            localCounter: counter
        )
    }

    private func element(
        _ operationID: SyncOperationID,
        _ offset: Int
    ) throws -> SyncTextElementID {
        try SyncTextElementID(operationID: operationID, elementOffset: offset)
    }

    private func span(
        _ operationID: SyncOperationID,
        start: Int,
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

    private func state(
        runs: [SyncTextSequenceRun],
        fragments: [SyncTextSequenceFragment]
    ) throws -> SyncTextSequenceState {
        try SyncTextSequenceState(runs: runs, fragments: fragments)
    }

    private func deletePayload(
        _ spans: [SyncTextElementIDSpan]
    ) throws -> SyncTextDeleteOperationPayload {
        try SyncTextDeleteOperationPayload(
            operationID: operation(10),
            deletedElementIDSpans: spans
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeAnchor(_ json: String) throws -> SyncOperationAnchor {
        try JSONDecoder().decode(SyncOperationAnchor.self, from: Data(json.utf8))
    }

    private func elementJSON(
        kind: String,
        left: SyncTextElementID? = nil,
        right: SyncTextElementID? = nil
    ) -> String {
        var fields = [#""kind":"\#(kind)""#]
        if let left {
            fields.append(#""leftElementID":\#(identityJSON(left))"#)
        }
        if let right {
            fields.append(#""rightElementID":\#(identityJSON(right))"#)
        }
        return "{\(fields.sorted().joined(separator: ","))}"
    }

    private func identityJSON(_ value: SyncTextElementID) -> String {
        #"{"elementOffset":\#(value.elementOffset),"operationID":{"deviceID":"\#(value.operationID.deviceID.uuidString.lowercased())","localCounter":\#(value.operationID.localCounter)}}"#
    }

    private func spanJSON(start: Int, length: Int) -> String {
        #"{"operationID":{"deviceID":"11111111-1111-1111-1111-111111111111","localCounter":1},"startOffset":\#(start),"utf16Length":\#(length)}"#
    }

    private func assertSpanError(
        start: Int,
        length: Int,
        expected: SyncTextSequenceStateError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SyncTextElementIDSpan.self,
                from: Data(spanJSON(start: start, length: length).utf8)
            ),
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

    private func assertVersionMatrix<T: Decodable>(
        fixture: String,
        type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for rawValue in [UInt32.zero, 2, UInt32.max] {
            let data = replacingVersion(in: fixture, with: String(rawValue))
            XCTAssertThrowsError(
                try JSONDecoder().decode(type, from: data),
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(
                    error as? SyncTextOperationPayloadError,
                    .unsupportedPayloadVersion(rawValue: rawValue),
                    file: file,
                    line: line
                )
            }
        }

        let missing = Data(
            fixture.replacingOccurrences(of: #","formatVersion":1"#, with: "").utf8
        )
        assertDecodingError(
            missing,
            as: type,
            expectedCase: .keyNotFound,
            codingPath: [],
            missingKey: "formatVersion",
            file: file,
            line: line
        )
        for literal in ["null"] {
            assertDecodingError(
                replacingVersion(in: fixture, with: literal),
                as: type,
                expectedCase: .valueNotFound,
                codingPath: ["formatVersion"],
                file: file,
                line: line
            )
        }
        for literal in [#""1""#, "true"] {
            assertDecodingError(
                replacingVersion(in: fixture, with: literal),
                as: type,
                expectedCase: .typeMismatch,
                codingPath: ["formatVersion"],
                file: file,
                line: line
            )
        }
        for literal in ["-1", "1.5", "4294967296"] {
            assertDecodingError(
                replacingVersion(in: fixture, with: literal),
                as: type,
                expectedCase: .dataCorrupted,
                codingPath: [],
                file: file,
                line: line
            )
        }

        XCTAssertNoThrow(
            try JSONDecoder().decode(
                type,
                from: replacingVersion(in: fixture, with: "1.0")
            ),
            file: file,
            line: line
        )
    }

    private func replacingVersion(
        in fixture: String,
        with literal: String
    ) -> Data {
        Data(
            fixture.replacingOccurrences(
                of: #""formatVersion":1"#,
                with: #""formatVersion":\#(literal)"#
            ).utf8
        )
    }

    private enum ExpectedDecodingErrorCase {
        case keyNotFound
        case valueNotFound
        case typeMismatch
        case dataCorrupted
    }

    private func assertDecodingError<T: Decodable>(
        _ data: Data,
        as type: T.Type,
        expectedCase: ExpectedDecodingErrorCase,
        codingPath: [String],
        missingKey: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(type, from: data),
            file: file,
            line: line
        ) { error in
            switch (expectedCase, error) {
            case (.keyNotFound, DecodingError.keyNotFound(let key, let context)):
                XCTAssertEqual(key.stringValue, missingKey, file: file, line: line)
                XCTAssertEqual(
                    context.codingPath.map(\.stringValue),
                    codingPath,
                    file: file,
                    line: line
                )
            case (.valueNotFound, DecodingError.valueNotFound(_, let context)),
                 (.typeMismatch, DecodingError.typeMismatch(_, let context)),
                 (.dataCorrupted, DecodingError.dataCorrupted(let context)):
                XCTAssertEqual(
                    context.codingPath.map(\.stringValue),
                    codingPath,
                    file: file,
                    line: line
                )
            default:
                XCTFail(
                    "Unexpected decoding error: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

private extension String {
    func replacingOccurrences(
        of target: String,
        with replacement: String,
        maxReplacements: Int
    ) -> String {
        var result = self
        var searchStart = result.startIndex
        for _ in 0..<maxReplacements {
            guard let range = result.range(
                of: target,
                range: searchStart..<result.endIndex
            ) else {
                break
            }
            result.replaceSubrange(range, with: replacement)
            searchStart = result.index(
                range.lowerBound,
                offsetBy: replacement.count
            )
        }
        return result
    }
}
