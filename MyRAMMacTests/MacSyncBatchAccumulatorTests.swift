import XCTest
@testable import MyRAMMac

final class MacSyncBatchAccumulatorTests: XCTestCase {
    func testChangesAppendToPendingBatchAndPreserveOrdering() async {
        let accumulator = makeAccumulator()
        let firstChange = titleChange("First")
        let secondChange = titleChange("Second")
        let start = Date(timeIntervalSince1970: 100)

        await accumulator.record(firstChange, at: start)
        await accumulator.record(secondChange, at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertEqual(batch?.changes, [firstChange, secondChange])
    }

    func testQuietWindowRearmsAndBatchIDStaysStable() async {
        let accumulator = makeAccumulator()
        let start = Date(timeIntervalSince1970: 200)

        await accumulator.record(titleChange("First"), at: start)
        let originalBatchID = await accumulator.pendingBatchID()
        let originalReadyAt = await accumulator.pendingReadyAt()

        await accumulator.record(titleChange("Second"), at: start.addingTimeInterval(2))
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

        await accumulator.record(titleChange("Ready"), at: start)
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(3))

        let batch = await nextBatchTask.value
        XCTAssertEqual(batch?.changes, [titleChange("Ready")])
    }

    func testBatchSequenceIsAssignedWhenPendingBatchStarts() async {
        let accumulator = MacSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000102")! },
            batchSequenceProvider: { 7 }
        )
        let start = Date(timeIntervalSince1970: 500)

        await accumulator.record(titleChange("First"), at: start)
        await accumulator.record(titleChange("Second"), at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertEqual(batch?.batchSequence, 7)
    }

    private func makeAccumulator() -> MacSyncBatchAccumulator {
        MacSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }
        )
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
