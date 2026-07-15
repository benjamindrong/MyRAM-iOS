import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncConvergenceCoordinatorTests: XCTestCase {
    func testPendingIncomingSurvivesCoordinatorReconstruction() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let noteID = Self.uuid(1)
        let note = Note(title: "Shared", content: "local")
        note.id = noteID
        context.insert(note)
        try context.save()
        let controller = try makeController()
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let deferredBatch = bodyInsertBatch(idSuffix: 10, noteID: noteID, base: "base", inserted: " remote")

        await coordinator.submitRemoteBatch(deferredBatch)
        let reconstructed = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches.map(\.id), [deferredBatch.id])
        XCTAssertEqual(reconstructed.pendingIncomingBatchCount, 1)
        XCTAssertEqual(note.content, "local")
    }

    func testDeferredIncomingDoesNotBlockDisjointEligibleBatch() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let blockedNoteID = Self.uuid(2)
        let disjointNoteID = Self.uuid(3)
        let blockedNote = Note(title: "Blocked", content: "local-a")
        blockedNote.id = blockedNoteID
        let disjointNote = Note(title: "Before", content: "local-b")
        disjointNote.id = disjointNoteID
        context.insert(blockedNote)
        context.insert(disjointNote)
        try context.save()
        let controller = try makeController()
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let deferredBatch = bodyInsertBatch(idSuffix: 20, noteID: blockedNoteID, base: "base", inserted: " remote")
        let disjointBatch = titleBatch(idSuffix: 21, noteID: disjointNoteID, title: "After")

        await coordinator.submitRemoteBatch(deferredBatch)
        await coordinator.submitRemoteBatch(disjointBatch)

        XCTAssertEqual(disjointNote.title, "After")
        XCTAssertEqual(blockedNote.content, "local-a")
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches.map(\.id), [deferredBatch.id])
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)
    }

    func testLocalObligationSurvivesFailedDurableTransportEnqueue() async throws {
        let localObligationURL = temporaryQueueFileURL(named: "mac-local-obligation-queue.json")
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let failingUnsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        failingUnsentQueue.injectPersistenceFailureForNextWrite()
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let noteID = Self.uuid(4)
        let note = Note(title: "Before", content: "Body")
        note.id = noteID
        context.insert(note)
        try context.save()
        note.title = "After"
        try context.save()
        let controller = try makeController(unsentBatchQueue: failingUnsentQueue)
        let coordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localObligationURL
        )
        let batch = titleBatch(idSuffix: 22, noteID: noteID, title: "After")
        let obligation = SyncConvergenceLocalObligation(
            batch: batch,
            capturedChanges: [SyncConvergenceCapturedLocalChange(change: batch.changes[0], evidence: nil)]
        )

        await coordinator.submitLocalObligation(obligation)

        XCTAssertEqual(note.title, "After")
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).pendingBatches, [])
        XCTAssertEqual(
            FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationURL).pendingObligations,
            [obligation]
        )
    }

    func testRelaunchResumesDurableLocalObligationAfterFailedTransportEnqueue() async throws {
        let localObligationURL = temporaryQueueFileURL(named: "mac-local-obligation-queue.json")
        let unsentURL = temporaryQueueFileURL(named: "mac-unsent-batch-queue.json")
        let failingUnsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        failingUnsentQueue.injectPersistenceFailureForNextWrite()
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let noteID = Self.uuid(5)
        let note = Note(title: "Before", content: "Body")
        note.id = noteID
        context.insert(note)
        try context.save()
        note.title = "After relaunch"
        try context.save()
        let batch = titleBatch(idSuffix: 23, noteID: noteID, title: "After relaunch")
        let obligation = SyncConvergenceLocalObligation(
            batch: batch,
            capturedChanges: [SyncConvergenceCapturedLocalChange(change: batch.changes[0], evidence: nil)]
        )
        let failingController = try makeController(unsentBatchQueue: failingUnsentQueue)
        let firstCoordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: failingController,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localObligationURL
        )
        await firstCoordinator.submitLocalObligation(obligation)
        XCTAssertEqual(
            FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationURL).pendingObligations,
            [obligation]
        )

        let resumedController = try makeController(unsentBatchQueueFileURL: unsentURL)
        let resumedCoordinator = MacSyncConvergenceCoordinator(
            context: context,
            syncController: resumedController,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localObligationURL
        )
        await resumedCoordinator.resumePendingWork()

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: unsentURL).pendingBatches, [batch])
        XCTAssertEqual(
            FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationURL).pendingObligations,
            []
        )
    }

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func bodyInsertBatch(idSuffix: Int, noteID: UUID, base: String, inserted: String) -> SyncBatch {
        SyncBatch(
            id: Self.uuid(idSuffix),
            originDeviceID: Self.uuid(900),
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: base.utf16.count,
                    text: inserted,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: base)
                ))
            ]
        )
    }

    private func titleBatch(idSuffix: Int, noteID: UUID, title: String) -> SyncBatch {
        SyncBatch(
            id: Self.uuid(idSuffix),
            originDeviceID: Self.uuid(901),
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: title,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(idSuffix))
                ))
            ]
        )
    }

    private func makeController() throws -> MacSyncBatchController {
        try makeController(unsentBatchQueueFileURL: nil)
    }

    private func makeController(unsentBatchQueueFileURL: URL?) throws -> MacSyncBatchController {
        MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            startsNetworking: false
        )
    }

    private func makeController(unsentBatchQueue: FileBackedSyncBatchQueue) throws -> MacSyncBatchController {
        MacSyncBatchController(
            context: try makeInMemoryContainer().mainContext,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: unsentBatchQueue,
            startsNetworking: false
        )
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

    private func readyBoundarySurface() -> MacSyncIncomingLocalBoundarySurface {
        MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in .ready })
    }

    private func temporaryQueueFileURL(named filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "MacSyncConvergenceCoordinatorTests-\(UUID().uuidString)",
            schema: Schema(MyRAMModelRegistry.models),
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: configuration
        )
    }
}
