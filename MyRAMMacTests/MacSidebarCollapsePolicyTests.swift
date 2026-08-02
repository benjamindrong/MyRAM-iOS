import AnchoredSequenceCore
import Foundation
import XCTest
@testable import MyRAMMac

final class MacSidebarCollapsePolicyTests: XCTestCase {
    func testExpandedCollapsesWhenWidthDropsBelowThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .expanded,
            availableWidth: 400,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .autoCollapsed)
    }

    func testExpandedStaysExpandedAboveThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .expanded,
            availableWidth: 600,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .expanded)
    }

    func testAutoCollapsedExpandsWhenWidthGrowsPastThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .autoCollapsed,
            availableWidth: 600,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .expanded)
    }

    func testAutoCollapsedStaysCollapsedBelowThreshold() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .autoCollapsed,
            availableWidth: 400,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .autoCollapsed)
    }

    func testManuallyCollapsedNeverAutoExpandsWhenWidthGrows() {
        let nextState = MacSidebarCollapsePolicy.stateAfterWidthChange(
            currentState: .manuallyCollapsed,
            availableWidth: 800,
            collapseThreshold: 500
        )

        XCTAssertEqual(nextState, .manuallyCollapsed)
    }

    func testManualVisibilityChangeToHiddenMarksManuallyCollapsed() {
        XCTAssertEqual(
            MacSidebarCollapsePolicy.stateAfterManualVisibilityChange(isSidebarVisible: false),
            .manuallyCollapsed
        )
    }

    func testManualVisibilityChangeToVisibleMarksExpanded() {
        XCTAssertEqual(
            MacSidebarCollapsePolicy.stateAfterManualVisibilityChange(isSidebarVisible: true),
            .expanded
        )
    }

    func testWindowFrameExpandingSidebarToLeftPreservesRightEdge() {
        let frame = MacSidebarCollapsePolicy.windowFrameExpandingSidebarToLeft(
            currentFrame: CGRect(x: 500, y: 100, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            sidebarWidth: 260
        )

        XCTAssertEqual(frame.minX, 240)
        XCTAssertEqual(frame.width, 860)
        XCTAssertEqual(frame.maxX, 1100)
        XCTAssertEqual(frame.height, 400)
    }

    func testWindowFrameExpandingSidebarToLeftClampsToVisibleFrame() {
        let frame = MacSidebarCollapsePolicy.windowFrameExpandingSidebarToLeft(
            currentFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            sidebarWidth: 260
        )

        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, 700)
        XCTAssertEqual(frame.maxX, 700)
    }
}

final class SyncBatchEnvelopeV2Tests: XCTestCase {
    private let noteID = UUID(uuidString: "17400000-0000-0000-0000-000000000003")!
    private let deviceID = UUID(uuidString: "17400000-0000-0000-0000-000000000002")!

    func testSchemaIsDerivedFromBodyRepresentation() throws {
        XCTAssertEqual(try decoded(metadataBatch()).schemaVersion, 1)
        XCTAssertEqual(try decoded(legacyBatch()).schemaVersion, 1)
        XCTAssertEqual(try decoded(anchoredBatch()).schemaVersion, 2)
    }

    func testMixedRepresentationCannotBeEncoded() throws {
        let mixed = batch(changes: [
            legacyBatch().changes[0],
            try anchoredBatch().changes[0]
        ])

        XCTAssertThrowsError(try SyncBatchEnvelopeCodec.encode(batch: mixed)) {
            XCTAssertEqual(
                $0 as? SyncBatchEnvelopeError,
                .mixedBodyOperationRepresentations
            )
        }
    }

    func testUnsupportedVersionFailsBeforeNestedBatchDecode() {
        for version in [0, -1, 3] {
            let data = Data("{\"schemaVersion\":\(version),\"batch\":\"malformed\"}".utf8)
            XCTAssertThrowsError(try SyncBatchEnvelopeCodec.decode(data)) {
                XCTAssertEqual(
                    $0 as? SyncBatchEnvelopeError,
                    .unsupportedSchemaVersion(version)
                )
            }
        }
    }

    func testSchemaRepresentationMismatchFailsClosed() throws {
        let anchoredAsV1 = try replacingSchema(
            with: 1,
            in: SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        )
        XCTAssertThrowsError(try SyncBatchEnvelopeCodec.decode(anchoredAsV1)) {
            XCTAssertEqual(
                $0 as? SyncBatchEnvelopeError,
                .representationMismatch(schema: .v1, representation: .anchored)
            )
        }

        let legacyAsV2 = try replacingSchema(
            with: 2,
            in: SyncBatchEnvelopeCodec.encode(batch: legacyBatch())
        )
        XCTAssertThrowsError(try SyncBatchEnvelopeCodec.decode(legacyAsV2)) {
            XCTAssertEqual(
                $0 as? SyncBatchEnvelopeError,
                .representationMismatch(schema: .v2, representation: .legacy)
            )
        }
    }

