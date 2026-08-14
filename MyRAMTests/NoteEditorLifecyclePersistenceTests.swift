import XCTest
import SwiftData
@testable import MyRAM

@MainActor
final class NoteEditorLifecyclePersistenceTests: XCTestCase {
    func testActivationOffLifecycleBoundaryCommitsSynchronously() throws {
        XCTAssertFalse(SyncBatchAnchoredPayloadCapability.isEnabled)
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR179Lifecycle-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        let note = Note(title: "Before", content: "Before")
        context.insert(note)
        try context.save()
        let viewModel = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent("conflicts.json")
            ),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )

        let completed = viewModel.acceptEditorLifecycleSnapshot(
            note,
            title: "After",
            content: "After",
            richTextContentData: Data("After".utf8),
            generation: UUID()
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(note.title, "After")
        XCTAssertEqual(note.content, "After")
        XCTAssertEqual(note.richTextContentData, Data("After".utf8))
    }

    func testLifecyclePersistenceOwnershipTransfersBeforeEditorUnregisters() async {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        var persistedGeneration: UUID?
        let generation = UUID()
        let core = NoteEditorLifecyclePersistenceCore { snapshot in
            persistedGeneration = snapshot.generation
            return true
        }
        bridge.register(noteID: noteID) { .succeeded }
        core.accept(snapshot(noteID: noteID, generation: generation))
        bridge.unregister(noteID: noteID)

        await eventually { persistedGeneration == generation }
    }

    func testFailureRetainsNewestGenerationUntilExplicitRetry() async {
        let noteID = UUID()
        let first = UUID()
        let second = UUID()
        var shouldSucceed = false
        var attempts: [UUID] = []
        let core = NoteEditorLifecyclePersistenceCore { snapshot in
            attempts.append(snapshot.generation)
            return shouldSucceed
        }

        core.accept(snapshot(noteID: noteID, generation: first))
        core.accept(snapshot(noteID: noteID, generation: second))
        await eventually { !core.isDrainingForTesting(noteID: noteID) }
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: noteID), second)
        XCTAssertEqual(attempts, [second])

        shouldSucceed = true
        core.retry(noteID: noteID)
        await eventually { core.pendingGenerationForTesting(noteID: noteID) == nil }
        XCTAssertEqual(attempts, [second, second])
    }

    func testNewerGenerationWaitsForInFlightPersistenceAndThenDrainsSerially() async {
        let noteID = UUID()
        let first = UUID()
        let second = UUID()
        let persistence = SuspendedLifecyclePersistence()
        var successes: [UUID] = []
        let core = NoteEditorLifecyclePersistenceCore(
            persist: { snapshot in
                await persistence.persist(snapshot)
            },
            didPersist: { snapshot in
                successes.append(snapshot.generation)
            }
        )

        core.accept(snapshot(noteID: noteID, generation: first))
        await eventually { persistence.startedGenerations == [first] }
        core.accept(snapshot(noteID: noteID, generation: second))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(persistence.startedGenerations, [first])
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: noteID), second)

        persistence.completeNext(success: true)
        await eventually { persistence.startedGenerations == [first, second] }
        XCTAssertEqual(successes, [first])
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: noteID), second)

        persistence.completeNext(success: true)
        await eventually { core.pendingGenerationForTesting(noteID: noteID) == nil }
        XCTAssertEqual(successes, [first, second])
        XCTAssertFalse(core.isDrainingForTesting(noteID: noteID))
    }

    func testStaleFailedCompletionCannotDiscardNewerGeneration() async {
        let noteID = UUID()
        let first = UUID()
        let second = UUID()
        let persistence = SuspendedLifecyclePersistence()
        let core = NoteEditorLifecyclePersistenceCore { snapshot in
            await persistence.persist(snapshot)
        }

        core.accept(snapshot(noteID: noteID, generation: first))
        await eventually { persistence.startedGenerations == [first] }
        core.accept(snapshot(noteID: noteID, generation: second))

        persistence.completeNext(success: false)
        await eventually { !core.isDrainingForTesting(noteID: noteID) }
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: noteID), second)
        XCTAssertEqual(persistence.startedGenerations, [first])

        core.retry(noteID: noteID)
        await eventually { persistence.startedGenerations == [first, second] }
        persistence.completeNext(success: true)
        await eventually { core.pendingGenerationForTesting(noteID: noteID) == nil }
    }

    func testRetryAllDrainsRetainedFailuresAcrossNotesWithoutActiveSelection() async {
        let firstNoteID = UUID()
        let secondNoteID = UUID()
        var shouldSucceed = false
        var attempts: [UUID] = []
        let core = NoteEditorLifecyclePersistenceCore { snapshot in
            attempts.append(snapshot.noteID)
            return shouldSucceed
        }

        core.accept(snapshot(noteID: firstNoteID, generation: UUID()))
        core.accept(snapshot(noteID: secondNoteID, generation: UUID()))
        await eventually {
            !core.isDrainingForTesting(noteID: firstNoteID)
                && !core.isDrainingForTesting(noteID: secondNoteID)
        }
        XCTAssertNotNil(core.pendingGenerationForTesting(noteID: firstNoteID))
        XCTAssertNotNil(core.pendingGenerationForTesting(noteID: secondNoteID))

        shouldSucceed = true
        core.retryAll()
        await eventually {
            core.pendingGenerationForTesting(noteID: firstNoteID) == nil
                && core.pendingGenerationForTesting(noteID: secondNoteID) == nil
        }
        XCTAssertEqual(attempts.filter { $0 == firstNoteID }.count, 2)
        XCTAssertEqual(attempts.filter { $0 == secondNoteID }.count, 2)
    }

    func testSuccessEffectsRunOncePerDurablyPersistedGeneration() async {
        let noteID = UUID()
        let generation = UUID()
        var shouldSucceed = false
        var successes: [UUID] = []
        let core = NoteEditorLifecyclePersistenceCore(
            persist: { _ in shouldSucceed },
            didPersist: { successes.append($0.generation) }
        )

        core.accept(snapshot(noteID: noteID, generation: generation))
        await eventually { !core.isDrainingForTesting(noteID: noteID) }
        XCTAssertTrue(successes.isEmpty)

        shouldSucceed = true
        core.retry(noteID: noteID)
        core.retry(noteID: noteID)
        await eventually { core.pendingGenerationForTesting(noteID: noteID) == nil }
        core.retry(noteID: noteID)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(successes, [generation])
    }

    func testBackgroundThenDisappearanceCanTransferSameGenerationOnlyOnce() async {
        let noteID = UUID()
        let generation = UUID()
        let persistence = SuspendedLifecyclePersistence()
        var successes: [UUID] = []
        let core = NoteEditorLifecyclePersistenceCore(
            persist: { snapshot in await persistence.persist(snapshot) },
            didPersist: { successes.append($0.generation) }
        )

        let transferred = snapshot(noteID: noteID, generation: generation)
        core.accept(transferred)
        await eventually { persistence.startedGenerations == [generation] }
        core.accept(transferred)
        XCTAssertEqual(core.pendingGenerationForTesting(noteID: noteID), generation)

        persistence.completeNext(success: true)
        await eventually { core.pendingGenerationForTesting(noteID: noteID) == nil }
        XCTAssertEqual(persistence.startedGenerations, [generation])
        XCTAssertEqual(successes, [generation])
    }

    private func snapshot(noteID: UUID, generation: UUID) -> NoteEditorLifecycleSnapshot {
        NoteEditorLifecycleSnapshot(
            noteID: noteID,
            title: "Title",
            body: "Body",
            richTextContentData: Data("Body".utf8),
            generation: generation
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class SuspendedLifecyclePersistence {
    private(set) var startedGenerations: [UUID] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    func persist(_ snapshot: NoteEditorLifecycleSnapshot) async -> Bool {
        startedGenerations.append(snapshot.generation)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeNext(success: Bool) {
        continuations.removeFirst().resume(returning: success)
    }
}
