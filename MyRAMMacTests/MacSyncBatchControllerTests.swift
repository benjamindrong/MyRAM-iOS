import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchControllerTests: XCTestCase {
    func testDisconnectedTransportAcceptsByDurablyEnqueuingUnsentBatch() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let controller = try makeController(unsentBatchQueueFileURL: unsentURL)
        let batch = makeBatch(idSuffix: 1)

        try await controller.acceptLocalBatch(batch)

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).pendingBatches, [batch])
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testFailedDurableUnsentEnqueueThrowsAndLeavesQueueUnchanged() async throws {
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let queue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        let existing = makeBatch(idSuffix: 1)
        try queue.enqueueDurably(existing)
        let before = queue.snapshot()
        let beforeBytes = try Data(contentsOf: unsentURL)
        let failingQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        failingQueue.injectPersistenceFailureForNextWrite()
        let controller = try makeController(unsentBatchQueue: failingQueue)
        let batch = makeBatch(idSuffix: 2)

        var thrownError: Error?
        do {
            try await controller.acceptLocalBatch(batch)
        } catch {
            thrownError = error
        }
        XCTAssertNotNil(thrownError)
        XCTAssertEqual(failingQueue.snapshot().pendingBatches, before.pendingBatches)
        XCTAssertEqual(try Data(contentsOf: unsentURL), beforeBytes)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).snapshot(), before)
    }

    func testReceiveDoesNotIndependentlyEnqueueRemoteBatchBeforeRuntimeSubmission() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let controller = try makeController(unsentBatchQueueFileURL: nil)
        let container = try makeInMemoryContainer()
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in .ready }),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let emptyBatch = makeBatch(idSuffix: 1)

        controller.receive(emptyBatch)
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = coordinator

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches, [])
        XCTAssertEqual(controller.pendingIncomingBatchCount, 0)
    }


    func testQuarantinedConvergenceStatusPreservesWorkReason() throws {
        let controller = try makeController(unsentBatchQueueFileURL: nil)
        let item = SyncConvergenceQuarantinedItem(
            domain: .localObligation,
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            affectedNoteIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000202")!],
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            reason: .localEvidenceBaseHashMismatch
        )
        let work = SyncConvergenceQuarantinedWork(items: [item])

        controller.markConvergenceQuarantined(work)

        XCTAssertEqual(controller.quarantinedWork, work)
        XCTAssertNotEqual(
            controller.lastErrorMessage,
            SyncBatchDrainFailureClassifier.userMessage(
                for: SyncBatchDrainFailure(batchID: item.batchID, kind: .corruptHistory)
            )
        )
    }

    func testProductionMacSyncFilesDoNotConstructOldDrainEngine() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedFiles = [
            "MyRAM/Mac/MyRAMMacRootView.swift",
            "MyRAM/Mac/Sync/MacSyncBatchController.swift",
            "MyRAM/Mac/Sync/MacSyncBatchAccumulator.swift",
            "MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift",
            "MyRAM/Mac/Sync/MacSyncConvergencePresentationAdapter.swift"
        ]
        let forbiddenTokens = [
            "MacSyncBatchApplier",
            "SyncBatchDrainCoordinator",
            "drainPendingIncomingBatchesIfPossible",
            "onBeforeApplyingRemoteBatch",
            "onBatchApplied",
            "handleAppliedSyncBatch",
            "MacAppliedSyncBatch",
            "submitLocalBatch(",
            "bodyTextChanged(",
            "import UIKit"
        ]

        for relativePath in checkedFiles {
            let source = try String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(source.contains(token), "\(relativePath) contains forbidden token \(token)")
            }
        }

        let coordinatorSource = try String(
            contentsOf: repo.appendingPathComponent("MyRAM/Mac/Sync/MacSyncConvergenceCoordinator.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(coordinatorSource.contains("kind: .corruptHistory"))
    }

    private func makeController(unsentBatchQueueFileURL: URL?) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: unsentBatchQueueFileURL, unsentBatchQueue: nil)
    }

    private func makeController(unsentBatchQueue: FileBackedSyncBatchQueue) throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: nil, unsentBatchQueue: unsentBatchQueue)
    }

    private func makeController(
        unsentBatchQueueFileURL: URL?,
        unsentBatchQueue: FileBackedSyncBatchQueue?
    ) throws -> MacSyncBatchController {
        MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            unsentBatchQueue: unsentBatchQueue,
            startsNetworking: false
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

    private func temporaryQueueFileURL(named filename: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return directory.appendingPathComponent(filename)
    }

    private func completingPresentationSurface() -> MacSyncConvergencePresentationSurface {
        MacSyncConvergencePresentationSurface(
            selectedNoteID: { nil },
            hasUnsavedChanges: { false },
            refreshNotesList: {},
            applyIncremental: { _, _, _ in
                EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
            },
            reloadSelectedEditor: { _, _ in true },
            currentEditorBody: { nil }
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "MacSyncBatchControllerTests-\(UUID().uuidString)",
            schema: Schema(MyRAMModelRegistry.models),
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: configuration
        )
    }
}
