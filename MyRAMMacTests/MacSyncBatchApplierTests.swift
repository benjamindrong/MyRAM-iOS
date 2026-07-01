import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchApplierTests: XCTestCase {
    func testDuplicateCreateNotePayloadsCreateDistinctNotesWhenIDsDiffer() throws {
        let container = try makeInMemoryContainer()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000002001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000002002")!

        try apply(batchID: "00000000-0000-0000-0000-000000002101", changes: [createChange(noteID: firstID)], in: container)
        try apply(batchID: "00000000-0000-0000-0000-000000002102", changes: [createChange(noteID: secondID)], in: container)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(Set(notes.map(\.id)), [firstID, secondID])
        XCTAssertEqual(notes.map(\.title).filter { $0 == "Shared" }.count, 2)
    }

    func testIncomingInsertionAtEmptyTargetPositionInsertsExactlyThere() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002003")!, content: "", in: container)

        try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "Remote"))],
            in: container
        )

        XCTAssertEqual(note.content, "Remote")
    }

    func testIncomingInsertionAtOccupiedTargetPositionInsertsAtRequestedBoundary() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002004")!, content: "AB", in: container)

        try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "x"))],
            in: container
        )

        XCTAssertEqual(note.content, "xAB")
    }

    func testIncomingInsertionAtInvalidUTF16BoundaryFallsForward() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200A")!, content: "A😀B", in: container)

        try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 2, text: "x"))],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
    }

    func testIncomingDeleteAppliesOnlyWhenExpectedTextMatches() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002005")!, content: "abcdef", in: container)

        try apply(
            changes: [
                .noteBodyTextDeleted(
                    MacSyncNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "cd",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abef")
    }

    func testUnsafeIncomingDeleteDoesNotDeleteUnrelatedLocalText() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002006")!, content: "abcdef", in: container)

        try apply(
            changes: [
                .noteBodyTextDeleted(
                    MacSyncNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "xy",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abcdef")
    }

    func testIncomingPlainTextMutationPreservesUnmappableRichTextData() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200B")!, content: "abc", in: container)
        let originalRichTextData = Data("not valid rtf".utf8)
        note.richTextContentData = originalRichTextData
        try container.mainContext.save()

        try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "x"))],
            in: container
        )

        XCTAssertEqual(note.content, "axbc")
        XCTAssertEqual(note.richTextContentData, originalRichTextData)
    }

    func testIncomingChangeWithMissingFolderReferenceCreatesNoteAtRoot() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000002007")!

        try apply(
            changes: [
                .noteCreated(
                    MacSyncNoteCreatedChange(
                        noteID: noteID,
                        title: "Remote",
                        body: "Body",
                        folderID: UUID(uuidString: "00000000-0000-0000-0000-000000002008")!,
                        createdAt: Date(timeIntervalSince1970: 1),
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ],
            in: container
        )

        let note = try XCTUnwrap(try fetchNote(id: noteID, in: container))
        XCTAssertEqual(note.title, "Remote")
        XCTAssertNil(note.folder)
    }

    func testDuplicateBatchIDIsIgnored() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002009")!, content: "", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000002109")!
        let applier = MacSyncBatchApplier(context: container.mainContext, seenBatchStore: MacSyncSeenBatchStore(defaults: defaults))
        let batch = MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "Once"))]
        )

        try applier.apply(batch)
        try applier.apply(batch)

        XCTAssertEqual(note.content, "Once")
    }

    private func apply(
        batchID: String = "00000000-0000-0000-0000-000000002100",
        changes: [MacSyncChange],
        in container: ModelContainer
    ) throws {
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: MacSyncSeenBatchStore(defaults: makeDefaults())
        )
        try applier.apply(
            MacSyncBatch(
                id: UUID(uuidString: batchID)!,
                originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 1),
                changes: changes
            )
        )
    }

    private func createChange(noteID: UUID) -> MacSyncChange {
        .noteCreated(
            MacSyncNoteCreatedChange(
                noteID: noteID,
                title: "Shared",
                body: "Body",
                folderID: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
        )
    }

    private func insertChange(noteID: UUID, offset: Int, text: String) -> MacSyncNoteBodyTextInsertedChange {
        MacSyncNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: Date(timeIntervalSince1970: 11)
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
            "MacSyncBatchApplierTests-\(UUID().uuidString)",
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
        let suiteName = "MacSyncBatchApplierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
