import AnchoredSequenceCore
import XCTest
@testable import MyRAMMac

final class MacSyncBatchAccumulatorTests: XCTestCase {
    func testChangesAppendToPendingBatchAndPreserveOrdering() async {
        let accumulator = makeAccumulator()
        let firstChange = capturedTitleChange("First")
        let secondChange = capturedTitleChange("Second")
        let start = Date(timeIntervalSince1970: 100)

        await accumulator.record(firstChange, at: start)
        await accumulator.record(secondChange, at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(5))?.primary.batch

        XCTAssertEqual(batch?.changes, [firstChange.change, secondChange.change])
    }

    func testQuietWindowRearmsAndBatchIDStaysStable() async {
        let accumulator = makeAccumulator()
        let start = Date(timeIntervalSince1970: 200)

        await accumulator.record(capturedTitleChange("First"), at: start)
        let originalBatchID = await accumulator.pendingBatchID()
        let originalReadyAt = await accumulator.pendingReadyAt()

        await accumulator.record(capturedTitleChange("Second"), at: start.addingTimeInterval(2))
        let rearmedBatchID = await accumulator.pendingBatchID()
        let rearmedReadyAt = await accumulator.pendingReadyAt()

        XCTAssertEqual(rearmedBatchID, originalBatchID)
        XCTAssertEqual(originalReadyAt, start.addingTimeInterval(3))
        XCTAssertEqual(rearmedReadyAt, start.addingTimeInterval(5))
        let earlyBatch = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(4))?.primary.batch
        let readyBatch = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(5))?.primary.batch
        XCTAssertNil(earlyBatch)
        XCTAssertNotNil(readyBatch)
    }

    func testReadyBatchStreamYieldsAfterQuietWindow() async throws {
        let accumulator = makeAccumulator()
        let stream = await accumulator.readyLocalObligations()
        let nextBatchTask = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let start = Date(timeIntervalSince1970: 300)

        await accumulator.record(capturedTitleChange("Ready"), at: start)
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(3))

        let collection = await nextBatchTask.value
        XCTAssertEqual(collection?.obligations.count, 1)
        let batch = collection?.primary.batch
        XCTAssertEqual(batch?.changes, [titleChange("Ready")])
    }

    func testBatchSequenceIsAssignedWhenPendingBatchStarts() async {
        let accumulator = MacSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000102")! },
            batchSequenceProvider: { .reserved(7) }
        )
        let start = Date(timeIntervalSince1970: 500)

        await accumulator.record(capturedTitleChange("First"), at: start)
        await accumulator.record(capturedTitleChange("Second"), at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(5))?.primary.batch

        XCTAssertEqual(batch?.batchSequence, 7)
    }

    func testBoundaryRecordAndTakeReturnsSuppliedBodyChangesExactlyOnce() async throws {
        let accumulator = makeAccumulator()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let start = Date(timeIntervalSince1970: 600)
        let captured = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: "Hello",
            newBody: "Hello world",
            modifiedAt: start,
            bodyHashCapabilityEnabled: true
        )

        let collection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: captured,
            affecting: noteID,
            at: start
        )
        let obligation = collection?.primary
        try await commitAfterDurableAdmission(collection, accumulator: accumulator)
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(5))
        let replayed = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(5))?.primary.batch

        XCTAssertEqual(obligation?.batch.changes, captured.map(\.change))
        guard case .captured(let capturedChanges) = obligation?.evidence else {
            return XCTFail("Expected captured evidence")
        }
        XCTAssertEqual(capturedChanges, captured)
        XCTAssertNil(replayed)
    }

    func testBoundaryRecordAndTakeWithEmptyInputExtractsAlreadyPendingBodyWork() async throws {
        let accumulator = makeAccumulator()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let start = Date(timeIntervalSince1970: 700)
        let captured = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: "A",
            newBody: "AB",
            modifiedAt: start,
            bodyHashCapabilityEnabled: true
        )

        await accumulator.record(captured, at: start)
        let collection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: [],
            affecting: noteID,
            at: start.addingTimeInterval(1)
        )
        let obligation = collection?.primary

        guard case .captured(let capturedChanges) = obligation?.evidence else {
            return XCTFail("Expected captured evidence")
        }
        XCTAssertEqual(capturedChanges, captured)
    }

    func testBoundaryRecordAndTakeLeavesMetadataOnlyPendingWhenNoBodyWorkAffectsNote() async {
        let accumulator = makeAccumulator()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
        let start = Date(timeIntervalSince1970: 800)
        let title = SyncConvergenceCapturedLocalChange(change: titleChange("Only title"), evidence: nil)

        let collection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: [title],
            affecting: noteID,
            at: start
        )
        let obligation = collection?.primary
        let ready = await accumulator.takeReadyObligationCollection(at: start.addingTimeInterval(5))?.primary.batch

        XCTAssertNil(obligation)
        XCTAssertEqual(ready?.changes, [title.change])
    }


    func testLaterSaveCanQueueAfterEarlierObligationWasExtracted() async throws {
        let accumulator = makeAccumulator()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
        let firstDate = Date(timeIntervalSince1970: 900)
        let secondDate = Date(timeIntervalSince1970: 910)
        let first = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: "A",
            newBody: "AB",
            modifiedAt: firstDate,
            bodyHashCapabilityEnabled: true
        )
        let second = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: "AB",
            newBody: "ABC",
            modifiedAt: secondDate,
            bodyHashCapabilityEnabled: true
        )

        await accumulator.record(first, at: firstDate)
        let firstCollection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: [],
            affecting: noteID,
            at: firstDate.addingTimeInterval(1)
        )
        let firstObligation = firstCollection?.primary
        try await commitAfterDurableAdmission(firstCollection, accumulator: accumulator)
        await accumulator.record(second, at: secondDate)
        let secondObligation = await accumulator.takeReadyObligationCollection(at: secondDate.addingTimeInterval(5))?.primary.batch

        XCTAssertEqual(firstObligation?.batch.changes, first.map(\.change))
        XCTAssertEqual(secondObligation?.changes, second.map(\.change))
    }

    func testDisjointLaterSaveCanProgressAfterEarlierBoundaryExtraction() async throws {
        let accumulator = makeAccumulator()
        let firstNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
        let secondNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000306")!
        let firstDate = Date(timeIntervalSince1970: 920)
        let secondDate = Date(timeIntervalSince1970: 930)
        let first = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: firstNoteID,
            oldBody: "one",
            newBody: "one!",
            modifiedAt: firstDate,
            bodyHashCapabilityEnabled: true
        )
        let second = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: secondNoteID,
            oldBody: "two",
            newBody: "two!",
            modifiedAt: secondDate,
            bodyHashCapabilityEnabled: true
        )

        await accumulator.record(first, at: firstDate)
        let firstCollection = await accumulator.recordAndPrepareBoundaryCollection(
            adding: [],
            affecting: firstNoteID,
            at: firstDate.addingTimeInterval(1)
        )
        try await commitAfterDurableAdmission(firstCollection, accumulator: accumulator)
        await accumulator.record(second, at: secondDate)
        let secondObligation = await accumulator.takeReadyObligationCollection(at: secondDate.addingTimeInterval(5))?.primary.batch

        XCTAssertEqual(secondObligation?.changes, second.map(\.change))
    }

    func testMixedCapturePartitionsCompatibleThenSingleNoteV3BatchesInCanonicalNoteOrder() async throws {
        let accumulator = MacSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000227300")!,
            quietWindow: 3,
            batchSequenceProvider: { .sequenceLess(.transientFailure) }
        )
        let noteA = UUID(uuidString: "00000000-0000-0000-0000-000000227301")!
        let noteB = UUID(uuidString: "00000000-0000-0000-0000-000000227302")!
        let a1 = try markOperation(counter: 1, logicalClock: 1)
        let a2 = try markOperation(counter: 2, logicalClock: 2)
        let b1 = try markOperation(counter: 3, logicalClock: 3)
        let captured: [SyncConvergenceCapturedLocalChange] = [
            capturedTitleChange("Compatible"),
            structuralMarkChange(noteID: noteB, operation: b1, modifiedAt: Date(timeIntervalSince1970: 20)),
            structuralMarkChange(noteID: noteA, operation: a2, modifiedAt: Date(timeIntervalSince1970: 30)),
            structuralMarkChange(noteID: noteA, operation: a1, modifiedAt: Date(timeIntervalSince1970: 10))
        ]

        await accumulator.record(captured, at: Date(timeIntervalSince1970: 1))
        let originalBatchID = await accumulator.pendingBatchID()
        let obligations = await accumulator.takePendingObligationCollectionNow()?.obligations ?? []

        XCTAssertEqual(obligations.count, 3)
        XCTAssertEqual(obligations.first?.id, originalBatchID)
        XCTAssertEqual(Set(obligations.map(\.id)).count, 3)
        XCTAssertEqual(
            obligations.map { SyncBatchDeliveryPartitionPlanner.classification(of: $0.changes) },
            [.v1Compatible, .structuralMarkV3, .structuralMarkV3]
        )

        guard case .noteStructuralMarksChanged(let firstMark) = obligations[1].changes.first,
              case .noteStructuralMarksChanged(let secondMark) = obligations[2].changes.first else {
            return XCTFail("Expected one structural-mark change per V3 batch")
        }
        XCTAssertEqual(firstMark.noteID, noteA)
        XCTAssertEqual(firstMark.operations, [a1, a2])
        XCTAssertEqual(firstMark.modifiedAt, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(secondMark.noteID, noteB)
        XCTAssertEqual(secondMark.operations, [b1])
        XCTAssertEqual(obligations[1].changes.count, 1)
        XCTAssertEqual(obligations[2].changes.count, 1)
    }

    private func commitAfterDurableAdmission(
        _ prepared: SyncPreparedLocalObligationCollection?,
        accumulator: MacSyncBatchAccumulator
    ) async throws {
        let collection = try XCTUnwrap(prepared)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("local.json")
        let queue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: fileURL)
        try queue.enqueueAtomically(collection.obligations)
        XCTAssertEqual(FileBackedSyncConvergenceLocalObligationQueue(fileURL: fileURL).pendingObligations,
                       collection.obligations)
        let committed = await accumulator.commitPreparedCollection(token: collection.token)
        XCTAssertTrue(committed)
    }

    private func markOperation(
        counter: UInt64,
        logicalClock: UInt64
    ) throws -> SyncTextMarkOperation {
        try SyncTextMarkOperation(
            operationID: SyncOperationID(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000227399")!,
                localCounter: counter
            ),
            logicalClock: logicalClock,
            key: .bold,
            assignment: .enabled,
            startAnchor: .empty,
            endAnchor: .empty
        )
    }

    private func structuralMarkChange(
        noteID: UUID,
        operation: SyncTextMarkOperation,
        modifiedAt: Date
    ) -> SyncConvergenceCapturedLocalChange {
        SyncConvergenceCapturedLocalChange(
            change: .noteStructuralMarksChanged(
                SyncBatchNoteStructuralMarksChangedChange(
                    noteID: noteID,
                    operations: [operation],
                    modifiedAt: modifiedAt
                )
            ),
            evidence: nil
        )
    }

    private func makeAccumulator() -> MacSyncBatchAccumulator {
        MacSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }
        )
    }

    private func capturedTitleChange(_ title: String) -> SyncConvergenceCapturedLocalChange {
        SyncConvergenceCapturedLocalChange(change: titleChange(title), evidence: nil)
    }

    private func titleChange(_ title: String) -> MacSyncChange {
        .noteTitleChanged(
            MacSyncNoteTitleChangedChange(
                noteID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                title: title,
                modifiedAt: Date(timeIntervalSince1970: 10)
            )
        )
    }
}
