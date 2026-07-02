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

    func testIncomingPolicyRejectsNewBatchInsteadOfEvictingHead() throws {
        var queue = SyncBatchUnsentQueue(limit: 2)
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)

        try queue.enqueuePreservingExisting(first)
        try queue.enqueuePreservingExisting(second)
        XCTAssertThrowsError(try queue.enqueuePreservingExisting(third))

        XCTAssertEqual(queue.pendingBatches, [first, second])
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

    func testQueueFirstReturnsOldestPendingBatchWithoutDraining() {
        var queue = SyncBatchUnsentQueue(limit: 10)
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)

        queue.enqueue(first)
        queue.enqueue(second)

        XCTAssertEqual(queue.first, first)
        XCTAssertEqual(queue.pendingBatches, [first, second])
    }

    func testQueueContainsDetectsPendingBatchIDs() {
        var queue = SyncBatchUnsentQueue(limit: 10)
        let batch = makeBatch(idSuffix: 1)

        queue.enqueue(batch)

        XCTAssertTrue(queue.contains(batch.id))
        XCTAssertFalse(queue.contains(UUID(uuidString: "00000000-0000-0000-0000-000000999999")!))
    }

    func testQueueRemoveDropsOneBatchByID() {
        var queue = SyncBatchUnsentQueue(limit: 10)
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.remove(first.id)

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

    func testFileBackedIncomingQueueRejectsCapacityWithoutChangingExistingEntries() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        try queue.enqueueIncoming(first)
        try queue.enqueueIncoming(second)
        XCTAssertThrowsError(try queue.enqueueIncoming(third))

        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)
        XCTAssertEqual(reloadedQueue.pendingBatches, [first, second])
    }

    func testFileBackedIncomingQueueRollsBackMemoryAndDiskOnPersistenceFailure() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueIncoming(first)
        queue.injectPersistenceFailureForNextWrite()
        XCTAssertThrowsError(try queue.enqueueIncoming(second)) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }

        XCTAssertEqual(queue.pendingBatches, [first])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first])

        try queue.enqueueIncoming(second)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
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

    func testFileBackedQueueFirstReturnsOldestPersistedBatch() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.first, first)
        XCTAssertEqual(reloadedQueue.pendingBatches, [first, second])
    }

    func testFileBackedQueueContainsDetectsPersistedBatchID() {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(reloadedQueue.contains(batch.id))
        XCTAssertFalse(reloadedQueue.contains(UUID(uuidString: "00000000-0000-0000-0000-000000999999")!))
    }

    func testFileBackedQueueRemoveDropsOneBatchFromDisk() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        queue.remove(first.id)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second])
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

    func testMixedReplayKeysSortLegacyBeforeSequencedThenOperationIndex() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000123801")!
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000123802")!
        let firstLegacy = makeOrderingBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123803")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 1),
            sequence: nil,
            noteID: noteID
        )
        let secondLegacy = makeOrderingBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123804")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 2),
            sequence: nil,
            noteID: noteID
        )
        let sequenced = makeOrderingBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000123805")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSince1970: 0),
            sequence: 1,
            noteID: noteID
        )

        let secondOperation = SyncBatchReplayKey(batch: sequenced, change: sequenced.changes[1], operationIndex: 1)
        let firstOperation = SyncBatchReplayKey(batch: sequenced, change: sequenced.changes[0], operationIndex: 0)
        let keys = [
            secondOperation,
            SyncBatchReplayKey(batch: secondLegacy, change: secondLegacy.changes[0], operationIndex: 0),
            firstOperation,
            SyncBatchReplayKey(batch: firstLegacy, change: firstLegacy.changes[0], operationIndex: 0)
        ]

        XCTAssertEqual(
            keys.sorted(),
            [
                SyncBatchReplayKey(batch: firstLegacy, change: firstLegacy.changes[0], operationIndex: 0),
                SyncBatchReplayKey(batch: secondLegacy, change: secondLegacy.changes[0], operationIndex: 0),
                firstOperation,
                secondOperation
            ]
        )
    }

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000123999")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func makeOrderingBatch(
        id: UUID,
        originDeviceID: UUID,
        createdAt: Date,
        sequence: UInt64?,
        noteID: UUID
    ) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: originDeviceID,
            createdAt: createdAt,
            batchSequence: sequence,
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "First",
                        modifiedAt: Date(timeIntervalSince1970: 50)
                    )
                ),
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: noteID,
                        title: "Second",
                        modifiedAt: Date(timeIntervalSince1970: 50)
                    )
                )
            ]
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
