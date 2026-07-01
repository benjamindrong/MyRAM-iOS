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
}
