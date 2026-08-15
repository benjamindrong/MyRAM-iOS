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

    func testExternalRouteEditorMismatchLeavesNoRowsUndoSelectionOrBodyRead() async throws {
        let expectedID = UUID()
        let actualID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        var didInvokeWrongEditor = false
        bridge.register(noteID: actualID) {
            didInvokeWrongEditor = true
            return .succeeded
        }

        try await assertExternalRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: bridge,
            expectedResult: .editorMismatch(
                expected: .note(expectedID),
                actualNoteID: actualID
            )
        )
        XCTAssertFalse(didInvokeWrongEditor)
    }

    func testExternalRouteUnavailableEditorLeavesNoRowsUndoSelectionOrBodyRead() async throws {
        let expectedID = UUID()

        try await assertExternalRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: NoteEditorFileOperationBridge(),
            expectedResult: .expectedEditorUnavailable(noteID: expectedID)
        )
    }

    private func assertExternalRouteBlocked(
        expectedEditor: ExpectedEditor,
        bridge: NoteEditorFileOperationBridge,
        expectedResult: EditorFlushResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let viewModel = makeViewModel(context: context)
        var bodyReadCount = 0
        let coordinator = MarkdownImportOperationCoordinator(
            classifier: MarkdownFileClassifier(contentTypeProvider: { _ in
                MarkdownFileClassifier.markdownContentType
            }),
            reader: MarkdownFileReader(dataLoader: { _ in
                bodyReadCount += 1
                return Data("Body".utf8)
            })
        )
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in MarkdownFileClassifier.markdownContentType }
        ))
        let route: () async throws -> ExternalImportRoutingResult<Note, Note?> = {
            try await router.route(
                url: URL(fileURLWithPath: "/tmp/Blocked.md"),
                expectedEditor: expectedEditor,
                markdownCoordinator: coordinator,
                flushBridge: bridge,
                importMarkdown: viewModel.importMarkdownDocument,
                importMyRAM: { _ -> Note? in
                    XCTFail("Unexpected .myram import", file: file, line: line)
                    return nil
                }
            )
        }

        do {
            _ = try await route()
            XCTFail("Expected editor precondition failure", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MarkdownImportOperationError,
                .editorPreconditionFailed(expectedResult),
                file: file,
                line: line
            )
        }

        XCTAssertEqual(bodyReadCount, 0, file: file, line: line)
        XCTAssertFalse(viewModel.hasUndoableAction, file: file, line: line)
        XCTAssertNil(viewModel.currentNote, file: file, line: line)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<Note>()).isEmpty,
            file: file,
            line: line
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).isEmpty,
            file: file,
            line: line
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
