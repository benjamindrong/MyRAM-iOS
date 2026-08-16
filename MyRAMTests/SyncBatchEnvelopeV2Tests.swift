import AnchoredSequenceCore
import Foundation
import XCTest
@testable import MyRAM

final class SyncBatchEnvelopeV2Tests: XCTestCase {
    private let noteID = UUID(uuidString: "17400000-0000-0000-0000-000000000003")!
    private let deviceID = UUID(uuidString: "17400000-0000-0000-0000-000000000002")!
    private let leftAnchorOperationID = SyncOperationID(
        deviceID: UUID(uuidString: "17400000-0000-0000-0000-000000000004")!,
        localCounter: 4
    )
    private let rightAnchorOperationID = SyncOperationID(
        deviceID: UUID(uuidString: "17400000-0000-0000-0000-000000000005")!,
        localCounter: 5
    )

    func testSchemaIsDerivedFromBodyRepresentation() throws {
        XCTAssertEqual(try roundTrip(metadataBatch()).schemaVersion, .v1)
        XCTAssertEqual(try roundTrip(legacyBatch()).schemaVersion, .v1)

        let anchored = try roundTrip(anchoredBatch())
        XCTAssertEqual(anchored.schemaVersion, .v2)
        XCTAssertEqual(anchored.batch.bodyOperationRepresentation, .anchored)
        XCTAssertTrue(anchored.batch.changes.contains {
            if case .noteTitleChanged = $0 { return true }
            return false
        })
    }

    func testMixedRepresentationIsRejectedBeforeEnvelopeCreation() throws {
        let mixed = try mixedBatch()

        XCTAssertThrowsError(try SyncBatchEnvelopeCodec.encode(batch: mixed)) {
            XCTAssertEqual(
                $0 as? SyncBatchEnvelopeError,
                .mixedBodyOperationRepresentations
            )
        }
    }

    func testCraftedSchemaRepresentationMismatchesAreRejected() throws {
        let anchoredAsV1 = try replacingSchema(
            with: 1,
            in: SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        )
        assertEnvelopeError(
            .representationMismatch(schema: .v1, representation: .anchored),
            decoding: anchoredAsV1
        )

        let legacyAsV2 = try replacingSchema(
            with: 2,
            in: SyncBatchEnvelopeCodec.encode(batch: legacyBatch())
        )
        assertEnvelopeError(
            .representationMismatch(schema: .v2, representation: .legacy),
            decoding: legacyAsV2
        )

        let metadataAsV2 = try replacingSchema(
            with: 2,
            in: SyncBatchEnvelopeCodec.encode(batch: metadataBatch())
        )
        assertEnvelopeError(
            .representationMismatch(schema: .v2, representation: .none),
            decoding: metadataAsV2
        )

        assertEnvelopeError(
            .mixedBodyOperationRepresentations,
            decoding: try craftedMixedV2Data()
        )
    }

    func testUnsupportedIntegerVersionsFailBeforeNestedBatchDecode() {
        for version in [0, -1, 3] {
            let data = Data(
                "{\"schemaVersion\":\(version),\"batch\":\"malformed\"}".utf8
            )
            assertEnvelopeError(
                .unsupportedSchemaVersion(version),
                decoding: data
            )
        }
    }

    func testMalformedVersionsRemainDecodingErrors() {
        let cases = [
            #"{"batch":"malformed"}"#,
            #"{"schemaVersion":null,"batch":"malformed"}"#,
            #"{"schemaVersion":"2","batch":"malformed"}"#,
            #"{"schemaVersion":1.5,"batch":"malformed"}"#,
            #"{"schemaVersion":9223372036854775808,"batch":"malformed"}"#
        ]

        for fixture in cases {
            XCTAssertThrowsError(
                try SyncBatchEnvelopeCodec.decode(Data(fixture.utf8))
            ) {
                XCTAssertTrue($0 is DecodingError, "Unexpected error: \($0)")
            }
        }
    }

