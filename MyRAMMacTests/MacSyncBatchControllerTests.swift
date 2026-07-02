import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchControllerTests: XCTestCase {
    func testReceiveQueuesBatchWhenPreApplyCallbackIsMissing() throws {
        let queueURL = temporaryQueueFileURL()
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL)
        let batch = makeBatch(idSuffix: 1)

        controller.receive(batch)

        XCTAssertEqual(controller.pendingIncomingBatchCount, 1)
        XCTAssertEqual(controller.lastErrorMessage, "Incoming sync is waiting for local edits to save.")
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches, [batch])
    }

    func testReceiveDrainsQueuedBatchesFIFO() throws {
        let queueURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        FileBackedSyncBatchQueue(fileURL: queueURL).enqueue(first)
        var appliedIDs: [UUID] = []
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL) { batch in
            appliedIDs.append(batch.id)
            return MacAppliedSyncBatch(batchID: batch.id, changes: [])
        }
        controller.onBeforeApplyingRemoteBatch = { true }

        controller.receive(second)

        XCTAssertEqual(appliedIDs, [first.id, second.id])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
        XCTAssertTrue(FileBackedSyncBatchQueue(fileURL: queueURL).isEmpty)
        XCTAssertEqual(controller.lastSyncAt, second.createdAt)
    }

    func testDuplicateBufferedBatchIDIsNotQueuedTwice() throws {
        let queueURL = temporaryQueueFileURL()
        var applyCount = 0
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL) { batch in
            applyCount += 1
            return MacAppliedSyncBatch(batchID: batch.id, changes: [])
        }
        controller.onBeforeApplyingRemoteBatch = { false }
        let batch = makeBatch(idSuffix: 1)

        controller.receive(batch)
        controller.receive(batch)

        XCTAssertEqual(controller.pendingIncomingBatchCount, 1)
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches, [batch])
    }

    func testDrainStopsOnFirstApplyFailureAndPreservesRemainingQueue() throws {
        let queueURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: queueURL)
        queue.enqueue(first)
        queue.enqueue(second)
        var appliedIDs: [UUID] = []
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL) { batch in
            appliedIDs.append(batch.id)
            if batch.id == first.id {
                throw TestApplyError.failed
            }
            return MacAppliedSyncBatch(batchID: batch.id, changes: [])
        }
        controller.onBeforeApplyingRemoteBatch = { true }

        controller.drainPendingIncomingBatchesIfPossible()

        XCTAssertEqual(appliedIDs, [first.id])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 2)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches, [first, second])
        XCTAssertEqual(controller.lastErrorMessage, "Unable to save incoming sync changes.")
    }

    func testDrainBlocksOnMismatchedHeadBatchWithoutApplyingLaterQueuedBatch() throws {
        let queueURL = temporaryQueueFileURL()
        let first = makeBatch(idSuffix: 1)
        let second = makeBatch(idSuffix: 2)
        let queue = FileBackedSyncBatchQueue(fileURL: queueURL)
        queue.enqueue(first)
        queue.enqueue(second)
        var attemptedIDs: [UUID] = []
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL) { batch in
            attemptedIDs.append(batch.id)
            throw SyncBatchApplyPreflightError.mismatchedBaseContentHash(
                noteID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                expected: "expected",
                actual: "actual"
            )
        }
        controller.onBeforeApplyingRemoteBatch = { true }

        controller.drainPendingIncomingBatchesIfPossible()

        XCTAssertEqual(attemptedIDs, [first.id])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 2)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches, [first, second])
        XCTAssertEqual(controller.lastErrorMessage, "Incoming changes are waiting for deterministic merge support.")
    }

    func testAlreadySeenZeroChangeBatchIsRemovedHarmlessly() throws {
        let queueURL = temporaryQueueFileURL()
        let batch = makeBatch(idSuffix: 1)
        FileBackedSyncBatchQueue(fileURL: queueURL).enqueue(batch)
        var appliedBatches: [MacAppliedSyncBatch] = []
        let controller = try makeController(pendingIncomingBatchQueueFileURL: queueURL) { batch in
            MacAppliedSyncBatch(batchID: batch.id, changes: [])
        }
        controller.onBeforeApplyingRemoteBatch = { true }
        controller.onBatchApplied = { appliedBatches.append($0) }

        controller.drainPendingIncomingBatchesIfPossible()

        XCTAssertEqual(appliedBatches, [MacAppliedSyncBatch(batchID: batch.id, changes: [])])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
        XCTAssertTrue(FileBackedSyncBatchQueue(fileURL: queueURL).isEmpty)
    }

    private func makeController(
        pendingIncomingBatchQueueFileURL: URL,
        applyBatch: ((MacSyncBatch) throws -> MacAppliedSyncBatch)? = nil
    ) throws -> MacSyncBatchController {
        try MacSyncBatchController(
            context: makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: nil,
            pendingIncomingBatchQueueFileURL: pendingIncomingBatchQueueFileURL,
            startsNetworking: false,
            applyBatch: applyBatch
        )
    }

    private func makeBatch(idSuffix: Int) -> MacSyncBatch {
        MacSyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func temporaryQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("mac-pending-incoming-batch-queue.json")
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Folder.self,
            Note.self,
            NotePhotoAttachment.self,
            PinnedThought.self
        ])
        let configuration = ModelConfiguration(
            "MacSyncBatchControllerTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: Folder.self,
            Note.self,
            NotePhotoAttachment.self,
            PinnedThought.self,
            configurations: configuration
        )
    }
}

private enum TestApplyError: Error {
    case failed
}
