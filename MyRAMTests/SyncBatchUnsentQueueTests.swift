import XCTest

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

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

    func testFileBackedQueueDeduplicatesByStableBatchID() {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(batch)
        queue.enqueue(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [batch])
    }

    func testFileBackedQueueKeepsMostRecentBatchesWithinLimitAfterReload() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second, third])
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

    func testFileBackedQueueReloadsAfterPartialRemoval() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)
        queue.removeAll(withIDs: [first.id, third.id])
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second])
    }

    func testFileBackedQueueDoesNotRewriteFileForUnknownRemovalIDs() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(batch)
        let originalData = try Data(contentsOf: fileURL)
        queue.removeAll(withIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000999999")!])

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testFileBackedQueueRecoversFromCorruptJSONAndRemainsUsable() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        try Data("not json".utf8).write(to: fileURL)
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(queue.isEmpty)
        queue.enqueue(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [batch])
    }

    func testFileBackedQueueRecoversFromUnsupportedVersionAndRemainsUsable() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        let staleBatch = makeBatch(idSuffix: 1)
        let supportedBatch = makeBatch(idSuffix: 2)
        let unsupportedQueue = TestPersistedSyncBatchQueue(version: 999, batches: [staleBatch])
        try JSONEncoder().encode(unsupportedQueue).write(to: fileURL)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(queue.isEmpty)
        queue.enqueue(supportedBatch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [supportedBatch])
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

    private func createDirectory(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

private struct TestPersistedSyncBatchQueue: Codable {
    let version: Int
    let batches: [SyncBatch]
}
