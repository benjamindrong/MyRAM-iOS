import SwiftData
import XCTest
@testable import MyRAM

final class SyncConvergenceFoundationTests: XCTestCase {
    func testSyntheticKeysAreDeterministicAndVersioned() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132001")!
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132002")!

        XCTAssertEqual(
            SyncConvergenceKey.snapshot(noteID: noteID, contentHash: "abc"),
            "v2|n:8:snapshot|u:36:00000000-0000-0000-0000-000000132001|s:3:abc"
        )
        XCTAssertEqual(
            SyncConvergenceKey.retainedOperation(batchID: batchID, operationIndex: 7),
            "v2|n:9:operation|u:36:00000000-0000-0000-0000-000000132002|i:1:7"
        )
        XCTAssertEqual(
            SyncConvergenceKey.batchNoteEffect(batchID: batchID, noteID: noteID),
            "v2|n:17:batch-note-effect|u:36:00000000-0000-0000-0000-000000132002|u:36:00000000-0000-0000-0000-000000132001"
        )
        XCTAssertEqual(
            SyncConvergenceKey.incorporationBlockingReference(
                batchID: batchID,
                blockingBatchID: UUID(uuidString: "00000000-0000-0000-0000-000000132003")!,
                noteID: noteID
            ),
            "v2|n:32:incorporation-blocking-reference|u:36:00000000-0000-0000-0000-000000132002|u:36:00000000-0000-0000-0000-000000132003|u:36:00000000-0000-0000-0000-000000132001"
        )
    }

    func testSyntheticKeysAreCollisionSafeForArbitraryComponents() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132011")!
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132012")!
        let composed = "é"
        let decomposed = "e\u{301}"

        XCTAssertNotEqual(
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a|b"),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a")
        )
        XCTAssertNotEqual(
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a|b|"),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a|b")
        )
        XCTAssertNotEqual(
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: composed),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: decomposed)
        )
        XCTAssertNotEqual(
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: ""),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "|")
        )
        XCTAssertNotEqual(
            SyncConvergenceKey.incorporationContradiction(batchID: batchID, noteID: nil),
            SyncConvergenceKey.incorporationContradiction(batchID: batchID, noteID: noteID)
        )
        XCTAssertEqual(
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a|b"),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "a|b")
        )

        let allModelKeys = [
            SyncConvergenceKey.snapshot(noteID: noteID, contentHash: "hash|with|pipes"),
            SyncConvergenceKey.retainedOperation(batchID: batchID, operationIndex: 1),
            SyncConvergenceKey.incorporatedBatch(batchID: batchID),
            SyncConvergenceKey.incorporatedBatchTombstone(batchID: batchID),
            SyncConvergenceKey.batchNoteEffect(batchID: batchID, noteID: noteID),
            SyncConvergenceKey.batchOperationIdentity(batchID: batchID, operationIndex: 1),
            SyncConvergenceKey.batchResultEvidence(batchID: batchID, noteID: noteID, kind: "kind|value"),
            SyncConvergenceKey.incorporationBlockingReference(batchID: batchID, blockingBatchID: batchID, noteID: noteID),
            SyncConvergenceKey.incorporationContradiction(batchID: batchID, noteID: nil),
            SyncConvergenceKey.titleWinner(noteID: noteID),
            SyncConvergenceKey.compaction(noteID: noteID),
            SyncConvergenceKey.diagnostic(noteID: noteID),
            SyncConvergenceKey.diagnosticBlockingReference(noteID: noteID, blockingBatchID: batchID, affectedNoteID: noteID),
            SyncConvergenceKey.episode(noteID: noteID, generation: 1),
            SyncConvergenceKey.reconciliationCandidate(noteID: noteID, generation: 1, candidateIdentity: "identity|value"),
            SyncConvergenceKey.reconciliationCompletionEvidence(noteID: noteID, generation: 1, kind: "kind|value")
        ]

        XCTAssertEqual(Set(allModelKeys).count, allModelKeys.count)
        XCTAssertTrue(allModelKeys.allSatisfy { $0.hasPrefix("v2|") })
    }

    func testDateBitPatternPreservesSubMillisecondIdentity() {
        let first = Date(timeIntervalSinceReferenceDate: 1_000.000_000_1)
        let second = Date(timeIntervalSinceReferenceDate: 1_000.000_000_2)

        let firstBits = SyncConvergenceDateBits.bitPattern(for: first)
        let secondBits = SyncConvergenceDateBits.bitPattern(for: second)

        XCTAssertNotEqual(firstBits, secondBits)
        XCTAssertEqual(SyncConvergenceDateBits.date(from: firstBits), first)
        XCTAssertEqual(SyncConvergenceDateBits.date(from: secondBits), second)
    }

    func testCanonicalReplayKeyPayloadRoundTripPreservesOrdering() throws {
        let firstBatch = makeBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000132101")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132201")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10.000_000_1)
        )
        let secondBatch = makeBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000132102")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132201")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10.000_000_2)
        )

        let first = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: firstBatch, change: firstBatch.changes[0], operationIndex: 0)
        )
        let second = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: secondBatch, change: secondBatch.changes[0], operationIndex: 0)
        )

        let firstRoundTrip = try CanonicalReplayKeyPayload.decodeEvidenceData(first.encodedEvidenceData())
        let secondRoundTrip = try CanonicalReplayKeyPayload.decodeEvidenceData(second.encodedEvidenceData())

        XCTAssertLessThan(try ValidatedCanonicalReplayKey(first), try ValidatedCanonicalReplayKey(second))
        XCTAssertLessThan(
            try ValidatedCanonicalReplayKey(firstRoundTrip),
            try ValidatedCanonicalReplayKey(secondRoundTrip)
        )
        XCTAssertEqual(firstRoundTrip, first)
        XCTAssertEqual(secondRoundTrip, second)
    }

    func testCanonicalReplayKeyPayloadValidationRejectsMalformedEvidence() throws {
        let validLegacy = validReplayPayload(batchOrderKind: .legacy)
        let validSequenced = validReplayPayload(
            batchOrderKind: .sequenced,
            legacyCreatedAtBitPattern: nil,
            sequence: 1
        )

        XCTAssertNoThrow(try validLegacy.encodedEvidenceData())
        XCTAssertNoThrow(try validSequenced.encodedEvidenceData())
        XCTAssertThrowsError(try validReplayPayload(version: 99).encodedEvidenceData())
        XCTAssertThrowsError(
            try validReplayPayload(
                batchOrderKind: .legacy,
                legacyCreatedAtBitPattern: nil
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(
            try validReplayPayload(
                batchOrderKind: .legacy,
                sequence: 1
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(
            try validReplayPayload(
                batchOrderKind: .sequenced,
                legacyCreatedAtBitPattern: nil,
                sequence: nil
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(
            try validReplayPayload(
                batchOrderKind: .sequenced,
                legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSinceReferenceDate: 1)),
                sequence: 1
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(try validReplayPayload(originDeviceIDLowercase: "not-a-uuid").encodedEvidenceData())
        XCTAssertThrowsError(
            try validReplayPayload(
                originDeviceIDLowercase: "abcdefab-cdef-abcd-efab-abcdefabcdef".uppercased()
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(try validReplayPayload(batchIDLowercase: "not-a-uuid").encodedEvidenceData())
        XCTAssertThrowsError(
            try validReplayPayload(
                batchIDLowercase: "abcdefab-cdef-abcd-efab-abcdefabcdef".uppercased()
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(try validReplayPayload(operationIndex: -1).encodedEvidenceData())
        XCTAssertThrowsError(try CanonicalReplayKeyPayload.decodeEvidenceData(Data([0xde, 0xad, 0xbe, 0xef])))
        XCTAssertThrowsError(try ValidatedCanonicalReplayKey(validReplayPayload(operationIndex: -1)))
    }

    func testCanonicalReplayKeyPayloadLegacyCreatedAtMatchesRuntimeOrderingForNegativeDates() throws {
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000132210")!
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132211")!
        let scenarios: [(Date, Date)] = [
            (Date(timeIntervalSinceReferenceDate: -20), Date(timeIntervalSinceReferenceDate: -10)),
            (Date(timeIntervalSinceReferenceDate: -1), Date(timeIntervalSinceReferenceDate: 1)),
            (Date(timeIntervalSinceReferenceDate: -100), Date(timeIntervalSinceReferenceDate: -10))
        ]

        for (index, scenario) in scenarios.enumerated() {
            let firstBatch = makeOrderingBatch(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 132220 + index * 2))!,
                originDeviceID: originDeviceID,
                createdAt: scenario.0,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
                noteID: noteID
            )
            let secondBatch = makeOrderingBatch(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 132221 + index * 2))!,
                originDeviceID: originDeviceID,
                createdAt: scenario.1,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
                noteID: noteID
            )
            let runtimeKeys = [
                SyncBatchReplayKey(batch: secondBatch, change: secondBatch.changes[0], operationIndex: 0),
                SyncBatchReplayKey(batch: firstBatch, change: firstBatch.changes[0], operationIndex: 0)
            ].sorted()
            let persistedKeys = try [
                CanonicalReplayKeyPayload(replayKey: runtimeKeys[1]),
                CanonicalReplayKeyPayload(replayKey: runtimeKeys[0])
            ]
                .map { try CanonicalReplayKeyPayload.decodeEvidenceData($0.encodedEvidenceData()) }
                .map { try ValidatedCanonicalReplayKey($0) }
                .sorted()
                .map(\.payload)

            XCTAssertEqual(persistedKeys, runtimeKeys.map(CanonicalReplayKeyPayload.init(replayKey:)))
        }
    }

    func testCanonicalReplayKeyPayloadPreservesLegacyAndModifiedAtSubMillisecondIdentity() {
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000132230")!
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132231")!
        let firstBatch = makeOrderingBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000132232")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: -1_000.000_000_1),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1_000.000_000_1),
            noteID: noteID
        )
        let secondBatch = makeOrderingBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000132233")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: -1_000.000_000_2),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1_000.000_000_2),
            noteID: noteID
        )

        let first = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: firstBatch, change: firstBatch.changes[0], operationIndex: 0)
        )
        let second = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(batch: secondBatch, change: secondBatch.changes[0], operationIndex: 0)
        )

        XCTAssertNotEqual(first.modifiedAtBitPattern, second.modifiedAtBitPattern)
        XCTAssertNotEqual(first.legacyCreatedAtBitPattern, second.legacyCreatedAtBitPattern)
        XCTAssertEqual(
            try [ValidatedCanonicalReplayKey(second), ValidatedCanonicalReplayKey(first)].sorted().map(\.payload),
            [first, second]
        )
    }

    func testUnsupportedDigestFormatMapsToDedicatedDrainFailure() {
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132301")!
        let failure = SyncConvergenceTransactionFailure.unsupportedDigestFormat(
            noteID: nil,
            batchID: batchID,
            formatVersion: 99
        )

        XCTAssertEqual(
            SyncConvergenceDrainFailureMapping.failureKind(for: failure),
            .unsupportedDigestFormat
        )
        XCTAssertEqual(
            SyncBatchDrainFailureClassifier.userMessage(
                for: SyncBatchDrainFailure(batchID: batchID, kind: .unsupportedDigestFormat)
            ),
            "Incoming sync history uses an unsupported digest format."
        )
    }

    func testCommittedAtOrderingPayloadRoundTripAndValidation() throws {
        let committedAt = Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132401")!
        let payload = CommittedAtOrderingPayload(batchID: batchID, committedAt: committedAt)
        let encoded = try payload.encodedEvidenceData()
        let decoded = try CommittedAtOrderingPayload.decodeEvidenceData(encoded)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.committedAt, committedAt)
        XCTAssertEqual(decoded.batchIDLowercase, batchID.uuidString.lowercased())
        XCTAssertThrowsError(
            try CommittedAtOrderingPayload(
                version: 99,
                committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
                batchIDLowercase: batchID.uuidString
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(
            try CommittedAtOrderingPayload(
                committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
                batchIDLowercase: "not-a-uuid"
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(
            try CommittedAtOrderingPayload(
                committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
                batchIDLowercase: "abcdefab-cdef-abcd-efab-abcdefabcdef".uppercased()
            ).encodedEvidenceData()
        )
        XCTAssertNoThrow(
            try CommittedAtOrderingPayload(
                batchID: UUID(uuidString: "abcdefab-cdef-abcd-efab-abcdefabcdef")!,
                committedAt: committedAt
            ).encodedEvidenceData()
        )
    }

    func testCommittedAtOrderingPayloadDetectsModelDisagreement() throws {
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132403")!
        let committedAt = Date(timeIntervalSinceReferenceDate: 20)
        let batch = IncorporatedSyncBatch(
            batchID: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132404")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            batchSequence: nil,
            schemaVersion: 1,
            committedAt: committedAt,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitStatePayloadData: Data()
        )
        let mismatchedPayload = CommittedAtOrderingPayload(
            batchID: batchID,
            committedAt: Date(timeIntervalSinceReferenceDate: 21)
        )

        XCTAssertThrowsError(try mismatchedPayload.validate(against: batch))
    }

    func testTombstoneUsesDeterministicV1JSONPayloadAndMeasuredSize() throws {
        let tombstone = try makeValidTombstone()
        let encoded = try tombstone.canonicalEncodedPayloadBytes()
        let expectedJSON = """
        {"b":"00000000-0000-0000-0000-000000132401","c":{"b":"00000000-0000-0000-0000-000000132401","t":4653144502448127204,"v":1},"d":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","df":1,"o":"00000000-0000-0000-0000-000000132402","r":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","rf":1,"s":1,"v":1}
        """

        XCTAssertEqual(String(data: encoded, encoding: .utf8), expectedJSON)
        XCTAssertEqual(encoded.count, 334)
        XCTAssertTrue(tombstone.isWithinFixedSizeLimit)
        XCTAssertEqual(tombstone.tombstoneKey, SyncConvergenceKey.incorporatedBatchTombstone(batchID: tombstone.batchID))
    }

    func testTombstoneValidationFailsClosedForInvalidPayloads() throws {
        let committedAt = Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
        let orderingPayload = CommittedAtOrderingPayload(
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000132401")!,
            committedAt: committedAt
        )

        XCTAssertNoThrow(try IncorporatedBatchTombstone.validateEncodedPayloadSize(Data(repeating: 0x01, count: 512)))
        XCTAssertThrowsError(try IncorporatedBatchTombstone.validateEncodedPayloadSize(Data(repeating: 0x01, count: 513)))
        XCTAssertThrowsError(
            try makeValidTombstone(canonicalPayloadDigest: String(repeating: "a", count: 65))
        )
        XCTAssertThrowsError(
            try makeValidTombstone(canonicalPayloadDigest: String(repeating: "z", count: 64))
        )
        XCTAssertThrowsError(
            try makeValidTombstone(
                committedAtOrderingPayloadData: try SyncConvergenceStableEncoding.encode(
                    CommittedAtOrderingPayload(
                        version: 99,
                        committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
                        batchIDLowercase: "00000000-0000-0000-0000-000000132401"
                    )
                )
            )
        )
        XCTAssertThrowsError(
            try makeValidTombstone(
                committedAtOrderingPayloadData: Data([0xde, 0xad, 0xbe, 0xef])
            )
        )
        XCTAssertThrowsError(
            try makeValidTombstone(tombstoneFormatVersion: 2)
        )
        XCTAssertThrowsError(
            try makeValidTombstone(
                committedAtOrderingPayloadData: try orderingPayload.encodedEvidenceData(),
                tombstoneFormatVersion: 2
            )
        )
    }

    func testTombstonePostInitializationValidationRejectsCorruption() throws {
        let tombstone = try makeValidTombstone()

        tombstone.testOnlySetCanonicalPayloadDigest(String(repeating: "a", count: 65))
        XCTAssertFalse(tombstone.isWithinFixedSizeLimit)
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(tombstone))

        let invalidCharacterTombstone = try makeValidTombstone()
        invalidCharacterTombstone.testOnlySetCanonicalPayloadDigest(String(repeating: "z", count: 64))
        XCTAssertFalse(invalidCharacterTombstone.isWithinFixedSizeLimit)
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(invalidCharacterTombstone))

        let mismatchedOrderingTombstone = try makeValidTombstone()
        mismatchedOrderingTombstone.testOnlySetCommittedAtOrderingPayloadData(
            try CommittedAtOrderingPayload(
                batchID: UUID(uuidString: "00000000-0000-0000-0000-000000132499")!,
                committedAt: Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
            ).encodedEvidenceData()
        )
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(mismatchedOrderingTombstone))

        let unsupportedFormatTombstone = try makeValidTombstone()
        unsupportedFormatTombstone.testOnlySetTombstoneFormatVersion(2)
        XCTAssertFalse(unsupportedFormatTombstone.isWithinFixedSizeLimit)
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(unsupportedFormatTombstone))
    }

    func testTombstoneSizeChecksUseFullPersistenceValidation() throws {
        let tombstone = try makeValidTombstone()

        XCTAssertTrue(tombstone.isWithinFixedSizeLimit)
        XCTAssertNoThrow(try IncorporatedBatchTombstone.validateEncodedPayloadSize(Data(repeating: 0x01, count: 512)))
        XCTAssertThrowsError(try IncorporatedBatchTombstone.validateEncodedPayloadSize(Data(repeating: 0x01, count: 513)))

        tombstone.testOnlySetCommittedAtOrderingPayloadData(Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertFalse(tombstone.isWithinFixedSizeLimit)
    }

    func testTombstoneAndFullRecordUseSameCommittedAtOrderingPayloadType() throws {
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132401")!
        let committedAt = Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
        let batch = IncorporatedSyncBatch(
            batchID: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132402")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            batchSequence: nil,
            schemaVersion: 1,
            committedAt: committedAt,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitStatePayloadData: Data()
        )
        let payload = CommittedAtOrderingPayload(batchID: batchID, committedAt: committedAt)
        let tombstone = try makeValidTombstone(committedAtOrderingPayloadData: try payload.encodedEvidenceData())

        XCTAssertNoThrow(try payload.validate(against: batch))
        XCTAssertNoThrow(try payload.validate(against: tombstone))
    }

    func testDateAuthorityValidationCoversDuplicatedModelPairs() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132601")!
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132602")!
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000132603")!
        let date = Date(timeIntervalSinceReferenceDate: 123.456_789)
        let replayBatch = makeOrderingBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: date,
            modifiedAt: date,
            noteID: noteID
        )
        let replayKeyPayload = CanonicalReplayKeyPayload(
            replayKey: SyncBatchReplayKey(
                batch: replayBatch,
                change: replayBatch.changes[0],
                operationIndex: 0
            )
        )
        let replayPayload = try replayKeyPayload.encodedEvidenceData()
        let operationIdentityPayload = try OperationIdentityPayload(
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: 0,
            operationKind: "insert",
            canonicalReplayKey: replayKeyPayload
        ).encodedPayloadData()
        let retained = RetainedBodyOperation(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: 0,
            operationKindRaw: "insert",
            utf16Offset: 0,
            text: "A",
            modifiedAt: date,
            canonicalReplayKeyPayloadData: replayPayload,
            sourceRaw: "remote"
        )
        let batch = IncorporatedSyncBatch(
            batchID: batchID,
            originDeviceID: originDeviceID,
            createdAt: date,
            batchSequence: nil,
            schemaVersion: 1,
            committedAt: date,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: String(repeating: "c", count: 64),
            postCommitStatePayloadData: Data()
        )
        let winner = NoteTitleWinner(
            noteID: noteID,
            title: "Title",
            canonicalReplayKeyPayloadData: replayPayload,
            operationIdentityPayloadData: operationIdentityPayload,
            updatedAt: date
        )
        let operationIdentity = IncorporatedBatchOperationIdentity(
            batchID: batchID,
            noteID: noteID,
            operationIndex: 0,
            operationIdentityPayloadData: operationIdentityPayload,
            canonicalReplayKeyPayloadData: replayPayload
        )
        let diagnostic = ConvergenceNoteDiagnosticState(noteID: noteID, statusRaw: "blocked", createdAt: date, updatedAt: date)
        let episode = ReconciliationEpisode(noteID: noteID, generation: 1, stateRaw: "complete", completedAt: date)

        XCTAssertNoThrow(try retained.validateDateAuthority())
        XCTAssertNoThrow(try batch.validateDateAuthority())
        XCTAssertNoThrow(try winner.validateDateAuthority())
        XCTAssertNoThrow(try diagnostic.validateDateAuthority())
        XCTAssertNoThrow(try episode.validateDateAuthority())

        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(retained))
        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(batch))
        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(winner))
        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(operationIdentity))
        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(diagnostic))
        XCTAssertNoThrow(try SyncConvergencePersistenceValidation.validate(episode))

        let malformedIdentityWinner = NoteTitleWinner(
            noteID: noteID,
            title: "Title",
            canonicalReplayKeyPayloadData: replayPayload,
            operationIdentityPayloadData: Data([0xde, 0xad, 0xbe, 0xef]),
            updatedAt: date
        )
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(malformedIdentityWinner))

        let synchronizedDate = Date(timeIntervalSinceReferenceDate: 456)
        retained.setModifiedAt(synchronizedDate)
        batch.setCreatedAt(synchronizedDate)
        batch.setCommittedAt(synchronizedDate)
        winner.setUpdatedAt(synchronizedDate)
        diagnostic.setCreatedAt(synchronizedDate)
        diagnostic.setUpdatedAt(synchronizedDate)
        episode.setCompletedAt(synchronizedDate)

        XCTAssertNoThrow(try retained.validateDateAuthority())
        XCTAssertNoThrow(try batch.validateDateAuthority())
        XCTAssertNoThrow(try winner.validateDateAuthority())
        XCTAssertNoThrow(try diagnostic.validateDateAuthority())
        XCTAssertNoThrow(try episode.validateDateAuthority())

        retained.testOnlySetModifiedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        XCTAssertThrowsError(try retained.validateDateAuthority())
        let authoritativeRetainedBits = retained.modifiedAtBitPattern
        retained.rebuildConvenienceDatesFromAuthoritativeBits()
        XCTAssertEqual(retained.modifiedAtBitPattern, authoritativeRetainedBits)
        XCTAssertEqual(retained.modifiedAt, SyncConvergenceDateBits.date(from: authoritativeRetainedBits))
        XCTAssertNoThrow(try retained.validateDateAuthority())

        batch.testOnlySetCreatedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        batch.testOnlySetCommittedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        winner.testOnlySetUpdatedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        diagnostic.testOnlySetCreatedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        diagnostic.testOnlySetUpdatedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        episode.testOnlySetCompletedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))

        XCTAssertThrowsError(try batch.validateDateAuthority())
        XCTAssertThrowsError(try winner.validateDateAuthority())
        XCTAssertThrowsError(try diagnostic.validateDateAuthority())
        XCTAssertThrowsError(try episode.validateDateAuthority())

        let batchCreatedBits = batch.createdAtBitPattern
        let batchCommittedBits = batch.committedAtBitPattern
        let winnerUpdatedBits = winner.updatedAtBitPattern
        let diagnosticCreatedBits = diagnostic.createdAtBitPattern
        let diagnosticUpdatedBits = diagnostic.updatedAtBitPattern
        let episodeCompletedBits = episode.completedAtBitPattern
        batch.rebuildConvenienceDatesFromAuthoritativeBits()
        winner.rebuildConvenienceDatesFromAuthoritativeBits()
        diagnostic.rebuildConvenienceDatesFromAuthoritativeBits()
        episode.rebuildConvenienceDatesFromAuthoritativeBits()

        XCTAssertEqual(batch.createdAtBitPattern, batchCreatedBits)
        XCTAssertEqual(batch.committedAtBitPattern, batchCommittedBits)
        XCTAssertEqual(winner.updatedAtBitPattern, winnerUpdatedBits)
        XCTAssertEqual(diagnostic.createdAtBitPattern, diagnosticCreatedBits)
        XCTAssertEqual(diagnostic.updatedAtBitPattern, diagnosticUpdatedBits)
        XCTAssertEqual(episode.completedAtBitPattern, episodeCompletedBits)

        episode.setCompletedAt(nil)
        XCTAssertNoThrow(try episode.validateDateAuthority())
        episode.testOnlySetCompletedAtWithoutUpdatingBits(Date(timeIntervalSinceReferenceDate: 999))
        XCTAssertThrowsError(try SyncConvergencePersistenceValidation.validate(episode))
    }

    @MainActor
    func testConvergenceModelsAreIncludedInAppSchema() throws {
        let configuration = ModelConfiguration(
            "SyncConvergenceFoundationTests-\(UUID().uuidString)",
            schema: Schema(MyRAMModelRegistry.models),
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: Schema(MyRAMModelRegistry.models), configurations: configuration)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132501")!
        let snapshot = NoteContentSnapshot(
            noteID: noteID,
            contentHash: SyncBatchContentHash.sha256Hex(for: "Body"),
            body: "Body",
            generation: 1
        )

        container.mainContext.insert(snapshot)
        container.mainContext.insert(
            IncorporationBlockingReference(
                batchID: UUID(uuidString: "00000000-0000-0000-0000-000000132502")!,
                blockingBatchID: UUID(uuidString: "00000000-0000-0000-0000-000000132503")!,
                noteID: noteID,
                blockingBatchReferencePayloadData: Data([0x01])
            )
        )
        container.mainContext.insert(
            IncorporationContradictionDiagnostic(
                batchID: UUID(uuidString: "00000000-0000-0000-0000-000000132504")!,
                noteID: noteID,
                diagnosticEvidencePayloadData: Data([0x02])
            )
        )
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<NoteContentSnapshot>())
        XCTAssertEqual(fetched.map(\.snapshotKey), [snapshot.snapshotKey])
    }

    private func makeBatch(
        id: UUID,
        originDeviceID: UUID,
        createdAt: Date,
        modifiedAt: Date
    ) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: UUID(uuidString: "00000000-0000-0000-0000-000000132999")!,
                        utf16Offset: 0,
                        text: "A",
                        modifiedAt: modifiedAt,
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                    )
                )
            ]
        )
    }

    private func makeOrderingBatch(
        id: UUID,
        originDeviceID: UUID,
        createdAt: Date,
        modifiedAt: Date,
        noteID: UUID
    ) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "Title",
                        modifiedAt: modifiedAt
                    )
                )
            ]
        )
    }

    private func makeValidTombstone(
        canonicalPayloadDigest: String = String(repeating: "a", count: 64),
        committedAtOrderingPayloadData: Data? = nil,
        tombstoneFormatVersion: Int = 1
    ) throws -> IncorporatedBatchTombstone {
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132401")!
        let committedAt = Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
        let payloadData = try committedAtOrderingPayloadData ?? CommittedAtOrderingPayload(
            batchID: batchID,
            committedAt: committedAt
        ).encodedEvidenceData()

        return try IncorporatedBatchTombstone.makeValidated(
            batchID: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132402")!,
            canonicalPayloadDigest: canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: 1,
            schemaVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            committedAtOrderingPayloadData: payloadData,
            tombstoneFormatVersion: tombstoneFormatVersion
        )
    }

    private func validReplayPayload(
        version: Int = CanonicalReplayKeyPayload.supportedVersion,
        originDeviceIDLowercase: String = "00000000-0000-0000-0000-000000132701",
        batchOrderKind: CanonicalReplayKeyPayload.BatchOrderKind = .legacy,
        legacyCreatedAtBitPattern: UInt64? = SyncConvergenceDateBits.bitPattern(
            for: Date(timeIntervalSinceReferenceDate: -1)
        ),
        sequence: UInt64? = nil,
        batchIDLowercase: String = "00000000-0000-0000-0000-000000132702",
        operationIndex: Int = 0
    ) -> CanonicalReplayKeyPayload {
        CanonicalReplayKeyPayload(
            version: version,
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(
                for: Date(timeIntervalSinceReferenceDate: 2)
            ),
            originDeviceIDLowercase: originDeviceIDLowercase,
            batchOrderKind: batchOrderKind,
            legacyCreatedAtBitPattern: legacyCreatedAtBitPattern,
            sequence: sequence,
            batchIDLowercase: batchIDLowercase,
            operationIndex: operationIndex
        )
    }
}
