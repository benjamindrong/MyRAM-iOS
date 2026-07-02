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
        let defaults = makeDefaults()
        let store = SyncBatchSequenceStore(defaults: defaults)
        let firstDevice = UUID(uuidString: "00000000-0000-0000-0000-000000123251")!
        let secondDevice = UUID(uuidString: "00000000-0000-0000-0000-000000123252")!

        XCTAssertEqual(store.nextSequence(for: firstDevice), 1)
        XCTAssertEqual(SyncBatchSequenceStore(defaults: defaults).nextSequence(for: firstDevice), 2)
        XCTAssertEqual(store.nextSequence(for: secondDevice), 1)
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SyncBatchPayloadCompatibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
