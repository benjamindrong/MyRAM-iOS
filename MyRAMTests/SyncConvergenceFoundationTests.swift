import SwiftData
import XCTest
@testable import MyRAM

final class SyncConvergenceFoundationTests: XCTestCase {
    func testSyntheticKeysAreDeterministicAndVersioned() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000132001")!
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000132002")!

        XCTAssertEqual(
            SyncConvergenceKey.snapshot(noteID: noteID, contentHash: "abc"),
            "v1|snapshot|00000000-0000-0000-0000-000000132001|abc"
        )
        XCTAssertEqual(
            SyncConvergenceKey.retainedOperation(batchID: batchID, operationIndex: 7),
            "v1|operation|00000000-0000-0000-0000-000000132002|7"
        )
        XCTAssertEqual(
            SyncConvergenceKey.batchNoteEffect(batchID: batchID, noteID: noteID),
            "v1|batch-note-effect|00000000-0000-0000-0000-000000132002|00000000-0000-0000-0000-000000132001"
        )
        XCTAssertEqual(
            SyncConvergenceKey.incorporationBlockingReference(
                batchID: batchID,
                blockingBatchID: UUID(uuidString: "00000000-0000-0000-0000-000000132003")!,
                noteID: noteID
            ),
            "v1|incorporation-blocking-reference|00000000-0000-0000-0000-000000132002|00000000-0000-0000-0000-000000132003|00000000-0000-0000-0000-000000132001"
        )
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

        let firstRoundTrip = try SyncConvergenceStableEncoding.decode(
            CanonicalReplayKeyPayload.self,
            from: SyncConvergenceStableEncoding.encode(first)
        )
        let secondRoundTrip = try SyncConvergenceStableEncoding.decode(
            CanonicalReplayKeyPayload.self,
            from: SyncConvergenceStableEncoding.encode(second)
        )

        XCTAssertLessThan(first, second)
        XCTAssertLessThan(firstRoundTrip, secondRoundTrip)
        XCTAssertEqual(firstRoundTrip, first)
        XCTAssertEqual(secondRoundTrip, second)
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

    func testTombstoneUsesFixedSizeIdentityEvidence() throws {
        let committedAt = Date(timeIntervalSinceReferenceDate: 1_234.567_890_1)
        let orderingPayload = CommittedAtOrderingPayload(
            version: 1,
            committedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: committedAt),
            batchIDLowercase: "00000000-0000-0000-0000-000000132401"
        )
        let tombstone = IncorporatedBatchTombstone(
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000132401")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000132402")!,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            schemaVersion: 1,
            committedResultDigest: String(repeating: "b", count: 64),
            committedResultDigestFormatVersion: 1,
            committedAtOrderingPayloadData: try SyncConvergenceStableEncoding.encode(orderingPayload)
        )

        XCTAssertTrue(tombstone.isWithinFixedSizeLimit)
        XCTAssertEqual(tombstone.tombstoneKey, SyncConvergenceKey.incorporatedBatchTombstone(batchID: tombstone.batchID))
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
}

private struct CommittedAtOrderingPayload: Codable, Equatable {
    let version: Int
    let committedAtBitPattern: UInt64
    let batchIDLowercase: String
}
