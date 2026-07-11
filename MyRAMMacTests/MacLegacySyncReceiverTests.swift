import SwiftData
import XCTest
import NearbySyncCore
@testable import MyRAMMac

@MainActor
final class MacLegacySyncReceiverTests: XCTestCase {
    func testMalformedPayloadIsRejectedAndNotAcknowledged() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let malformed = SyncChange(
            entityType: .item,
            entityID: "note-1",
            operation: .upsert,
            payload: Data("not a valid payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [malformed]))

        XCTAssertEqual(result.rejectedChangeIDs, [malformed.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertFalse(appliedStore.recordedIDs.contains(malformed.id))
    }

    func testNewValidChangeIsAppliedSavedAndAcknowledged() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160201")!
        let change = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000160202")!, noteID: noteID, title: "From iPhone")

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertTrue(result.rejectedChangeIDs.isEmpty)
        XCTAssertTrue(appliedStore.recordedIDs.contains(change.id))

        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))
        XCTAssertEqual(notes.first?.title, "From iPhone")
    }

    func testDuplicateDeliveryAppliesOnceButAcknowledgesAgain() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160203")!
        let change = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000160204")!, noteID: noteID, title: "First")

        _ = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))
        XCTAssertEqual(appliedStore.recordedIDs, [change.id])

        let secondResult = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(secondResult.acknowledgementIDs, [change.id])
        XCTAssertEqual(appliedStore.recordedIDs, [change.id], "a duplicate delivery must not corrupt or duplicate the applied-ID ledger")

        let notes = try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))
        XCTAssertEqual(notes.count, 1)
    }

    func testModelSaveFailureAcknowledgesNoNewIDs() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(
            context: context,
            appliedStore: appliedStore,
            performSave: { throw TestSaveError.failed }
        )
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160205")!
        let change = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000160206")!, noteID: noteID, title: "Should not persist")

        XCTAssertThrowsError(try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))) { error in
            XCTAssertEqual(error as? MacLegacySyncReceiverError, .modelSaveFailed)
        }
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty, "no ID may be acknowledged when the save that would make it durable failed")
    }

    func testAppliedLedgerPersistenceFailureAcknowledgesNoNewIDs() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        appliedStore.insertShouldThrow = true
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160207")!
        let change = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000160208")!, noteID: noteID, title: "Ledger fails")

        XCTAssertThrowsError(try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))) { error in
            XCTAssertEqual(error as? MacLegacySyncReceiverError, .appliedLedgerPersistenceFailed)
        }
    }

    func testAckOnlyEnvelopeProducesNoAcknowledgementIDsOrSideEffects() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)

        let result = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [], acknowledgedChangeIDs: [UUID()])
        )

        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertTrue(result.rejectedChangeIDs.isEmpty)
        XCTAssertEqual(appliedStore.insertCallCount, 0)
    }

    func testMixedEnvelopeAcknowledgesOnlyValidChanges() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160209")!
        let validChange = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-00000016020A")!, noteID: noteID, title: "Valid")
        let malformedChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016020B")!,
            entityType: .marker,
            entityID: "bad",
            operation: .upsert,
            payload: Data("garbage".utf8),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [validChange, malformedChange])
        )

        XCTAssertEqual(result.acknowledgementIDs, [validChange.id])
        XCTAssertEqual(result.rejectedChangeIDs, [malformedChange.id])
    }

    func testAppliesFolderNoteAndAttachmentEntityTypesInOneEnvelope() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)

        let folderID = UUID(uuidString: "00000000-0000-0000-0000-00000016020C")!
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000016020D")!
        let attachmentID = UUID(uuidString: "00000000-0000-0000-0000-00000016020E")!

        let folderChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016020F")!,
            entityType: .collection,
            entityID: folderID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makeFolderPayload(id: folderID, name: "Recovered Folder")),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )
        let noteChange = try makeNoteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000160210")!, noteID: noteID, title: "Recovered Note")
        let attachmentChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160211")!,
            entityType: .attachment,
            entityID: attachmentID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makeAttachmentPayload(id: attachmentID, noteID: noteID)),
            updatedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [folderChange, noteChange, attachmentChange])
        )

        XCTAssertEqual(Set(result.acknowledgementIDs), Set([folderChange.id, noteChange.id, attachmentChange.id]))

        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotePhotoAttachment>(predicate: #Predicate { $0.id == attachmentID })).count, 1)
    }

    // MARK: - Helpers

    // Retained for the lifetime of the test case: the returned ModelContext does not keep
    // its ModelContainer alive, and letting the container deallocate crashes SwiftData mid-test.
    private var retainedContainers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self])
        let configuration = ModelConfiguration(
            "MacLegacySyncReceiverTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self,
            configurations: configuration
        )
        retainedContainers.append(container)
        return container.mainContext
    }

    private func makeNoteChange(id: UUID, noteID: UUID, title: String) throws -> SyncChange {
        let sourceNote = Note(title: title, content: "Body for \(title)")
        sourceNote.id = noteID
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 5)
        let payload = MyRAMNoteSyncPayload(note: sourceNote)
        return SyncChange(
            id: id,
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(payload),
            updatedAt: sourceNote.modifiedAt,
            originDeviceID: "iphone"
        )
    }

    private func makeFolderPayload(id: UUID, name: String) -> MyRAMFolderSyncPayload {
        let folder = Folder(name: name)
        folder.id = id
        return MyRAMFolderSyncPayload(folder: folder)
    }

    private func makeAttachmentPayload(id: UUID, noteID: UUID) -> MyRAMPhotoAttachmentSyncPayload {
        let note = Note(title: "placeholder")
        note.id = noteID
        let attachment = NotePhotoAttachment(imageData: Data([1, 2, 3]), note: note)
        attachment.id = id
        return MyRAMPhotoAttachmentSyncPayload(attachment: attachment)
    }
}

private enum TestSaveError: Error {
    case failed
}

private final class FakeMacLegacyAppliedChangeStore: MacLegacyAppliedChangeStoring {
    private(set) var recordedIDs: Set<UUID> = []
    private(set) var insertCallCount = 0
    var insertShouldThrow = false

    func contains(_ id: UUID) -> Bool {
        recordedIDs.contains(id)
    }

    func insert(_ ids: Set<UUID>) throws {
        insertCallCount += 1
        if insertShouldThrow {
            throw TestStoreError.persistenceFailed
        }
        recordedIDs.formUnion(ids)
    }
}

private enum TestStoreError: Error {
    case persistenceFailed
}
