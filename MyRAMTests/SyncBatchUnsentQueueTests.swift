import AnchoredSequenceCore
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

    func testFileBackedQueueReloadsPersistedBatchesWithStableIDs() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [batch])
        XCTAssertEqual(reloadedQueue.pendingBatches.first?.id, batch.id)
    }

    func testLocalObligationQueueMigratesVersionOneBatchesAsLegacyMissingEvidence() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let legacyQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        try legacyQueue.enqueueIncoming(first)
        try legacyQueue.enqueueIncoming(second)

        let migratedQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(migratedQueue.pendingBatches, [first, second])
        XCTAssertEqual(migratedQueue.pendingObligations.map(\.evidence), [.legacyMissing, .legacyMissing])
        XCTAssertEqual(FileBackedSyncConvergenceLocalObligationQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
    }

    func testDrainPassSchedulerSkipsBlockedNotesWithoutRotatingQueueOrder() {
        let noteA = UUID(uuidString: "00000000-0000-0000-0000-000000124301")!
        let noteB = UUID(uuidString: "00000000-0000-0000-0000-000000124302")!
        let noteC = UUID(uuidString: "00000000-0000-0000-0000-000000124303")!
        let originA = UUID(uuidString: "00000000-0000-0000-0000-000000124304")!
        let originB = UUID(uuidString: "00000000-0000-0000-0000-000000124305")!
        let candidates = [
            SyncConvergenceQueueCandidate(batchID: UUID(), originDeviceID: originA, affectedNoteIDs: [noteA], queuePosition: 0),
            SyncConvergenceQueueCandidate(batchID: UUID(), originDeviceID: originB, affectedNoteIDs: [noteB], queuePosition: 1),
            SyncConvergenceQueueCandidate(batchID: UUID(), originDeviceID: originB, affectedNoteIDs: [noteA, noteC], queuePosition: 2),
            SyncConvergenceQueueCandidate(batchID: UUID(), originDeviceID: originB, affectedNoteIDs: [noteC], queuePosition: 3)
        ]

        let index = SyncConvergenceDrainPassScheduler.nextEligibleIndex(
            candidates: candidates,
            attemptedBatchIDs: [candidates[0].batchID],
            blockedNoteIDs: [noteA],
            blockedOrigins: [originA]
        )

        XCTAssertEqual(index, 1)
        XCTAssertEqual(candidates.map(\.queuePosition), [0, 1, 2, 3])
    }

    func testDrainPassSchedulerAllowsExactAnchoredDependencyProviderThroughBlock() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000179301")!
        let originID = UUID(uuidString: "00000000-0000-0000-0000-000000179302")!
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000179303")!
        let dependencyID = SyncOperationID(deviceID: deviceID, localCounter: 41)
        let blocked = SyncConvergenceQueueCandidate(
            batchID: UUID(),
            originDeviceID: originID,
            affectedNoteIDs: [noteID],
            queuePosition: 0
        )
        let provider = SyncConvergenceQueueCandidate(
            batchID: UUID(),
            originDeviceID: originID,
            affectedNoteIDs: [noteID],
            queuePosition: 1,
            anchoredOperationIDs: [dependencyID]
        )

        let index = SyncConvergenceDrainPassScheduler.nextEligibleIndex(
            candidates: [blocked, provider],
            attemptedBatchIDs: [blocked.batchID],
            blockedNoteIDs: [noteID],
            blockedOrigins: [originID],
            anchoredDependenciesByNoteID: [noteID: [dependencyID]]
        )

        XCTAssertEqual(index, 1)
    }

    func testDrainPassSchedulerDoesNotBypassBlockForDifferentAnchoredOperation() {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000179311")!
        let disjointNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000179312")!
        let originID = UUID(uuidString: "00000000-0000-0000-0000-000000179313")!
        let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000179314")!
        let dependencyID = SyncOperationID(deviceID: deviceID, localCounter: 51)
        let unrelatedID = SyncOperationID(deviceID: deviceID, localCounter: 52)
        let blocked = SyncConvergenceQueueCandidate(
            batchID: UUID(),
            originDeviceID: originID,
            affectedNoteIDs: [noteID],
            queuePosition: 0
        )
        let unrelated = SyncConvergenceQueueCandidate(
            batchID: UUID(),
            originDeviceID: originID,
            affectedNoteIDs: [noteID],
            queuePosition: 1,
            anchoredOperationIDs: [unrelatedID]
        )
        let disjoint = SyncConvergenceQueueCandidate(
            batchID: UUID(),
            originDeviceID: UUID(),
            affectedNoteIDs: [disjointNoteID],
            queuePosition: 2
        )

        let index = SyncConvergenceDrainPassScheduler.nextEligibleIndex(
            candidates: [blocked, unrelated, disjoint],
            attemptedBatchIDs: [blocked.batchID],
            blockedNoteIDs: [noteID],
            blockedOrigins: [originID],
            anchoredDependenciesByNoteID: [noteID: [dependencyID]]
        )

        XCTAssertEqual(index, 2)
    }

    func testFileBackedQueueDeduplicatesByStableBatchID() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(batch)
        try queue.enqueueDurably(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [batch])
    }

    func testFileBackedQueueRejectsOverflowWithoutEvictionAfterReload() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
        XCTAssertThrowsError(try queue.enqueueDurably(third))
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 2)

        XCTAssertEqual(reloadedQueue.pendingBatches, [first, second])
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

    func testFileBackedQueueRemovesOnlySuccessfulIDsFromDisk() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
        queue.removeAll(withIDs: [first.id])
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second])
    }

    func testFileBackedQueueReloadsAfterPartialRemoval() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let third = makeBatch(idSuffix: 3)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
        try queue.enqueueDurably(third)
        queue.removeAll(withIDs: [first.id, third.id])
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.pendingBatches, [second])
    }

    func testFileBackedQueueDoesNotRewriteFileForUnknownRemovalIDs() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(batch)
        let originalData = try Data(contentsOf: fileURL)
        queue.removeAll(withIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000999999")!])

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testFileBackedQueueFirstReturnsOldestPersistedBatch() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertEqual(reloadedQueue.first, first)
        XCTAssertEqual(reloadedQueue.pendingBatches, [first, second])
    }

    func testFileBackedQueueContainsDetectsPersistedBatchID() throws {
        let fileURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(batch)
        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        XCTAssertTrue(reloadedQueue.contains(batch.id))
        XCTAssertFalse(reloadedQueue.contains(UUID(uuidString: "00000000-0000-0000-0000-000000999999")!))
    }

    func testFileBackedQueueRemoveDropsOneBatchFromDisk() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
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
        XCTAssertThrowsError(try queue.enqueueDurably(batch))
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
        XCTAssertThrowsError(try queue.enqueueDurably(supportedBatch))
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

    func testFileBackedQueueReportsHealthyReloadSnapshot() throws {
        let fileURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
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

        try queue.enqueueDurably(first)
        try queue.enqueueDurably(second)
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

        try queue.enqueueDurably(first)
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

    func testFileBackedQueueCanRunMemoryOnlyWithNilFileURL() throws {
        let batch = makeBatch(idSuffix: 1)
        let queue = FileBackedSyncBatchQueue(fileURL: nil, limit: 10)

        try queue.enqueueDurably(batch)
        queue.removeAll(withIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000999999")!])

        XCTAssertEqual(queue.pendingBatches, [batch])
    }

    func testBothDurableQueuesRejectAnchoredAdmissionWithoutMutation() throws {
        let batchQueueURL = temporaryQueueFileURL()
        let obligationQueueURL = temporaryQueueFileURL()
        try createDirectory(for: batchQueueURL)
        try createDirectory(for: obligationQueueURL)
        let legacy = makeBatch(idSuffix: 1)
        let anchored = try makeAnchoredInsertBatchForTest()
        let batchQueue = FileBackedSyncBatchQueue(fileURL: batchQueueURL, limit: 10)
        let obligationQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: obligationQueueURL,
            limit: 10
        )
        try batchQueue.enqueueDurably(legacy)
        try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: legacy)
        )
        let originalBatchQueueData = try Data(contentsOf: batchQueueURL)
        let originalObligationQueueData = try Data(contentsOf: obligationQueueURL)

        XCTAssertThrowsError(try batchQueue.enqueueDurably(anchored)) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadPolicyError,
                .anchoredPayloadDisabled(
                    boundary: .durableQueue,
                    noteID: anchored.changes[0].noteID
                )
            )
        }
        XCTAssertThrowsError(try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: anchored)
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadPolicyError,
                .anchoredPayloadDisabled(
                    boundary: .durableQueue,
                    noteID: anchored.changes[0].noteID
                )
            )
        }
        XCTAssertEqual(batchQueue.pendingBatches, [legacy])
        XCTAssertEqual(obligationQueue.pendingBatches, [legacy])
        XCTAssertEqual(try Data(contentsOf: batchQueueURL), originalBatchQueueData)
        XCTAssertEqual(
            try Data(contentsOf: obligationQueueURL),
            originalObligationQueueData
        )
    }

    func testBothDurableQueuesRejectMixedAdmissionWithoutMutation() throws {
        let legacy = makeBatch(idSuffix: 1)
        let anchored = try makeAnchoredInsertBatchForTest()
        let mixed = SyncBatch(
            id: anchored.id,
            originDeviceID: anchored.originDeviceID,
            createdAt: anchored.createdAt,
            batchSequence: anchored.batchSequence,
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: anchored.changes[0].noteID,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: anchored.createdAt
                )),
                anchored.changes[0]
            ]
        )
        let batchQueue = FileBackedSyncBatchQueue(fileURL: nil, limit: 10)
        let obligationQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: nil,
            limit: 10
        )
        try batchQueue.enqueueDurably(legacy)
        try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: legacy)
        )

        XCTAssertThrowsError(try batchQueue.enqueueDurably(mixed)) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadPolicyError,
                .mixedBodyOperationRepresentations(boundary: .durableQueue)
            )
        }
        XCTAssertThrowsError(try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: mixed)
        )) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadPolicyError,
                .mixedBodyOperationRepresentations(boundary: .durableQueue)
            )
        }
        XCTAssertEqual(batchQueue.pendingBatches, [legacy])
        XCTAssertEqual(obligationQueue.pendingBatches, [legacy])
    }

    func testBothDurableQueuesValidateCompleteReplacementBeforeMutation() throws {
        let legacy = makeBatch(idSuffix: 1)
        let anchored = try makeAnchoredInsertBatchForTest()
        let batchQueue = FileBackedSyncBatchQueue(fileURL: nil, limit: 10)
        let obligationQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: nil,
            limit: 10
        )
        try batchQueue.enqueueDurably(legacy)
        try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: legacy)
        )

        XCTAssertThrowsError(
            try batchQueue.replacePendingBatches([legacy, anchored])
        )
        XCTAssertThrowsError(
            try obligationQueue.replacePendingBatches([legacy, anchored])
        )
        XCTAssertEqual(batchQueue.pendingBatches, [legacy])
        XCTAssertEqual(obligationQueue.pendingBatches, [legacy])
    }

    func testBothDurableQueuesQuarantinePersistedAnchoredBytes() throws {
        let fileURL = temporaryQueueFileURL()
        try createDirectory(for: fileURL)
        let anchored = try makeAnchoredInsertBatchForTest()
        try JSONEncoder().encode(
            TestPersistedSyncBatchQueue(version: 1, batches: [anchored])
        ).write(to: fileURL)
        let originalData = try Data(contentsOf: fileURL)

        let batchQueue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        XCTAssertEqual(batchQueue.snapshot().health, .unsupportedAnchoredPayload)
        XCTAssertTrue(batchQueue.pendingBatches.isEmpty)
        XCTAssertThrowsError(try batchQueue.enqueueDurably(makeBatch(idSuffix: 2)))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)

        let obligationQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: fileURL,
            limit: 10
        )
        XCTAssertEqual(
            obligationQueue.snapshot().health,
            .unsupportedAnchoredPayload
        )
        XCTAssertTrue(obligationQueue.pendingBatches.isEmpty)
        XCTAssertThrowsError(try obligationQueue.enqueue(
            SyncConvergenceLocalObligation(legacyBatch: makeBatch(idSuffix: 2))
        ))
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
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

func makeAnchoredInsertBatchForTest(
    id: UUID = UUID(),
    noteID: UUID = UUID()
) throws -> SyncBatch {
    let deviceID = UUID(uuidString: "17100000-0000-0000-0000-0000000000AA")!
    let operationID = SyncOperationID(deviceID: deviceID, localCounter: 1)
    let state = try SyncTextSequenceState(runs: [], fragments: [])
    let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
        noteID: noteID,
        utf16Offset: 0,
        text: "A",
        modifiedAt: Date(timeIntervalSince1970: 1_710),
        baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
        operationID: operationID,
        state: state
    )
    return SyncBatch(
        id: id,
        originDeviceID: deviceID,
        createdAt: Date(timeIntervalSince1970: 1_710),
        batchSequence: 1,
        changes: [change]
    )
}
