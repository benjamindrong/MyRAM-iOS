import Foundation
import XCTest

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncSequenceIdentityTests: XCTestCase {
    // Guards deterministic hash/diagnostic encoding only.
    // This is not the anchored wire-format contract.
    func testOperationIdentityStableEncodingUsesExactCanonicalBytes() throws {
        let identity = operationID()
        let expected = Data(
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":2}"#.utf8
        )

        XCTAssertEqual(try identity.stableEncodedData(), expected)
        XCTAssertEqual(try identity.stableEncodedData(), try identity.stableEncodedData())
        XCTAssertEqual(try SyncOperationID.decodeStableData(expected), identity)
    }

    func testOperationIdentityEncodingCanonicalizesUUIDToLowercase() throws {
        let identity = SyncOperationID(
            deviceID: uuid("ABCDEFAB-CDEF-ABCD-EFAB-ABCDEFABCDEF"),
            localCounter: 2
        )
        let expected = Data(
            #"{"deviceID":"abcdefab-cdef-abcd-efab-abcdefabcdef","localCounter":2}"#.utf8
        )

        XCTAssertEqual(try identity.stableEncodedData(), expected)
    }

    func testOperationIdentityEqualityHashingAndKeyBehavior() {
        let identity = operationID()
        let equalIdentity = operationID()
        let otherDevice = SyncOperationID(
            deviceID: uuid("00000000-0000-0000-0000-000000000002"),
            localCounter: 2
        )
        let otherCounter = SyncOperationID(deviceID: identity.deviceID, localCounter: 3)

        XCTAssertEqual(identity, equalIdentity)
        XCTAssertEqual(identity.hashValue, equalIdentity.hashValue)
        XCTAssertNotEqual(identity, otherDevice)
        XCTAssertNotEqual(identity, otherCounter)
        XCTAssertEqual(Set([identity, equalIdentity, otherDevice, otherCounter]).count, 3)

        let dictionary = [identity: "equal", otherDevice: "device", otherCounter: "counter"]
        XCTAssertEqual(dictionary[equalIdentity], "equal")
        XCTAssertEqual(dictionary.count, 3)
    }

    func testOperationIdentityCounterBoundariesRoundTrip() throws {
        for counter in [UInt64.zero, UInt64.max] {
            let identity = SyncOperationID(deviceID: operationID().deviceID, localCounter: counter)
            XCTAssertEqual(
                try SyncOperationID.decodeStableData(identity.stableEncodedData()),
                identity
            )
        }
    }

    func testStableOperationDecodingMapsStructuralFailuresToMalformedEncoding() {
        let malformedInputs = [
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":-1}"#,
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":18446744073709551616}"#,
            #"{"deviceID":"00000000-0000-0000-0000-000000000001"}"#,
            #"{"deviceID":1,"localCounter":2}"#,
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":"2"}"#,
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":2"#,
            #"not-json"#
        ]

        for input in malformedInputs {
            assertIdentityError(
                try SyncOperationID.decodeStableData(Data(input.utf8)),
                equals: .malformedEncoding
            )
        }
    }

    func testStableOperationDecodingPreservesDeviceIDValidationErrors() {
        let malformed = #"{"deviceID":"not-a-uuid","localCounter":2}"#
        let uppercase = #"{"deviceID":"00000000-0000-0000-0000-00000000000A","localCounter":2}"#

        assertIdentityError(
            try SyncOperationID.decodeStableData(Data(malformed.utf8)),
            equals: .malformedDeviceID("not-a-uuid")
        )
        assertIdentityError(
            try SyncOperationID.decodeStableData(Data(uppercase.utf8)),
            equals: .malformedDeviceID("00000000-0000-0000-0000-00000000000A")
        )
    }

    func testRawOperationDecodingLeavesStructuralFailuresAsDecodingErrors() {
        let negativeCounter = Data(
            #"{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":-1}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(SyncOperationID.self, from: negativeCounter)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // Guards deterministic hash/diagnostic encoding only.
    // This is not the anchored wire-format contract.
    func testElementIdentityStableEncodingUsesExactCanonicalBytes() throws {
        let identity = try SyncTextElementID(operationID: operationID(), elementOffset: 1)
        let expected = Data(
            #"{"elementOffset":1,"operationID":{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":2}}"#.utf8
        )

        XCTAssertEqual(try identity.stableEncodedData(), expected)
        XCTAssertEqual(try SyncTextElementID.decodeStableData(expected), identity)
    }

    func testElementIdentityEqualityHashingAndKeyBehavior() throws {
        let first = try SyncTextElementID(operationID: operationID(), elementOffset: 1)
        let equalFirst = try SyncTextElementID(operationID: operationID(), elementOffset: 1)
        let otherOffset = try SyncTextElementID(operationID: operationID(), elementOffset: 2)
        let otherOperation = try SyncTextElementID(
            operationID: SyncOperationID(deviceID: operationID().deviceID, localCounter: 3),
            elementOffset: 1
        )

        XCTAssertEqual(first, equalFirst)
        XCTAssertEqual(first.hashValue, equalFirst.hashValue)
        XCTAssertNotEqual(first, otherOffset)
        XCTAssertNotEqual(first, otherOperation)
        XCTAssertEqual(Set([first, equalFirst, otherOffset, otherOperation]).count, 3)

        let dictionary = [first: "equal", otherOffset: "offset", otherOperation: "operation"]
        XCTAssertEqual(dictionary[equalFirst], "equal")
        XCTAssertEqual(dictionary.count, 3)
    }

    func testElementIdentityRejectsNegativeOffsetsFromConstructionAndDecoding() {
        assertIdentityError(
            try SyncTextElementID(operationID: operationID(), elementOffset: -1),
            equals: .negativeElementOffset(-1)
        )

        let encoded = Data(
            #"{"elementOffset":-1,"operationID":{"deviceID":"00000000-0000-0000-0000-000000000001","localCounter":2}}"#.utf8
        )
        assertIdentityError(
            try SyncTextElementID.decodeStableData(encoded),
            equals: .negativeElementOffset(-1)
        )
    }

    func testRunDerivesOneIdentityPerUTF16CodeUnit() {
        let text = "A😀B"
        let operationID = operationID()
        let run = operationID.elementIDs(for: text)

        XCTAssertEqual(text.count, 3)
        XCTAssertEqual(text.utf16.count, 4)
        XCTAssertEqual(run.count, text.utf16.count)
        XCTAssertEqual(run.startIndex, 0)
        XCTAssertEqual(run.endIndex, 4)
        XCTAssertEqual(Array(run.indices), [0, 1, 2, 3])
        XCTAssertTrue(run.allSatisfy { $0.operationID == operationID })
        XCTAssertEqual(run.map(\.elementOffset), [0, 1, 2, 3])
        XCTAssertEqual(Array(operationID.elementIDs(for: text)), Array(run))

        let emptyRun = operationID.elementIDs(for: "")
        XCTAssertTrue(emptyRun.isEmpty)
        XCTAssertEqual(emptyRun.startIndex, emptyRun.endIndex)
    }

    func testRunUncheckedDerivationMatchesValidatedConstruction() throws {
        let operationID = operationID()
        let run = operationID.elementIDs(for: "A😀B")

        for index in run.indices {
            let fromRun = run[index]
            let validated = try SyncTextElementID(
                operationID: operationID,
                elementOffset: index
            )

            XCTAssertEqual(fromRun, validated)
        }
    }

    func testExternallySourcedRunLengthValidatesBoundaries() throws {
        let operationID = operationID()

        assertIdentityError(
            try SyncTextElementIDRun(
                operationID: operationID,
                externallySourcedUTF16Count: -1
            ),
            equals: .negativeRunLength(-1)
        )

        let empty = try SyncTextElementIDRun(
            operationID: operationID,
            externallySourcedUTF16Count: 0
        )
        let positive = try SyncTextElementIDRun(
            operationID: operationID,
            externallySourcedUTF16Count: 3
        )

        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.count, empty.utf16Count)
        XCTAssertEqual(positive.count, 3)
        XCTAssertEqual(positive.count, positive.utf16Count)
    }

    func testStringFactoryAlwaysProducesNonnegativeRunLengths() {
        for text in ["", "A", "😀", "A😀B"] {
            let run = operationID().elementIDs(for: text)
            XCTAssertGreaterThanOrEqual(run.utf16Count, 0)
            XCTAssertEqual(run.count, run.utf16Count)
        }
    }

    private func operationID() -> SyncOperationID {
        SyncOperationID(
            deviceID: uuid("00000000-0000-0000-0000-000000000001"),
            localCounter: 2
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func assertIdentityError<T>(
        _ expression: @autoclosure () throws -> T,
        equals expectedError: SyncSequenceIdentityError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? SyncSequenceIdentityError, expectedError, file: file, line: line)
        }
    }
}