    func testV1EncodingRemainsStructurallyCompatibleAndBidirectional() throws {
        let batch = legacyBatch()
        let current = try SyncBatchEnvelopeCodec.encode(batch: batch)
        let legacy = try JSONEncoder().encode(
            LegacyV1Envelope(schemaVersion: 1, batch: batch)
        )

        XCTAssertEqual(try jsonObject(current), try jsonObject(legacy))
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyV1Envelope.self, from: current).batch,
            batch
        )
        XCTAssertEqual(try SyncBatchEnvelopeCodec.decode(legacy).batch, batch)
    }

    func testV2EncodingIsCanonicalAndMatchesFrozenFixture() throws {
        let first = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        let second = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        let decoded = try SyncBatchEnvelopeCodec.decode(first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, Data(Self.frozenV2JSON.utf8))
        XCTAssertEqual(decoded.schemaVersion, .v2)
        guard let firstChange = decoded.batch.changes.first,
              case .noteBodyTextInsertedAnchored(let inserted) = firstChange else {
            return XCTFail("Expected anchored insertion fixture")
        }
        XCTAssertEqual(inserted.payload.anchor.kind, .between)
        XCTAssertEqual(
            inserted.payload.anchor.leftElementID,
            try SyncTextElementID(
                operationID: leftAnchorOperationID,
                elementOffset: 0
            )
        )
        XCTAssertEqual(
            inserted.payload.anchor.rightElementID,
            try SyncTextElementID(
                operationID: rightAnchorOperationID,
                elementOffset: 0
            )
        )
    }

    func testOuterV1CarriesInnerV2ThroughActivatedProductionTransport() throws {
        let batch = try anchoredBatch()
        let innerV2 = try SyncBatchEnvelopeCodec.encode(batch: batch)
        let outerV1 = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: innerV2
        )
        let decodedOuter = try MultipeerSyncMessageCoding.decodeMessage(from: outerV1)

        XCTAssertEqual(decodedOuter.kind.rawValue, "myram.batchSync.v1")
        XCTAssertEqual(decodedOuter.schemaVersion, 1)
        XCTAssertEqual(
            try MultipeerSyncMessageCoding.decodeBatchPayload(decodedOuter.payload)
                .schemaVersion,
            .v2
        )

        XCTAssertNoThrow(try MultipeerSyncMessageCoding.encodeBatch(batch))
        XCTAssertTrue(SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    func testPreMYR174PeerRejectsInnerV2BeforeDownstreamEffect() throws {
        let innerV2 = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        let outerV1 = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: innerV2
        )
        let decodedOuter = try JSONDecoder().decode(
            PreMYR174OuterEnvelope.self,
            from: outerV1
        )
        let decodedInner = try JSONDecoder().decode(
            PreMYR174InnerEnvelope.self,
            from: decodedOuter.payload
        )
        var downstreamCount = 0

        XCTAssertEqual(decodedOuter.kind, .batchSync)
        XCTAssertEqual(decodedOuter.schemaVersion, 1)
        XCTAssertEqual(decodedInner.schemaVersion, 2)
        XCTAssertEqual(decodedInner.batch, try anchoredBatch())
        XCTAssertFalse(try preMYR174Admit(outerV1) { downstreamCount += 1 })
        XCTAssertEqual(downstreamCount, 0)
    }

    private static let frozenV2JSON = #"{"batch":{"batchSequence":7,"changes":[{"noteBodyTextInsertedAnchored":{"_0":{"baseContentHash":"096d92ee9c796a7c2419a6ff814b2c0322f13c2eae282894002f99e433ec5641","modifiedAt":-978306199,"noteID":"17400000-0000-0000-0000-000000000003","payload":{"anchor":{"kind":"between","leftElementID":{"elementOffset":0,"operationID":{"deviceID":"17400000-0000-0000-0000-000000000004","localCounter":4}},"rightElementID":{"elementOffset":0,"operationID":{"deviceID":"17400000-0000-0000-0000-000000000005","localCounter":5}}},"formatVersion":1,"operationID":{"deviceID":"17400000-0000-0000-0000-000000000002","localCounter":9}},"text":"A","utf16Offset":1}}},{"noteTitleChanged":{"_0":{"modifiedAt":-978306198,"noteID":"17400000-0000-0000-0000-000000000003","title":"Title"}}}],"createdAt":-978306200,"id":"17400000-0000-0000-0000-000000000001","originDeviceID":"17400000-0000-0000-0000-000000000002"},"schemaVersion":2}"#

    private struct LegacyV1Envelope: Codable {
        let schemaVersion: Int
        let batch: SyncBatch
    }

    private struct PreMYR174OuterEnvelope: Decodable {
        let kind: MultipeerSyncMessageKind
        let schemaVersion: Int
        let payload: Data
    }

    private struct PreMYR174InnerEnvelope: Decodable {
        let schemaVersion: Int
        let batch: SyncBatch
    }

    private func preMYR174Admit(
        _ data: Data,
        downstream: () -> Void
    ) throws -> Bool {
        let outer = try JSONDecoder().decode(PreMYR174OuterEnvelope.self, from: data)
        guard outer.kind == .batchSync, outer.schemaVersion <= 1 else {
            return false
        }
        let inner = try JSONDecoder().decode(
            PreMYR174InnerEnvelope.self,
            from: outer.payload
        )
        guard inner.schemaVersion <= 1 else {
            return false
        }
        downstream()
        return true
    }

    private func roundTrip(_ batch: SyncBatch) throws -> SyncBatchEnvelope {
        try SyncBatchEnvelopeCodec.decode(
            SyncBatchEnvelopeCodec.encode(batch: batch)
        )
    }

    private func metadataBatch() -> SyncBatch {
        batch(changes: [
            .noteTitleChanged(.init(
                noteID: noteID,
                title: "Title",
                modifiedAt: Date(timeIntervalSince1970: 1_002)
            ))
        ])
    }

    private func legacyBatch() -> SyncBatch {
        batch(changes: [
            .noteBodyTextInserted(.init(
                noteID: noteID,
                utf16Offset: 0,
                text: "A",
                modifiedAt: Date(timeIntervalSince1970: 1_001)
            ))
        ])
    }

    private func anchoredBatch() throws -> SyncBatch {
        let state = try anchoredFixtureState()
        let anchored = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 1,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_001),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: state.visibleText),
            operationID: SyncOperationID(deviceID: deviceID, localCounter: 9),
            state: state
        )
        return batch(changes: [
            anchored,
            .noteTitleChanged(.init(
                noteID: noteID,
                title: "Title",
                modifiedAt: Date(timeIntervalSince1970: 1_002)
            ))
        ])
    }

    private func anchoredFixtureState() throws -> SyncTextSequenceState {
        let leftElementID = try SyncTextElementID(
            operationID: leftAnchorOperationID,
            elementOffset: 0
        )
        return try SyncTextSequenceState(
            runs: [
                try SyncTextSequenceRun(
                    operationID: leftAnchorOperationID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: nil,
                        rightElementID: nil
                    ),
                    text: "L"
                ),
                try SyncTextSequenceRun(
                    operationID: rightAnchorOperationID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: leftElementID,
                        rightElementID: nil
                    ),
                    text: "R"
                )
            ],
            fragments: [
                try SyncTextSequenceFragment(
                    operationID: leftAnchorOperationID,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                try SyncTextSequenceFragment(
                    operationID: rightAnchorOperationID,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                )
            ]
        )
    }

    private func mixedBatch() throws -> SyncBatch {
        batch(changes: [legacyBatch().changes[0], try anchoredBatch().changes[0]])
    }

    private func batch(changes: [SyncBatchChange]) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: "17400000-0000-0000-0000-000000000001")!,
            originDeviceID: deviceID,
            createdAt: Date(timeIntervalSince1970: 1_000),
            batchSequence: 7,
            changes: changes
        )
    }

    private func replacingSchema(with schema: Int, in data: Data) throws -> Data {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = schema
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func craftedMixedV2Data() throws -> Data {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
            ) as? [String: Any]
        )
        var batchObject = try XCTUnwrap(object["batch"] as? [String: Any])
        var changes = try XCTUnwrap(batchObject["changes"] as? [Any])
        changes.append(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyBatch().changes[0])
            )
        )
        batchObject["changes"] = changes
        object["batch"] = batchObject
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertEnvelopeError(
        _ expected: SyncBatchEnvelopeError,
        decoding data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SyncBatchEnvelopeCodec.decode(data),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? SyncBatchEnvelopeError, expected, file: file, line: line)
        }
    }

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? NSDictionary
        )
    }
}
