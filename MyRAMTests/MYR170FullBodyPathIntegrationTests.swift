import Foundation
import SwiftData
import XCTest
import NearbySyncCore
@testable import MyRAM

@MainActor
final class MYR170FullBodyPathIntegrationTests: XCTestCase {
    func testIOSStartupRunsMigrationBeforeNetworkingAndConvergence() async throws {
        let container = try makeContainer()
        var events: [String] = []
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: { events.append("rollback") },
                    migrateNoteSequenceStates: { events.append("migration") },
                    refreshPendingSyncStatus: { events.append("status") },
                    resumeOutboundAfterRecovery: { events.append("outbound") },
                    startNetworkingIfNeeded: { events.append("networking") },
                    resumePendingConvergencePresentationIfNeeded: {
                        events.append("convergence")
                    }
                )
            }
        )

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(
            events,
            ["rollback", "migration", "status", "outbound", "networking", "convergence"]
        )
        XCTAssertEqual(state.bootstrapState, .ready)
    }

    func testIOSStartupMigrationFailureKeepsOutboundSuspended() async throws {
        let container = try makeContainer()
        var events: [String] = []
        let state = NotesListState(
            context: container.mainContext,
            startsBootstrapAutomatically: false,
            bootstrapActionsFactory: { _, _ in
                NotesListState.BootstrapActions(
                    rollbackIfNeededOnLaunch: { events.append("rollback") },
                    migrateNoteSequenceStates: {
                        events.append("migration")
                        throw MYR170PathTestError.injected
                    },
                    refreshPendingSyncStatus: { events.append("status") },
                    resumeOutboundAfterRecovery: { events.append("outbound") },
                    startNetworkingIfNeeded: { events.append("networking") },
                    resumePendingConvergencePresentationIfNeeded: {
                        events.append("convergence")
                    }
                )
            }
        )

        await state.bootstrapAfterRecovery()

        XCTAssertEqual(events, ["rollback", "migration"])
        guard case .failed = state.bootstrapState else {
            return XCTFail("Migration failure must keep the startup gate closed")
        }
    }

    func testCreateNewNoteSavesNoteAndStateBeforePublishingSyncOrUndo() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var viewModel: NotesViewModel!
        var observedAtomicModels = false
        viewModel = makeViewModel(context: context, saveContext: {
            observedAtomicModels = try context.fetch(FetchDescriptor<Note>()).count == 1
                && context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).count == 1
                && !viewModel.hasUndoableAction
            try context.save()
        })

        let note = try XCTUnwrap(viewModel.createNewNoteIfPossible())

        XCTAssertTrue(observedAtomicModels)
        XCTAssertTrue(viewModel.hasUndoableAction)
        try assertState(noteID: note.id, body: "", revision: 0, in: container)
    }

    func testCreateNewNoteSaveFailureRollsBackNoteAndStateWithoutPublication() throws {
        let container = try makeContainer()
        let viewModel = makeViewModel(
            context: container.mainContext,
            saveContext: { throw MYR170PathTestError.injected }
        )

        XCTAssertNil(viewModel.createNewNoteIfPossible())
        XCTAssertFalse(viewModel.hasUndoableAction)
        XCTAssertTrue(try fetchNotes(in: container).isEmpty)
        XCTAssertTrue(try fetchStateRecords(in: container).isEmpty)
    }

    func testImportCreatesOneRevisionZeroStatePerImportedNote() throws {
        let container = try makeContainer()
        let viewModel = makeViewModel(context: container.mainContext)
        let url = try makeImportFile(bodies: ["First", "Second \u{1F680}"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let imported = try viewModel.importNotes(from: url)

        XCTAssertEqual(imported.count, 2)
        for note in imported {
            try assertState(noteID: note.id, body: note.content, revision: 0, in: container)
        }
    }

    func testImportFailureRollsBackAllImportedModelsAndStateRows() throws {
        let container = try makeContainer()
        let viewModel = makeViewModel(
            context: container.mainContext,
            saveContext: { throw MYR170PathTestError.injected }
        )
        let url = try makeImportFile(bodies: ["First", "Second"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertThrowsError(try viewModel.importNotes(from: url))
        XCTAssertTrue(try fetchNotes(in: container).isEmpty)
        XCTAssertTrue(try fetchStateRecords(in: container).isEmpty)
    }

    func testRestoreNoteReestablishesCurrentBodyStateBeforeLifecyclePublication() throws {
        let fixture = try makeLifecycleFixture()
        fixture.note.deletedAt = Date()
        try deleteState(noteID: fixture.note.id, in: fixture.container)

        fixture.viewModel.restoreNote(fixture.note)

        XCTAssertNil(fixture.note.deletedAt)
        try assertState(
            noteID: fixture.note.id,
            body: fixture.note.content,
            revision: 0,
            in: fixture.container
        )
    }

    func testRedoNoteCreationReestablishesCurrentBodyState() throws {
        let container = try makeContainer()
        let viewModel = makeViewModel(context: container.mainContext)
        let note = try XCTUnwrap(viewModel.createNewNote())
        viewModel.undoLastAction()
        try deleteState(noteID: note.id, in: container)

        viewModel.redoLastAction()

        XCTAssertNil(note.deletedAt)
        try assertState(noteID: note.id, body: note.content, revision: 0, in: container)
    }

    func testUndoNoteDeletionReestablishesCurrentBodyState() throws {
        let fixture = try makeLifecycleFixture()
        fixture.viewModel.deleteNote(fixture.note)
        try deleteState(noteID: fixture.note.id, in: fixture.container)

        fixture.viewModel.undoLastAction()

        XCTAssertNil(fixture.note.deletedAt)
        try assertState(
            noteID: fixture.note.id,
            body: fixture.note.content,
            revision: 0,
            in: fixture.container
        )
    }

    func testUndoFolderDeletionReestablishesEveryRestoredNoteOrRollsBackAll() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let viewModel = makeViewModel(context: context)
        viewModel.createFolder(named: "Folder")
        let folder = try XCTUnwrap(context.fetch(FetchDescriptor<Folder>()).first)
        viewModel.openFolder(folder)
        let first = try insertNote(body: "First", folder: folder, in: context)
        let second = try insertNote(body: "Second", folder: folder, in: context)
        try context.save()
        viewModel.deleteFolder(folder)
        try deleteState(noteID: first.id, in: container)
        try corruptState(noteID: second.id, in: container)

        viewModel.undoLastAction()

        XCTAssertNotNil(first.deletedAt)
        XCTAssertNotNil(second.deletedAt)
        XCTAssertTrue(viewModel.hasUndoableAction)
    }

    func testConvergenceInsertCreatesNoteAndStateInTheTransaction() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        let noteID = UUID()

        try transaction.insertNote(SyncConvergenceNewNoteRecord(
            noteID: noteID,
            folderID: nil,
            title: "Incoming",
            body: "Body",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2)
        ))
        try transaction.save()

        try assertState(noteID: noteID, body: "Body", revision: 0, in: container)
    }

    func testConvergenceUpdateReplacesBodyAndStateInTheTransaction() throws {
        let fixture = try makePersistedNote(body: "Before")
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(
            context: fixture.container.mainContext
        )

        try transaction.updateNote(SyncConvergenceUpdatedNoteRecord(
            noteID: fixture.noteID,
            title: "Updated",
            body: "After",
            modifiedAt: Date(timeIntervalSince1970: 3)
        ))
        try transaction.save()

        try assertState(
            noteID: fixture.noteID,
            body: "After",
            revision: 1,
            in: fixture.container
        )
    }

    func testConvergenceRollbackRemovesPendingBodyAndStateChanges() throws {
        let fixture = try makePersistedNote(body: "Before")
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(
            context: fixture.container.mainContext
        )
        try transaction.updateNote(SyncConvergenceUpdatedNoteRecord(
            noteID: fixture.noteID,
            title: "Updated",
            body: "After",
            modifiedAt: Date()
        ))

        transaction.rollback()

        try assertState(
            noteID: fixture.noteID,
            body: "Before",
            revision: 0,
            in: fixture.container
        )
    }

    func testConflictIncomingResolutionSavesBodyAndStateBeforeRemovingConflict() throws {
        let fixture = try makeConflictFixture(localBody: "Local", remoteBody: "Remote")

        let result = fixture.service.acceptIncoming(fixture.conflict, activeNoteID: nil)

        XCTAssertNotNil(result)
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
        try assertState(
            noteID: fixture.noteID,
            body: "Remote",
            revision: 1,
            in: fixture.container
        )
    }

    func testConflictKeepLocalReestablishesStaleState() throws {
        let fixture = try makeConflictFixture(localBody: "Local", remoteBody: "Remote")
        try replacePersistedState(
            noteID: fixture.noteID,
            representedBody: "Stale",
            revision: 7,
            in: fixture.container
        )

        let result = fixture.service.keepLocal(fixture.conflict, activeNoteID: nil)

        XCTAssertNotNil(result)
        try assertState(
            noteID: fixture.noteID,
            body: "Local",
            revision: 8,
            in: fixture.container
        )
    }

    func testConflictSaveFailureKeepsConflictAndRollsBackBodyAndState() throws {
        let fixture = try makeConflictFixture(
            localBody: "Local",
            remoteBody: "Remote",
            saveOperation: { _ in throw MYR170PathTestError.injected }
        )

        XCTAssertNil(fixture.service.acceptIncoming(fixture.conflict, activeNoteID: nil))

        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        try assertState(
            noteID: fixture.noteID,
            body: "Local",
            revision: 0,
            in: fixture.container
        )
    }

    func testIOSLegacyNewNoteApplyCommitsRevisionZeroState() async throws {
        let container = try makeContainer()
        let folder = Folder(name: "Incoming Folder")
        container.mainContext.insert(folder)
        try container.mainContext.save()
        let viewModel = makeViewModel(context: container.mainContext)
        let noteID = UUID()
        let change = try makeNoteChange(
            noteID: noteID,
            body: "Incoming",
            folderID: folder.id
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result, [.init(changeID: change.id, disposition: .applied)])
        try assertState(
            noteID: noteID,
            body: "Incoming",
            revision: 0,
            in: container
        )
        XCTAssertEqual(try fetchNotes(in: container).first?.folder?.id, folder.id)
    }

    func testIOSLegacyExistingNoteApplyCommitsReplacementState() async throws {
        let fixture = try makePersistedNote(body: "Before")
        let viewModel = makeViewModel(context: fixture.container.mainContext)
        let change = try makeNoteChange(
            noteID: fixture.noteID,
            body: "After",
            baseBody: "Before"
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result.first?.disposition, .applied)
        try assertState(
            noteID: fixture.noteID,
            body: "After",
            revision: 1,
            in: fixture.container
        )
    }

    func testIOSLegacyStateFailureReturnsRetryRequiredWithoutSideEffects() async throws {
        let fixture = try makePersistedNote(body: "Before")
        try corruptState(noteID: fixture.noteID, in: fixture.container)
        let originalPayload = try XCTUnwrap(
            fetchStateRecords(in: fixture.container).first?.statePayloadData
        )
        let viewModel = makeViewModel(context: fixture.container.mainContext)
        let change = try makeNoteChange(
            noteID: fixture.noteID,
            body: "After",
            baseBody: "Before"
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result.first?.disposition, .retryRequired)
        XCTAssertEqual(try fetchNotes(in: fixture.container).first?.content, "Before")
        XCTAssertEqual(
            try fetchStateRecords(in: fixture.container).first?.statePayloadData,
            originalPayload
        )
    }

    func testIOSLegacyResolvedConflictMetadataReplacesBodyAndStateBeforeEffects() async throws {
        let fixture = try makeLegacyConflictFixture()
        let viewModel = makeViewModel(
            context: fixture.container.mainContext,
            conflictStore: fixture.store
        )
        let change = try makeResolvedConflictChange(
            fixture.conflict,
            resolvedBody: "Resolved",
            baseBody: "Local"
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result.first?.disposition, .applied)
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
        try assertState(
            noteID: fixture.noteID,
            body: "Resolved",
            revision: 1,
            in: fixture.container
        )
    }

    func testIOSLegacyResolvedConflictMetadataStateFailureLeavesNoteConflictAndBaselineUnchanged() async throws {
        let fixture = try makeLegacyConflictFixture()
        try corruptState(noteID: fixture.noteID, in: fixture.container)
        fixture.store.saveNoteContentBaseline(
            noteID: fixture.noteID,
            content: "Baseline",
            richTextContentData: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "seed"
        )
        let baseline = fixture.store.remoteBaseline(
            entityType: .note,
            entityID: fixture.noteID,
            field: .noteContent
        )
        let viewModel = makeViewModel(
            context: fixture.container.mainContext,
            conflictStore: fixture.store
        )
        let change = try makeResolvedConflictChange(
            fixture.conflict,
            resolvedBody: "Resolved",
            baseBody: "Local"
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result.first?.disposition, .retryRequired)
        XCTAssertEqual(try fetchNotes(in: fixture.container).first?.content, "Local")
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        XCTAssertEqual(
            fixture.store.remoteBaseline(
                entityType: .note,
                entityID: fixture.noteID,
                field: .noteContent
            ),
            baseline
        )
    }

    func testIOSLegacyResolvedConflictMetadataModelSaveFailureLeavesNoteStateConflictAndBaselineUnchanged() async throws {
        let fixture = try makeLegacyConflictFixture()
        let originalRecord = try XCTUnwrap(fetchStateRecords(in: fixture.container).first)
        let viewModel = makeViewModel(
            context: fixture.container.mainContext,
            conflictStore: fixture.store,
            saveLegacyIncomingApplyContext: { _ in throw MYR170PathTestError.injected }
        )
        let change = try makeResolvedConflictChange(
            fixture.conflict,
            resolvedBody: "Resolved",
            baseBody: "Local"
        )

        let result = await viewModel.applyIncomingSyncChanges([change])

        XCTAssertEqual(result.first?.disposition, .retryRequired)
        XCTAssertEqual(try fetchNotes(in: fixture.container).first?.content, "Local")
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        let currentRecord = try XCTUnwrap(fetchStateRecords(in: fixture.container).first)
        XCTAssertEqual(currentRecord.revision, originalRecord.revision)
        XCTAssertEqual(currentRecord.statePayloadData, originalRecord.statePayloadData)
        XCTAssertNil(fixture.store.remoteBaseline(
            entityType: .note,
            entityID: fixture.noteID,
            field: .noteContent
        ))
    }

    func testIOSLegacyMainContextRefreshDoesNotAdvanceStateTwice() async throws {
        let fixture = try makePersistedNote(body: "Before")
        let viewModel = makeViewModel(context: fixture.container.mainContext)
        let change = try makeNoteChange(
            noteID: fixture.noteID,
            body: "After",
            baseBody: "Before"
        )

        _ = await viewModel.applyIncomingSyncChanges([change])

        try assertState(
            noteID: fixture.noteID,
            body: "After",
            revision: 1,
            in: fixture.container
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR170Path-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeViewModel(
        context: ModelContext,
        conflictStore: SyncConflictStore? = nil,
        saveContext: (() throws -> Void)? = nil,
        saveLegacyIncomingApplyContext: ((ModelContext) throws -> Void)? = nil
    ) -> NotesViewModel {
        NotesViewModel(
            context: context,
            syncConflictStore: conflictStore ?? SyncConflictStore(fileURL: temporaryFileURL("conflicts.json")),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveContext: saveContext,
            saveLegacyIncomingApplyContext: saveLegacyIncomingApplyContext
        )
    }

    private func makePersistedNote(
        body: String
    ) throws -> (container: ModelContainer, noteID: UUID) {
        let container = try makeContainer()
        let context = container.mainContext
        let note = Note(content: body)
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: body
        )
        _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
            note,
            preparedState: prepared,
            in: context
        )
        try context.save()
        return (container, note.id)
    }

    private func makeLifecycleFixture() throws -> (
        container: ModelContainer,
        viewModel: NotesViewModel,
        note: Note
    ) {
        let container = try makeContainer()
        let viewModel = makeViewModel(context: container.mainContext)
        let note = try XCTUnwrap(viewModel.createNewNote())
        return (container, viewModel, note)
    }

    private func makeConflictFixture(
        localBody: String,
        remoteBody: String,
        saveOperation: ((ModelContext) throws -> Void)? = nil
    ) throws -> (
        container: ModelContainer,
        noteID: UUID,
        conflict: SyncConflictVersion,
        store: SyncConflictStore,
        service: MyRAMSyncConflictService
    ) {
        let persisted = try makePersistedNote(body: localBody)
        let store = SyncConflictStore(fileURL: temporaryFileURL("conflicts.json"))
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: persisted.noteID,
            noteID: persisted.noteID,
            field: .noteContent,
            localText: localBody,
            remoteText: remoteBody,
            remoteModifiedAt: Date(timeIntervalSince1970: 2),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = store.preserve(conflict)
        let context = persisted.container.mainContext
        let service = MyRAMSyncConflictService(
            context: context,
            store: store,
            saveOperation: saveOperation ?? { try $0.save() }
        )
        return (persisted.container, persisted.noteID, conflict, store, service)
    }

    private func makeLegacyConflictFixture() throws -> (
        container: ModelContainer,
        noteID: UUID,
        conflict: SyncConflictVersion,
        store: SyncConflictStore
    ) {
        let persisted = try makePersistedNote(body: "Local")
        let store = SyncConflictStore(fileURL: temporaryFileURL("conflicts.json"))
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: persisted.noteID,
            noteID: persisted.noteID,
            field: .noteContent,
            localText: "Local",
            remoteText: "Remote",
            remoteModifiedAt: Date(timeIntervalSince1970: 2),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = store.preserve(conflict)
        return (persisted.container, persisted.noteID, conflict, store)
    }

    private func fetchNotes(in container: ModelContainer) throws -> [Note] {
        try ModelContext(container).fetch(FetchDescriptor<Note>())
    }

    private func fetchStateRecords(
        in container: ModelContainer
    ) throws -> [NoteSequenceStateRecord] {
        try ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>())
    }

    private func assertState(
        noteID: UUID,
        body: String,
        revision: UInt64,
        in container: ModelContainer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            context.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { $0.id == requestedID }
            )).first,
            file: file,
            line: line
        )
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>(
                predicate: #Predicate { $0.noteID == requestedID }
            )).first,
            file: file,
            line: line
        )
        let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: noteID
        )
        XCTAssertTrue(
            NoteSequenceStateExactText.matches(note.content, body),
            file: file,
            line: line
        )
        XCTAssertTrue(
            NoteSequenceStateExactText.matches(state.visibleText, body),
            file: file,
            line: line
        )
        XCTAssertEqual(record.revision, revision, file: file, line: line)
    }

    private func deleteState(noteID: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        for record in try context.fetch(FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedID }
        )) {
            context.delete(record)
        }
        try context.save()
    }

    private func corruptState(noteID: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedID }
        )).first)
        record.statePayloadData = Data("corrupt".utf8)
        record.payloadByteCount = record.statePayloadData.count
        try context.save()
    }

    private func replacePersistedState(
        noteID: UUID,
        representedBody: String,
        revision: UInt64,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedID }
        )).first)
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: noteID,
            body: representedBody
        )
        prepared.apply(to: record, revision: revision)
        try context.save()
    }

    private func makeImportFile(bodies: [String]) throws -> URL {
        let url = temporaryFileURL("notes.myram")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let notes = bodies.enumerated().map { index, body in
            [
                "id": UUID().uuidString,
                "title": "Imported \(index)",
                "content": body,
                "pinnedThoughts": [],
                "createdAt": "2026-01-01T00:00:00Z",
                "modifiedAt": "2026-01-01T00:00:00Z",
                "deletedAt": NSNull(),
                "folderPath": [],
                "attachments": []
            ] as [String: Any]
        }
        let object: [String: Any] = [
            "format": "myram-note-export",
            "version": 1,
            "exportedAt": "2026-01-01T00:00:00Z",
            "notes": notes
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private func makeNoteChange(
        noteID: UUID,
        body: String,
        baseBody: String? = nil,
        folderID: UUID? = nil
    ) throws -> SyncChange {
        let note = Note(title: "Incoming", content: body)
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 10)
        if let folderID {
            let folder = Folder(name: "Incoming Folder")
            folder.id = folderID
            note.folder = folder
        }
        return SyncChange(
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(
                note: note,
                baseTitle: baseBody == nil ? nil : "",
                baseContent: baseBody
            )),
            updatedAt: note.modifiedAt,
            originDeviceID: "remote"
        )
    }

    private func makeResolvedConflictChange(
        _ conflict: SyncConflictVersion,
        resolvedBody: String,
        baseBody: String
    ) throws -> SyncChange {
        SyncChange(
            entityType: .conflict,
            entityID: conflict.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMSyncConflictPayload(
                action: .resolved,
                conflict: conflict,
                resolvedText: resolvedBody,
                baseText: baseBody,
                updatedAt: Date(timeIntervalSince1970: 20)
            )),
            updatedAt: Date(timeIntervalSince1970: 20),
            originDeviceID: "remote"
        )
    }

    private func temporaryFileURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR170-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func insertNote(
        body: String,
        folder: Folder?,
        in context: ModelContext
    ) throws -> Note {
        let note = Note(content: body)
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: body
        )
        _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
            note,
            preparedState: prepared,
            in: context
        )
        note.folder = folder
        return note
    }
}

private enum MYR170PathTestError: Error {
    case injected
}
