import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class IPhoneSyncBatchApplierTests: XCTestCase {
    func testIncomingNoteCreatedPayloadCreatesNote() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000125001")!

        try apply(changes: [createChange(noteID: noteID)], in: container)

        let note = try XCTUnwrap(try fetchNote(id: noteID, in: container))
        XCTAssertEqual(note.title, "Shared")
        XCTAssertEqual(note.content, "Body")
    }

    func testSameTitleAndBodyWithDifferentIDsCreateDistinctNotes() throws {
        let container = try makeInMemoryContainer()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000125002")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000125003")!

        try apply(batchID: "00000000-0000-0000-0000-000000125102", changes: [createChange(noteID: firstID)], in: container)
        try apply(batchID: "00000000-0000-0000-0000-000000125103", changes: [createChange(noteID: secondID)], in: container)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(Set(notes.map(\.id)), [firstID, secondID])
        XCTAssertEqual(notes.map(\.title).filter { $0 == "Shared" }.count, 2)
    }

    func testIncomingTitleChangeUpdatesByNoteID() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125004")!, content: "", in: container)

        try apply(
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Remote Title",
                        modifiedAt: Date(timeIntervalSince1970: 3)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.title, "Remote Title")
    }

    func testIncomingInsertionFallsForwardAtUnsafeUTF16Boundary() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125005")!, content: "A😀B", in: container)

        try apply(
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 4)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
    }

    func testDeleteAppliesOnlyWhenSafeAndExpectedTextMatches() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125006")!, content: "abcdef", in: container)

        try apply(
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "cd",
                        modifiedAt: Date(timeIntervalSince1970: 5)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abef")
    }

    func testUnsafeDeleteDoesNotRemoveUnrelatedLocalText() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125007")!, content: "abcdef", in: container)

        try apply(
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "xy",
                        modifiedAt: Date(timeIntervalSince1970: 6)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abcdef")
    }

    func testMissingFolderFallsBackToRoot() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000125008")!

        try apply(
            changes: [
                .noteCreated(
                    SyncBatchNoteCreatedChange(
                        noteID: noteID,
                        title: "Remote",
                        body: "Body",
                        folderID: UUID(uuidString: "00000000-0000-0000-0000-000000125009")!,
                        createdAt: Date(timeIntervalSince1970: 1),
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ],
            in: container
        )

        let note = try XCTUnwrap(try fetchNote(id: noteID, in: container))
        XCTAssertNil(note.folder)
    }

    func testDuplicateBatchIDIsIgnoredAndPersistsAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500A")!, content: "", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000012510A")!
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000125201")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "Once",
                        modifiedAt: Date(timeIntervalSince1970: 7)
                    )
                )
            ]
        )

        try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: defaults)
        ).apply(batch)
        XCTAssertTrue(SyncBatchSeenBatchStore(defaults: defaults).hasSeen(batchID))
        try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: defaults)
        ).apply(batch)

        XCTAssertEqual(note.content, "Once")
    }

    func testPlainTextMutationClearsRichTextData() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500B")!, content: "abc", in: container)
        note.richTextContentData = Data("stale rtf".utf8)
        try container.mainContext.save()

        try apply(
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 1,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 8)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "axbc")
        XCTAssertNil(note.richTextContentData)
    }

    private func apply(
        batchID: String = "00000000-0000-0000-0000-000000125100",
        changes: [SyncBatchChange],
        in container: ModelContainer
    ) throws {
        let applier = IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: makeDefaults())
        )
        try applier.apply(
            SyncBatch(
                id: UUID(uuidString: batchID)!,
                originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000125200")!,
                createdAt: Date(timeIntervalSince1970: 1),
                changes: changes
            )
        )
    }

    private func createChange(noteID: UUID) -> SyncBatchChange {
        .noteCreated(
            SyncBatchNoteCreatedChange(
                noteID: noteID,
                title: "Shared",
                body: "Body",
                folderID: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
        )
    }

    private func insertNote(id: UUID, content: String, in container: ModelContainer) throws -> Note {
        let note = Note(title: "Local", content: content)
        note.id = id
        container.mainContext.insert(note)
        try container.mainContext.save()
        return note
    }

    private func fetchNote(id: UUID, in container: ModelContainer) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == id
            }
        )
        return try container.mainContext.fetch(descriptor).first
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Folder.self,
            Note.self,
            NotePhotoAttachment.self,
            PinnedThought.self
        ])
        let configuration = ModelConfiguration(
            "IPhoneSyncBatchApplierTests-\(UUID().uuidString)",
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "IPhoneSyncBatchApplierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
