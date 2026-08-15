import Foundation
import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class MyRAMWidgetHostTests: XCTestCase {
    func testSelectionStorePersistsAndClearsExplicitNoteID() throws {
        let defaults = try makeDefaults()
        let noteID = UUID()
        let store = MyRAMWidgetNoteSelectionStore(defaults: defaults)

        XCTAssertNil(store.selectedNoteID)
        store.select(noteID)
        XCTAssertEqual(store.selectedNoteID, noteID)
        XCTAssertEqual(
            MyRAMWidgetNoteSelectionStore(defaults: defaults).selectedNoteID,
            noteID
        )

        store.clear()
        XCTAssertNil(store.selectedNoteID)
        XCTAssertNil(defaults.string(forKey: MyRAMWidgetNoteSelectionStore.key))
    }

    func testDispatcherPreservesArrivalOrderAndRetainedHead() throws {
        let dispatcher = MyRAMExternalOpenDispatcher()
        let noteID = UUID()
        let widgetURL = try XCTUnwrap(
            MyRAMWidgetDeepLink.url(noteID: noteID, platform: .iOS)
        )
        let fileURL = URL(fileURLWithPath: "/tmp/example.md")

        XCTAssertNotNil(dispatcher.enqueue(url: widgetURL, platform: .iOS))
        XCTAssertNotNil(dispatcher.enqueue(url: fileURL, platform: .iOS))

        let first = try XCTUnwrap(dispatcher.claimNextIfReady(
            startupIsReady: true,
            externalOperationIsAvailable: true
        ))
        XCTAssertEqual(first.kind, .widgetNote(noteID))

        dispatcher.retainForRetry(requestID: first.id)
        XCTAssertEqual(
            dispatcher.claimNextIfReady(
                startupIsReady: true,
                externalOperationIsAvailable: true
            )?.id,
            first.id
        )

        dispatcher.complete(requestID: first.id)
        let second = try XCTUnwrap(dispatcher.claimNextIfReady(
            startupIsReady: true,
            externalOperationIsAvailable: true
        ))
        XCTAssertEqual(second.kind, .file(fileURL))
    }

    func testDelayedMacRequestCannotBeClaimedByAnotherScene() throws {
        let sceneA = MyRAMExternalOpenDispatcher()
        let sceneB = MyRAMExternalOpenDispatcher()
        let noteID = UUID()
        let widgetURL = try XCTUnwrap(
            MyRAMWidgetDeepLink.url(noteID: noteID, platform: .macOS)
        )

        XCTAssertNotNil(sceneA.enqueue(url: widgetURL, platform: .macOS))
        XCTAssertNil(sceneA.claimNextIfReady(
            startupIsReady: false,
            externalOperationIsAvailable: true
        ))

        XCTAssertNil(sceneB.claimNextIfReady(
            startupIsReady: true,
            externalOperationIsAvailable: true
        ))

        let claimedByOriginatingScene = try XCTUnwrap(sceneA.claimNextIfReady(
            startupIsReady: true,
            externalOperationIsAvailable: true
        ))
        XCTAssertEqual(claimedByOriginatingScene.kind, .widgetNote(noteID))
    }

    func testDispatcherRejectsMalformedWidgetURLWithoutQueueing() {
        let dispatcher = MyRAMExternalOpenDispatcher()
        let malformed = URL(string: "myram://note/not-a-uuid")!

        XCTAssertNil(dispatcher.enqueue(url: malformed, platform: .iOS))
        XCTAssertEqual(dispatcher.pendingCount, 0)
    }

    func testIOSRouterFlushesBeforePresentationAndRetainsFailure() async {
        let note = Note(title: "Selected", content: "Body")
        let bridge = NoteEditorFileOperationBridge()
        var events: [String] = []
        bridge.register(noteID: note.id) {
            events.append("flush")
            return .succeeded
        }

        let success = await MyRAMWidgetIOSNoteRouter().route(
            noteID: note.id,
            expectedEditor: .note(note.id),
            flushBridge: bridge,
            fetchActiveNote: { _ in
                events.append("fetch")
                return note
            },
            present: { _ in events.append("present") }
        )

        XCTAssertEqual(success, .completed)
        XCTAssertEqual(events, ["flush", "fetch", "present"])

        let failingBridge = NoteEditorFileOperationBridge()
        failingBridge.register(noteID: note.id) {
            .failed(message: "Injected")
        }
        var didFetch = false
        var didPresent = false

        let failure = await MyRAMWidgetIOSNoteRouter().route(
            noteID: note.id,
            expectedEditor: .note(note.id),
            flushBridge: failingBridge,
            fetchActiveNote: { _ in
                didFetch = true
                return note
            },
            present: { _ in didPresent = true }
        )

        XCTAssertEqual(failure, .retainedForRetry)
        XCTAssertFalse(didFetch)
        XCTAssertFalse(didPresent)
    }

    func testIOSRouterRejectsUnavailableOrMismatchedEditorWithoutMutation() async {
        let note = Note(title: "Selected", content: "Body")
        var didPresent = false

        let unavailable = await MyRAMWidgetIOSNoteRouter().route(
            noteID: note.id,
            expectedEditor: .note(note.id),
            flushBridge: NoteEditorFileOperationBridge(),
            fetchActiveNote: { _ in note },
            present: { _ in didPresent = true }
        )
        XCTAssertEqual(unavailable, .retainedForRetry)
        XCTAssertFalse(didPresent)

        let mismatchBridge = NoteEditorFileOperationBridge()
        mismatchBridge.register(noteID: UUID()) { .succeeded }
        let mismatched = await MyRAMWidgetIOSNoteRouter().route(
            noteID: note.id,
            expectedEditor: .note(note.id),
            flushBridge: mismatchBridge,
            fetchActiveNote: { _ in note },
            present: { _ in didPresent = true }
        )
        XCTAssertEqual(mismatched, .retainedForRetry)
        XCTAssertFalse(didPresent)
    }

    func testMacRouterFlushesBeforePresentationAndRetainsFailure() async {
        let note = Note(title: "Selected", content: "Body")
        var events: [String] = []

        let success = await MyRAMWidgetMacNoteRouter().route(
            noteID: note.id,
            flushPendingSave: {
                events.append("flush")
                return true
            },
            fetchActiveNote: { _ in
                events.append("fetch")
                return note
            },
            present: { _ in events.append("present") }
        )

        XCTAssertEqual(success, .completed)
        XCTAssertEqual(events, ["flush", "fetch", "present"])

        events.removeAll()
        let failure = await MyRAMWidgetMacNoteRouter().route(
            noteID: note.id,
            flushPendingSave: {
                events.append("flush")
                return false
            },
            fetchActiveNote: { _ in
                events.append("fetch")
                return note
            },
            present: { _ in events.append("present") }
        )

        XCTAssertEqual(failure, .retainedForRetry)
        XCTAssertEqual(events, ["flush"])
    }

    func testPublicationUsesDurablePinOrderAndSuppressesSemanticNoOp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let note = Note(title: "Title", content: "Body")
        let later = PinnedThought(text: "Second", order: 1, note: note)
        let earlier = PinnedThought(text: "First", order: 0, note: note)
        context.insert(note)
        context.insert(later)
        context.insert(earlier)
        note.pinnedThoughts = [later, earlier]
        try context.save()

        let root = temporaryDirectory()
        let snapshotStore = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        let selectionStore = MyRAMWidgetNoteSelectionStore(defaults: try makeDefaults())
        var pinnedHighlightColorRaw = "yellow"
        var reloadedKinds: [String] = []
        let coordinator = MyRAMWidgetHostCoordinator(
            container: container,
            observedContext: context,
            platform: .iOS,
            selectionStore: selectionStore,
            snapshotStore: snapshotStore,
            pinnedHighlightColorRawProvider: { pinnedHighlightColorRaw },
            reloadTimelines: { reloadedKinds.append($0) }
        )

        coordinator.select(noteID: note.id)
        var snapshot = try XCTUnwrap(snapshotStore.read().snapshot)
        XCTAssertEqual(snapshot.note?.orderedPinnedTexts, ["First", "Second"])
        XCTAssertEqual(snapshot.note?.bodyPreviewSource, "Body")
        XCTAssertEqual(snapshot.note?.pinnedHighlightColorRaw, "yellow")
        XCTAssertEqual(reloadedKinds, ["com.northsignalstudio.myram.priority-widget"])

        pinnedHighlightColorRaw = "slate"
        XCTAssertEqual(coordinator.publishNow(), .published)
        snapshot = try XCTUnwrap(snapshotStore.read().snapshot)
        XCTAssertEqual(snapshot.note?.orderedPinnedTexts, ["First", "Second"])
        XCTAssertEqual(snapshot.note?.bodyPreviewSource, "Body")
        XCTAssertEqual(snapshot.note?.pinnedHighlightColorRaw, "slate")
        XCTAssertEqual(reloadedKinds.count, 2)

        XCTAssertEqual(coordinator.publishNow(), .unchanged)
        XCTAssertEqual(reloadedKinds.count, 2)
    }

    func testSelectionPublishesPendingCurrentContextNoteImmediately() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let note = Note(title: "Newly Selected", content: "Pending Body")
        context.insert(note)

        let root = temporaryDirectory()
        let snapshotStore = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        let selectionStore = MyRAMWidgetNoteSelectionStore(defaults: try makeDefaults())
        var reloadedKinds: [String] = []
        let coordinator = MyRAMWidgetHostCoordinator(
            container: container,
            observedContext: context,
            platform: .iOS,
            selectionStore: selectionStore,
            snapshotStore: snapshotStore,
            reloadTimelines: { reloadedKinds.append($0) }
        )

        coordinator.select(noteID: note.id)

        let snapshot = try XCTUnwrap(snapshotStore.read().snapshot)
        XCTAssertEqual(snapshot.note?.id, note.id)
        XCTAssertEqual(snapshot.note?.title, "Newly Selected")
        XCTAssertEqual(snapshot.note?.bodyPreviewSource, "Pending Body")
        XCTAssertEqual(selectionStore.selectedNoteID, note.id)
        XCTAssertEqual(reloadedKinds, ["com.northsignalstudio.myram.priority-widget"])
    }

    func testSuccessfulSaveTriggersRefreshAndInvalidSelectionClears() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let note = Note(title: "Title", content: "Before")
        context.insert(note)
        try context.save()

        let root = temporaryDirectory()
        let snapshotStore = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        let selectionStore = MyRAMWidgetNoteSelectionStore(defaults: try makeDefaults())
        var reloadCount = 0
        let coordinator = MyRAMWidgetHostCoordinator(
            container: container,
            observedContext: context,
            platform: .iOS,
            selectionStore: selectionStore,
            snapshotStore: snapshotStore,
            debounceNanoseconds: 0,
            reloadTimelines: { _ in reloadCount += 1 }
        )
        coordinator.start()
        coordinator.select(noteID: note.id)

        note.content = "After"
        try context.save()
        await drainMainActorTasks()

        XCTAssertEqual(snapshotStore.read().snapshot?.note?.bodyPreviewSource, "After")
        XCTAssertEqual(reloadCount, 2)

        context.delete(note)
        try context.save()
        await drainMainActorTasks()

        XCTAssertNil(selectionStore.selectedNoteID)
        XCTAssertNil(snapshotStore.read().snapshot?.note)
        XCTAssertEqual(reloadCount, 3)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MyRAMWidgetHostTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MyRAMWidgetHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func drainMainActorTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private extension MyRAMWidgetSnapshotReadResult {
    var snapshot: MyRAMWidgetSnapshotEnvelope? {
        guard case .snapshot(let envelope) = self else { return nil }
        return envelope
    }
}
