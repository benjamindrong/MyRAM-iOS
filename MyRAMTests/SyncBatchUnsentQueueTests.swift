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

    func testDurableEnqueueRejectsCapacityWithoutEvictingExistingEntries() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
        XCTAssertThrowsError(try queue.enqueueDurably(third)) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .capacityExceeded)
        }

        XCTAssertEqual(queue.pendingBatches, [first, second])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2).pendingBatches, [first, second])
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
        if case .readFailed = queue.snapshot().health {
            // Expected; failed queue writes must remain visible for recovery.
        } else {
            XCTFail("Expected failed persistence to mark queue health as readFailed")
        }
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first])

        XCTAssertThrowsError(try queue.enqueueIncoming(second)) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .unhealthyPersistence)
        }
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first])
    }

    func testDurableEnqueueRestoresMemoryWhenPersistenceFails() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        queue.injectPersistenceFailureForNextWrite()
        XCTAssertThrowsError(try queue.enqueueDurably(second)) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }

        XCTAssertEqual(queue.pendingBatches, [first])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first])
    }

    func testDurableEnqueueDuplicateBatchIDIsIdempotentAndDoesNotRewriteFile() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(batch)
        let originalData = try Data(contentsOf: fileURL)
        queue.injectPersistenceFailureForNextWrite()
        try queue.enqueueDurably(batch)

        XCTAssertEqual(queue.pendingBatches, [batch])
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [batch])
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

    func testFileBackedQueueReportsCorruptJSONAndDoesNotOverwriteIt() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        let corruptData = Data("not json".utf8)
        try corruptData.write(to: fileURL)
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.snapshot().health, .corrupt)
        queue.enqueue(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
        XCTAssertEqual(reloadedQueue.snapshot().health, .corrupt)
        XCTAssertTrue(reloadedQueue.pendingBatches.isEmpty)
    }

    func testFileBackedQueueReportsUnsupportedVersionAndDoesNotOverwriteIt() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        let staleBatch = makeBatch(idSuffix: 1)
        let supportedBatch = makeBatch(idSuffix: 2)
        let unsupportedQueue = TestPersistedSyncBatchQueue(version: 999, batches: [staleBatch])
        try JSONEncoder().encode(unsupportedQueue).write(to: fileURL)
        let originalData = try Data(contentsOf: fileURL)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.snapshot().health, .unsupportedVersion(999))
        queue.enqueue(supportedBatch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        XCTAssertEqual(reloadedQueue.snapshot().health, .unsupportedVersion(999))
        XCTAssertTrue(reloadedQueue.pendingBatches.isEmpty)
    }

    func testFileBackedQueueReportsMissingFileHealthAndPendingCount() {
        let queue = FileBackedSyncBatchQueue(fileURL: temporaryQueueFileURL(), limit: 10)

        XCTAssertEqual(queue.snapshot(), FileBackedSyncBatchQueueSnapshot(pendingBatches: [], health: .fileMissing))
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testFileBackedQueueReportsHealthyReloadSnapshot() {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(
            reloadedQueue.snapshot(),
            FileBackedSyncBatchQueueSnapshot(pendingBatches: [first, second], health: .healthy)
        )
        XCTAssertEqual(reloadedQueue.pendingCount, 2)
    }

    func testFileBackedQueueReplacePendingBatchesPersistsAtomically() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let replacement = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.enqueue(second)
        try queue.replacePendingBatches([replacement])

        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        XCTAssertEqual(queue.snapshot().pendingBatches, [replacement])
        XCTAssertEqual(queue.snapshot().health, .healthy)
        XCTAssertEqual(reloadedQueue.pendingBatches, [replacement])
    }

    func testFileBackedQueueReplacePendingBatchesRollsBackOnPersistenceFailure() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let replacement = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        queue.enqueue(first)
        queue.injectPersistenceFailureForNextWrite()
        XCTAssertThrowsError(try queue.replacePendingBatches([replacement])) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }

        XCTAssertEqual(queue.pendingBatches, [first])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first])
    }

    func testFileBackedQueueRejectsReplacementWhenLoadedPersistenceIsUnhealthy() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        try Data("not json".utf8).write(to: fileURL)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertThrowsError(try queue.replacePendingBatches([makeBatch(idSuffix: 1)])) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .unhealthyPersistence)
        }
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