    func testV2EncodingIsCanonicalAndMatchesFrozenFixture() throws {
        let first = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        let second = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, Data(Self.frozenV2JSON.utf8))
    }

    func testV1RemainsStructurallyCompatibleWithLegacyEnvelope() throws {
        let batch = legacyBatch()
        let current = try SyncBatchEnvelopeCodec.encode(batch: batch)
        let legacy = try JSONEncoder().encode(
            LegacyEnvelope(schemaVersion: 1, batch: batch)
        )

        XCTAssertEqual(try jsonObject(current), try jsonObject(legacy))
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyEnvelope.self, from: current).batch,
            batch
        )
    }

    func testOuterV1CanCarryInnerV2WhileProductionTransportRemainsDark() throws {
        let batch = try anchoredBatch()
        let inner = try SyncBatchEnvelopeCodec.encode(batch: batch)
        let outer = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: inner
        )
        let decodedOuter = try MultipeerSyncMessageCoding.decodeMessage(from: outer)

        XCTAssertEqual(decodedOuter.kind, .batchSync)
        XCTAssertEqual(decodedOuter.schemaVersion, 1)
        XCTAssertEqual(
            try MultipeerSyncMessageCoding.decodeBatchPayload(decodedOuter.payload)
                .schemaVersion,
            2
        )

        XCTAssertThrowsError(try MultipeerSyncMessageCoding.encodeBatch(batch)) { error in
            guard let policyError = error as? SyncBatchAnchoredPayloadPolicyError,
                  case .anchoredPayloadDisabled(let boundary, let noteID) = policyError else {
                return XCTFail("Expected anchored payload policy failure")
            }
            XCTAssertEqual(boundary, .transportEncode)
            XCTAssertEqual(noteID, self.noteID)
        }
    }

    func testLegacyPeerRejectsInnerV2BeforeDownstreamEffect() throws {
        let inner = try SyncBatchEnvelopeCodec.encode(batch: anchoredBatch())
        let outer = try MultipeerSyncMessageCoding.encode(
            kind: .batchSync,
            payload: inner
        )
        var downstreamCount = 0

        XCTAssertFalse(try legacyAdmit(outer) { downstreamCount += 1 })
        XCTAssertEqual(downstreamCount, 0)
    }

    private static let frozenV2JSON = #"{"batch":{"batchSequence":7,"changes":[{"noteBodyTextInsertedAnchored":{"_0":{"baseContentHash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","modifiedAt":-978306199,"noteID":"17400000-0000-0000-0000-000000000003","payload":{"anchor":{"kind":"empty"},"formatVersion":1,"operationID":{"deviceID":"17400000-0000-0000-0000-000000000002","localCounter":9}},"text":"A","utf16Offset":0}}},{"noteTitleChanged":{"_0":{"modifiedAt":-978306198,"noteID":"17400000-0000-0000-0000-000000000003","title":"Title"}}}],"createdAt":-978306200,"id":"17400000-0000-0000-0000-000000000001","originDeviceID":"17400000-0000-0000-0000-000000000002"},"schemaVersion":2}"#

    private struct LegacyEnvelope: Codable {
        let schemaVersion: Int
        let batch: SyncBatch
    }

    private struct LegacyOuter: Decodable {
        let kind: MultipeerSyncMessageKind
        let schemaVersion: Int
        let payload: Data
    }

    private func legacyAdmit(
        _ data: Data,
        downstream: () -> Void
    ) throws -> Bool {
        let outer = try JSONDecoder().decode(LegacyOuter.self, from: data)
        guard outer.kind == .batchSync, outer.schemaVersion <= 1 else {
            return false
        }
        let inner = try JSONDecoder().decode(LegacyEnvelope.self, from: outer.payload)
        guard inner.schemaVersion <= 1 else {
            return false
        }
        downstream()
        return true
    }

    private func decoded(_ batch: SyncBatch) throws -> SyncBatchEnvelope {
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
        let state = try SyncTextSequenceState(runs: [], fragments: [])
        let anchored = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_001),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(
                deviceID: deviceID,
                localCounter: 9
            ),
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

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? NSDictionary
        )
    }
}
