import Foundation
import NearbySyncCore
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MYR170MacFullBodyPathIntegrationTests: XCTestCase {
    func testMacLegacyNewNoteApplyCommitsRevisionZeroState() throws {
        let container = try makeContainer()
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: container.mainContext,
            conflictStore: makeConflictStore(),
            appliedStore: ledger
        )
        let noteID = UUID()
        let change = try makeNoteChange(noteID: noteID, body: "Incoming")

        let result = try receiver.receive(envelope(change))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertEqual(ledger.recordedIDs, [change.id])
        try assertState(noteID: noteID, body: "Incoming", revision: 0, in: container)
    }

    func testMacLegacyExistingNoteApplyCommitsReplacementState() throws {
        let fixture = try makePersistedNote(body: "Before")
        let change = try makeNoteChange(
            noteID: fixture.noteID,
            body: "After",
            baseBody: "Before"
        )
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: makeConflictStore(),
            appliedStore: MYR170MacAppliedLedger()
        )

        let result = try receiver.receive(envelope(change))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        try assertState(
            noteID: fixture.noteID,
            body: "After",
            revision: 1,
            in: fixture.container
        )
    }

    func testMacLegacyStateFailureIsNotAcknowledgedOrLedgered() throws {
        let fixture = try makePersistedNote(body: "Before")
        try corruptState(noteID: fixture.noteID, in: fixture.container)
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: makeConflictStore(),
            appliedStore: ledger
        )
        let change = try makeNoteChange(
            noteID: fixture.noteID,
            body: "After",
            baseBody: "Before"
        )

        let result = try receiver.receive(envelope(change))

        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(ledger.recordedIDs.isEmpty)
        XCTAssertEqual(try fetchNote(noteID: fixture.noteID, in: fixture.container)?.content, "Before")
    }

    func testMacLegacyModelSaveFailureRollsBackNoteAndState() throws {
        let container = try makeContainer()
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: container.mainContext,
            conflictStore: makeConflictStore(),
            appliedStore: ledger,
            performSave: { throw MYR170MacPathError.injected }
        )
        let noteID = UUID()
        let change = try makeNoteChange(noteID: noteID, body: "Incoming")

        XCTAssertThrowsError(try receiver.receive(envelope(change))) { error in
            XCTAssertEqual(error as? MacLegacySyncReceiverError, .modelSaveFailed)
        }

        XCTAssertNil(try fetchNote(noteID: noteID, in: container))
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
        XCTAssertTrue(ledger.recordedIDs.isEmpty)
    }

    func testMacLegacyResolvedConflictMetadataReplacesBodyAndStateBeforeEffectsAndAcknowledgement() throws {
        let fixture = try makeConflictFixture()
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: fixture.store,
            appliedStore: ledger
        )
        let change = try makeResolvedConflictChange(fixture.conflict, resolvedBody: "Resolved")

        let result = try receiver.receive(envelope(change))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertEqual(ledger.recordedIDs, [change.id])
        XCTAssertTrue(fixture.store.activeConflicts().isEmpty)
        try assertState(
            noteID: fixture.noteID,
            body: "Resolved",
            revision: 1,
            in: fixture.container
        )
    }

    func testMacLegacyResolvedConflictMetadataStateFailureLeavesAllDurableStateUnchanged() throws {
        let fixture = try makeConflictFixture()
        try corruptState(noteID: fixture.noteID, in: fixture.container)
        let originalPayload = try XCTUnwrap(
            fetchRecords(in: fixture.container).first?.statePayloadData
        )
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: fixture.store,
            appliedStore: ledger
        )
        let change = try makeResolvedConflictChange(fixture.conflict, resolvedBody: "Resolved")

        let result = try receiver.receive(envelope(change))

        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(ledger.recordedIDs.isEmpty)
        XCTAssertEqual(try fetchNote(noteID: fixture.noteID, in: fixture.container)?.content, "Local")
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        XCTAssertEqual(
            try fetchRecords(in: fixture.container).first?.statePayloadData,
            originalPayload
        )
    }

    func testMacLegacyResolvedConflictMetadataModelSaveFailureLeavesNoteStateConflictBaselineLedgerAndAcknowledgementUnchanged() throws {
        let fixture = try makeConflictFixture()
        let originalRecord = try XCTUnwrap(fetchRecords(in: fixture.container).first)
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: fixture.store,
            appliedStore: ledger,
            performSave: { throw MYR170MacPathError.injected }
        )
        let change = try makeResolvedConflictChange(fixture.conflict, resolvedBody: "Resolved")

        XCTAssertThrowsError(try receiver.receive(envelope(change))) { error in
            XCTAssertEqual(error as? MacLegacySyncReceiverError, .modelSaveFailed)
        }

        let currentRecord = try XCTUnwrap(fetchRecords(in: fixture.container).first)
        XCTAssertEqual(try fetchNote(noteID: fixture.noteID, in: fixture.container)?.content, "Local")
        XCTAssertEqual(currentRecord.revision, originalRecord.revision)
        XCTAssertEqual(currentRecord.statePayloadData, originalRecord.statePayloadData)
        XCTAssertEqual(fixture.store.activeConflicts(), [fixture.conflict])
        XCTAssertNil(fixture.store.remoteBaseline(
            entityType: .note,
            entityID: fixture.noteID,
            field: .noteContent
        ))
        XCTAssertTrue(ledger.recordedIDs.isEmpty)
    }

    func testMacLegacyConflictEffectCommitFailureDoesNotLedgerOrAcknowledge() throws {
        let fixture = try makeConflictFixture()
        let failingStore = makeConflictStore(
            fileURL: fixture.fileURL,
            failsCheckedTextWrites: true
        )
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: failingStore,
            appliedStore: ledger
        )
        let change = try makeResolvedConflictChange(fixture.conflict, resolvedBody: "Resolved")

        XCTAssertThrowsError(try receiver.receive(envelope(change))) { error in
            XCTAssertEqual(
                error as? MacLegacySyncReceiverError,
                .conflictEffectsPersistenceFailed
            )
        }

        XCTAssertTrue(ledger.recordedIDs.isEmpty)
        XCTAssertEqual(failingStore.activeConflicts(), [fixture.conflict])
        try assertState(
            noteID: fixture.noteID,
            body: "Resolved",
            revision: 1,
            in: fixture.container
        )
    }

    func testMacLegacyRetryAfterConflictEffectFailureDoesNotAdvanceStateTwiceAndCompletesDurability() throws {
        let fixture = try makeConflictFixture()
        let ledger = MYR170MacAppliedLedger()
        let change = try makeResolvedConflictChange(fixture.conflict, resolvedBody: "Resolved")
        let failingReceiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: makeConflictStore(
                fileURL: fixture.fileURL,
                failsCheckedTextWrites: true
            ),
            appliedStore: ledger
        )
        XCTAssertThrowsError(try failingReceiver.receive(envelope(change)))

        let retryStore = makeConflictStore(fileURL: fixture.fileURL)
        let retryReceiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: retryStore,
            appliedStore: ledger
        )
        let result = try retryReceiver.receive(envelope(change))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertEqual(ledger.recordedIDs, [change.id])
        XCTAssertTrue(retryStore.activeConflicts().isEmpty)
        try assertState(
            noteID: fixture.noteID,
            body: "Resolved",
            revision: 1,
            in: fixture.container
        )
    }

    func testMacLegacyMixedEnvelopeCommitsAndAcknowledgesSuccessfulChangesWhileRejectingOnlyFailedChange() throws {
        let fixture = try makePersistedNote(body: "Before")
        try corruptState(noteID: fixture.noteID, in: fixture.container)
        let successfulNoteID = UUID()
        let successful = try makeNoteChange(noteID: successfulNoteID, body: "Successful")
        let failed = try makeNoteChange(
            noteID: fixture.noteID,
            body: "Rejected",
            baseBody: "Before"
        )
        let ledger = MYR170MacAppliedLedger()
        let receiver = MacLegacySyncReceiver(
            context: fixture.container.mainContext,
            conflictStore: makeConflictStore(),
            appliedStore: ledger
        )

        let result = try receiver.receive(SyncEnvelope(
            senderDeviceID: "iphone",
            changes: [successful, failed]
        ))

        XCTAssertEqual(result.acknowledgementIDs, [successful.id])
        XCTAssertEqual(result.rejectedChangeIDs, [failed.id])
        XCTAssertEqual(ledger.recordedIDs, [successful.id])
        try assertState(
            noteID: successfulNoteID,
            body: "Successful",
            revision: 0,
            in: fixture.container
        )
        XCTAssertEqual(try fetchNote(noteID: fixture.noteID, in: fixture.container)?.content, "Before")
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR170MacPath-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makePersistedNote(
        body: String
    ) throws -> (container: ModelContainer, noteID: UUID) {
        let container = try makeContainer()
        let context = container.mainContext
        let note = Note(content: body)
        note.modifiedAt = Date(timeIntervalSince1970: 1)
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

    private func makeConflictFixture() throws -> (
        container: ModelContainer,
        noteID: UUID,
        conflict: SyncConflictVersion,
        store: SyncConflictStore,
        fileURL: URL
    ) {
        let persisted = try makePersistedNote(body: "Local")
        let fileURL = temporaryFileURL("conflicts.json")
        let store = makeConflictStore(fileURL: fileURL)
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
        return (persisted.container, persisted.noteID, conflict, store, fileURL)
    }

    private func makeConflictStore(
        fileURL: URL? = nil,
        failsCheckedTextWrites: Bool = false
    ) -> SyncConflictStore {
        let resolvedURL = fileURL ?? temporaryFileURL("conflicts.json")
        guard failsCheckedTextWrites else {
            return SyncConflictStore(fileURL: resolvedURL)
        }
        return SyncConflictStore(
            fileURL: resolvedURL,
            fileIO: .live,
            textFileIO: SyncTextConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(
                        at: $0,
                        withIntermediateDirectories: true
                    )
                },
                writeData: { _, _ in throw MYR170MacPathError.injected },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )
    }

    private func makeNoteChange(
        noteID: UUID,
        body: String,
        baseBody: String? = nil
    ) throws -> SyncChange {
        let note = Note(title: "Incoming", content: body)
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 10)
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
            originDeviceID: "iphone"
        )
    }

    private func makeResolvedConflictChange(
        _ conflict: SyncConflictVersion,
        resolvedBody: String
    ) throws -> SyncChange {
        SyncChange(
            entityType: .conflict,
            entityID: conflict.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMSyncConflictPayload(
                action: .resolved,
                conflict: conflict,
                resolvedText: resolvedBody,
                baseText: "Local",
                updatedAt: Date(timeIntervalSince1970: 20)
            )),
            updatedAt: Date(timeIntervalSince1970: 20),
            originDeviceID: "iphone"
        )
    }

    private func envelope(_ change: SyncChange) -> SyncEnvelope {
        SyncEnvelope(senderDeviceID: "iphone", changes: [change])
    }

    private func fetchNote(noteID: UUID, in container: ModelContainer) throws -> Note? {
        let context = ModelContext(container)
        let requestedID = noteID
        return try context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedID }
        )).first
    }

    private func fetchRecords(
        in container: ModelContainer
    ) throws -> [NoteSequenceStateRecord] {
        try ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>())
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
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedID }
        )).first, file: file, line: line)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedID }
        )).first, file: file, line: line)
        let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: noteID
        )
        XCTAssertTrue(NoteSequenceStateExactText.matches(note.content, body), file: file, line: line)
        XCTAssertTrue(NoteSequenceStateExactText.matches(state.visibleText, body), file: file, line: line)
        XCTAssertEqual(record.revision, revision, file: file, line: line)
    }

    private func temporaryFileURL(_ filename: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR170Mac-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

private final class MYR170MacAppliedLedger: MacLegacyAppliedChangeStoring {
    private(set) var recordedIDs: Set<UUID> = []

    func contains(_ id: UUID) -> Bool {
        recordedIDs.contains(id)
    }

    func insert(_ ids: Set<UUID>) throws {
        recordedIDs.formUnion(ids)
    }
}

private enum MYR170MacPathError: Error {
    case injected
}
