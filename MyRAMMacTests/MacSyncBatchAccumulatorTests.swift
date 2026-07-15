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
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

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
        let earlyBatch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(4))
        let readyBatch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))
        XCTAssertNil(earlyBatch)
        XCTAssertNotNil(readyBatch)
    }

    func testReadyBatchStreamYieldsAfterQuietWindow() async throws {
        let accumulator = makeAccumulator()
        let stream = await accumulator.readyBatches()
        let nextBatchTask = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let start = Date(timeIntervalSince1970: 300)

        await accumulator.record(capturedTitleChange("Ready"), at: start)
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(3))

        let batch = await nextBatchTask.value
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
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

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

        let obligation = await accumulator.recordAndTakeBoundaryObligation(
            adding: captured,
            affecting: noteID,
            at: start
        )
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(5))
        let replayed = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

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
        let obligation = await accumulator.recordAndTakeBoundaryObligation(
            adding: [],
            affecting: noteID,
            at: start.addingTimeInterval(1)
        )

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

        let obligation = await accumulator.recordAndTakeBoundaryObligation(
            adding: [title],
            affecting: noteID,
            at: start
        )
        let ready = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

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
        let firstObligation = await accumulator.recordAndTakeBoundaryObligation(
            adding: [],
            affecting: noteID,
            at: firstDate.addingTimeInterval(1)
        )
        await accumulator.record(second, at: secondDate)
        let secondObligation = await accumulator.takeReadyBatch(at: secondDate.addingTimeInterval(5))

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
        _ = await accumulator.recordAndTakeBoundaryObligation(
            adding: [],
            affecting: firstNoteID,
            at: firstDate.addingTimeInterval(1)
        )
        await accumulator.record(second, at: secondDate)
        let secondObligation = await accumulator.takeReadyBatch(at: secondDate.addingTimeInterval(5))

        XCTAssertEqual(secondObligation?.changes, second.map(\.change))
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
