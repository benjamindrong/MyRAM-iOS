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
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).count, 0)
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
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).first?.title, "Ledger fails")

        appliedStore.insertShouldThrow = false
        let replayResult = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(replayResult.acknowledgementIDs, [change.id])
        XCTAssertEqual(appliedStore.recordedIDs, [change.id])
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

    func testAttachmentUpsertWithMissingNoteIsNotLedgeredOrAcknowledged() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160212")!
        let attachmentID = UUID(uuidString: "00000000-0000-0000-0000-000000160213")!
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160214")!,
            entityType: .attachment,
            entityID: attachmentID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makeAttachmentPayload(id: attachmentID, noteID: noteID)),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty)
        XCTAssertEqual(result.applyResult.outcomes, [
            MyRAMSyncChangeOutcome(changeID: change.id, disposition: .deferredMissingDependency)
        ])
    }

    func testMixedEnvelopeAcknowledgesOnlyTerminalDispositions() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let validNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160220")!
        let missingNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160221")!
        let attachmentID = UUID(uuidString: "00000000-0000-0000-0000-000000160222")!
        let terminalChange = try makeNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160223")!,
            noteID: validNoteID,
            title: "Terminal"
        )
        let deferredChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160224")!,
            entityType: .attachment,
            entityID: attachmentID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makeAttachmentPayload(id: attachmentID, noteID: missingNoteID)),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [terminalChange, deferredChange])
        )

        XCTAssertEqual(result.acknowledgementIDs, [terminalChange.id])
        XCTAssertEqual(appliedStore.recordedIDs, [terminalChange.id])
        XCTAssertEqual(result.applyResult.outcomes.first {
            $0.changeID == deferredChange.id
        }?.disposition, .deferredMissingDependency)
    }

    func testParentDependenciesAreDeferredUntilAvailable() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)

        let folderID = UUID(uuidString: "00000000-0000-0000-0000-000000160215")!
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160216")!
        let pinnedThoughtID = UUID(uuidString: "00000000-0000-0000-0000-000000160217")!
        let missingFolderNote = try makeNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160218")!,
            noteID: noteID,
            title: "Missing Folder",
            folderID: folderID
        )
        let missingNotePinnedThought = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160219")!,
            entityType: .marker,
            entityID: pinnedThoughtID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makePinnedThoughtPayload(
                id: pinnedThoughtID,
                noteID: noteID,
                text: "Pinned"
            )),
            updatedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "iphone"
        )

        let deferredResult = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [missingFolderNote, missingNotePinnedThought])
        )

        XCTAssertTrue(deferredResult.acknowledgementIDs.isEmpty)
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty)

        let folderChange = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016021A")!,
            entityType: .collection,
            entityID: folderID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(makeFolderPayload(id: folderID, name: "Parent")),
            updatedAt: Date(timeIntervalSince1970: 3),
            originDeviceID: "iphone"
        )
        let convergedResult = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [missingNotePinnedThought, missingFolderNote, folderChange])
        )

        XCTAssertEqual(
            Set(convergedResult.acknowledgementIDs),
            Set([folderChange.id, missingFolderNote.id, missingNotePinnedThought.id])
        )
        XCTAssertEqual(appliedStore.recordedIDs, Set([folderChange.id, missingFolderNote.id, missingNotePinnedThought.id]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).first?.folder?.id, folderID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PinnedThought>(predicate: #Predicate { $0.id == pinnedThoughtID })).first?.note?.id, noteID)
    }

    func testMissingEntityDeleteIsAcknowledgedAsIdempotentTerminalOutcome() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000016021B")!
        let change = try makeNoteDeleteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016021C")!,
            noteID: noteID
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertEqual(appliedStore.recordedIDs, [change.id])
        XCTAssertEqual(result.applyResult.outcomes, [
            MyRAMSyncChangeOutcome(changeID: change.id, disposition: .alreadySatisfiedOrSuperseded)
        ])
    }

    func testPreExistingUnsavedMutationSurvivesLaterRemoteSaveFailure() throws {
        let context = try makeContext()
        let localNoteID = UUID(uuidString: "00000000-0000-0000-0000-00000016021D")!
        let localNote = Note(title: "Local Unsaved", content: "Local")
        localNote.id = localNoteID
        context.insert(localNote)

        var saveCallCount = 0
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(
            context: context,
            appliedStore: appliedStore,
            performSave: {
                saveCallCount += 1
                if saveCallCount == 1 {
                    try context.save()
                } else {
                    throw TestSaveError.failed
                }
            }
        )
        let remoteNoteID = UUID(uuidString: "00000000-0000-0000-0000-00000016021E")!
        let remoteChange = try makeNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016021F")!,
            noteID: remoteNoteID,
            title: "Remote Should Roll Back"
        )

        XCTAssertThrowsError(try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [remoteChange]))) { error in
            XCTAssertEqual(error as? MacLegacySyncReceiverError, .modelSaveFailed)
        }

        XCTAssertEqual(saveCallCount, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == localNoteID })).first?.title, "Local Unsaved")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == remoteNoteID })).count, 0)
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty)
    }

    func testNoteDeleteWithNilDeletedAtIsRejectedNotAppliedOrAcknowledged() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160225")!
        let change = try makeContradictoryNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160226")!,
            noteID: noteID,
            operation: .delete,
            markPayloadDeleted: false
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertTrue(appliedStore.recordedIDs.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).count, 0)
    }

    func testNoteUpsertWithDeletedPayloadStateIsRejected() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160227")!
        let change = try makeContradictoryNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160228")!,
            noteID: noteID,
            operation: .upsert,
            markPayloadDeleted: true
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).count, 0)
    }

    func testFolderDeleteWithIsDeletedFalseIsRejectedNotTreatedAsUpsert() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let folderID = UUID(uuidString: "00000000-0000-0000-0000-000000160229")!
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016022A")!,
            entityType: .collection,
            entityID: folderID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(makeFolderPayload(id: folderID, name: "Not Actually Deleted")),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })).count,
            0,
            "a contradictory delete must not be silently applied as an upsert"
        )
    }

    func testPinnedThoughtDeleteWithIsDeletedFalseIsRejectedNotTreatedAsUpsert() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000016022B")!
        let thoughtID = UUID(uuidString: "00000000-0000-0000-0000-00000016022C")!
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000016022D")!,
            entityType: .marker,
            entityID: thoughtID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(makePinnedThoughtPayload(id: thoughtID, noteID: noteID, text: "Not Deleted")),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PinnedThought>(predicate: #Predicate { $0.id == thoughtID })).count,
            0
        )
    }

    func testAttachmentDeleteWithIsDeletedFalseIsRejected() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000016022E")!
        let attachmentID = UUID(uuidString: "00000000-0000-0000-0000-00000016022F")!
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160230")!,
            entityType: .attachment,
            entityID: attachmentID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(makeAttachmentPayload(id: attachmentID, noteID: noteID)),
            updatedAt: Date(timeIntervalSince1970: 1),
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
    }

    func testPayloadIDDifferentFromEntityIDIsRejected() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160231")!
        let mismatchedEntityID = UUID(uuidString: "00000000-0000-0000-0000-000000160232")!
        let sourceNote = Note(title: "Mismatched", content: "Body")
        sourceNote.id = noteID
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 5)
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160233")!,
            entityType: .item,
            entityID: mismatchedEntityID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: sourceNote)),
            updatedAt: sourceNote.modifiedAt,
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.rejectedChangeIDs, [change.id])
        XCTAssertTrue(result.acknowledgementIDs.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == mismatchedEntityID })).count, 0)
    }

    func testValidStaleDeleteAgainstNewerLocalStateIsSafelyAcknowledgedAsSuperseded() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000160234")!
        let existingNote = Note(title: "Newer Local State", content: "Body")
        existingNote.id = noteID
        existingNote.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(existingNote)
        try context.save()

        let staleDeleteSource = Note(title: "Stale", content: "Stale")
        staleDeleteSource.id = noteID
        staleDeleteSource.modifiedAt = Date(timeIntervalSince1970: 5)
        staleDeleteSource.deletedAt = Date(timeIntervalSince1970: 5)
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160235")!,
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: staleDeleteSource)),
            updatedAt: staleDeleteSource.modifiedAt,
            originDeviceID: "iphone"
        )

        let result = try receiver.receive(SyncEnvelope(senderDeviceID: "iphone", changes: [change]))

        XCTAssertEqual(result.acknowledgementIDs, [change.id])
        XCTAssertEqual(appliedStore.recordedIDs, [change.id])
        XCTAssertEqual(result.applyResult.outcomes, [
            MyRAMSyncChangeOutcome(changeID: change.id, disposition: .alreadySatisfiedOrSuperseded)
        ])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })).first?.title,
            "Newer Local State",
            "a stale delete must not overwrite newer local state"
        )
    }

    func testMixedEnvelopeAcknowledgesOnlySemanticallyValidTerminalChanges() throws {
        let context = try makeContext()
        let appliedStore = FakeMacLegacyAppliedChangeStore()
        let receiver = MacLegacySyncReceiver(context: context, appliedStore: appliedStore)
        let validNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160236")!
        let contradictoryNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000160237")!
        let validChange = try makeNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160238")!,
            noteID: validNoteID,
            title: "Valid"
        )
        let contradictoryChange = try makeContradictoryNoteChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000160239")!,
            noteID: contradictoryNoteID,
            operation: .delete,
            markPayloadDeleted: false
        )

        let result = try receiver.receive(
            SyncEnvelope(senderDeviceID: "iphone", changes: [validChange, contradictoryChange])
        )

        XCTAssertEqual(result.acknowledgementIDs, [validChange.id])
        XCTAssertEqual(result.rejectedChangeIDs, [contradictoryChange.id])
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

    private func makeNoteChange(id: UUID, noteID: UUID, title: String, folderID: UUID? = nil) throws -> SyncChange {
        let sourceNote = Note(title: title, content: "Body for \(title)")
        sourceNote.id = noteID
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 5)
        if let folderID {
            let folder = Folder(name: "Parent")
            folder.id = folderID
            sourceNote.folder = folder
        }
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

    private func makeNoteDeleteChange(id: UUID, noteID: UUID) throws -> SyncChange {
        let sourceNote = Note(title: "Deleted", content: "Deleted")
        sourceNote.id = noteID
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 5)
        sourceNote.deletedAt = Date(timeIntervalSince1970: 6)
        let payload = MyRAMNoteSyncPayload(note: sourceNote)
        return SyncChange(
            id: id,
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .delete,
            payload: try MyRAMSyncPayloadCoding.encode(payload),
            updatedAt: sourceNote.modifiedAt,
            originDeviceID: "iphone"
        )
    }

    private func makeContradictoryNoteChange(
        id: UUID,
        noteID: UUID,
        operation: SyncOperation,
        markPayloadDeleted: Bool
    ) throws -> SyncChange {
        let sourceNote = Note(title: "Contradictory", content: "Body")
        sourceNote.id = noteID
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 5)
        if markPayloadDeleted {
            sourceNote.deletedAt = Date(timeIntervalSince1970: 5)
        }
        let payload = MyRAMNoteSyncPayload(note: sourceNote)
        return SyncChange(
            id: id,
            entityType: .item,
            entityID: noteID.uuidString,
            operation: operation,
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

    private func makePinnedThoughtPayload(id: UUID, noteID: UUID, text: String) -> MyRAMPinnedThoughtSyncPayload {
        let note = Note(title: "placeholder")
        note.id = noteID
        let thought = PinnedThought(text: text, order: 0, note: note)
        thought.id = id
        return MyRAMPinnedThoughtSyncPayload(thought: thought)
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
