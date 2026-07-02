import XCTest
import NearbySyncCore
@testable import MyRAM

final class SyncBatchPayloadCompatibilityTests: XCTestCase {
    func testBatchMessageEnvelopeRoutesPayloadByKind() throws {
        let batch = makeBatch()
        let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: batch))

        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        XCTAssertEqual(message.kind, .batchSync)

        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload)
        XCTAssertTrue(envelope.canDecodeWithCurrentSchema)
        XCTAssertEqual(envelope.batch, batch)
    }

    func testFutureBatchSchemaIsIgnoredByCurrentDecoder() throws {
        let futureEnvelope = SyncBatchEnvelope(
            schemaVersion: SyncBatchEnvelope.currentSchemaVersion + 1,
            batch: makeBatch()
        )
        let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(futureEnvelope)

        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: message.payload)

        XCTAssertFalse(envelope.canDecodeWithCurrentSchema)
    }

    func testOldSchemaVersionOnePayloadDecodesWithNilOptionalFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "batch": {
            "id": "00000000-0000-0000-0000-000000123101",
            "originDeviceID": "00000000-0000-0000-0000-000000123102",
            "createdAt": 1,
            "changes": [
              {
                "noteBodyTextInserted": {
                  "_0": {
                    "noteID": "00000000-0000-0000-0000-000000123103",
                    "utf16Offset": 0,
                    "text": "A",
                    "modifiedAt": 2
                  }
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: json)

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertNil(envelope.batch.batchSequence)
        guard case .noteBodyTextInserted(let change) = envelope.batch.changes.first else {
            return XCTFail("Expected inserted body change")
        }
        XCTAssertNil(change.baseContentHash)
    }

    func testNewOptionalFieldsRemainSchemaVersionOne() throws {
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123201")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123202")!,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 9,
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: UUID(uuidString: "00000000-0000-0000-0000-000000123203")!,
                        utf16Offset: 0,
                        text: "A",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                    )
                )
            ]
        )

        let data = try JSONEncoder().encode(SyncBatchEnvelope(batch: batch))
        let envelope = try JSONDecoder().decode(SyncBatchEnvelope.self, from: data)

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.batch, batch)
    }

    func testStableSHA256UsesUTF8Bytes() {
        XCTAssertEqual(
            SyncBatchContentHash.sha256Hex(for: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testBatchSequencePersistsPerDeviceIdentity() {
        let directoryURL = temporarySequenceDirectoryURL()
        let store = SyncBatchSequenceStore(directoryURL: directoryURL)
        let firstDevice = UUID(uuidString: "00000000-0000-0000-0000-000000123251")!
        let secondDevice = UUID(uuidString: "00000000-0000-0000-0000-000000123252")!

        XCTAssertEqual(store.nextSequence(for: firstDevice), .reserved(1))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: firstDevice), .reserved(2))
        XCTAssertEqual(store.nextSequence(for: secondDevice), .reserved(1))
    }

    func testSequenceReservationAllowsGapsWithoutReuse() {
        let directoryURL = temporarySequenceDirectoryURL()
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123253")!

        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .reserved(1))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .reserved(2))
    }

    func testTransientSequenceFailureDoesNotLatchAndRetriesLater() {
        let directoryURL = temporarySequenceDirectoryURL()
        let store = SyncBatchSequenceStore(directoryURL: directoryURL)
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123254")!

        XCTAssertEqual(store.nextSequence(for: deviceID), .reserved(1))
        store.injectFaultForNextReservation(.transientReservationFailure)
        XCTAssertEqual(store.nextSequence(for: deviceID), .sequenceLess(.transientFailure))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .reserved(2))
    }

    func testConfirmedSequenceCorruptionLatchesIdentity() throws {
        let directoryURL = temporarySequenceDirectoryURL()
        let store = SyncBatchSequenceStore(directoryURL: directoryURL)
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123255")!

        store.injectFaultForNextReservation(.confirmedCorruption)
        XCTAssertEqual(store.nextSequence(for: deviceID), .sequenceLess(.confirmedCorruption))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.alreadyLatched))

        try Data(#"{"lastReserved":99}"#.utf8).write(
            to: directoryURL.appendingPathComponent("\(deviceID.uuidString)-counter.json"),
            options: .atomic
        )
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.alreadyLatched))

        let newDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123256")!
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: newDeviceID), .reserved(1))
    }

    func testMalformedSequenceLatchFailsClosedAndRewritesLatch() throws {
        let directoryURL = temporarySequenceDirectoryURL()
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123281")!
        try createDirectory(directoryURL)
        try Data("not json".utf8).write(to: latchURL(for: deviceID, in: directoryURL), options: .atomic)
        try Data(#"{"lastReserved":41}"#.utf8).write(to: counterURL(for: deviceID, in: directoryURL), options: .atomic)

        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.confirmedCorruption))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.alreadyLatched))
    }

    func testMalformedSequenceLatchFailedRewriteIsTransientAndDoesNotAdvanceCounter() throws {
        let directoryURL = temporarySequenceDirectoryURL()
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123282")!
        try createDirectory(directoryURL)
        try Data("not json".utf8).write(to: latchURL(for: deviceID, in: directoryURL), options: .atomic)
        try Data(#"{"lastReserved":41}"#.utf8).write(to: counterURL(for: deviceID, in: directoryURL), options: .atomic)
        let store = SyncBatchSequenceStore(directoryURL: directoryURL)

        store.injectFaultForNextReservation(.latchPersistenceFailure)
        XCTAssertEqual(store.nextSequence(for: deviceID), .sequenceLess(.transientFailure))
        XCTAssertEqual(try JSONDecoder().decode(TestSequenceCounter.self, from: Data(contentsOf: counterURL(for: deviceID, in: directoryURL))).lastReserved, 41)
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.confirmedCorruption))
    }

    func testCorruptCounterFailedLatchWriteIsTransientAndRetryLatches() throws {
        let directoryURL = temporarySequenceDirectoryURL()
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123283")!
        try createDirectory(directoryURL)
        try Data("not json".utf8).write(to: counterURL(for: deviceID, in: directoryURL), options: .atomic)
        let store = SyncBatchSequenceStore(directoryURL: directoryURL)

        store.injectFaultForNextReservation(.latchPersistenceFailure)
        XCTAssertEqual(store.nextSequence(for: deviceID), .sequenceLess(.transientFailure))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latchURL(for: deviceID, in: directoryURL).path))
        XCTAssertEqual(SyncBatchSequenceStore(directoryURL: directoryURL).nextSequence(for: deviceID), .sequenceLess(.confirmedCorruption))
    }

    func testDisabledBodyHashGateMakesCaptureHashless() {
        guard case .noteBodyTextInserted(let change) = SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: UUID(uuidString: "00000000-0000-0000-0000-000000123257")!,
            oldBody: "Hello",
            newBody: "Hello!",
            modifiedAt: Date(timeIntervalSince1970: 1)
        ) else {
            return XCTFail("Expected insert")
        }

        XCTAssertNil(change.baseContentHash)
    }

    func testEnabledBodyHashGateCapturesBaseHash() {
        guard case .noteBodyTextInserted(let change) = SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: UUID(uuidString: "00000000-0000-0000-0000-000000123258")!,
            oldBody: "Hello",
            newBody: "Hello!",
            modifiedAt: Date(timeIntervalSince1970: 1),
            bodyHashCapabilityEnabled: true
        ) else {
            return XCTFail("Expected insert")
        }

        XCTAssertEqual(change.baseContentHash, SyncBatchContentHash.sha256Hex(for: "Hello"))
    }

    func testPreflightAcceptsValidSameNoteHashChain() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123259")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123260")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123261")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 2,
                        text: "C",
                        modifiedAt: Date(timeIntervalSince1970: 3),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testPreflightRejectsInvalidChainBeforeMutation() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123262")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123263")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123264")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 2,
                        text: "C",
                        modifiedAt: Date(timeIntervalSince1970: 3),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "wrong")
                    )
                )
            ]
        )

        XCTAssertThrowsError(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testPreflightUsesPostLegacyBodyForLaterHashedOperation() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123265")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123266")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123267")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 2,
                        text: "C",
                        modifiedAt: Date(timeIntervalSince1970: 3),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testPreflightUsesNewlyCreatedNoteBodyForLaterHashedOperation() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123271")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123272")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123273")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteCreated(
                    SyncBatchNoteCreatedChange(
                        noteID: noteID,
                        title: "New",
                        body: "A",
                        folderID: nil,
                        createdAt: Date(timeIntervalSince1970: 1),
                        modifiedAt: Date(timeIntervalSince1970: 1)
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in nil })
    }

    func testPreflightSkipsEmptyInsertBeforeHashValidation() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123284")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123285")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123286")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 0,
                        text: "",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "wrong")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testIdempotentlySkippedNoteCreatedDoesNotResetAdvancedWorkingBody() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123287")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123288")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123289")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteCreated(
                    SyncBatchNoteCreatedChange(
                        noteID: noteID,
                        title: "Existing",
                        body: "stale",
                        folderID: nil,
                        createdAt: Date(timeIntervalSince1970: 1),
                        modifiedAt: Date(timeIntervalSince1970: 3)
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 2,
                        text: "C",
                        modifiedAt: Date(timeIntervalSince1970: 4),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testSkippedDeleteDoesNotAdvancePreflightWorkingBody() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123274")!
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123275")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123276")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: noteID,
                        utf16Offset: 0,
                        utf16Length: 1,
                        expectedText: "Z",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: 1,
                        text: "B",
                        modifiedAt: Date(timeIntervalSince1970: 3),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                )
            ]
        )

        XCTAssertNoThrow(try SyncBatchPreflight(bodyHashCapabilityEnabled: true).validate(batch: batch) { _ in "A" })
    }

    func testPreflightHashCacheReusesUnchangedBodyHash() throws {
        var hashCallCount = 0
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123268")!
        let cache = SyncBatchHashCache { body in
            hashCallCount += 1
            return SyncBatchContentHash.sha256Hex(for: body)
        }
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123269")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123270")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: noteID,
                        utf16Offset: 0,
                        utf16Length: 1,
                        expectedText: "Z",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: noteID,
                        utf16Offset: 0,
                        utf16Length: 1,
                        expectedText: "Z",
                        modifiedAt: Date(timeIntervalSince1970: 3),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                )
            ]
        )

        try SyncBatchPreflight(bodyHashCapabilityEnabled: true, hashCache: cache).validate(batch: batch) { _ in "A" }

        XCTAssertEqual(hashCallCount, 1)
    }

    func testMixedLegacyAndSequencedReplayKeysHaveTotalOrder() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123301")!
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123302")!
        let modifiedAt = Date(timeIntervalSince1970: 50)
        let legacyBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123303")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "Legacy",
                        modifiedAt: modifiedAt
                    )
                )
            ]
        )
        let sequencedBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123304")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "Sequenced",
                        modifiedAt: modifiedAt
                    )
                )
            ]
        )

        let legacyKey = SyncBatchReplayKey(batch: legacyBatch, change: legacyBatch.changes[0], operationIndex: 0)
        let sequencedKey = SyncBatchReplayKey(batch: sequencedBatch, change: sequencedBatch.changes[0], operationIndex: 0)

        XCTAssertLessThan(legacyKey, sequencedKey)
        XCTAssertEqual([sequencedKey, legacyKey].sorted(), [legacyKey, sequencedKey])
    }

    func testBatchMessageDoesNotDecodeAsLegacySyncEnvelopeWithoutRouting() throws {
        let data = try MultipeerSyncMessageCoding.encodeBatchEnvelope(SyncBatchEnvelope(batch: makeBatch()))

        XCTAssertThrowsError(try JSONDecoder().decode(SyncEnvelope.self, from: data))
    }

    private func makeBatch() -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123001")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123002")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: UUID(uuidString: "00000000-0000-0000-0000-000000123003")!,
                        title: "Remote",
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ]
        )
    }

    private func temporarySequenceDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sequences", isDirectory: true)
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func counterURL(for deviceID: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(deviceID.uuidString)-counter.json")
    }

    private func latchURL(for deviceID: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(deviceID.uuidString)-sequence-less.json")
    }
}

private struct TestSequenceCounter: Decodable {
    let lastReserved: UInt64
}
