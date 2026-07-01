import XCTest
@testable import MyRAM

final class SyncBatchUnsentQueueTests: XCTestCase {
    func testQueueDeduplicatesByStableBatchID() {
        let batch = makeBatch(idSuffix: 1)
        var queue = SyncBatchUnsentQueue(limit: 10)

        queue.enqueue(batch)
        queue.enqueue(batch)

        XCTAssertEqual(queue.drain(), [batch])
        XCTAssertTrue(queue.isEmpty)
    }

    func testQueueKeepsMostRecentBatchesWithinLimit() {
        var queue = SyncBatchUnsentQueue(limit: 2)
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        XCTAssertEqual(queue.drain(), [second, third])
    }

    func testPendingBatchesDoesNotDrainQueue() {
        let batch = makeBatch(idSuffix: 1)
        var queue = SyncBatchUnsentQueue(limit: 10)

        queue.enqueue(batch)

        XCTAssertEqual(queue.pendingBatches, [batch])
        XCTAssertEqual(queue.drain(), [batch])
    }

    func testRemoveAllDropsKnownIDsAndIgnoresUnknownIDs() {
        var queue = SyncBatchUnsentQueue(limit: 10)
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.removeAll(
            withIDs: [
                first.id,
                UUID(uuidString: "00000000-0000-0000-0000-000000999999")!
            ]
        )

        XCTAssertEqual(queue.pendingBatches, [second])
    }

    func testFileBackedQueueReloadsPersistedBatchesWithStableIDs() {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [batch])
        XCTAssertEqual(reloadedQueue.pendingBatches.first?.id, batch.id)
    }

    func testFileBackedQueueRemovesOnlySuccessfulIDsFromDisk() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.removeAll(withIDs: [first.id])
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second])
    }

    func testFileBackedQueueCanRunMemoryOnlyWithNilFileURL() {
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: nil, limit: 10)

        queue.enqueue(batch)
        queue.removeAll(withIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000999999")!])

        XCTAssertEqual(queue.pendingBatches, [batch])
    }

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123999")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mac-unsent-batch-queue.json")
    }
}
