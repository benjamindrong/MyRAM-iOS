import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncTextLegacyBootstrapTests: XCTestCase {
    func testEmptyBodyProducesCanonicalEmptyState() throws {
        let state = try SyncTextLegacyBootstrap.makeState(
            noteID: noteID(),
            body: ""
        )

        XCTAssertEqual(state, .empty)
        XCTAssertTrue(state.runs.isEmpty)
        XCTAssertTrue(state.fragments.isEmpty)
        XCTAssertEqual(state.visibleText, "")
        XCTAssertEqual(state.visibleUTF16Count, 0)
        XCTAssertEqual(state.tombstonedUTF16Count, 0)
    }

    func testV1KnownVectorFreezesDeterministicOperationID() throws {
        let state = try SyncTextLegacyBootstrap.makeState(
            noteID: uuid("00000000-0000-0000-0000-000000000001"),
            body: "Hello 👋",
            formatVersion: .v1
        )

        XCTAssertEqual(
            try XCTUnwrap(state.runs.first).operationID,
            SyncOperationID(
                deviceID: uuid("40be31f3-909e-84c5-8ffb-660683e73ce8"),
                localCounter: 3_307_257_957_749_224_882
            )
        )
    }

    func testIdenticalInputsProduceIdenticalBootstrapState() throws {
        let noteID = noteID()
        let body = "Repeatable 👋\nbody"

        let first = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: body)
        let second = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: body)
        let third = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: body)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    func testDefaultFormatMatchesExplicitV1() throws {
        let noteID = noteID()
        let body = "Default format"

        let defaultState = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: body)
        let explicitState = try SyncTextLegacyBootstrap.makeState(
            noteID: noteID,
            body: body,
            formatVersion: .v1
        )

        XCTAssertEqual(defaultState, explicitState)
    }

    func testSameBodyUnderDifferentNoteIDsProducesDifferentRunIDs() throws {
        let body = "Same body"
        let first = try SyncTextLegacyBootstrap.makeState(
            noteID: uuid("00000000-0000-0000-0000-000000000001"),
            body: body
        )
        let second = try SyncTextLegacyBootstrap.makeState(
            noteID: uuid("00000000-0000-0000-0000-000000000002"),
            body: body
        )

        XCTAssertNotEqual(try operationID(in: first), try operationID(in: second))
    }

    func testDifferentBodiesUnderSameNoteIDProduceDifferentRunIDs() throws {
        let noteID = noteID()
        let first = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: "Body A")
        let second = try SyncTextLegacyBootstrap.makeState(noteID: noteID, body: "Body B")

        XCTAssertNotEqual(try operationID(in: first), try operationID(in: second))
    }

    func testCanonicallyEquivalentBodiesWithDifferentUTF16TopologyDoNotAlias() throws {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let noteID = noteID()

        let precomposedState = try SyncTextLegacyBootstrap.makeState(
            noteID: noteID,
            body: precomposed
        )
        let decomposedState = try SyncTextLegacyBootstrap.makeState(
            noteID: noteID,
            body: decomposed
        )

        XCTAssertNotEqual(precomposed.utf16.count, decomposed.utf16.count)
        XCTAssertNotEqual(
            try operationID(in: precomposedState),
            try operationID(in: decomposedState)
        )
        XCTAssertEqual(Array(precomposedState.visibleText.utf16), Array(precomposed.utf16))
        XCTAssertEqual(Array(decomposedState.visibleText.utf16), Array(decomposed.utf16))
        XCTAssertNotEqual(
            Array(precomposedState.visibleText.utf16),
            Array(decomposedState.visibleText.utf16)
        )
    }

    func testNonemptyBodyProducesOneRunAndOneVisibleFragment() throws {
        let body = "Exact 👋\r\nbody"
        let state = try SyncTextLegacyBootstrap.makeState(noteID: noteID(), body: body)
        let run = try XCTUnwrap(state.runs.first)
        let fragment = try XCTUnwrap(state.fragments.first)

        XCTAssertEqual(state.runs.count, 1)
        XCTAssertNil(run.origin.leftElementID)
        XCTAssertNil(run.origin.rightElementID)
        XCTAssertEqual(Array(run.text.utf16), Array(body.utf16))
        XCTAssertEqual(state.fragments.count, 1)
        XCTAssertEqual(fragment.operationID, run.operationID)
        XCTAssertEqual(fragment.startOffset, 0)
        XCTAssertEqual(fragment.utf16Length, body.utf16.count)
        XCTAssertEqual(fragment.visibility, .visible)
        XCTAssertEqual(Array(state.visibleText.utf16), Array(body.utf16))
        XCTAssertEqual(state.visibleUTF16Count, body.utf16.count)
        XCTAssertEqual(state.tombstonedUTF16Count, 0)
    }

    func testSupplementaryScalarRetainsTwoElementOffsets() throws {
        let body = "A👋B"
        let state = try SyncTextLegacyBootstrap.makeState(noteID: noteID(), body: body)
        let operationID = try operationID(in: state)
        let elementIDs = operationID.elementIDs(for: body)

        XCTAssertEqual(body.utf16.count, 4)
        XCTAssertEqual(elementIDs.count, 4)
        XCTAssertEqual(elementIDs[0].elementOffset, 0)
        XCTAssertEqual(elementIDs[1].elementOffset, 1)
        XCTAssertEqual(elementIDs[2].elementOffset, 2)
        XCTAssertEqual(elementIDs[3].elementOffset, 3)
        XCTAssertEqual(try state.leftElementID(beforeVisibleUTF16Offset: 1), elementIDs[0])
        XCTAssertEqual(try state.leftElementID(beforeVisibleUTF16Offset: 3), elementIDs[2])
        XCTAssertEqual(try state.leftElementID(beforeVisibleUTF16Offset: 4), elementIDs[3])
        XCTAssertThrowsError(try state.leftElementID(beforeVisibleUTF16Offset: 2)) { error in
            XCTAssertEqual(
                error as? SyncTextSequenceStateError,
                .visibleOffsetSplitsSurrogatePair(2)
            )
        }
        XCTAssertEqual(Array(state.visibleText.utf16), Array(body.utf16))
    }

    func testSyntheticLegacyRunIDUsesVersion8RFCVariantUUID() throws {
        let state = try SyncTextLegacyBootstrap.makeState(
            noteID: noteID(),
            body: "Synthetic identity"
        )
        let bytes = rawUUIDBytes(try operationID(in: state).deviceID)

        XCTAssertEqual(bytes[6] >> 4, 8)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }

    func testLargeBodyStillUsesOneRunAndOneFragment() throws {
        let body = String(repeating: "a", count: 65_536)
        let state = try SyncTextLegacyBootstrap.makeState(noteID: noteID(), body: body)

        XCTAssertEqual(body.utf16.count, 65_536)
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.fragments.count, 1)
        XCTAssertEqual(state.visibleUTF16Count, 65_536)
        XCTAssertEqual(state.fragments.first?.utf16Length, 65_536)
    }

    private func operationID(in state: SyncTextSequenceState) throws -> SyncOperationID {
        try XCTUnwrap(state.runs.first).operationID
    }

    private func noteID() -> UUID {
        uuid("10000000-2000-3000-4000-500000000006")
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func rawUUIDBytes(_ uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15
        ]
    }
}
