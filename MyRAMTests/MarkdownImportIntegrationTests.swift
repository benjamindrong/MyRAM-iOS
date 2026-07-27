import Foundation
import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownImportIntegrationTests: XCTestCase {
    func testImportCommitsExactBodyAndRevisionZeroStateBeforeUndoAndSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var viewModel: NotesViewModel!
        var observedAtomicModels = false
        viewModel = makeViewModel(context: context, saveContext: {
            observedAtomicModels = try context.fetch(FetchDescriptor<Note>()).count == 1
                && context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).count == 1
                && !viewModel.hasUndoableAction
                && viewModel.currentNote == nil
            try context.save()
        })
        let source = "\r\n# Exact  \rBare\r\nEmoji 🚀\ne\u{301}\n"

        let note = try viewModel.importMarkdownDocument(ImportedMarkdownDocument(
            source: source,
            suggestedTitle: "Project.Plan"
        ))

        XCTAssertTrue(observedAtomicModels)
        XCTAssertEqual(note.title, "Project.Plan")
        XCTAssertEqual(Array(note.content.utf16), Array(source.utf16))
        XCTAssertNil(note.richTextContentData)
        XCTAssertEqual(viewModel.currentNote?.id, note.id)
        XCTAssertTrue(viewModel.hasUndoableAction)

        let record = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        XCTAssertEqual(record.noteID, note.id)
        XCTAssertEqual(record.revision, 0)
        let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: note.id
        )
        XCTAssertEqual(Array(state.visibleText.utf16), Array(source.utf16))
    }

    func testEmptyMarkdownCreatesEmptyRevisionZeroState() throws {
        let container = try makeContainer()
        let viewModel = makeViewModel(context: container.mainContext)

        let note = try viewModel.importMarkdownDocument(ImportedMarkdownDocument(
            source: "",
            suggestedTitle: "Empty"
        ))

        XCTAssertEqual(note.content, "")
        let record = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        XCTAssertEqual(record.revision, 0)
        XCTAssertEqual(record.visibleUTF16Count, 0)
    }

    func testImportUsesCurrentFolderCreationPolicy() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let viewModel = makeViewModel(context: context)
        viewModel.createFolder(named: "Imported")
        let folder = try XCTUnwrap(context.fetch(FetchDescriptor<Folder>()).first)
        viewModel.openFolder(folder)

        let note = try viewModel.importMarkdownDocument(ImportedMarkdownDocument(
            source: "Body",
            suggestedTitle: "File"
        ))

        XCTAssertEqual(note.folder?.id, folder.id)
    }

    func testSaveFailureRollsBackNoteStateFolderTimestampUndoAndSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var shouldFail = false
        let viewModel = makeViewModel(context: context, saveContext: {
            if shouldFail {
                throw MarkdownImportIntegrationTestError.injected
            }
            try context.save()
        })
        viewModel.createFolder(named: "Imported")
        let folder = try XCTUnwrap(context.fetch(FetchDescriptor<Folder>()).first)
        viewModel.openFolder(folder)
        let originalModifiedAt = folder.modifiedAt
        let hadUndoableAction = viewModel.hasUndoableAction
        shouldFail = true

        XCTAssertThrowsError(try viewModel.importMarkdownDocument(ImportedMarkdownDocument(
            source: "Body",
            suggestedTitle: "File"
        )))

        XCTAssertEqual(folder.modifiedAt, originalModifiedAt)
        XCTAssertNil(viewModel.currentNote)
        XCTAssertEqual(viewModel.hasUndoableAction, hadUndoableAction)
        let verificationContext = ModelContext(container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<Note>()).isEmpty)
        XCTAssertTrue(
            try verificationContext.fetch(FetchDescriptor<NoteSequenceStateRecord>()).isEmpty
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MarkdownImport-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeViewModel(
        context: ModelContext,
        saveContext: (() throws -> Void)? = nil
    ) -> NotesViewModel {
        NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("MarkdownImportConflicts-\(UUID().uuidString).json")
            ),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveContext: saveContext
        )
    }
}

private enum MarkdownImportIntegrationTestError: Error {
    case injected
}
