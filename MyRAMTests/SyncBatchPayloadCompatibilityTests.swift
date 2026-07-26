import CoreFoundation
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

    func testCapabilityOffProductionCaptureCreatesOnlyLegacyBodyCases() throws {
        let fixture = try makeSixCaseCompatibilityFixture()

        assertCurrentSixCaseBatch(fixture.currentBatch)
        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    func testCapabilityOffCurrentSixCaseBatchStructurallyEqualsLegacyV1() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        assertCurrentSixCaseBatch(fixture.currentBatch)
        assertLegacySixCaseBatch(fixture.legacyBatch)

        let currentData = try JSONEncoder().encode(fixture.currentBatch)
        let legacyData = try JSONEncoder().encode(fixture.legacyBatch)
        let currentJSON = try StructuralJSONValue.parse(currentData)
        let legacyJSON = try StructuralJSONValue.parse(legacyData)

        XCTAssertEqual(currentJSON, legacyJSON)
        assertSixCaseBatchJSONShape(currentJSON)
        assertSixCaseBatchJSONShape(legacyJSON)
    }

    func testCapabilityOffCurrentSixCaseBatchEnvelopeStructurallyEqualsLegacyV1() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        assertCurrentSixCaseBatch(fixture.currentBatch)
        assertLegacySixCaseBatch(fixture.legacyBatch)

        let currentData = try JSONEncoder().encode(
            SyncBatchEnvelope(batch: fixture.currentBatch)
        )
        let legacyData = try JSONEncoder().encode(
            LegacySyncBatchEnvelopeV1(
                schemaVersion: 1,
                batch: fixture.legacyBatch
            )
        )
        let currentJSON = try StructuralJSONValue.parse(currentData)
        let legacyJSON = try StructuralJSONValue.parse(legacyData)

        XCTAssertEqual(currentJSON, legacyJSON)
        assertInnerEnvelopeJSONShape(currentJSON)
        assertInnerEnvelopeJSONShape(legacyJSON)
    }

    func testCapabilityOffCurrentSixCaseMultipeerEnvelopeIsRecursivelyCompatibleWithLegacyV1() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        assertCurrentSixCaseBatch(fixture.currentBatch)
        assertLegacySixCaseBatch(fixture.legacyBatch)

        let currentData = try MultipeerSyncMessageCoding.encodeBatchEnvelope(
            SyncBatchEnvelope(batch: fixture.currentBatch)
        )
        let legacyPayload = try JSONEncoder().encode(
            LegacySyncBatchEnvelopeV1(
                schemaVersion: 1,
                batch: fixture.legacyBatch
            )
        )
        let legacyData = try JSONEncoder().encode(
            LegacyMultipeerSyncMessageEnvelopeV1(
                kind: .batchSync,
                schemaVersion: 1,
                payload: legacyPayload
            )
        )
        let currentOuter = try structuralOuterEnvelope(from: currentData)
        let legacyOuter = try structuralOuterEnvelope(from: legacyData)

        XCTAssertEqual(currentOuter, legacyOuter)
        assertInnerEnvelopeJSONShape(currentOuter.payload)
        assertInnerEnvelopeJSONShape(legacyOuter.payload)
    }

    func testCapabilityOffSixCaseEncodingRemainsStructurallyStableAcrossRepeatedInvocations() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        assertCurrentSixCaseBatch(fixture.currentBatch)
        assertLegacySixCaseBatch(fixture.legacyBatch)

        let firstCurrent = try encodeCurrentArtifacts(fixture.currentBatch)
        let firstLegacy = try encodeLegacyArtifacts(fixture.legacyBatch)
        XCTAssertEqual(firstCurrent.artifacts, firstLegacy.artifacts)

        for _ in 0..<20 {
            let current = try encodeCurrentArtifacts(fixture.currentBatch)
            let legacy = try encodeLegacyArtifacts(fixture.legacyBatch)

            XCTAssertEqual(current.artifacts, firstCurrent.artifacts)
            XCTAssertEqual(legacy.artifacts, firstLegacy.artifacts)
            XCTAssertEqual(current.artifacts, legacy.artifacts)

            XCTAssertNoThrow(
                try JSONDecoder().decode(
                    LegacySyncBatchEnvelopeV1.self,
                    from: current.innerEnvelopeData
                )
            )
            XCTAssertNoThrow(
                try JSONDecoder().decode(
                    SyncBatchEnvelope.self,
                    from: legacy.innerEnvelopeData
                )
            )
        }
    }

    func testCurrentDecoderReadsLegacyV1SixCaseFixture() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        let legacyData = try JSONEncoder().encode(
            LegacySyncBatchEnvelopeV1(
                schemaVersion: 1,
                batch: fixture.legacyBatch
            )
        )

        let decoded = try JSONDecoder().decode(
            SyncBatchEnvelope.self,
            from: legacyData
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        assertCurrentSixCaseBatch(decoded.batch)
        XCTAssertFalse(decoded.batch.changes.contains {
            $0.bodyOperationRepresentation == .anchored
        })

        let frozenCurrent = try JSONDecoder().decode(
            SyncBatchEnvelope.self,
            from: CompatibilityValues.frozenLegacyEnvelopeJSON
        )
        let frozenLegacy = try JSONDecoder().decode(
            LegacySyncBatchEnvelopeV1.self,
            from: CompatibilityValues.frozenLegacyEnvelopeJSON
        )
        XCTAssertEqual(frozenCurrent.batch, fixture.currentBatch)
        XCTAssertEqual(frozenLegacy.batch, fixture.legacyBatch)

        let frozenJSON = try StructuralJSONValue.parse(
            CompatibilityValues.frozenLegacyEnvelopeJSON
        )
        let generatedJSON = try StructuralJSONValue.parse(legacyData)
        XCTAssertEqual(frozenJSON, generatedJSON)
        assertInnerEnvelopeJSONShape(frozenJSON)
    }

    func testLegacyV1DecoderReadsCurrentCapabilityOffSixCaseFixture() throws {
        let fixture = try makeSixCaseCompatibilityFixture()
        let currentData = try JSONEncoder().encode(
            SyncBatchEnvelope(batch: fixture.currentBatch)
        )

        let decoded = try JSONDecoder().decode(
            LegacySyncBatchEnvelopeV1.self,
            from: currentData
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        assertLegacySixCaseBatch(decoded.batch)
    }

    func testLegacyV1CompatibilityFixtureRetainsAllSixCasesAndUTF16Evidence() throws {
        let fixture = try makeSixCaseCompatibilityFixture()

        assertCurrentSixCaseBatch(fixture.currentBatch)
        assertLegacySixCaseBatch(fixture.legacyBatch)
        XCTAssertEqual("😀".utf16.count, 2)

        let currentJSON = try StructuralJSONValue.parse(
            JSONEncoder().encode(fixture.currentBatch)
        )
        let legacyJSON = try StructuralJSONValue.parse(
            JSONEncoder().encode(fixture.legacyBatch)
        )
        assertSixCaseBatchJSONShape(currentJSON)
        assertSixCaseBatchJSONShape(legacyJSON)
    }

    func testLegacyTransportConstantsRemainV1() {
        XCTAssertEqual(SyncBatchEnvelope.currentSchemaVersion, 1)
        XCTAssertEqual(MultipeerSyncMessageEnvelope.currentSchemaVersion, 1)
        XCTAssertEqual(
            MultipeerSyncMessageKind.batchSync.rawValue,
            "myram.batchSync.v1"
        )
        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
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

    private func makeSixCaseCompatibilityFixture() throws -> SixCaseCompatibilityFixture {
        // The body cases intentionally come from production capture so this fixture
        // proves the disabled capability still emits the legacy representation.
        let capturedInsert = try XCTUnwrap(
            SyncBatchNoteChangeCapture.bodyTextChanged(
                noteID: CompatibilityValues.noteID,
                oldBody: "AB",
                newBody: "A😀B",
                modifiedAt: CompatibilityValues.insertModifiedAt
            )
        )
        let capturedDelete = try XCTUnwrap(
            SyncBatchNoteChangeCapture.bodyTextChanged(
                noteID: CompatibilityValues.noteID,
                oldBody: "A😀B",
                newBody: "AB",
                modifiedAt: CompatibilityValues.deleteModifiedAt
            )
        )

        guard case .noteBodyTextInserted = capturedInsert else {
            throw CompatibilityFixtureError.unexpectedInsertCase
        }
        guard case .noteBodyTextDeleted = capturedDelete else {
            throw CompatibilityFixtureError.unexpectedDeleteCase
        }

        let currentBatch = SyncBatch(
            id: CompatibilityValues.batchID,
            originDeviceID: CompatibilityValues.originDeviceID,
            createdAt: CompatibilityValues.batchCreatedAt,
            batchSequence: CompatibilityValues.batchSequence,
            changes: [
                .noteCreated(
                    SyncBatchNoteCreatedChange(
                        noteID: CompatibilityValues.noteID,
                        title: CompatibilityValues.createdTitle,
                        body: CompatibilityValues.createdBody,
                        folderID: CompatibilityValues.folderID,
                        createdAt: CompatibilityValues.noteCreatedAt,
                        modifiedAt: CompatibilityValues.noteCreatedModifiedAt
                    )
                ),
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: CompatibilityValues.noteID,
                        title: CompatibilityValues.changedTitle,
                        modifiedAt: CompatibilityValues.titleModifiedAt
                    )
                ),
                capturedInsert,
                capturedDelete,
                .noteBodyReconciled(
                    SyncBatchNoteBodyReconciledChange(
                        noteID: CompatibilityValues.noteID,
                        replacementBody: CompatibilityValues.replacementBody,
                        replacementContentHash: CompatibilityValues.replacementHash,
                        modifiedAt: CompatibilityValues.reconciledModifiedAt
                    )
                ),
                .noteLifecycleChanged(
                    SyncBatchNoteLifecycleChangedChange(
                        noteID: CompatibilityValues.noteID,
                        deletedAt: CompatibilityValues.deletedAt,
                        modifiedAt: CompatibilityValues.lifecycleModifiedAt,
                        title: CompatibilityValues.lifecycleTitle,
                        body: CompatibilityValues.lifecycleBody,
                        baseTitleHash: CompatibilityValues.baseTitleHash,
                        baseBodyHash: CompatibilityValues.baseBodyHash
                    )
                )
            ]
        )

        let legacyBatch = LegacySyncBatchV1(
            id: CompatibilityValues.batchID,
            originDeviceID: CompatibilityValues.originDeviceID,
            createdAt: CompatibilityValues.batchCreatedAt,
            batchSequence: CompatibilityValues.batchSequence,
            changes: [
                .noteCreated(
                    LegacySyncBatchNoteCreatedChangeV1(
                        noteID: CompatibilityValues.noteID,
                        title: CompatibilityValues.createdTitle,
                        body: CompatibilityValues.createdBody,
                        folderID: CompatibilityValues.folderID,
                        createdAt: CompatibilityValues.noteCreatedAt,
                        modifiedAt: CompatibilityValues.noteCreatedModifiedAt
                    )
                ),
                .noteTitleChanged(
                    LegacySyncBatchNoteTitleChangedChangeV1(
                        noteID: CompatibilityValues.noteID,
                        title: CompatibilityValues.changedTitle,
                        modifiedAt: CompatibilityValues.titleModifiedAt
                    )
                ),
                .noteBodyTextInserted(
                    LegacySyncBatchNoteBodyTextInsertedChangeV1(
                        noteID: CompatibilityValues.noteID,
                        utf16Offset: 1,
                        text: "😀",
                        modifiedAt: CompatibilityValues.insertModifiedAt,
                        baseContentHash: nil
                    )
                ),
                .noteBodyTextDeleted(
                    LegacySyncBatchNoteBodyTextDeletedChangeV1(
                        noteID: CompatibilityValues.noteID,
                        utf16Offset: 1,
                        utf16Length: 2,
                        expectedText: "😀",
                        modifiedAt: CompatibilityValues.deleteModifiedAt,
                        baseContentHash: nil
                    )
                ),
                .noteBodyReconciled(
                    LegacySyncBatchNoteBodyReconciledChangeV1(
                        noteID: CompatibilityValues.noteID,
                        replacementBody: CompatibilityValues.replacementBody,
                        replacementContentHash: CompatibilityValues.replacementHash,
                        modifiedAt: CompatibilityValues.reconciledModifiedAt
                    )
                ),
                .noteLifecycleChanged(
                    LegacySyncBatchNoteLifecycleChangedChangeV1(
                        noteID: CompatibilityValues.noteID,
                        deletedAt: CompatibilityValues.deletedAt,
                        modifiedAt: CompatibilityValues.lifecycleModifiedAt,
                        title: CompatibilityValues.lifecycleTitle,
                        body: CompatibilityValues.lifecycleBody,
                        baseTitleHash: CompatibilityValues.baseTitleHash,
                        baseBodyHash: CompatibilityValues.baseBodyHash
                    )
                )
            ]
        )

        return SixCaseCompatibilityFixture(
            currentBatch: currentBatch,
            legacyBatch: legacyBatch
        )
    }

    private func assertCurrentSixCaseBatch(_ batch: SyncBatch) {
        XCTAssertEqual(batch.id, CompatibilityValues.batchID)
        XCTAssertEqual(batch.originDeviceID, CompatibilityValues.originDeviceID)
        XCTAssertEqual(batch.createdAt, CompatibilityValues.batchCreatedAt)
        XCTAssertEqual(batch.batchSequence, CompatibilityValues.batchSequence)

        guard batch.changes.count == 6 else {
            return XCTFail("Expected all six legacy cases")
        }

        guard case .noteCreated(let created) = batch.changes[0] else {
            return XCTFail("Expected noteCreated first")
        }
        XCTAssertEqual(created.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(created.title, CompatibilityValues.createdTitle)
        XCTAssertEqual(created.body, CompatibilityValues.createdBody)
        XCTAssertEqual(created.folderID, CompatibilityValues.folderID)
        XCTAssertEqual(created.createdAt, CompatibilityValues.noteCreatedAt)
        XCTAssertEqual(created.modifiedAt, CompatibilityValues.noteCreatedModifiedAt)

        guard case .noteTitleChanged(let title) = batch.changes[1] else {
            return XCTFail("Expected noteTitleChanged second")
        }
        XCTAssertEqual(title.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(title.title, CompatibilityValues.changedTitle)
        XCTAssertEqual(title.modifiedAt, CompatibilityValues.titleModifiedAt)

        guard case .noteBodyTextInserted(let insert) = batch.changes[2] else {
            return XCTFail("Expected legacy insert third")
        }
        XCTAssertEqual(insert.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(insert.utf16Offset, 1)
        XCTAssertEqual(insert.text, "😀")
        XCTAssertEqual(insert.text.utf16.count, 2)
        XCTAssertEqual(insert.modifiedAt, CompatibilityValues.insertModifiedAt)
        XCTAssertNil(insert.baseContentHash)

        guard case .noteBodyTextDeleted(let delete) = batch.changes[3] else {
            return XCTFail("Expected legacy delete fourth")
        }
        XCTAssertEqual(delete.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(delete.utf16Offset, 1)
        XCTAssertEqual(delete.utf16Length, 2)
        XCTAssertEqual(delete.expectedText, "😀")
        XCTAssertEqual(delete.expectedText?.utf16.count, 2)
        XCTAssertEqual(delete.modifiedAt, CompatibilityValues.deleteModifiedAt)
        XCTAssertNil(delete.baseContentHash)

        guard case .noteBodyReconciled(let reconciled) = batch.changes[4] else {
            return XCTFail("Expected noteBodyReconciled fifth")
        }
        XCTAssertEqual(reconciled.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(reconciled.replacementBody, CompatibilityValues.replacementBody)
        XCTAssertEqual(reconciled.replacementContentHash, CompatibilityValues.replacementHash)
        XCTAssertEqual(reconciled.modifiedAt, CompatibilityValues.reconciledModifiedAt)

        guard case .noteLifecycleChanged(let lifecycle) = batch.changes[5] else {
            return XCTFail("Expected noteLifecycleChanged sixth")
        }
        XCTAssertEqual(lifecycle.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(lifecycle.deletedAt, CompatibilityValues.deletedAt)
        XCTAssertEqual(lifecycle.modifiedAt, CompatibilityValues.lifecycleModifiedAt)
        XCTAssertEqual(lifecycle.title, CompatibilityValues.lifecycleTitle)
        XCTAssertEqual(lifecycle.body, CompatibilityValues.lifecycleBody)
        XCTAssertEqual(lifecycle.baseTitleHash, CompatibilityValues.baseTitleHash)
        XCTAssertEqual(lifecycle.baseBodyHash, CompatibilityValues.baseBodyHash)
    }

    private func assertLegacySixCaseBatch(_ batch: LegacySyncBatchV1) {
        XCTAssertEqual(batch.id, CompatibilityValues.batchID)
        XCTAssertEqual(batch.originDeviceID, CompatibilityValues.originDeviceID)
        XCTAssertEqual(batch.createdAt, CompatibilityValues.batchCreatedAt)
        XCTAssertEqual(batch.batchSequence, CompatibilityValues.batchSequence)

        guard batch.changes.count == 6 else {
            return XCTFail("Expected all six legacy DTO cases")
        }

        guard case .noteCreated(let created) = batch.changes[0] else {
            return XCTFail("Expected legacy noteCreated first")
        }
        XCTAssertEqual(created.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(created.title, CompatibilityValues.createdTitle)
        XCTAssertEqual(created.body, CompatibilityValues.createdBody)
        XCTAssertEqual(created.folderID, CompatibilityValues.folderID)
        XCTAssertEqual(created.createdAt, CompatibilityValues.noteCreatedAt)
        XCTAssertEqual(created.modifiedAt, CompatibilityValues.noteCreatedModifiedAt)

        guard case .noteTitleChanged(let title) = batch.changes[1] else {
            return XCTFail("Expected legacy noteTitleChanged second")
        }
        XCTAssertEqual(title.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(title.title, CompatibilityValues.changedTitle)
        XCTAssertEqual(title.modifiedAt, CompatibilityValues.titleModifiedAt)

        guard case .noteBodyTextInserted(let insert) = batch.changes[2] else {
            return XCTFail("Expected legacy insert third")
        }
        XCTAssertEqual(insert.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(insert.utf16Offset, 1)
        XCTAssertEqual(insert.text, "😀")
        XCTAssertEqual(insert.text.utf16.count, 2)
        XCTAssertEqual(insert.modifiedAt, CompatibilityValues.insertModifiedAt)
        XCTAssertNil(insert.baseContentHash)

        guard case .noteBodyTextDeleted(let delete) = batch.changes[3] else {
            return XCTFail("Expected legacy delete fourth")
        }
        XCTAssertEqual(delete.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(delete.utf16Offset, 1)
        XCTAssertEqual(delete.utf16Length, 2)
        XCTAssertEqual(delete.expectedText, "😀")
        XCTAssertEqual(delete.expectedText?.utf16.count, 2)
        XCTAssertEqual(delete.modifiedAt, CompatibilityValues.deleteModifiedAt)
        XCTAssertNil(delete.baseContentHash)

        guard case .noteBodyReconciled(let reconciled) = batch.changes[4] else {
            return XCTFail("Expected legacy noteBodyReconciled fifth")
        }
        XCTAssertEqual(reconciled.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(reconciled.replacementBody, CompatibilityValues.replacementBody)
        XCTAssertEqual(reconciled.replacementContentHash, CompatibilityValues.replacementHash)
        XCTAssertEqual(reconciled.modifiedAt, CompatibilityValues.reconciledModifiedAt)

        guard case .noteLifecycleChanged(let lifecycle) = batch.changes[5] else {
            return XCTFail("Expected legacy noteLifecycleChanged sixth")
        }
        XCTAssertEqual(lifecycle.noteID, CompatibilityValues.noteID)
        XCTAssertEqual(lifecycle.deletedAt, CompatibilityValues.deletedAt)
        XCTAssertEqual(lifecycle.modifiedAt, CompatibilityValues.lifecycleModifiedAt)
        XCTAssertEqual(lifecycle.title, CompatibilityValues.lifecycleTitle)
        XCTAssertEqual(lifecycle.body, CompatibilityValues.lifecycleBody)
        XCTAssertEqual(lifecycle.baseTitleHash, CompatibilityValues.baseTitleHash)
        XCTAssertEqual(lifecycle.baseBodyHash, CompatibilityValues.baseBodyHash)
    }

    private func assertSixCaseBatchJSONShape(_ value: StructuralJSONValue) {
        guard case .object(let batch) = value else {
            return XCTFail("Expected batch JSON object")
        }
        XCTAssertEqual(
            Set(batch.keys),
            ["id", "originDeviceID", "createdAt", "batchSequence", "changes"]
        )
        assertJSONKinds(
            in: batch,
            stringKeys: ["id", "originDeviceID"],
            numberKeys: ["createdAt", "batchSequence"]
        )

        guard let changesValue = batch["changes"],
              case .array(let changes) = changesValue else {
            return XCTFail("Expected changes array")
        }
        let expectedCases: [ExpectedJSONCaseShape] = [
            ExpectedJSONCaseShape(
                tag: "noteCreated",
                keys: ["noteID", "title", "body", "folderID", "createdAt", "modifiedAt"],
                stringKeys: ["noteID", "title", "body", "folderID"],
                numberKeys: ["createdAt", "modifiedAt"]
            ),
            ExpectedJSONCaseShape(
                tag: "noteTitleChanged",
                keys: ["noteID", "title", "modifiedAt"],
                stringKeys: ["noteID", "title"],
                numberKeys: ["modifiedAt"]
            ),
            ExpectedJSONCaseShape(
                tag: "noteBodyTextInserted",
                keys: ["noteID", "utf16Offset", "text", "modifiedAt"],
                stringKeys: ["noteID", "text"],
                numberKeys: ["utf16Offset", "modifiedAt"]
            ),
            ExpectedJSONCaseShape(
                tag: "noteBodyTextDeleted",
                keys: ["noteID", "utf16Offset", "utf16Length", "expectedText", "modifiedAt"],
                stringKeys: ["noteID", "expectedText"],
                numberKeys: ["utf16Offset", "utf16Length", "modifiedAt"]
            ),
            ExpectedJSONCaseShape(
                tag: "noteBodyReconciled",
                keys: ["noteID", "replacementBody", "replacementContentHash", "modifiedAt"],
                stringKeys: ["noteID", "replacementBody", "replacementContentHash"],
                numberKeys: ["modifiedAt"]
            ),
            ExpectedJSONCaseShape(
                tag: "noteLifecycleChanged",
                keys: [
                    "noteID",
                    "deletedAt",
                    "modifiedAt",
                    "title",
                    "body",
                    "baseTitleHash",
                    "baseBodyHash"
                ],
                stringKeys: ["noteID", "title", "body", "baseTitleHash", "baseBodyHash"],
                numberKeys: ["deletedAt", "modifiedAt"]
            )
        ]

        guard changes.count == expectedCases.count else {
            return XCTFail("Expected all six JSON case values")
        }

        for (change, expected) in zip(changes, expectedCases) {
            guard case .object(let taggedCase) = change else {
                return XCTFail("Expected tagged case object")
            }
            XCTAssertEqual(Set(taggedCase.keys), [expected.tag])

            guard let taggedValue = taggedCase[expected.tag],
                  case .object(let wrapper) = taggedValue else {
                return XCTFail("Expected associated-value wrapper")
            }
            XCTAssertEqual(Set(wrapper.keys), ["_0"])

            guard let wrappedValue = wrapper["_0"],
                  case .object(let associatedValue) = wrappedValue else {
                return XCTFail("Expected associated-value object")
            }
            XCTAssertEqual(Set(associatedValue.keys), expected.keys)
            assertJSONKinds(
                in: associatedValue,
                stringKeys: expected.stringKeys,
                numberKeys: expected.numberKeys
            )
        }

        let prohibitedKeys: Set<String> = [
            "noteBodyTextInsertedAnchored",
            "noteBodyTextDeletedAnchored",
            "anchor",
            "operationID",
            "deletedElementSpans",
            "baseContentHash"
        ]
        XCTAssertTrue(value.allObjectKeys.isDisjoint(with: prohibitedKeys))
    }

    private func assertInnerEnvelopeJSONShape(_ value: StructuralJSONValue) {
        guard case .object(let envelope) = value else {
            return XCTFail("Expected inner-envelope JSON object")
        }
        XCTAssertEqual(Set(envelope.keys), ["schemaVersion", "batch"])
        XCTAssertEqual(
            envelope["schemaVersion"],
            .number(NSNumber(value: 1))
        )
        guard let batch = envelope["batch"] else {
            return XCTFail("Expected batch value")
        }
        assertSixCaseBatchJSONShape(batch)
    }

    private func assertJSONKinds(
        in object: [String: StructuralJSONValue],
        stringKeys: Set<String>,
        numberKeys: Set<String>
    ) {
        for key in stringKeys {
            XCTAssertEqual(object[key]?.kind, .string, "Expected string at \(key)")
        }
        for key in numberKeys {
            XCTAssertEqual(object[key]?.kind, .number, "Expected number at \(key)")
        }
    }

    private func structuralOuterEnvelope(
        from data: Data
    ) throws -> StructuralOuterEnvelope {
        let value = try StructuralJSONValue.parse(data)
        guard case .object(let envelope) = value else {
            throw CompatibilityJSONError.expectedOuterObject
        }
        XCTAssertEqual(Set(envelope.keys), ["kind", "schemaVersion", "payload"])

        guard let kindValue = envelope["kind"],
              case .string(let kind) = kindValue,
              let schemaValue = envelope["schemaVersion"],
              case .number(let schemaVersion) = schemaValue,
              let payloadValue = envelope["payload"],
              case .string(let encodedPayload) = payloadValue,
              let payloadData = Data(base64Encoded: encodedPayload) else {
            throw CompatibilityJSONError.invalidOuterShape
        }
        XCTAssertEqual(kind, "myram.batchSync.v1")
        XCTAssertEqual(schemaVersion, NSNumber(value: 1))

        return StructuralOuterEnvelope(
            kind: kind,
            schemaVersion: .number(schemaVersion),
            payload: try StructuralJSONValue.parse(payloadData)
        )
    }

    private func encodeCurrentArtifacts(
        _ batch: SyncBatch
    ) throws -> StructuralEncodingResult {
        let batchData = try JSONEncoder().encode(batch)
        let innerData = try JSONEncoder().encode(
            SyncBatchEnvelope(batch: batch)
        )
        let outerData = try MultipeerSyncMessageCoding.encodeBatchEnvelope(
            SyncBatchEnvelope(batch: batch)
        )
        let batchJSON = try StructuralJSONValue.parse(batchData)
        let innerJSON = try StructuralJSONValue.parse(innerData)
        let outerJSON = try structuralOuterEnvelope(from: outerData)
        XCTAssertEqual(outerJSON.payload, innerJSON)
        assertSixCaseBatchJSONShape(batchJSON)
        assertInnerEnvelopeJSONShape(innerJSON)
        assertInnerEnvelopeJSONShape(outerJSON.payload)

        return StructuralEncodingResult(
            artifacts: StructuralCompatibilityArtifacts(
                batch: batchJSON,
                innerEnvelope: innerJSON,
                outerEnvelope: outerJSON
            ),
            innerEnvelopeData: innerData
        )
    }

    private func encodeLegacyArtifacts(
        _ batch: LegacySyncBatchV1
    ) throws -> StructuralEncodingResult {
        let innerEnvelope = LegacySyncBatchEnvelopeV1(
            schemaVersion: 1,
            batch: batch
        )
        let innerData = try JSONEncoder().encode(innerEnvelope)
        let batchData = try JSONEncoder().encode(batch)
        let outerData = try JSONEncoder().encode(
            LegacyMultipeerSyncMessageEnvelopeV1(
                kind: .batchSync,
                schemaVersion: 1,
                payload: innerData
            )
        )
        let batchJSON = try StructuralJSONValue.parse(batchData)
        let innerJSON = try StructuralJSONValue.parse(innerData)
        let outerJSON = try structuralOuterEnvelope(from: outerData)
        XCTAssertEqual(outerJSON.payload, innerJSON)
        assertSixCaseBatchJSONShape(batchJSON)
        assertInnerEnvelopeJSONShape(innerJSON)
        assertInnerEnvelopeJSONShape(outerJSON.payload)

        return StructuralEncodingResult(
            artifacts: StructuralCompatibilityArtifacts(
                batch: batchJSON,
                innerEnvelope: innerJSON,
                outerEnvelope: outerJSON
            ),
            innerEnvelopeData: innerData
        )
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

    private struct SixCaseCompatibilityFixture {
        let currentBatch: SyncBatch
        let legacyBatch: LegacySyncBatchV1
    }

    private struct StructuralEncodingResult {
        let artifacts: StructuralCompatibilityArtifacts
        let innerEnvelopeData: Data
    }

    private struct StructuralCompatibilityArtifacts: Equatable {
        let batch: StructuralJSONValue
        let innerEnvelope: StructuralJSONValue
        let outerEnvelope: StructuralOuterEnvelope
    }

    private struct StructuralOuterEnvelope: Equatable {
        let kind: String
        let schemaVersion: StructuralJSONValue
        let payload: StructuralJSONValue
    }

    private struct ExpectedJSONCaseShape {
        let tag: String
        let keys: Set<String>
        let stringKeys: Set<String>
        let numberKeys: Set<String>
    }

    private enum StructuralJSONKind: Equatable {
        case object
        case array
        case string
        case number
        case boolean
        case null
    }

    private indirect enum StructuralJSONValue: Equatable {
        case object([String: StructuralJSONValue])
        case array([StructuralJSONValue])
        case string(String)
        case number(NSNumber)
        case boolean(Bool)
        case null

        static func parse(_ data: Data) throws -> StructuralJSONValue {
            try make(
                from: JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            )
        }

        private static func make(from value: Any) throws -> StructuralJSONValue {
            if let object = value as? [String: Any] {
                return .object(
                    try object.mapValues { try make(from: $0) }
                )
            }
            if let array = value as? [Any] {
                return .array(try array.map { try make(from: $0) })
            }
            if let string = value as? String {
                return .string(string)
            }
            if value is NSNull {
                return .null
            }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return .boolean(number.boolValue)
                }
                return .number(number)
            }
            throw CompatibilityJSONError.unsupportedJSONValue
        }

        var kind: StructuralJSONKind {
            switch self {
            case .object:
                .object
            case .array:
                .array
            case .string:
                .string
            case .number:
                .number
            case .boolean:
                .boolean
            case .null:
                .null
            }
        }

        var allObjectKeys: Set<String> {
            switch self {
            case .object(let object):
                object.reduce(into: Set(object.keys)) { keys, entry in
                    keys.formUnion(entry.value.allObjectKeys)
                }
            case .array(let array):
                array.reduce(into: Set<String>()) { keys, value in
                    keys.formUnion(value.allObjectKeys)
                }
            case .string, .number, .boolean, .null:
                []
            }
        }

        static func == (
            lhs: StructuralJSONValue,
            rhs: StructuralJSONValue
        ) -> Bool {
            switch (lhs, rhs) {
            case (.object(let lhs), .object(let rhs)):
                lhs == rhs
            case (.array(let lhs), .array(let rhs)):
                lhs == rhs
            case (.string(let lhs), .string(let rhs)):
                lhs == rhs
            case (.number(let lhs), .number(let rhs)):
                lhs == rhs
            case (.boolean(let lhs), .boolean(let rhs)):
                lhs == rhs
            case (.null, .null):
                true
            default:
                false
            }
        }
    }

    private enum CompatibilityFixtureError: Error {
        case unexpectedInsertCase
        case unexpectedDeleteCase
    }

    private enum CompatibilityJSONError: Error {
        case expectedOuterObject
        case invalidOuterShape
        case unsupportedJSONValue
    }

    private enum CompatibilityValues {
        static let batchID = UUID(
            uuidString: "17100000-0000-0000-0000-000000000301"
        )!
        static let originDeviceID = UUID(
            uuidString: "17100000-0000-0000-0000-000000000302"
        )!
        static let noteID = UUID(
            uuidString: "17100000-0000-0000-0000-000000000303"
        )!
        static let folderID = UUID(
            uuidString: "17100000-0000-0000-0000-000000000304"
        )!

        static let batchSequence: UInt64 = 171
        static let batchCreatedAt = Date(timeIntervalSince1970: 1_710_030_000)
        static let noteCreatedAt = Date(timeIntervalSince1970: 1_710_030_001)
        static let noteCreatedModifiedAt = Date(timeIntervalSince1970: 1_710_030_002)
        static let titleModifiedAt = Date(timeIntervalSince1970: 1_710_030_003)
        static let insertModifiedAt = Date(timeIntervalSince1970: 1_710_030_004)
        static let deleteModifiedAt = Date(timeIntervalSince1970: 1_710_030_005)
        static let reconciledModifiedAt = Date(timeIntervalSince1970: 1_710_030_006)
        static let deletedAt = Date(timeIntervalSince1970: 1_710_030_007)
        static let lifecycleModifiedAt = Date(timeIntervalSince1970: 1_710_030_008)

        static let createdTitle = "Created title"
        static let createdBody = "AB"
        static let changedTitle = "Updated title"
        static let replacementBody = "Reconciled body"
        static let replacementHash =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        static let lifecycleTitle = "Lifecycle title"
        static let lifecycleBody = "Lifecycle body"
        static let baseTitleHash =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        static let baseBodyHash =
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

        // A fixed V1 decode vector; its key ordering is intentionally non-normative.
        static let frozenLegacyEnvelopeJSON = Data(
            """
            {
              "schemaVersion": 1,
              "batch": {
                "id": "17100000-0000-0000-0000-000000000301",
                "originDeviceID": "17100000-0000-0000-0000-000000000302",
                "createdAt": 731722800,
                "batchSequence": 171,
                "changes": [
                  {
                    "noteCreated": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "title": "Created title",
                        "body": "AB",
                        "folderID": "17100000-0000-0000-0000-000000000304",
                        "createdAt": 731722801,
                        "modifiedAt": 731722802
                      }
                    }
                  },
                  {
                    "noteTitleChanged": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "title": "Updated title",
                        "modifiedAt": 731722803
                      }
                    }
                  },
                  {
                    "noteBodyTextInserted": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "utf16Offset": 1,
                        "text": "😀",
                        "modifiedAt": 731722804
                      }
                    }
                  },
                  {
                    "noteBodyTextDeleted": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "utf16Offset": 1,
                        "utf16Length": 2,
                        "expectedText": "😀",
                        "modifiedAt": 731722805
                      }
                    }
                  },
                  {
                    "noteBodyReconciled": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "replacementBody": "Reconciled body",
                        "replacementContentHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "modifiedAt": 731722806
                      }
                    }
                  },
                  {
                    "noteLifecycleChanged": {
                      "_0": {
                        "noteID": "17100000-0000-0000-0000-000000000303",
                        "deletedAt": 731722807,
                        "modifiedAt": 731722808,
                        "title": "Lifecycle title",
                        "body": "Lifecycle body",
                        "baseTitleHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "baseBodyHash": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                      }
                    }
                  }
                ]
              }
            }
            """.utf8
        )
    }
}

private struct TestSequenceCounter: Decodable {
    let lastReserved: UInt64
}

// These DTOs freeze the complete pre-anchored V1 wire contract without
// depending on the current MyRAM payload implementations under test.
private struct LegacySyncBatchEnvelopeV1: Codable, Equatable {
    let schemaVersion: Int
    let batch: LegacySyncBatchV1
}

private struct LegacySyncBatchV1: Codable, Equatable {
    let id: UUID
    let originDeviceID: UUID
    let createdAt: Date
    let batchSequence: UInt64?
    let changes: [LegacySyncBatchChangeV1]
}

private enum LegacySyncBatchChangeV1: Codable, Equatable {
    case noteCreated(LegacySyncBatchNoteCreatedChangeV1)
    case noteTitleChanged(LegacySyncBatchNoteTitleChangedChangeV1)
    case noteBodyTextInserted(LegacySyncBatchNoteBodyTextInsertedChangeV1)
    case noteBodyTextDeleted(LegacySyncBatchNoteBodyTextDeletedChangeV1)
    case noteBodyReconciled(LegacySyncBatchNoteBodyReconciledChangeV1)
    case noteLifecycleChanged(LegacySyncBatchNoteLifecycleChangedChangeV1)
}

private struct LegacySyncBatchNoteCreatedChangeV1: Codable, Equatable {
    let noteID: UUID
    let title: String
    let body: String
    let folderID: UUID?
    let createdAt: Date
    let modifiedAt: Date
}

private struct LegacySyncBatchNoteTitleChangedChangeV1: Codable, Equatable {
    let noteID: UUID
    let title: String
    let modifiedAt: Date
}

private struct LegacySyncBatchNoteBodyTextInsertedChangeV1: Codable, Equatable {
    let noteID: UUID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
    let baseContentHash: String?
}

private struct LegacySyncBatchNoteBodyTextDeletedChangeV1: Codable, Equatable {
    let noteID: UUID
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String?
    let modifiedAt: Date
    let baseContentHash: String?
}

private struct LegacySyncBatchNoteBodyReconciledChangeV1: Codable, Equatable {
    let noteID: UUID
    let replacementBody: String
    let replacementContentHash: String
    let modifiedAt: Date
}

private struct LegacySyncBatchNoteLifecycleChangedChangeV1: Codable, Equatable {
    let noteID: UUID
    let deletedAt: Date?
    let modifiedAt: Date
    let title: String
    let body: String
    let baseTitleHash: String
    let baseBodyHash: String
}

private enum LegacyMultipeerSyncMessageKindV1: String, Codable, Equatable {
    case legacySyncEnvelope = "myram.legacySyncEnvelope.v1"
    case batchSync = "myram.batchSync.v1"
    case batchAcknowledgement = "myram.batchAcknowledgement.v1"
}

private struct LegacyMultipeerSyncMessageEnvelopeV1: Codable, Equatable {
    let kind: LegacyMultipeerSyncMessageKindV1
    let schemaVersion: Int
    let payload: Data
}
