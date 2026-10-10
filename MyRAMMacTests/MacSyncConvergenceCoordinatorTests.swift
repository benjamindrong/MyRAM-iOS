import AnchoredSequenceCore
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

    // Regression coverage for MYR-165: the transport layer must durably capture a
    // batch before convergence. Capture is idempotent and necessary for ACK, but it
    // does not independently authorize ACK; the later convergence disposition does.
    func testDurablyCaptureIncomingBatchPersistsBeforeSubmission() async throws {
        let pendingURL = temporaryQueueFileURL(named: "mac-pending-incoming-batch-queue.json")
        let container = try makeInMemoryContainer()
        let noteID = Self.uuid(30)
        let controller = try makeController()
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: nil
        )
        let batch = titleBatch(idSuffix: 31, noteID: noteID, title: "Renamed")

        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(batch))

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches.map(\.id), [batch.id])
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 1)

        // Calling it again (as the retry path does) must stay idempotent.
        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(batch))
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches.map(\.id), [batch.id])
    }

    func testAnchoredDirectAdmissionReachesDurabilityAndRuntimeSubmission() async throws {
        let pendingURL = temporaryQueueFileURL(
            named: "mac-pending-incoming-batch-queue.json"
        )
        let localURL = temporaryQueueFileURL(
            named: "mac-local-obligation-queue.json"
        )
        let container = try makeInMemoryContainer()
        let controller = try makeController()
        var boundaryCalls = 0
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: completingPresentationSurface(),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in
                    boundaryCalls += 1
                    return .ready
                }
            ),
            pendingIncomingQueueFileURL: pendingURL,
            localObligationQueueFileURL: localURL
        )
        let batch = try anchoredBatch()

        XCTAssertTrue(coordinator.durablyCaptureIncomingBatch(batch))
        await coordinator.submitRemoteBatch(batch)
        await coordinator.submitLocalObligation(
            SyncConvergenceLocalObligation(legacyBatch: batch)
        )

        XCTAssertEqual(boundaryCalls, 1)
        XCTAssertEqual(
            FileBackedSyncBatchQueue(fileURL: pendingURL).pendingBatches,
            [batch]
        )
        XCTAssertEqual(
            FileBackedSyncConvergenceLocalObligationQueue(
                fileURL: localURL
            ).pendingBatches,
            [batch]
        )
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

    private func anchoredBatch() throws -> SyncBatch {
        let deviceID = Self.uuid(902)
        let state = try SyncTextSequenceState(runs: [], fragments: [])
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: Self.uuid(903),
            utf16Offset: 0,
            text: "A",
            modifiedAt: Date(timeIntervalSince1970: 1_710),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: SyncOperationID(deviceID: deviceID, localCounter: 1),
            state: state
        )
        return SyncBatch(
            id: Self.uuid(904),
            originDeviceID: deviceID,
            createdAt: Date(timeIntervalSince1970: 1_710),
            batchSequence: 1,
            changes: [change]
        )
    }

    // Exact synthetic batch retained by the MYR-233 seven-batch fixture. It
    // creates four notes before assigning their titles and anchored bodies.
    func testMYR233PreservedCreationTitleBodyBatchDrainsAfterReconstruction() async throws {
        let root = temporaryQueueFileURL(named: "recovery").deletingLastPathComponent()
        let pendingURL = root.appendingPathComponent("mac-pending-incoming-batch-queue.json")
        let batch = try preservedMYR233CreationTitleBodyBatch()
        try FileBackedSyncBatchQueue(fileURL: pendingURL).enqueueIncoming(batch)
        let container = try makeInMemoryContainer()
        let controller = MacSyncBatchController(context: container.mainContext,
            unsentBatchQueueFileURL: nil, startsNetworking: false)
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext, syncController: controller,
            conflictStore: SyncConflictStore(fileURL: root.appendingPathComponent("sync-conflicts.json")),
            presentationSurface: completingPresentationSurface(), incomingBoundarySurface: readyBoundarySurface(),
            pendingIncomingQueueFileURL: pendingURL, localObligationQueueFileURL: nil,
            anchoredRecoveryStore: FileBackedSyncBatchAnchoredRecoveryStore(
                fileURL: root.appendingPathComponent("anchored-recovery.json")),
            structuralConflictSidecarFileURL: root.appendingPathComponent("structural-conflicts.json")
        )

        let completion = await coordinator.resumePendingWorkAwaitingDrainOwnership()
        guard case .drained(let applied) = completion.outcome else {
            return XCTFail("Expected preserved batch to drain, got \(completion.outcome)")
        }
        XCTAssertEqual(applied, [batch.id])
        XCTAssertEqual(completion.successfullyCompletedBatchIDs, [batch.id])
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 0)
        XCTAssertNil(controller.quarantinedWork)
        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 4)
        for change in batch.changes {
            switch change {
            case .noteTitleChanged(let title):
                XCTAssertEqual(notes.first { $0.id == title.noteID }?.title, title.title)
            case .noteBodyTextInsertedAnchored(let insertion):
                let note = try XCTUnwrap(notes.first { $0.id == insertion.noteID })
                XCTAssertEqual(note.content, insertion.text)
                let state = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: container.mainContext)
                XCTAssertEqual(state.state.runs.first?.operationID, insertion.payload.operationID)
            default: break
            }
        }
        let roots = try container.mainContext.fetch(FetchDescriptor<IncorporatedSyncBatch>())
        XCTAssertEqual(roots.map(\.batchID), [batch.id])
        // Redelivery reuses the durable incorporation rather than recreating notes.
        let disposition = await coordinator.submitRemoteBatch(batch)
        XCTAssertEqual(disposition, .acknowledgementPermitted)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<Note>()).count, 4)
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 0)
    }

    private func preservedMYR233CreationTitleBodyBatch() throws -> SyncBatch {
        let entries: [(String, TimeInterval, TimeInterval)] = [
            ("F7E46044-9C5D-4E1A-A7C8-8B8B86764C4F", 811172089.776362, 811172089.779384),
            ("4272D882-1B4A-46E8-A444-ED16F304ACCA", 811172089.796125, 811172089.797446),
            ("B8A16740-4BC7-4B2E-A2C8-32EB0270481B", 811172089.814238, 811172089.815485),
            ("30346963-A65D-4771-B2DD-E760D19CC84F", 811172089.831489, 811172089.832762)
        ]
        let operationDeviceID = try XCTUnwrap(UUID(uuidString: "C03A7B22-6003-4B6C-96A0-C27B44A2B0CE"))
        var changes: [SyncBatchChange] = []
        for (index, entry) in entries.enumerated() {
            let noteID = try XCTUnwrap(UUID(uuidString: entry.0))
            let createdAt = Date(timeIntervalSinceReferenceDate: entry.1)
            let modifiedAt = Date(timeIntervalSinceReferenceDate: entry.2)
            changes.append(.noteCreated(.init(noteID: noteID, title: "", body: "", folderID: nil,
                createdAt: createdAt, modifiedAt: createdAt)))
            changes.append(.noteTitleChanged(.init(noteID: noteID,
                title: "BEN36-BEN36-20260915T133402Z-iOS-\(index + 1)", modifiedAt: modifiedAt)))
            let initial = try NoteSequenceStateBootstrapPersistence.prepareInitialState(noteID: noteID, body: "")
            changes.append(try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
                noteID: noteID, utf16Offset: 0,
                text: "BEN-36 synthetic endurance note | run=BEN36-20260915T133402Z | platform=iOS | note=\(index + 1)",
                modifiedAt: modifiedAt, baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
                operationID: SyncOperationID(deviceID: operationDeviceID, localCounter: UInt64(index)), state: initial.state))
        }
        return SyncBatch(id: try XCTUnwrap(UUID(uuidString: "C8F4B1B4-C432-46AA-A07F-B1C1A1286738")),
            originDeviceID: try XCTUnwrap(UUID(uuidString: "B3600000-0000-0000-0000-000000000001")),
            createdAt: Date(timeIntervalSinceReferenceDate: 811172089.794811), batchSequence: 1, changes: changes)
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
            closeRemovedSelectedEditor: { _ in },
            applyIncremental: { _, _, _ in
                EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
            },
            reloadSelectedEditor: { _ in true },
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
