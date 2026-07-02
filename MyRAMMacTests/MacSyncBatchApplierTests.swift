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

        let appliedBatch = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "Remote"))],
            in: container
        )

        XCTAssertEqual(note.content, "Remote")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    MacAppliedBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "Remote",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testIncomingInsertionAtOccupiedTargetPositionInsertsAtRequestedBoundary() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002004")!, content: "AB", in: container)

        let appliedBatch = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "x"))],
            in: container
        )

        XCTAssertEqual(note.content, "xAB")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    MacAppliedBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testIncomingInsertionAtInvalidUTF16BoundaryFallsForward() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200A")!, content: "A😀B", in: container)

        let appliedBatch = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 2, text: "x"))],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    MacAppliedBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 3,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testIncomingDeleteAppliesOnlyWhenExpectedTextMatches() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002005")!, content: "abcdef", in: container)

        let appliedBatch = try apply(
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
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyDeleted(
                    MacAppliedBodyDeletion(
                        noteID: note.id,
                        range: NSRange(location: 2, length: 2),
                        deletedText: "cd",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testUnsafeIncomingDeleteDoesNotDeleteUnrelatedLocalText() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002006")!, content: "abcdef", in: container)

        let appliedBatch = try apply(
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
        XCTAssertTrue(appliedBatch.changes.isEmpty)
    }

    func testSkippedChangesDoNotAppearInAppliedMetadata() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200C")!, content: "abcdef", in: container)

        let appliedBatch = try apply(
            changes: [
                .noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "")),
                .noteBodyTextDeleted(
                    MacSyncNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "xy",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                ),
                .noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "Z"))
            ],
            in: container
        )

        XCTAssertEqual(note.content, "aZbcdef")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    MacAppliedBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 1,
                        text: "Z",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testMultiChangeBatchEmitsMetadataInApplicationOrder() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200D")!, content: "abcd", in: container)

        let appliedBatch = try apply(
            changes: [
                .noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "X")),
                .noteBodyTextDeleted(
                    MacSyncNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 1,
                        expectedText: "b",
                        modifiedAt: Date(timeIntervalSince1970: 12)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "aXcd")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    MacAppliedBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 1,
                        text: "X",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                ),
                .bodyDeleted(
                    MacAppliedBodyDeletion(
                        noteID: note.id,
                        range: NSRange(location: 2, length: 1),
                        deletedText: "b",
                        modifiedAt: Date(timeIntervalSince1970: 12)
                    )
                )
            ]
        )
    }

    func testIncomingPlainTextMutationClearsUnmappableRichTextData() throws {
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
        XCTAssertNil(note.richTextContentData)
    }

    func testIncomingChangeWithMissingFolderReferenceCreatesNoteAtRoot() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000002007")!

        let appliedBatch = try apply(
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
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .noteCreated(
                    MacAppliedNoteCreated(
                        noteID: noteID,
                        title: "Remote",
                        body: "Body",
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ]
        )
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

        let firstApply = try applier.apply(batch)
        let secondApply = try applier.apply(batch)

        XCTAssertEqual(note.content, "Once")
        XCTAssertEqual(firstApply.changes.count, 1)
        XCTAssertTrue(secondApply.changes.isEmpty)
        XCTAssertEqual(secondApply.batchID, batchID)
    }

    func testTitleChangeEmitsAppliedMetadata() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200E")!, content: "Body", in: container)

        let appliedBatch = try apply(
            changes: [
                .noteTitleChanged(
                    MacSyncNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Remote Title",
                        modifiedAt: Date(timeIntervalSince1970: 13)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.title, "Remote Title")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .titleChanged(
                    MacAppliedTitleChanged(
                        noteID: note.id,
                        title: "Remote Title",
                        modifiedAt: Date(timeIntervalSince1970: 13)
                    )
                )
            ]
        )
    }

    private func apply(
        batchID: String = "00000000-0000-0000-0000-000000002100",
        changes: [MacSyncChange],
        in container: ModelContainer
    ) throws -> MacAppliedSyncBatch {
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: MacSyncSeenBatchStore(defaults: makeDefaults())
        )
        return try applier.apply(
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
