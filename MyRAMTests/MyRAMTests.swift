import XCTest
import NearbySyncCore
import SwiftData
import SwiftUI
import UIKit
@testable import MyRAM

@MainActor
final class MyRAMTests: XCTestCase {
    private struct EncodedNoteSyncPayload: Encodable {
        let kind: MyRAMSyncPayloadKind
        let id: UUID
        let title: String
        let content: String
        let richTextContentData: Data?
        let isPinned: Bool
        let createdAt: Date
        let modifiedAt: Date
        let deletedAt: Date?
        let folderID: UUID?
        let baseTitle: String?
        let baseContent: String?
        let baseRichTextContentData: Data?
    }

    private struct EncodedPinnedThoughtSyncPayload: Encodable {
        let kind: MyRAMSyncPayloadKind
        let id: UUID
        let noteID: UUID?
        let text: String
        let order: Int
        let isCollapsed: Bool
        let createdAt: Date
        let modifiedAt: Date
        let isDeleted: Bool
        let baseText: String?
    }

    private struct EncodedPhotoAttachmentSyncPayload: Encodable {
        let kind: MyRAMSyncPayloadKind
        let id: UUID
        let noteID: UUID?
        let imageData: Data
        let createdAt: Date
        let isDeleted: Bool
    }

    private struct DecodedExportManifest: Decodable {
        struct NoteRecord: Decodable {
            struct AttachmentRecord: Decodable {
                let id: String
                let createdAt: String
                let mimeType: String
                let filename: String
                let data: String
            }

            struct PinnedThoughtRecord: Decodable {
                let id: String
                let text: String
                let order: Int
                let isCollapsed: Bool
                let createdAt: String
                let modifiedAt: String
            }

            let id: String
            let title: String
            let content: String
            let pinnedThoughts: [PinnedThoughtRecord]
            let createdAt: String
            let modifiedAt: String
            let deletedAt: String?
            let folderPath: [String]
            let attachments: [AttachmentRecord]
        }

        let format: String
        let version: Int
        let exportedAt: String
        let notes: [NoteRecord]
    }

    private final class RecordingSyncController: MyRAMSyncControlling {
        var onChangesReceived: (([SyncChange]) async -> Void)?
        var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)?
        private(set) var recordedChanges: [SyncChange] = []

        func recordLocalChange(
            entityType: SyncEntityType,
            entityID: String,
            operation: SyncOperation,
            payload: Data,
            updatedAt: Date
        ) {
            recordedChanges.append(
                SyncChange(
                    entityType: entityType,
                    entityID: entityID,
                    operation: operation,
                    payload: payload,
                    updatedAt: updatedAt,
                    originDeviceID: "test-device"
                )
            )
        }
    }

    func testTrustedPeerReconnectTrackerBlocksDuplicateConnectAttempts() {
        var tracker = TrustedPeerReconnectTracker()

        XCTAssertNotNil(tracker.beginConnecting(to: "trusted-device"))
        XCTAssertNil(tracker.beginConnecting(to: "trusted-device"))
        XCTAssertTrue(tracker.isConnecting(to: "trusted-device"))
    }

    func testTrustedPeerReconnectTrackerAllowsRetryAfterConnectionEnds() {
        var tracker = TrustedPeerReconnectTracker()

        XCTAssertNotNil(tracker.beginConnecting(to: "trusted-device"))
        tracker.finishConnecting(to: "trusted-device")

        XCTAssertFalse(tracker.isConnecting(to: "trusted-device"))
        XCTAssertNotNil(tracker.beginConnecting(to: "trusted-device"))
    }

    func testTrustedPeerReconnectTrackerIgnoresStaleAttemptTimeout() throws {
        var tracker = TrustedPeerReconnectTracker()

        let staleAttempt = try XCTUnwrap(tracker.beginConnecting(to: "trusted-device"))
        tracker.finishConnecting(to: staleAttempt.peerID)
        let activeAttempt = try XCTUnwrap(tracker.beginConnecting(to: "trusted-device"))

        tracker.finishConnecting(staleAttempt)

        XCTAssertTrue(tracker.isConnecting(to: activeAttempt.peerID))
    }

    func testPinnedHighlightPaletteUsesReadableTextColor() {
        XCTAssertGreaterThan(
            contrastRatio(
                foreground: PinnedHighlightPalette.textUIColor,
                background: PinnedHighlightPalette.highlightUIColor
            ),
            4.5
        )
    }

    func testPinnedHighlightPaletteKeepsSelectableColorsReadable() {
        XCTAssertEqual(PinnedHighlightColor.yellow.title, "Yellow")
        XCTAssertTrue(PinnedHighlightColor.allCases.contains(.slate))

        for color in PinnedHighlightColor.allCases {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(
                    foreground: PinnedHighlightPalette.textUIColor(for: color),
                    background: PinnedHighlightPalette.highlightUIColor(for: color)
                ),
                4.5,
                "\(color.title) pinned color should use readable text"
            )
        }
    }

    func testChecklistActionNormalizesLegacyPrefixAndTogglesState() {
        let checklistText = NSMutableAttributedString(string: "- [ ] Task")

        let checkedSelection = ChecklistItemEditor.applyChecklistAction(
            in: checklistText,
            selection: NSRange(location: 2, length: 0)
        )

        XCTAssertEqual(checklistText.string, "\(ChecklistItemEditor.checkedPrefix)Task")
        XCTAssertEqual(checkedSelection.location, ChecklistItemEditor.checkedPrefix.utf16.count)

        _ = ChecklistItemEditor.applyChecklistAction(
            in: checklistText,
            selection: NSRange(location: checkedSelection.location, length: 0)
        )

        XCTAssertEqual(checklistText.string, "\(ChecklistItemEditor.uncheckedPrefix)Task")
    }

    func testChecklistCheckedContentRangesOnlyIncludesCheckedItems() {
        let text = "\(ChecklistItemEditor.checkedPrefix)Done\n\(ChecklistItemEditor.uncheckedPrefix)Todo\nPlain" as NSString

        let ranges = ChecklistItemEditor.checkedContentRanges(in: text)

        XCTAssertEqual(ranges, [NSRange(location: ChecklistItemEditor.checkedPrefix.utf16.count, length: 4)])
        XCTAssertEqual(text.substring(with: ranges[0]), "Done")
    }

    func testRichTextConflictSanitizationRequiresMatchingPlainTextAndStripsLegacyDefaultColor() throws {
        let attributedText = NSAttributedString(
            string: "Hello",
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.black
            ]
        )
        let encoded = try XCTUnwrap(RichTextContentCodec.encode(attributedText))

        XCTAssertNil(RichTextContentCodec.sanitizedConflictRichTextData(encoded, plainText: "Different"))

        let sanitized = try XCTUnwrap(
            RichTextContentCodec.sanitizedConflictRichTextData(encoded, plainText: "Hello")
        )
        let decoded = RichTextContentCodec.decode(
            richTextData: sanitized,
            plainText: "Hello",
            baseFont: UIFont.systemFont(ofSize: 16)
        )

        XCTAssertNil(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testNoteSyncPayloadRoundTripsNoteFields() throws {
        let noteID = UUID()
        let folderID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 300)
        let data = try JSONEncoder().encode(
            EncodedNoteSyncPayload(
                kind: .note,
                id: noteID,
                title: "Plan",
                content: "Ship nearby sync",
                richTextContentData: Data("rich".utf8),
                isPinned: true,
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 200),
                deletedAt: deletedAt,
                folderID: folderID,
                baseTitle: nil,
                baseContent: nil,
                baseRichTextContentData: nil
            )
        )
        let decoded = try MyRAMSyncPayloadCoding.decodeNote(from: data)

        XCTAssertEqual(decoded.kind, .note)
        XCTAssertEqual(decoded.id, noteID)
        XCTAssertEqual(decoded.title, "Plan")
        XCTAssertEqual(decoded.content, "Ship nearby sync")
        XCTAssertEqual(decoded.richTextContentData, Data("rich".utf8))
        XCTAssertEqual(decoded.isPinned, true)
        XCTAssertEqual(decoded.deletedAt, deletedAt)
        XCTAssertEqual(decoded.folderID, folderID)
    }

    func testNoteSyncPayloadEncodesNoteFields() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let folderID = UUID()
        let folder = Folder(name: "Projects")
        folder.id = folderID
        let noteID = UUID()
        let note = Note(title: "Plan", content: "Ship nearby sync")
        note.id = noteID
        context.insert(folder)
        context.insert(note)
        note.folder = folder
        note.richTextContentData = Data("rich".utf8)
        note.isPinned = true
        note.deletedAt = Date(timeIntervalSince1970: 300)
        try context.save()

        let data = try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: note))
        let decoded = try MyRAMSyncPayloadCoding.decodeNote(from: data)

        XCTAssertEqual(decoded.kind, .note)
        XCTAssertEqual(decoded.id, noteID)
        XCTAssertEqual(decoded.title, "Plan")
        XCTAssertEqual(decoded.content, "Ship nearby sync")
        XCTAssertEqual(decoded.richTextContentData, Data("rich".utf8))
        XCTAssertEqual(decoded.isPinned, true)
        XCTAssertEqual(decoded.deletedAt, note.deletedAt)
        XCTAssertEqual(decoded.folderID, folderID)
    }

    func testNoteSyncPayloadPreservesConcreteRichTextFontSizes() throws {
        let note = Note(title: "Formatting", content: "Large\nPhone")
        let richText = NSMutableAttributedString(string: note.content)
        richText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 24),
            range: NSRange(location: 0, length: 5)
        )
        richText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: NSRange(location: 6, length: 5)
        )
        note.richTextContentData = try XCTUnwrap(RichTextContentCodec.encode(richText))

        let data = try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: note))
        let decoded = try MyRAMSyncPayloadCoding.decodeNote(from: data)
        let decodedRichText = RichTextContentCodec.decode(
            richTextData: decoded.richTextContentData,
            plainText: decoded.content,
            baseFont: UIFont.systemFont(ofSize: 20)
        )

        XCTAssertEqual(fontSize(in: decodedRichText, at: 0), 24, accuracy: 0.1)
        XCTAssertEqual(fontSize(in: decodedRichText, at: 6), 17, accuracy: 0.1)
    }

    func testPhotoAttachmentSyncPayloadRoundTripsImageFields() throws {
        let attachmentID = UUID()
        let noteID = UUID()
        let createdAt = Date(timeIntervalSince1970: 400)
        let data = try JSONEncoder().encode(
            EncodedPhotoAttachmentSyncPayload(
                kind: .photoAttachment,
                id: attachmentID,
                noteID: noteID,
                imageData: Data("image".utf8),
                createdAt: createdAt,
                isDeleted: false
            )
        )
        let decoded = try MyRAMSyncPayloadCoding.decodePhotoAttachment(from: data)

        XCTAssertEqual(decoded.kind, .photoAttachment)
        XCTAssertEqual(decoded.id, attachmentID)
        XCTAssertEqual(decoded.noteID, noteID)
        XCTAssertEqual(decoded.imageData, Data("image".utf8))
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertFalse(decoded.isDeleted)
    }

    func testPhotoAttachmentSyncPayloadEncodesImageFields() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let note = Note(title: "Photo host")
        context.insert(note)
        let attachment = NotePhotoAttachment(imageData: Data("image".utf8), note: note)
        attachment.createdAt = Date(timeIntervalSince1970: 400)
        context.insert(attachment)
        try context.save()

        let data = try MyRAMSyncPayloadCoding.encode(MyRAMPhotoAttachmentSyncPayload(attachment: attachment))
        let decoded = try MyRAMSyncPayloadCoding.decodePhotoAttachment(from: data)

        XCTAssertEqual(decoded.kind, .photoAttachment)
        XCTAssertEqual(decoded.id, attachment.id)
        XCTAssertEqual(decoded.noteID, note.id)
        XCTAssertEqual(decoded.imageData, Data("image".utf8))
        XCTAssertEqual(decoded.createdAt, attachment.createdAt)
        XCTAssertFalse(decoded.isDeleted)
    }

    func testFolderAndPinnedPayloadsMapToCollectionAndMarkerChanges() async throws {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let folder = Folder(name: "Archive")
        let thought = PinnedThought(text: "Remember this", order: 2)

        _ = await engine.recordLocalChange(
            entityType: .collection,
            entityID: folder.id.uuidString,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMFolderSyncPayload(folder: folder)),
            updatedAt: folder.modifiedAt
        )
        _ = await engine.recordLocalChange(
            entityType: .marker,
            entityID: thought.id.uuidString,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMPinnedThoughtSyncPayload(thought: thought)),
            updatedAt: thought.modifiedAt
        )

        let nextEnvelope = await engine.nextEnvelope()
        let envelope = try XCTUnwrap(nextEnvelope)
        let pendingChangeCount = await engine.pendingChangeCount()

        XCTAssertEqual(envelope.changes.map(\.entityType), [.collection, .marker])
        XCTAssertEqual(pendingChangeCount, 2)
    }

    func testPendingSyncChangesCoalesceByEntity() async throws {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let noteID = UUID().uuidString

        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: noteID,
            payload: Data("first".utf8),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: noteID,
            payload: Data("second".utf8),
            updatedAt: Date(timeIntervalSince1970: 101)
        )

        let nextEnvelope = await engine.nextEnvelope()
        let envelope = try XCTUnwrap(nextEnvelope)
        let pendingChangeCount = await engine.pendingChangeCount()

        XCTAssertEqual(envelope.changes.count, 1)
        XCTAssertEqual(envelope.changes.first?.payload, Data("second".utf8))
        XCTAssertEqual(pendingChangeCount, 1)
    }

    func testPendingSyncChangesKeepDifferentEntities() async throws {
        let store = InMemorySyncStore()
        let engine = SyncEngine(deviceID: "device-a", store: store)
        let noteID = UUID().uuidString
        let folderID = UUID().uuidString

        _ = await engine.recordLocalChange(
            entityType: .item,
            entityID: noteID,
            payload: Data("note".utf8),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        _ = await engine.recordLocalChange(
            entityType: .collection,
            entityID: folderID,
            payload: Data("folder".utf8),
            updatedAt: Date(timeIntervalSince1970: 101)
        )

        let nextEnvelope = await engine.nextEnvelope()
        let envelope = try XCTUnwrap(nextEnvelope)
        let pendingChangeCount = await engine.pendingChangeCount()

        XCTAssertEqual(envelope.changes.map(\.entityType), [.item, .collection])
        XCTAssertEqual(pendingChangeCount, 2)
    }

    func testSyncQueuePersistsPendingChangesAcrossInstances() async throws {
        let fileURL = temporarySyncQueueFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let persistence = FileBackedSyncQueuePersistence(fileURL: fileURL)
        let noteID = UUID().uuidString
        let change = SyncChange(
            entityType: .item,
            entityID: noteID,
            operation: .upsert,
            payload: Data("persisted".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        await SyncQueue(persistence: persistence).enqueue(change)
        let reloadedQueue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let reloadedBatch = await reloadedQueue.pendingBatch()

        XCTAssertEqual(reloadedBatch, [change])
    }

    func testSyncQueuePersistsAcknowledgedChangesRemoval() async throws {
        let fileURL = temporarySyncQueueFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let queue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let change = SyncChange(
            entityType: .attachment,
            entityID: UUID().uuidString,
            operation: .upsert,
            payload: Data("image".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )

        await queue.enqueue(change)
        await queue.markAcknowledged([change.id])
        let reloadedQueue = SyncQueue(persistence: FileBackedSyncQueuePersistence(fileURL: fileURL))
        let reloadedBatch = await reloadedQueue.pendingBatch()

        XCTAssertTrue(reloadedBatch.isEmpty)
    }

    func testSyncEnvelopeDecodesMissingAcknowledgements() throws {
        let change = SyncChange(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            entityType: .item,
            entityID: UUID().uuidString,
            operation: .upsert,
            payload: Data("payload".utf8),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "device-a"
        )
        let envelope = SyncEnvelope(
            senderDeviceID: "device-a",
            sentAt: Date(timeIntervalSince1970: 200),
            changes: [change]
        )
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        json?["acknowledgedChangeIDs"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(json))

        let decodedEnvelope = try JSONDecoder().decode(SyncEnvelope.self, from: legacyData)

        XCTAssertEqual(decodedEnvelope.changes, [change])
        XCTAssertTrue(decodedEnvelope.acknowledgedChangeIDs.isEmpty)
    }

    func testIncomingPhotoAttachmentSyncAddsAndRemovesAttachment() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let attachmentID = UUID()
        let createdAt = Date(timeIntervalSince1970: 500)
        let addPayload = try JSONEncoder().encode(
            EncodedPhotoAttachmentSyncPayload(
                kind: .photoAttachment,
                id: attachmentID,
                noteID: note.id,
                imageData: Data("remote".utf8),
                createdAt: createdAt,
                isDeleted: false
            )
        )

        await vm.applyIncomingSyncChanges([
            SyncChange(
                entityType: .attachment,
                entityID: attachmentID.uuidString,
                operation: .upsert,
                payload: addPayload,
                updatedAt: Date(timeIntervalSince1970: 501),
                originDeviceID: "device-b"
            )
        ])

        XCTAssertEqual(note.photoAttachments.count, 1)
        XCTAssertEqual(note.photoAttachments.first?.id, attachmentID)
        XCTAssertEqual(note.photoAttachments.first?.imageData, Data("remote".utf8))

        let deletePayload = try MyRAMSyncPayloadCoding.encode(
            MyRAMPhotoAttachmentSyncPayload(attachment: note.photoAttachments[0], isDeleted: true)
        )
        await vm.applyIncomingSyncChanges([
            SyncChange(
                entityType: .attachment,
                entityID: attachmentID.uuidString,
                operation: .delete,
                payload: deletePayload,
                updatedAt: Date(timeIntervalSince1970: 502),
                originDeviceID: "device-b"
            )
        ])

        XCTAssertTrue(note.photoAttachments.isEmpty)
    }

    func testIncomingNoteDeletePreservesDivergedTextAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Local title", content: "Local body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        note.richTextContentData = Data("local rich".utf8)
        context.insert(note)
        let remoteNote = Note(title: "Remote title", content: "Remote body")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 200)
        remoteNote.deletedAt = remoteNote.modifiedAt
        remoteNote.richTextContentData = Data("remote rich".utf8)
        let deletePayload = try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: remoteNote))
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .delete,
                    payload: deletePayload,
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertTrue(result.shouldRefreshActiveNote)
        XCTAssertNil(note.deletedAt)
        XCTAssertEqual(note.title, "Local title")
        XCTAssertEqual(note.content, "Local body")
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(Set(conflicts.map(\.field)), [.noteTitle, .noteContent])
        XCTAssertTrue(conflicts.contains { $0.localText == "Local title" && $0.remoteText == "Remote title" })
        XCTAssertTrue(conflicts.contains { $0.localText == "Local body" && $0.remoteText == "Remote body" })
    }

    func testIncomingNewerNoteTextPreservesDivergedTextAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Local title", content: "Local body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let remoteNote = Note(title: "Remote title", content: "Remote body")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 200)
        let payload = try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: remoteNote))
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.title, "Local title")
        XCTAssertEqual(note.content, "Local body")
        XCTAssertNil(note.deletedAt)
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(Set(conflicts.map(\.field)), [.noteTitle, .noteContent])
        XCTAssertTrue(conflicts.contains { $0.localText == "Local title" && $0.remoteText == "Remote title" })
        XCTAssertTrue(conflicts.contains { $0.localText == "Local body" && $0.remoteText == "Remote body" })
    }

    func testIncomingBlankNoteBodyDuringActiveEditIsPreservedForReview() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "Local typing")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let remoteNote = Note(title: "Shared title", content: "")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 200)
        let payload = try MyRAMSyncPayloadCoding.encode(
            MyRAMNoteSyncPayload(
                note: remoteNote,
                baseTitle: "Shared title",
                baseContent: "Local typing"
            )
        )
        let applier = MyRAMSyncChangeApplier(
            context: context,
            conflictStore: conflictStore,
            isTextApplicationUnsafe: { entityType, entityID, field in
                entityType == .note && entityID == note.id && field == .noteContent
            }
        )

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Local typing")
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(conflicts.first?.field, .noteContent)
        XCTAssertEqual(conflicts.first?.localText, "Local typing")
        XCTAssertEqual(conflicts.first?.remoteText, "")
    }

    func testIncomingNewNoteAppliesWithoutConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let remoteNote = Note(title: "Remote title", content: "Remote body")
        remoteNote.id = UUID()
        remoteNote.createdAt = Date(timeIntervalSince1970: 90)
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 100)
        let payload = try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: remoteNote))
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: remoteNote.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: nil
        )

        let remoteNoteID = remoteNote.id
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == remoteNoteID
            }
        )
        let syncedNote = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertEqual(syncedNote.title, "Remote title")
        XCTAssertEqual(syncedNote.content, "Remote body")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 101)).isEmpty)
    }

    func testIncomingCleanNoteEditAppliesWithoutConflictWhenLocalMatchesRemoteBaseline() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let noteID = UUID()
        let originalRemoteNote = Note(title: "Original title", content: "Original body")
        originalRemoteNote.id = noteID
        originalRemoteNote.modifiedAt = Date(timeIntervalSince1970: 100)
        let editedRemoteNote = Note(title: "Edited title", content: "Edited body")
        editedRemoteNote.id = noteID
        editedRemoteNote.modifiedAt = Date(timeIntervalSince1970: 200)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: noteID.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: originalRemoteNote)),
                    updatedAt: originalRemoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: noteID,
            currentNoteID: noteID,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: noteID.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: editedRemoteNote,
                            baseTitle: originalRemoteNote.title,
                            baseContent: originalRemoteNote.content,
                            baseRichTextContentData: originalRemoteNote.richTextContentData
                        )
                    ),
                    updatedAt: editedRemoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: noteID,
            currentNoteID: noteID,
            currentFolderID: nil
        )

        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        let syncedNote = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertEqual(syncedNote.title, "Edited title")
        XCTAssertEqual(syncedNote.content, "Edited body")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).isEmpty)
    }

    // MYR-81: a peer can emit several debounced local edits before the first
    // one is acknowledged, so later edits in the same burst still carry the
    // base from before the burst started. The receiver must prefer its own
    // tracked baseline (which advances as each edit is applied) over that
    // stale sender-embedded base, or it sees two "edits" landing at the same
    // spot in an outdated base and reports a false conflict.

    func testRapidLocalTypingFromPeerDoesNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let firstKeystrokeBurst = Note(title: "Shared title", content: "hello")
        firstKeystrokeBurst.id = note.id
        firstKeystrokeBurst.modifiedAt = Date(timeIntervalSince1970: 200)
        let secondKeystrokeBurst = Note(title: "Shared title", content: "hello world")
        secondKeystrokeBurst.id = note.id
        secondKeystrokeBurst.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: firstKeystrokeBurst, baseTitle: "Shared title", baseContent: "")
                    ),
                    updatedAt: firstKeystrokeBurst.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: secondKeystrokeBurst, baseTitle: "Shared title", baseContent: "")
                    ),
                    updatedAt: secondKeystrokeBurst.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "hello world")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testRapidLocalTypoCorrectionFromPeerDoesNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "Hello")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        // Peer typed a typo and sent it before noticing.
        let typo = Note(title: "Shared title", content: "Helllo World")
        typo.id = note.id
        typo.modifiedAt = Date(timeIntervalSince1970: 200)
        // Peer deletes the extra letter and resends before the typo edit is acknowledged.
        let correction = Note(title: "Shared title", content: "Hello World")
        correction.id = note.id
        correction.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: typo, baseTitle: "Shared title", baseContent: "Hello")
                    ),
                    updatedAt: typo.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: correction, baseTitle: "Shared title", baseContent: "Hello")
                    ),
                    updatedAt: correction.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Hello World")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testRapidLocalDeletionFromPeerDoesNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "alpha beta gamma delta")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let firstDelete = Note(title: "Shared title", content: "alpha beta gamma")
        firstDelete.id = note.id
        firstDelete.modifiedAt = Date(timeIntervalSince1970: 200)
        let secondDelete = Note(title: "Shared title", content: "alpha beta")
        secondDelete.id = note.id
        secondDelete.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: firstDelete,
                            baseTitle: "Shared title",
                            baseContent: "alpha beta gamma delta"
                        )
                    ),
                    updatedAt: firstDelete.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: secondDelete,
                            baseTitle: "Shared title",
                            baseContent: "alpha beta gamma delta"
                        )
                    ),
                    updatedAt: secondDelete.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "alpha beta")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testRapidDeleteThenAddBackFromPeerDoesNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "alpha beta gamma")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let deletion = Note(title: "Shared title", content: "alpha gamma")
        deletion.id = note.id
        deletion.modifiedAt = Date(timeIntervalSince1970: 200)
        let replacement = Note(title: "Shared title", content: "alpha better gamma")
        replacement.id = note.id
        replacement.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: deletion, baseTitle: "Shared title", baseContent: "alpha beta gamma")
                    ),
                    updatedAt: deletion.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: replacement,
                            baseTitle: "Shared title",
                            baseContent: "alpha beta gamma"
                        )
                    ),
                    updatedAt: replacement.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "alpha better gamma")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testRapidSameRangeAutocorrectFromPeerDoesNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "I went tehre")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let autocorrect = Note(title: "Shared title", content: "I went there")
        autocorrect.id = note.id
        autocorrect.modifiedAt = Date(timeIntervalSince1970: 200)
        let continuation = Note(title: "Shared title", content: "I went there today")
        continuation.id = note.id
        continuation.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: autocorrect, baseTitle: "Shared title", baseContent: "I went tehre")
                    ),
                    updatedAt: autocorrect.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: continuation, baseTitle: "Shared title", baseContent: "I went tehre")
                    ),
                    updatedAt: continuation.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "I went there today")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testRapidNewlineHeavyEditsFromPeerDoNotCreateFalseConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "Notes:")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let firstLine = Note(title: "Shared title", content: "Notes:\nitem1")
        firstLine.id = note.id
        firstLine.modifiedAt = Date(timeIntervalSince1970: 200)
        let moreLines = Note(title: "Shared title", content: "Notes:\nitem1\nitem2\nitem3")
        moreLines.id = note.id
        moreLines.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: firstLine, baseTitle: "Shared title", baseContent: "Notes:")
                    ),
                    updatedAt: firstLine.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: moreLines, baseTitle: "Shared title", baseContent: "Notes:")
                    ),
                    updatedAt: moreLines.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Notes:\nitem1\nitem2\nitem3")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211)).isEmpty)
    }

    func testGenuineTwoDeviceDivergenceFromSameBaseStillConflicts() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "Hello")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        // This device makes a genuine local edit the peer does not know about yet.
        note.content = "Hello there"
        note.modifiedAt = Date(timeIntervalSince1970: 150)
        // The peer independently edits from the same shared base.
        let divergentRemoteNote = Note(title: "Shared title", content: "Hello World")
        divergentRemoteNote.id = note.id
        divergentRemoteNote.modifiedAt = Date(timeIntervalSince1970: 200)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: divergentRemoteNote, baseTitle: "Shared title", baseContent: "Hello")
                    ),
                    updatedAt: divergentRemoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Hello there")
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(conflicts.first?.field, .noteContent)
        XCTAssertEqual(conflicts.first?.localText, "Hello there")
        XCTAssertEqual(conflicts.first?.remoteText, "Hello World")
    }

    func testDifferentRemoteSenderStaleBaseDoesNotOverwriteTrackedText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "Hello")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: nil,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let deviceCEdit = Note(title: "Shared title", content: "Hello from C")
        deviceCEdit.id = note.id
        deviceCEdit.modifiedAt = Date(timeIntervalSince1970: 200)
        let staleDeviceAEdit = Note(title: "Shared title", content: "Hello from A")
        staleDeviceAEdit.id = note.id
        staleDeviceAEdit.modifiedAt = Date(timeIntervalSince1970: 210)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: deviceCEdit, baseTitle: "Shared title", baseContent: "Hello")
                    ),
                    updatedAt: deviceCEdit.modifiedAt,
                    originDeviceID: "device-c"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )
        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: staleDeviceAEdit, baseTitle: "Shared title", baseContent: "Hello")
                    ),
                    updatedAt: staleDeviceAEdit.modifiedAt,
                    originDeviceID: "device-a"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Hello from C")
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(conflicts.first?.field, .noteContent)
        XCTAssertEqual(conflicts.first?.localText, "Hello from C")
        XCTAssertEqual(conflicts.first?.remoteText, "Hello from A")
    }

    func testActiveConflictPreventsRemoteOrdinaryTextFromOverwritingLocalText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "local editor text")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 200)
        context.insert(note)
        let existingConflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "local editor text",
            remoteText: "remote conflicting text",
            remoteModifiedAt: Date(timeIntervalSince1970: 190),
            preservedAt: Date(timeIntervalSince1970: 190),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(existingConflict)
        let remoteNote = Note(title: "Shared title", content: "stale remote replacement")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 210)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: remoteNote, baseTitle: "Shared title", baseContent: "shared text")
                    ),
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "local editor text")
        let conflicts = conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 211))
        XCTAssertEqual(conflicts.first?.localText, "local editor text")
    }

    func testActiveConflictPreservesLocalDeleteThenRetypeAgainstRemoteOrdinaryText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared title", content: "local corrected text after retyping")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 220)
        context.insert(note)
        let existingConflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "local text before correction",
            remoteText: "remote conflicting text",
            remoteModifiedAt: Date(timeIntervalSince1970: 190),
            preservedAt: Date(timeIntervalSince1970: 190),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(existingConflict)
        let remoteNote = Note(title: "Shared title", content: "remote text while reviewing")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 230)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(note: remoteNote, baseTitle: "Shared title", baseContent: "shared text")
                    ),
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "local corrected text after retyping")
        let queuedConflict = conflictStore.queuedConflict(entityType: .note, entityID: note.id, field: .noteContent)
        XCTAssertEqual(queuedConflict?.conflict.localText, "local corrected text after retyping")
    }

    func testIncomingCleanNoteEditAppliesAfterLocalBaselineWasSent() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Mac title", content: "Mac body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        conflictStore.saveNoteTitleBaseline(noteID: note.id, title: note.title, modifiedAt: note.modifiedAt, originDeviceID: "device-a")
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: note.content,
            richTextContentData: note.richTextContentData,
            modifiedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        let remoteNote = Note(title: "Mac title", content: "iPhone body")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 200)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: remoteNote,
                            baseTitle: "Mac title",
                            baseContent: "Mac body",
                            baseRichTextContentData: note.richTextContentData
                        )
                    ),
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "iPhone body")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).isEmpty)
    }

    func testAcknowledgedLocalNoteChangeAdvancesSyncBaseline() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let vm = NotesViewModel(context: context)
        let note = Note(title: "Synced title", content: "Synced body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let acknowledgedChange = SyncChange(
            entityType: .item,
            entityID: note.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: note)),
            updatedAt: note.modifiedAt,
            originDeviceID: "device-a"
        )
        await vm.advanceSyncBaselines(forAcknowledgedLocalChanges: [acknowledgedChange])
        let remoteNote = Note(title: "Synced title", content: "Peer body")
        remoteNote.id = note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 200)

        await vm.applyIncomingSyncChanges([
            SyncChange(
                entityType: .item,
                entityID: note.id.uuidString,
                operation: .upsert,
                payload: try MyRAMSyncPayloadCoding.encode(
                    MyRAMNoteSyncPayload(
                        note: remoteNote,
                        baseTitle: "Synced title",
                        baseContent: "Synced body",
                        baseRichTextContentData: note.richTextContentData
                    )
                ),
                updatedAt: remoteNote.modifiedAt,
                originDeviceID: "device-b"
            )
        ])

        XCTAssertEqual(note.content, "Peer body")
        XCTAssertTrue(vm.activeSyncConflicts(for: note).isEmpty)
    }

    func testSyncConflictMetadataPreservesAndResolvesConflictOnPeer() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared", content: "Receiver local")
        note.id = UUID()
        context.insert(note)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Receiver local",
            remoteText: "Sender remote",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: conflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(action: .preserved, conflict: conflict, updatedAt: conflict.preservedAt)
                    ),
                    updatedAt: conflict.preservedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: nil
        )
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).first?.id, conflict.id)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: conflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(
                            action: .resolved,
                            conflict: conflict,
                            resolvedText: "Receiver local",
                            baseText: "Sender remote",
                            updatedAt: Date(timeIntervalSince1970: 203)
                        )
                    ),
                    updatedAt: Date(timeIntervalSince1970: 203),
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: nil
        )

        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 204)).isEmpty)
    }

    func testIncomingPeerConflictMetadataShowsCurrentDeviceLocalAndPeerVersionToSync() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared", content: "Mac local edit")
        note.id = UUID()
        context.insert(note)
        let peerConflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "iPhone offline edit",
            remoteText: "Mac local edit",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: peerConflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(action: .preserved, conflict: peerConflict, updatedAt: peerConflict.preservedAt)
                    ),
                    updatedAt: peerConflict.preservedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        let conflict = try XCTUnwrap(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).first)
        XCTAssertEqual(conflict.localText, "Mac local edit")
        XCTAssertEqual(conflict.remoteText, "iPhone offline edit")
        XCTAssertEqual(note.content, "Mac local edit")
    }

    func testSyncConflictResolutionRemovesMatchingPeerConflictWithDifferentLocalID() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let noteID = UUID()
        let resolvedConflict = SyncConflictVersion(
            id: UUID(),
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Device A local",
            remoteText: "Device B remote",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let peerConflict = SyncConflictVersion(
            id: UUID(),
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Device A local edited again",
            remoteText: resolvedConflict.remoteText,
            remoteModifiedAt: resolvedConflict.remoteModifiedAt,
            preservedAt: Date(timeIntervalSince1970: 202),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(peerConflict)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: resolvedConflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(
                            action: .resolved,
                            conflict: resolvedConflict,
                            resolvedText: "Device A local",
                            baseText: "Device B remote",
                            updatedAt: Date(timeIntervalSince1970: 203)
                        )
                    ),
                    updatedAt: Date(timeIntervalSince1970: 203),
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: noteID,
            currentNoteID: noteID,
            currentFolderID: nil
        )

        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 204)).isEmpty)
    }

    func testResolvedSyncConflictDoesNotPreserveAgainFromStaleMessage() throws {
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let noteID = UUID()
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Local body",
            remoteText: "Remote body",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)

        XCTAssertTrue(conflictStore.removeResolvedConflict(conflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(conflict).isEmpty)
    }

    func testResolvedSyncConflictIgnoresStalePreservedMessageWithDifferentRichTextPayload() throws {
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let noteID = UUID()
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteRichTextContentData: Data("rich-a".utf8),
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let stalePreservedConflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Mac local",
            remoteText: "iPhone incoming",
            remoteRichTextContentData: Data("rich-b".utf8),
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 202),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)

        XCTAssertTrue(conflictStore.removeResolvedConflict(conflict).isEmpty)
        XCTAssertTrue(conflictStore.preserve(stalePreservedConflict).isEmpty)
    }

    func testKeepLocalSyncConflictRecordsResolvedTombstone() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Local title", content: "Mac kept local")
        note.id = UUID()
        context.insert(note)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: note.content,
            remoteText: "iPhone remote version",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)
        let service = MyRAMSyncConflictService(context: context, store: conflictStore)

        let result = try XCTUnwrap(service.markReviewed(conflict, activeNoteID: note.id))

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(conflictStore.preserve(conflict).isEmpty)
        XCTAssertEqual(note.content, "Mac kept local")
    }

    func testSaveMergedSyncConflictWritesEditableTextAndOnlyEmitsResolvedMetadata() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        note.richTextContentData = Data("stale rich text".utf8)
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)
        let mergedText = "Local-only text\nVersion to Sync"

        vm.saveMergedSyncConflict(conflict, mergedText: mergedText)

        XCTAssertEqual(note.content, mergedText)
        XCTAssertNil(note.richTextContentData)
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).isEmpty)
        XCTAssertEqual(
            conflictStore.remoteBaseline(entityType: .note, entityID: note.id, field: .noteContent)?.text,
            mergedText
        )
        XCTAssertEqual(recorder.recordedChanges.count, 1)
        let change = try XCTUnwrap(recorder.recordedChanges.first)
        XCTAssertEqual(change.entityType, .conflict)
        XCTAssertFalse(recorder.recordedChanges.contains { $0.entityType == .item })
        let payload = try MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload)
        XCTAssertEqual(payload.action, .resolved)
        XCTAssertEqual(payload.resolvedText, mergedText)
        XCTAssertEqual(payload.baseText, "Version to Sync")
    }

    func testOrdinaryNoteSyncIsBlockedWhileContentConflictIsActive() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)

        vm.commitNoteEdit(note, title: "Shared", content: "typed during review")

        XCTAssertEqual(note.content, "typed during review")
        XCTAssertTrue(recorder.recordedChanges.isEmpty)
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).first, conflict)
    }

    func testEditorBufferDefersRemoteRefreshDuringPendingLocalEdit() {
        XCTAssertTrue(EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: .localEditing,
            hasPendingNoteCommit: true
        ))
    }

    func testEditorBufferAllowsRemoteRefreshWhenLocalEditHasCommitted() {
        XCTAssertFalse(EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: .localEditing,
            hasPendingNoteCommit: false
        ))
    }

    func testEditorBufferAllowsDeliberateNonLocalOwnersToRefresh() {
        XCTAssertFalse(EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: .idle,
            hasPendingNoteCommit: true
        ))
        XCTAssertFalse(EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: .restoringHistory,
            hasPendingNoteCommit: true
        ))
        XCTAssertFalse(EditorBufferReloadPolicy.shouldDeferRemoteRefresh(
            owner: .resolvingConflict,
            hasPendingNoteCommit: true
        ))
    }

    func testSelectionFormattingPolicyAllowsSmallSelectionScan() {
        XCTAssertFalse(EditorSelectionFormattingPolicy.shouldDeferFullFormattingScan(
            selectionLength: EditorSelectionFormattingPolicy.largeSelectionFormattingThreshold
        ))
    }

    func testSelectionFormattingPolicyDefersLargeSelectionScan() {
        XCTAssertTrue(EditorSelectionFormattingPolicy.shouldDeferFullFormattingScan(
            selectionLength: EditorSelectionFormattingPolicy.largeSelectionFormattingThreshold + 1
        ))
    }

    func testSearchHighlighterRejectsMissingRange() {
        XCTAssertNil(EditorSearchHighlighter.validHighlightRange(nil, textLength: 12))
    }

    func testSearchHighlighterRejectsNotFoundRange() {
        let range = NSRange(location: NSNotFound, length: 4)

        XCTAssertNil(EditorSearchHighlighter.validHighlightRange(range, textLength: 12))
    }

    func testSearchHighlighterRejectsZeroLengthRange() {
        let range = NSRange(location: 3, length: 0)

        XCTAssertNil(EditorSearchHighlighter.validHighlightRange(range, textLength: 12))
    }

    func testSearchHighlighterRejectsRangePastTextLength() {
        let range = NSRange(location: 9, length: 4)

        XCTAssertNil(EditorSearchHighlighter.validHighlightRange(range, textLength: 12))
    }

    func testSearchHighlighterAcceptsValidRange() {
        let range = NSRange(location: 3, length: 4)

        XCTAssertEqual(EditorSearchHighlighter.validHighlightRange(range, textLength: 12), range)
    }

    func testSearchHighlighterClearRemovesActiveState() {
        let textView = UITextView()
        textView.text = "Hello search highlight"
        let highlighter = EditorSearchHighlighter()

        highlighter.apply(range: NSRange(location: 0, length: 5), in: textView)
        XCTAssertTrue(highlighter.hasActiveHighlight)

        highlighter.clear(in: textView)
        XCTAssertFalse(highlighter.hasActiveHighlight)
    }

    func testRichTextCommitPolicyUsesDeferredEncoderAtCommitBoundary() throws {
        var encodeCount = 0
        let staleData = try XCTUnwrap("stale".data(using: .utf8))
        let expectedData = try XCTUnwrap("fresh serialized".data(using: .utf8))
        let encoder = DeferredRichTextContentEncoder {
            encodeCount += 1
            return expectedData
        }

        XCTAssertEqual(encodeCount, 0)
        let committedData = EditorRichTextCommitPolicy.committedRichTextContentData(
            currentData: staleData,
            pendingEncoder: encoder
        )

        XCTAssertEqual(committedData, expectedData)
        XCTAssertEqual(encodeCount, 1)
    }

    func testRichTextCommitPolicyFallsBackToCurrentDataWithoutDeferredEncoder() throws {
        let currentData = try XCTUnwrap("current serialized".data(using: .utf8))

        XCTAssertEqual(
            EditorRichTextCommitPolicy.committedRichTextContentData(
                currentData: currentData,
                pendingEncoder: nil
            ),
            currentData
        )
    }

    func testIncomingNoteSyncDoesNotOverwriteImmediateLocalTextEdit() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Shared body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)
        vm.selectNote(note)

        vm.commitNoteEdit(note, title: "Shared", content: "Shared body\nDevice B text")

        let deviceANote = Note(title: "Shared", content: "Shared body\nDevice A text")
        deviceANote.id = note.id
        deviceANote.createdAt = note.createdAt
        deviceANote.modifiedAt = note.modifiedAt.addingTimeInterval(1)

        await vm.applyIncomingSyncChanges([
            SyncChange(
                entityType: .item,
                entityID: note.id.uuidString,
                operation: .upsert,
                payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: deviceANote)),
                updatedAt: deviceANote.modifiedAt,
                originDeviceID: "device-a"
            )
        ])

        let conflicts = conflictStore.activeConflicts()
        XCTAssertEqual(note.content, "Shared body\nDevice B text")
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.localText, "Shared body\nDevice B text")
        XCTAssertEqual(conflicts.first?.remoteText, "Shared body\nDevice A text")
        XCTAssertEqual(recorder.recordedChanges.map(\.entityType), [.item, .conflict])
    }

    func testKeepLocalConflictPreservesTextTypedAfterConflictCreation() throws {
        let fixture = try makeActiveNoteContentConflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }
        let typedAfterConflict = "Local before conflict\nTyped after conflict"

        fixture.vm.commitNoteEdit(fixture.note, title: "Shared", content: typedAfterConflict)

        XCTAssertEqual(fixture.note.content, typedAfterConflict)
        XCTAssertEqual(fixture.vm.localText(forSyncConflict: fixture.conflict), typedAfterConflict)
        XCTAssertTrue(fixture.recorder.recordedChanges.isEmpty)

        fixture.vm.markSyncConflictReviewed(fixture.conflict)

        XCTAssertEqual(fixture.note.content, typedAfterConflict)
        XCTAssertTrue(fixture.conflictStore.activeConflicts().isEmpty)
        XCTAssertEqual(
            fixture.conflictStore.remoteBaseline(
                entityType: .note,
                entityID: fixture.note.id,
                field: .noteContent
            )?.text,
            typedAfterConflict
        )
        XCTAssertEqual(fixture.recorder.recordedChanges.count, 1)
        let change = try XCTUnwrap(fixture.recorder.recordedChanges.first)
        XCTAssertEqual(change.entityType, .conflict)
        XCTAssertFalse(fixture.recorder.recordedChanges.contains { $0.entityType == .item })
        let payload = try MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload)
        XCTAssertEqual(payload.action, .resolved)
        XCTAssertEqual(payload.resolvedText, typedAfterConflict)
        XCTAssertEqual(payload.baseText, fixture.conflict.remoteText)
    }

    func testRestoreConflictReplacesTextTypedAfterConflictOnlyWhenIncomingIsSelected() throws {
        let staleIncomingRichTextData = Data("incoming rtf with explicit black foreground".utf8)
        let fixture = try makeActiveNoteContentConflictFixture(remoteRichTextContentData: staleIncomingRichTextData)
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }
        let typedAfterConflict = "Local before conflict\nTyped after conflict"
        fixture.note.richTextContentData = Data("local editor formatting".utf8)

        fixture.vm.commitNoteEdit(fixture.note, title: "Shared", content: typedAfterConflict)

        XCTAssertEqual(fixture.note.content, typedAfterConflict)
        XCTAssertTrue(fixture.recorder.recordedChanges.isEmpty)

        fixture.vm.restoreSyncConflict(fixture.conflict)

        XCTAssertEqual(fixture.note.content, fixture.conflict.remoteText)
        XCTAssertNil(fixture.note.richTextContentData)
        XCTAssertTrue(fixture.conflictStore.activeConflicts().isEmpty)
        XCTAssertEqual(
            fixture.conflictStore.remoteBaseline(
                entityType: .note,
                entityID: fixture.note.id,
                field: .noteContent
            )?.text,
            fixture.conflict.remoteText
        )
        XCTAssertEqual(fixture.recorder.recordedChanges.count, 1)
        let change = try XCTUnwrap(fixture.recorder.recordedChanges.first)
        XCTAssertEqual(change.entityType, .conflict)
        XCTAssertFalse(fixture.recorder.recordedChanges.contains { $0.entityType == .item })
        let payload = try MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload)
        XCTAssertEqual(payload.action, .resolved)
        XCTAssertEqual(payload.resolvedText, fixture.conflict.remoteText)
        XCTAssertEqual(payload.baseText, fixture.conflict.localText)
    }

    func testRestoreConflictPreservesRichTextFormattingWithoutDefaultTextColor() throws {
        let remoteText = "Version to Sync"
        let incomingRichTextData = try makeConflictRichTextData(text: remoteText)
        let fixture = try makeActiveNoteContentConflictFixture(
            remoteText: remoteText,
            remoteRichTextContentData: incomingRichTextData
        )
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }

        fixture.vm.restoreSyncConflict(fixture.conflict)

        let richTextData = try XCTUnwrap(fixture.note.richTextContentData)
        let attributedText = try decodeRichTextData(richTextData)
        XCTAssertEqual(attributedText.string, remoteText)
        XCTAssertNil(attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNotNil(attributedText.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            (attributedText.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? UIColor)?.rgbaTestComponents,
            UIColor.systemRed.rgbaTestComponents
        )
    }

    func testSaveMergedConflictUsesMergedTextAfterPostConflictTyping() throws {
        let fixture = try makeActiveNoteContentConflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }
        let typedAfterConflict = "Local before conflict\nTyped after conflict"
        let mergedText = "\(typedAfterConflict)\nVersion to Sync"

        fixture.vm.commitNoteEdit(fixture.note, title: "Shared", content: typedAfterConflict)

        XCTAssertEqual(fixture.note.content, typedAfterConflict)
        XCTAssertTrue(fixture.recorder.recordedChanges.isEmpty)

        fixture.vm.saveMergedSyncConflict(fixture.conflict, mergedText: mergedText)

        XCTAssertEqual(fixture.note.content, mergedText)
        XCTAssertNotEqual(fixture.note.content, fixture.conflict.localText)
        XCTAssertTrue(fixture.conflictStore.activeConflicts().isEmpty)
        XCTAssertEqual(
            fixture.conflictStore.remoteBaseline(
                entityType: .note,
                entityID: fixture.note.id,
                field: .noteContent
            )?.text,
            mergedText
        )
        XCTAssertEqual(fixture.recorder.recordedChanges.count, 1)
        let change = try XCTUnwrap(fixture.recorder.recordedChanges.first)
        XCTAssertEqual(change.entityType, .conflict)
        XCTAssertFalse(fixture.recorder.recordedChanges.contains { $0.entityType == .item })
        let payload = try MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload)
        XCTAssertEqual(payload.action, .resolved)
        XCTAssertEqual(payload.resolvedText, mergedText)
        XCTAssertEqual(payload.baseText, fixture.conflict.remoteText)
    }

    func testNoteDeleteSyncIsBlockedWhileContentConflictIsActive() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)

        vm.deleteNote(note)

        XCTAssertNotNil(note.deletedAt)
        XCTAssertTrue(recorder.recordedChanges.isEmpty)
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).first, conflict)
    }

    func testPinnedThoughtDeleteSyncIsBlockedWhilePinnedConflictIsActive() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Pinned host")
        note.id = UUID()
        let thought = PinnedThought(text: "Local pinned", order: 0, note: note)
        thought.id = UUID()
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .pinnedThought,
            entityID: thought.id,
            noteID: note.id,
            field: .pinnedText,
            localText: "Local pinned",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)

        vm.deletePinnedParagraph(thought)

        XCTAssertFalse(note.pinnedThoughts.contains { $0.id == thought.id })
        XCTAssertFalse(recorder.recordedChanges.contains { $0.entityType == .marker })
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).first, conflict)
    }

    func testIncomingOrdinaryTextQueuesBehindActiveContentConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let remoteNote = Note(title: "Remote title", content: "Latest Version to Sync")
        remoteNote.id = note.id
        remoteNote.createdAt = note.createdAt
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 300)
        remoteNote.isPinned = true
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMNoteSyncPayload(
                            note: remoteNote,
                            baseTitle: "Shared",
                            baseContent: "Version to Sync"
                        )
                    ),
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, "Local-only text")
        XCTAssertEqual(note.title, "Shared")
        XCTAssertEqual(note.isPinned, false)
        XCTAssertEqual(note.modifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(result.preservedConflicts.isEmpty)
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 301)).first?.remoteText, "Version to Sync")
        XCTAssertEqual(
            conflictStore.queuedConflict(entityType: .note, entityID: note.id, field: .noteContent)?.conflict.remoteText,
            "Latest Version to Sync"
        )
    }

    func testIncomingNoteDeleteIsBlockedWhileContentConflictIsActive() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: "Version to Sync",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let remoteNote = Note(title: "Shared", content: "Local-only text")
        remoteNote.id = note.id
        remoteNote.createdAt = note.createdAt
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 300)
        remoteNote.deletedAt = Date(timeIntervalSince1970: 300)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .item,
                    entityID: note.id.uuidString,
                    operation: .delete,
                    payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(note: remoteNote)),
                    updatedAt: remoteNote.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertNil(note.deletedAt)
        XCTAssertNil(result.deletedCurrentNoteID)
        XCTAssertEqual(note.modifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 301)).first, conflict)
    }

    func testIncomingResolvedSyncConflictAppliesWinnerAndClearsLocalConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Shared", content: "iPhone incoming")
        note.id = UUID()
        note.richTextContentData = Data("stale incoming rich text".utf8)
        context.insert(note)
        let expiresAt = Date().addingTimeInterval(1_000)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Mac kept local",
            remoteText: "iPhone incoming",
            remoteRichTextContentData: Data("incoming rtf with explicit black foreground".utf8),
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: expiresAt
        )
        _ = conflictStore.preserve(conflict)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        let resolvedText = "Mac kept local\niPhone incoming"

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: conflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(
                            action: .resolved,
                            conflict: conflict,
                            resolvedText: resolvedText,
                            baseText: "iPhone incoming",
                            updatedAt: Date(timeIntervalSince1970: 300)
                        )
                    ),
                    updatedAt: Date(timeIntervalSince1970: 300),
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertEqual(note.content, resolvedText)
        XCTAssertNil(note.richTextContentData)
        XCTAssertTrue(conflictStore.activeConflicts().isEmpty)
    }

    func testIncomingResolvedSyncConflictPreservesRichTextFormattingWithoutDefaultTextColor() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let resolvedText = "Version to Sync"
        let note = Note(title: "Shared", content: "Local-only text")
        note.id = UUID()
        context.insert(note)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: "Local-only text",
            remoteText: resolvedText,
            remoteRichTextContentData: try makeConflictRichTextData(text: resolvedText),
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .conflict,
                    entityID: conflict.id.uuidString,
                    operation: .upsert,
                    payload: try MyRAMSyncPayloadCoding.encode(
                        MyRAMSyncConflictPayload(
                            action: .resolved,
                            conflict: conflict,
                            resolvedText: resolvedText,
                            baseText: "Local-only text",
                            updatedAt: Date(timeIntervalSince1970: 300)
                        )
                    ),
                    updatedAt: Date(timeIntervalSince1970: 300),
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        let richTextData = try XCTUnwrap(note.richTextContentData)
        let attributedText = try decodeRichTextData(richTextData)
        XCTAssertEqual(attributedText.string, resolvedText)
        XCTAssertNil(attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNotNil(attributedText.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            (attributedText.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? UIColor)?.rgbaTestComponents,
            UIColor.systemRed.rgbaTestComponents
        )
        XCTAssertTrue(conflictStore.activeConflicts().isEmpty)
    }

    func testDiscardSyncConflictAdvancesLocalNoteTimestamp() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Local title", content: "Local body")
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: note.content,
            remoteText: "Remote body",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = conflictStore.preserve(conflict)
        let service = MyRAMSyncConflictService(context: context, store: conflictStore)

        let result = try XCTUnwrap(service.discard(conflict, activeNoteID: note.id))

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(note.content, "Local body")
        XCTAssertGreaterThan(note.modifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 202)).isEmpty)
    }

    func testIncomingFolderDeletePreservesRenamedFolderAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let folder = Folder(name: "Local folder")
        folder.id = UUID()
        folder.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(folder)
        let remoteFolder = Folder(name: "Remote folder")
        remoteFolder.id = folder.id
        remoteFolder.modifiedAt = Date(timeIntervalSince1970: 200)
        let deletePayload = try MyRAMSyncPayloadCoding.encode(
            MyRAMFolderSyncPayload(folder: remoteFolder, isDeleted: true)
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .collection,
                    entityID: folder.id.uuidString,
                    operation: .delete,
                    payload: deletePayload,
                    updatedAt: remoteFolder.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: folder.id
        )

        let folders = try context.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(folders.contains { $0.id == folder.id })
        let conflict = try XCTUnwrap(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).first)
        XCTAssertEqual(conflict.field, .folderTitle)
        XCTAssertEqual(conflict.localText, "Local folder")
        XCTAssertEqual(conflict.remoteText, "Remote folder")
    }

    func testIncomingNewerFolderTitlePreservesRenamedFolderAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let folder = Folder(name: "Local folder")
        folder.id = UUID()
        folder.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(folder)
        let remoteFolder = Folder(name: "Remote folder")
        remoteFolder.id = folder.id
        remoteFolder.modifiedAt = Date(timeIntervalSince1970: 200)
        let payload = try MyRAMSyncPayloadCoding.encode(MyRAMFolderSyncPayload(folder: remoteFolder))
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        _ = applier.apply(
            [
                SyncChange(
                    entityType: .collection,
                    entityID: folder.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteFolder.modifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: folder.id
        )

        XCTAssertEqual(folder.name, "Local folder")
        let conflict = try XCTUnwrap(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).first)
        XCTAssertEqual(conflict.field, .folderTitle)
        XCTAssertEqual(conflict.localText, "Local folder")
        XCTAssertEqual(conflict.remoteText, "Remote folder")
    }

    func testIncomingPinnedTextDeletePreservesEditedPinnedTextAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Pinned host")
        let thought = PinnedThought(text: "Remote pinned", order: 0, note: note)
        thought.id = UUID()
        thought.modifiedAt = Date(timeIntervalSince1970: 200)
        context.insert(note)
        let deletePayload = try MyRAMSyncPayloadCoding.encode(
            MyRAMPinnedThoughtSyncPayload(thought: thought, isDeleted: true)
        )
        thought.text = "Local pinned"
        thought.modifiedAt = Date(timeIntervalSince1970: 100)
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .marker,
                    entityID: thought.id.uuidString,
                    operation: .delete,
                    payload: deletePayload,
                    updatedAt: Date(timeIntervalSince1970: 200),
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertTrue(result.shouldRefreshActiveNote)
        XCTAssertTrue(note.pinnedThoughts.contains { $0.id == thought.id })
        XCTAssertEqual(thought.text, "Local pinned")
        let conflict = try XCTUnwrap(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).first)
        XCTAssertEqual(conflict.field, .pinnedText)
        XCTAssertEqual(conflict.localText, "Local pinned")
        XCTAssertEqual(conflict.remoteText, "Remote pinned")
    }

    func testIncomingNewerPinnedTextPreservesEditedPinnedTextAsConflict() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let originalNote = Note(title: "Original host")
        let destinationNote = Note(title: "Remote host")
        let thought = PinnedThought(text: "Local pinned", order: 0)
        thought.id = UUID()
        thought.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(originalNote)
        context.insert(destinationNote)
        context.insert(thought)
        originalNote.pinnedThoughts.append(thought)
        try context.save()
        let remoteModifiedAt = Date(timeIntervalSince1970: 200)
        let payload = try JSONEncoder().encode(
            EncodedPinnedThoughtSyncPayload(
                kind: .pinnedThought,
                id: thought.id,
                noteID: destinationNote.id,
                text: "Remote pinned",
                order: 1,
                isCollapsed: false,
                createdAt: thought.createdAt,
                modifiedAt: remoteModifiedAt,
                isDeleted: false,
                baseText: "Shared pinned"
            )
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .marker,
                    entityID: thought.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteModifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: originalNote.id,
            currentNoteID: originalNote.id,
            currentFolderID: nil
        )

        XCTAssertTrue(result.shouldRefreshActiveNote)
        XCTAssertEqual(thought.text, "Local pinned")
        XCTAssertEqual(thought.note?.id, originalNote.id)
        XCTAssertTrue(originalNote.pinnedThoughts.contains { $0.id == thought.id })
        XCTAssertFalse(destinationNote.pinnedThoughts.contains { $0.id == thought.id })
        let conflict = try XCTUnwrap(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).first)
        XCTAssertEqual(conflict.field, .pinnedText)
        XCTAssertEqual(conflict.localText, "Local pinned")
        XCTAssertEqual(conflict.remoteText, "Remote pinned")
    }

    func testIncomingCleanPinnedTextEditAppliesAfterLocalBaselineWasSent() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let note = Note(title: "Pinned host")
        let thought = PinnedThought(text: "Mac pinned", order: 0)
        thought.id = UUID()
        thought.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        context.insert(thought)
        note.pinnedThoughts.append(thought)
        try context.save()
        conflictStore.savePinnedTextBaseline(
            thoughtID: thought.id,
            text: "Mac pinned",
            modifiedAt: thought.modifiedAt,
            originDeviceID: "device-a"
        )
        let remoteModifiedAt = Date(timeIntervalSince1970: 200)
        let payload = try JSONEncoder().encode(
            EncodedPinnedThoughtSyncPayload(
                kind: .pinnedThought,
                id: thought.id,
                noteID: note.id,
                text: "iPhone pinned",
                order: 0,
                isCollapsed: false,
                createdAt: thought.createdAt,
                modifiedAt: remoteModifiedAt,
                isDeleted: false,
                baseText: "Mac pinned"
            )
        )
        let applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)

        let result = applier.apply(
            [
                SyncChange(
                    entityType: .marker,
                    entityID: thought.id.uuidString,
                    operation: .upsert,
                    payload: payload,
                    updatedAt: remoteModifiedAt,
                    originDeviceID: "device-b"
                )
            ],
            activeNoteID: note.id,
            currentNoteID: note.id,
            currentFolderID: nil
        )

        XCTAssertTrue(result.shouldRefreshActiveNote)
        XCTAssertEqual(thought.text, "iPhone pinned")
        XCTAssertTrue(conflictStore.activeConflicts(now: Date(timeIntervalSince1970: 201)).isEmpty)
        XCTAssertEqual(
            conflictStore.remoteBaseline(entityType: .pinnedThought, entityID: thought.id, field: .pinnedText)?.text,
            "iPhone pinned"
        )
    }

    func testAcknowledgedLocalPinnedTextChangeAdvancesSyncBaseline() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let vm = NotesViewModel(context: context)
        let note = Note(title: "Pinned host")
        note.id = UUID()
        let thought = PinnedThought(text: "Synced pinned", order: 0)
        thought.id = UUID()
        thought.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        context.insert(thought)
        note.pinnedThoughts.append(thought)
        try context.save()
        let acknowledgedChange = SyncChange(
            entityType: .marker,
            entityID: thought.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMPinnedThoughtSyncPayload(thought: thought)),
            updatedAt: thought.modifiedAt,
            originDeviceID: "device-a"
        )
        await vm.advanceSyncBaselines(forAcknowledgedLocalChanges: [acknowledgedChange])
        let remoteModifiedAt = Date(timeIntervalSince1970: 200)

        await vm.applyIncomingSyncChanges([
            SyncChange(
                entityType: .marker,
                entityID: thought.id.uuidString,
                operation: .upsert,
                payload: try JSONEncoder().encode(
                    EncodedPinnedThoughtSyncPayload(
                        kind: .pinnedThought,
                        id: thought.id,
                        noteID: note.id,
                        text: "Peer pinned",
                        order: 0,
                        isCollapsed: false,
                        createdAt: thought.createdAt,
                        modifiedAt: remoteModifiedAt,
                        isDeleted: false,
                        baseText: "Synced pinned"
                    )
                ),
                updatedAt: remoteModifiedAt,
                originDeviceID: "device-b"
            )
        ])

        XCTAssertEqual(thought.text, "Peer pinned")
        XCTAssertTrue(vm.activeSyncConflicts(for: note).isEmpty)
    }

    func testWarmPaperAppearanceUsesIconPalette() {
        XCTAssertFalse(AppearanceSetting.allCases.map(\.title).contains("Warm Paper"))
        XCTAssertFalse(EditorChromeStyle.allCases.map(\.title).contains("Standard"))
        XCTAssertEqual(EditorChromeStyle.standard.title, "None")
        XCTAssertEqual(EditorChromeStyle.warmPaper.title, "Warm Paper")
        XCTAssertEqual(EditorChromeStyle.chromeAccent.title, "Chrome Accent")
        XCTAssertTrue(EditorChromeStyle.chromeAccent.isChromeAccent)
        XCTAssertFalse(EditorChromeStyle.standard.isChromeAccent)
        XCTAssertTrue(EditorChromeStyle.warmPaper.isWarmPaper)
        XCTAssertTrue(EditorChromeStyle.allCases.contains(.warmPaper))
        XCTAssertTrue(EditorChromeStyle.allCases.contains(.chromeAccent))
        XCTAssertNil(EditorChromeStyle.warmPaper.colorSchemeOverride)
        XCTAssertNil(EditorChromeStyle.standard.editorTintUIColor)
        XCTAssertEqual(
            EditorChromeStyle.warmPaper.editorTintUIColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
            WarmPaperPalette.accentUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        )
        XCTAssertGreaterThan(
            contrastRatio(
                foreground: UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
                background: WarmPaperPalette.surfaceUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            ),
            4.5
        )
        XCTAssertGreaterThan(
            contrastRatio(
                foreground: UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
                background: WarmPaperPalette.surfaceUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(
                foreground: WarmPaperPalette.toolbarUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
                background: WarmPaperPalette.backgroundUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            ),
            1.09
        )
        XCTAssertGreaterThan(
            contrastRatio(
                foreground: WarmPaperPalette.controlUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
                background: WarmPaperPalette.toolbarUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            ),
            1.1
        )
        XCTAssertGreaterThan(
            contrastRatio(
                foreground: WarmPaperPalette.controlUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
                background: WarmPaperPalette.toolbarUIColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            ),
            1.1
        )
    }

    private struct NoteIntelligenceRuleSpec: Decodable {
        struct Rule: Decodable {
            let id: String
            let label: String
            let priority: Int
            let conditions: [String: [String]]
            let rationale: String
        }

        let specVersion: Int
        let specName: String
        let labels: [String]
        let rules: [Rule]
    }

    private struct NoteIntelligenceFixture: Decodable {
        struct Input: Decodable {
            struct Features: Decodable {
                let lemmas: [String]
                let tokens: [String]
                let openCount30d: Int
                let editCount7d: Int
                let firstPersonRatio: Double

                enum CodingKeys: String, CodingKey {
                    case lemmas
                    case tokens
                    case openCount30d = "open_count_30d"
                    case editCount7d = "edit_count_7d"
                    case firstPersonRatio = "first_person_ratio"
                }
            }

            struct Entities: Decodable {
                let datetimes: [String]
                let emails: [String]
                let phones: [String]
                let urls: [String]
                let addresses: [String]
            }

            let noteId: String
            let text: String
            let language: String
            let createdAt: String
            let modifiedAt: String
            let features: Features
            let entities: Entities
            let similarNoteIds: [String]

            enum CodingKeys: String, CodingKey {
                case noteId = "note_id"
                case text
                case language
                case createdAt = "created_at"
                case modifiedAt = "modified_at"
                case features
                case entities
                case similarNoteIds = "similar_note_ids"
            }
        }

        let fixtureId: String
        let input: Input
        let expectedLabels: [String]

        enum CodingKeys: String, CodingKey {
            case fixtureId = "fixture_id"
            case input
            case expectedLabels = "expected_labels"
        }
    }

    func testCreateFolderSupportsRootAndNestedHierarchy() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let rootFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" }))
        XCTAssertNil(rootFolder.parentFolder)

        vm.openFolder(rootFolder)
        vm.createFolder(named: "Client A")
        let nestedFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Client A" }))

        XCTAssertEqual(nestedFolder.parentFolder?.id, rootFolder.id)
    }

    func testDebugBuildUsesDevelopmentBundleIdentifier() {
#if DEBUG
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(
            bundleIdentifier == "com.apexcoretechs.MyRAM.dev"
                || bundleIdentifier == "com.northsignalstudio.myram.dev",
            "Debug runs should use a MyRAM app bundle identifier."
        )
#endif
    }

    func testNoteIntelligenceRuleSpecV1HasExpectedVersionAndUniqueRuleIds() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )

        XCTAssertEqual(spec.specVersion, 1)
        XCTAssertEqual(spec.specName, "note_intelligence_rules")
        XCTAssertEqual(Set(spec.labels).count, spec.labels.count, "Labels should be unique.")
        XCTAssertFalse(spec.rules.isEmpty)

        let ruleIDs = spec.rules.map(\.id)
        XCTAssertEqual(Set(ruleIDs).count, ruleIDs.count, "Rule IDs should be unique.")
        XCTAssertTrue(spec.rules.allSatisfy { spec.labels.contains($0.label) })
        XCTAssertTrue(spec.rules.allSatisfy { $0.priority >= 0 && $0.priority <= 100 })
    }

    func testNoteIntelligenceFixturesOnlyUseKnownLabels() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )
        let knownLabels = Set(spec.labels)
        let fixtures = try loadNoteIntelligenceFixtures()
        XCTAssertEqual(fixtures.count, 8)

        for fixture in fixtures {
            XCTAssertFalse(fixture.expectedLabels.isEmpty, "Fixture must include expected labels: \(fixture.fixtureId)")
            XCTAssertEqual(
                Set(fixture.expectedLabels).count,
                fixture.expectedLabels.count,
                "Fixture labels should be unique: \(fixture.fixtureId)"
            )
            XCTAssertTrue(
                fixture.expectedLabels.allSatisfy { knownLabels.contains($0) },
                "Fixture contains unknown label: \(fixture.fixtureId)"
            )
        }
    }

    func testNoteIntelligenceFixturesHaveBaselineCanonicalInputShape() throws {
        let fixtures = try loadNoteIntelligenceFixtures()

        for fixture in fixtures {
            XCTAssertFalse(fixture.fixtureId.isEmpty)
            XCTAssertFalse(fixture.input.noteId.isEmpty)
            XCTAssertFalse(fixture.input.text.isEmpty)
            XCTAssertGreaterThanOrEqual(fixture.input.language.count, 2)
            XCTAssertGreaterThanOrEqual(fixture.input.features.openCount30d, 0)
            XCTAssertGreaterThanOrEqual(fixture.input.features.editCount7d, 0)
            XCTAssertGreaterThanOrEqual(fixture.input.features.firstPersonRatio, 0)
            XCTAssertLessThanOrEqual(fixture.input.features.firstPersonRatio, 1)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: fixture.input.createdAt))
            XCTAssertNotNil(ISO8601DateFormatter().date(from: fixture.input.modifiedAt))
        }
    }

    func testNoteIntelligenceRuleSpecUsesSupportedConditionKeysAndNames() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )
        let supportedConditionNames: Set<String> = [
            "contains_action_verb",
            "has_datetime_entity",
            "contains_event_phrase",
            "contains_followup_phrase",
            "has_datetime_or_contact_entity",
            "contains_idea_phrase",
            "not_contains_action_verb",
            "contains_reflective_phrase",
            "first_person_ratio_high",
            "open_count_above_threshold",
            "edited_recently_multiple_times",
            "text_similarity_above_threshold",
            "shares_topic_keywords"
        ]

        for rule in spec.rules {
            for (conditionKey, conditionNames) in rule.conditions {
                XCTAssertTrue(
                    conditionKey == "all" || conditionKey == "any",
                    "Unexpected condition key in rule \(rule.id): \(conditionKey)"
                )
                XCTAssertTrue(
                    conditionNames.allSatisfy { supportedConditionNames.contains($0) },
                    "Rule uses unsupported condition name: \(rule.id)"
                )
            }
        }
    }

    func testNoteIntelligenceRuntimeEvaluatorMatchesFixtureExpectedLabels() throws {
        let fixtures = try loadNoteIntelligenceFixtures()
        let service = NoteIntelligenceService()

        for fixture in fixtures {
            let labels = Set(service.evaluateCanonicalInput(canonicalInput(from: fixture)))
            XCTAssertEqual(
                labels,
                Set(fixture.expectedLabels),
                "Runtime evaluator mismatch for fixture: \(fixture.fixtureId)"
            )
        }
    }

    func testCreateNewNoteUsesCurrentFolderContext() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.openFolder(workFolder)
        let nestedNote = vm.createNewNote()

        XCTAssertEqual(nestedNote.folder?.id, workFolder.id)

        vm.navigateToParentFolder()
        let rootNote = vm.createNewNote()
        XCTAssertNil(rootNote.folder)
    }

    func testRootListIncludesPinnedNotesFromOtherFoldersOnly() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let rootNote = vm.createNewNote()

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.openFolder(workFolder)
        let pinnedWorkNote = vm.createNewNote()
        let unpinnedWorkNote = vm.createNewNote()
        vm.setNotePinned(pinnedWorkNote, isPinned: true)

        vm.navigateToParentFolder()
        vm.refreshCurrentFolderContent()

        let visibleNoteIDs = Set(vm.notes.map(\.id))
        XCTAssertTrue(visibleNoteIDs.contains(rootNote.id))
        XCTAssertTrue(visibleNoteIDs.contains(pinnedWorkNote.id))
        XCTAssertFalse(visibleNoteIDs.contains(unpinnedWorkNote.id))
    }

    func testFolderListIncludesPinnedNotesFromOtherFoldersOnly() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let rootNote = vm.createNewNote()

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.openFolder(workFolder)
        let pinnedWorkNote = vm.createNewNote()
        let unpinnedWorkNote = vm.createNewNote()
        vm.setNotePinned(pinnedWorkNote, isPinned: true)

        vm.navigateToParentFolder()
        vm.createFolder(named: "Personal")
        let personalFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Personal" }))
        vm.openFolder(personalFolder)
        let personalNote = vm.createNewNote()

        let visibleNoteIDs = Set(vm.notes.map(\.id))
        XCTAssertTrue(visibleNoteIDs.contains(pinnedWorkNote.id))
        XCTAssertTrue(visibleNoteIDs.contains(personalNote.id))
        XCTAssertFalse(visibleNoteIDs.contains(rootNote.id))
        XCTAssertFalse(visibleNoteIDs.contains(unpinnedWorkNote.id))
    }

    func testCurrentFolderListItemsOrdersPinnedNotesFoldersThenRegularNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let regularRootNote = vm.createNewNote()
        let pinnedRootNote = vm.createNewNote()
        vm.setNotePinned(pinnedRootNote, isPinned: true)
        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))

        let listItemIDs = vm.currentFolderListItems().map(\.id)

        XCTAssertEqual(listItemIDs, [
            "note-\(pinnedRootNote.id.uuidString)",
            "folder-\(workFolder.id.uuidString)",
            "note-\(regularRootNote.id.uuidString)"
        ])
    }

    func testActiveNoteCountInFolderExcludesDeletedNotesAndOtherFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))

        vm.openFolder(folderA)
        _ = vm.createNewNote()
        let deletedNote = vm.createNewNote()
        vm.deleteNote(deletedNote)

        vm.openFolder(folderB)
        _ = vm.createNewNote()

        XCTAssertEqual(vm.activeNoteCount(in: folderA), 1)
        XCTAssertEqual(vm.activeNoteCount(in: folderB), 1)
    }

    func testActiveNoteCountInFolderIncludesNestedFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Parent")
        let parentFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Parent" }))
        vm.openFolder(parentFolder)
        vm.createFolder(named: "Child")
        let childFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Child" }))

        vm.openFolder(childFolder)
        _ = vm.createNewNote()
        _ = vm.createNewNote()
        let deletedNestedNote = vm.createNewNote()
        vm.deleteNote(deletedNestedNote)

        XCTAssertEqual(vm.activeNoteCount(in: childFolder), 2)
        XCTAssertEqual(vm.activeNoteCount(in: parentFolder), 2)
    }

    func testFetchRecentlyDeletedNotesLoadsPreexistingDeletedNotesOnInit() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let preexistingDeletedNote = Note(title: "Deleted Earlier", content: "Body")
        preexistingDeletedNote.deletedAt = Date()
        context.insert(preexistingDeletedNote)
        try context.save()

        let vm = NotesViewModel(context: context)
        let deletedNotes = vm.fetchRecentlyDeletedNotes()

        XCTAssertTrue(deletedNotes.contains(where: { $0.id == preexistingDeletedNote.id }))
    }

    func testRefreshRecentlyDeletedNotesPurgesExpiredDeletedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        let staleDeletedNote = Note(title: "Old Deleted", content: "Expired")
        staleDeletedNote.deletedAt = Date().addingTimeInterval(-(8 * 24 * 60 * 60))
        context.insert(staleDeletedNote)

        let recentDeletedNote = Note(title: "New Deleted", content: "Active")
        recentDeletedNote.deletedAt = Date()
        context.insert(recentDeletedNote)

        try context.save()

        let vm = NotesViewModel(context: context)
        vm.refreshRecentlyDeletedNotes()
        let deletedNotes = vm.fetchRecentlyDeletedNotes()

        XCTAssertFalse(deletedNotes.contains(where: { $0.id == staleDeletedNote.id }))
        XCTAssertTrue(deletedNotes.contains(where: { $0.id == recentDeletedNote.id }))
    }

#if DEBUG
    func testDebugDemoDataGeneratorCreatesExpectedNotesAndPinnedThoughts() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let demoNotes = notes.filter { DebugDemoDataGenerator.demoNoteIDs.contains($0.id) }
        XCTAssertEqual(demoNotes.count, 8)

        let todayNote = try XCTUnwrap(demoNotes.first { $0.title == "TODAY - Jun 3, 2026" })
        XCTAssertFalse(todayNote.content.contains("Ask landlord about garage opener"))
        XCTAssertEqual(todayNote.pinnedThoughts.map(\.text), ["Ask landlord about garage opener"])
        XCTAssertTrue(todayNote.content.contains("Need to remember to move the laundry before bed."))

        let noPinnedThoughtsNote = try XCTUnwrap(demoNotes.first { $0.title == "Stuff To Figure Out" })
        XCTAssertTrue(noPinnedThoughtsNote.pinnedThoughts.isEmpty)
    }

    func testDebugDemoDataGeneratorIsSafeToRunRepeatedly() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)
        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let demoNotes = notes.filter { DebugDemoDataGenerator.demoNoteIDs.contains($0.id) }
        XCTAssertEqual(demoNotes.count, 8)
        XCTAssertEqual(Set(demoNotes.map(\.id)).count, 8)
    }

    func testDebugDemoDataGeneratorClearPreservesUserNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let userNote = Note(title: "User Note", content: "Keep this")
        container.mainContext.insert(userNote)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)
        DebugDemoDataGenerator.clearDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.map(\.id), [userNote.id])
        XCTAssertEqual(notes.first?.title, "User Note")
    }
#endif

    func testDeleteFolderPreservingNotesMovesNotesToTopLevel() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let parent = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" }))
        vm.openFolder(parent)
        let parentNote = vm.createNewNote()
        vm.createFolder(named: "Client")
        let child = try XCTUnwrap(vm.folders.first(where: { $0.name == "Client" }))
        vm.openFolder(child)
        let childNote = vm.createNewNote()

        vm.deleteFolder(parent, preserveNotes: true)

        let remainingFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(remainingFolders.isEmpty)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let preservedParentNote = try XCTUnwrap(notes.first(where: { $0.id == parentNote.id }))
        let preservedChildNote = try XCTUnwrap(notes.first(where: { $0.id == childNote.id }))
        XCTAssertNil(preservedParentNote.folder)
        XCTAssertNil(preservedChildNote.folder)
    }

    func testDeleteFolderWithoutPreservingNotesSoftDeletesContainedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Temp")
        let folder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Temp" }))
        vm.openFolder(folder)
        let note = vm.createNewNote()

        vm.deleteFolder(folder, preserveNotes: false)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let deletedNote = try XCTUnwrap(notes.first(where: { $0.id == note.id }))
        XCTAssertNotNil(deletedNote.deletedAt)
        XCTAssertNil(deletedNote.folder)
    }

    func testRenameFolderUpdatesNameWhenProvidedNonEmptyValue() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Old Name")
        let folder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Old Name" }))

        vm.renameFolder(folder, to: "  New Name  ")

        XCTAssertEqual(folder.name, "New Name")
    }

    func testMoveNoteSupportsTopLevelAndFolderDestinations() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let rootNote = vm.createNewNote()
        XCTAssertNil(rootNote.folder)

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.moveNote(rootNote, to: workFolder)
        XCTAssertEqual(rootNote.folder?.id, workFolder.id)

        vm.moveNote(rootNote, to: nil)
        XCTAssertNil(rootNote.folder)
    }

    func testMoveNoteBetweenFoldersChangesParentFolder() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))

        vm.openFolder(folderA)
        let note = vm.createNewNote()
        XCTAssertEqual(note.folder?.id, folderA.id)

        vm.moveNote(note, to: folderB)
        XCTAssertEqual(note.folder?.id, folderB.id)
    }

    func testUndoRedoLastActionMovesNoteBetweenFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))
        vm.openFolder(folderA)
        let note = vm.createNewNote()

        vm.moveNote(note, to: folderB)
        XCTAssertEqual(note.folder?.id, folderB.id)

        vm.undoLastAction()
        XCTAssertEqual(note.folder?.id, folderA.id)
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        XCTAssertEqual(note.folder?.id, folderB.id)
    }

    func testUndoRedoLastActionTogglesCreatedNoteVisibility() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let note = vm.createNewNote()
        XCTAssertNil(note.deletedAt)

        vm.undoLastAction()
        XCTAssertNotNil(note.deletedAt)
        XCTAssertFalse(vm.notes.contains { $0.id == note.id })
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        XCTAssertNil(note.deletedAt)
        XCTAssertTrue(vm.notes.contains { $0.id == note.id })
    }

    func testUndoRedoLastActionTogglesCreatedFolderVisibility() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let folderID = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" })?.id)

        vm.undoLastAction()
        var folders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertFalse(folders.contains { $0.id == folderID })
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        folders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(folders.contains { $0.id == folderID })
    }

    func testAddPhotoAttachmentStoresImageOnNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let imageData = try makeJPEGData()

        vm.addPhotoAttachment(to: note, imageData: imageData)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let fetched = try XCTUnwrap(notes.first { $0.id == note.id })
        XCTAssertEqual(fetched.photoAttachments.count, 1)
        XCTAssertFalse(fetched.photoAttachments[0].imageData.isEmpty)
    }

    func testRemovePhotoAttachmentDeletesAttachment() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let imageData = try makeJPEGData()

        vm.addPhotoAttachment(to: note, imageData: imageData)
        vm.addPhotoAttachment(to: note, imageData: imageData)

        let attachmentToRemove = try XCTUnwrap(note.photoAttachments.first)
        vm.removePhotoAttachment(attachmentToRemove, from: note)

        XCTAssertEqual(note.photoAttachments.count, 1)
        XCTAssertFalse(note.photoAttachments.contains { $0.id == attachmentToRemove.id })
    }

    func testPinnedThoughtsCanBeAddedEditedDraggedAndUnpinnedWithoutChangingBody() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        note.content = "Body text"
        note.richTextContentData = Data("rich body".utf8)

        let first = try XCTUnwrap(vm.addPinnedThought(to: note, text: "First thought"))
        let second = try XCTUnwrap(vm.addPinnedThought(to: note, text: "Second thought"))

        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["First thought", "Second thought"])

        vm.updatePinnedThought(first, text: "  Updated first  ")
        vm.setPinnedThoughtCollapsed(first, isCollapsed: true)
        vm.movePinnedThought(second, before: first)

        let reordered = vm.sortedPinnedThoughts(for: note)
        XCTAssertEqual(reordered.map(\.text), ["Second thought", "Updated first"])
        XCTAssertTrue(first.isCollapsed)
        XCTAssertEqual(reordered.map(\.order), [0, 1])

        vm.movePinnedThought(second, toIndex: 2)
        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["Updated first", "Second thought"])

        vm.unpinThought(first)

        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["Second thought"])
        XCTAssertEqual(note.content, "Body text")
        XCTAssertEqual(note.richTextContentData, Data("rich body".utf8))
    }

    func testPinnedTextCommitTrimsOnlyWhenUpdatingModel() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let pinnedText = try XCTUnwrap(vm.addPinnedThought(to: note, text: "Initial"))

        vm.updatePinnedThought(pinnedText, text: "One space ")

        XCTAssertEqual(pinnedText.text, "One space")
    }

    func testSelectionFormattingCacheMarksMovedSelectionDirty() {
        var cache = EditorSelectionFormattingCache()
        let range = NSRange(location: 8, length: 24)

        cache.update(range: NSRange(location: 0, length: 1), formattingState: EditorFormattingState(), isApproximate: false)
        cache.markDirty(range: range)

        XCTAssertEqual(cache.range, range)
        XCTAssertTrue(cache.formattingStateIsDirty)
    }

    func testSelectionFormattingCacheStoresFreshFormattingState() {
        var cache = EditorSelectionFormattingCache()
        let range = NSRange(location: 3, length: 4)
        let state = EditorFormattingState(bold: true, italic: true, underline: false, strikethrough: false)

        cache.update(range: range, formattingState: state, isApproximate: false)

        XCTAssertEqual(cache.range, range)
        XCTAssertEqual(cache.formattingState, state)
        XCTAssertFalse(cache.formattingStateIsDirty)
        XCTAssertFalse(cache.formattingStateIsApproximate)
    }

    func testSelectionFormattingCacheTracksApproximateFormattingState() {
        var cache = EditorSelectionFormattingCache()
        let state = EditorFormattingState(underline: true)

        cache.update(
            range: NSRange(location: 0, length: EditorSelectionFormattingPolicy.largeSelectionFormattingThreshold + 1),
            formattingState: state,
            isApproximate: true
        )

        XCTAssertEqual(cache.formattingState, state)
        XCTAssertTrue(cache.formattingStateIsApproximate)
    }

    func testTextPlacementResolverUsesLeadingBlankLineCaret() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        textView.font = UIFont.systemFont(ofSize: 20)
        textView.text = "\nSome existing content\nMore content"
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)
        textView.layoutIfNeeded()

        let range = EditorTextPlacementResolver.caretRange(
            forTapLocation: CGPoint(x: 16, y: 10),
            in: textView
        )

        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func testPinnedThoughtExpansionStateDefaultsCollapsedAndPersistsPerSessionNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let firstNote = vm.createNewNote()
        let secondNote = vm.createNewNote()

        XCTAssertFalse(vm.isPinnedThoughtsSectionExpanded(for: firstNote))
        XCTAssertFalse(vm.isPinnedThoughtsSectionExpanded(for: secondNote))

        vm.setPinnedThoughtsSectionExpanded(true, for: firstNote)

        XCTAssertTrue(vm.isPinnedThoughtsSectionExpanded(for: firstNote))
        XCTAssertFalse(vm.isPinnedThoughtsSectionExpanded(for: secondNote))

        vm.setPinnedThoughtsSectionExpanded(false, for: firstNote)

        XCTAssertFalse(vm.isPinnedThoughtsSectionExpanded(for: firstNote))
    }

    func testPinnedParagraphCanBeDeletedWithoutRestoringToBody() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        note.content = "Body text"
        note.richTextContentData = Data("rich body".utf8)

        let paragraph = try XCTUnwrap(vm.addPinnedThought(to: note, text: "Delete this"))

        vm.deletePinnedParagraph(paragraph)

        XCTAssertTrue(vm.sortedPinnedThoughts(for: note).isEmpty)
        XCTAssertEqual(note.content, "Body text")
        XCTAssertEqual(note.richTextContentData, Data("rich body".utf8))
    }

    func testChecklistPinCandidateExtractsThoughtAndSourceLineForMove() throws {
        let sourceText = "Before\n☐ Follow up on pinned thought\nAfter" as NSString
        let selection = NSRange(location: sourceText.range(of: "Follow up").location, length: 6)

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: selection
        ))

        XCTAssertEqual(candidate.text, "Follow up on pinned thought")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "☐ Follow up on pinned thought\n")
    }

    func testPinCandidateIgnoresSelectionAndUsesEntireCursorLine() throws {
        let sourceText = "Before\nPin this entire line please\nAfter" as NSString
        let selectedWordRange = sourceText.range(of: "entire")

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: selectedWordRange
        ))

        XCTAssertEqual(candidate.text, "Pin this entire line please")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "Pin this entire line please\n")
    }

    func testPinCandidateIgnoresMultiLineSelectionAndUsesStartLine() throws {
        let sourceText = "Before\nPin this first selected line\nDo not pin this line\nAfter" as NSString
        let selectionStart = sourceText.range(of: "first").location
        let selectionEnd = sourceText.range(of: "Do not pin this line").location + "Do not pin this line".utf16.count
        let multiLineSelection = NSRange(location: selectionStart, length: selectionEnd - selectionStart)

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: multiLineSelection
        ))

        XCTAssertEqual(candidate.text, "Pin this first selected line")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "Pin this first selected line\n")
    }

    func testPinCandidateUsesCursorLineWhenSelectionIsCollapsed() throws {
        let sourceText = "Before\nPin this line from cursor\nAfter" as NSString
        let cursorLocation = sourceText.range(of: "from").location

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: NSRange(location: cursorLocation, length: 0)
        ))

        XCTAssertEqual(candidate.text, "Pin this line from cursor")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "Pin this line from cursor\n")
    }

    func testPinnedThoughtsPersistAcrossContainerReinit() throws {
        let storeName = "MyRAMPinnedThoughtTests-\(UUID().uuidString)"
        let noteID: UUID

        do {
            let container = try makeContainer(
                isStoredInMemoryOnly: false,
                configurationName: storeName
            )
            let vm = NotesViewModel(context: container.mainContext)
            let note = vm.createNewNote()
            noteID = note.id

            _ = vm.addPinnedThought(to: note, text: "Remember this")
        }

        let reopenedContainer = try makeContainer(
            isStoredInMemoryOnly: false,
            configurationName: storeName
        )
        let reopenedContext = reopenedContainer.mainContext
        let reopenedNotes = try reopenedContext.fetch(FetchDescriptor<Note>())
        let reopenedNote = try XCTUnwrap(reopenedNotes.first { $0.id == noteID })

        XCTAssertEqual(reopenedNote.pinnedThoughts.map(\.text), ["Remember this"])
    }

    func testAttachmentsPersistAcrossContainerReinit() throws {
        let storeName = "MyRAMTests-\(UUID().uuidString)"
        let noteID: UUID

        do {
            let container = try makeContainer(
                isStoredInMemoryOnly: false,
                configurationName: storeName
            )
            let vm = NotesViewModel(context: container.mainContext)
            let note = vm.createNewNote()
            let imageData = try makeJPEGData()

            vm.addPhotoAttachment(to: note, imageData: imageData)
            noteID = note.id
        }

        let reopenedContainer = try makeContainer(
            isStoredInMemoryOnly: false,
            configurationName: storeName
        )
        let reopenedContext = reopenedContainer.mainContext
        let reopenedNotes = try reopenedContext.fetch(FetchDescriptor<Note>())
        let reopenedNote = try XCTUnwrap(reopenedNotes.first { $0.id == noteID })

        XCTAssertEqual(reopenedNote.photoAttachments.count, 1)
    }

    func testUpdateNoteKeepsExistingNotesWithoutAttachmentsCompatible() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.updateNote(note, title: "Title", content: "Content")

        XCTAssertEqual(note.title, "Title")
        XCTAssertEqual(note.content, "Content")
        XCTAssertTrue(note.photoAttachments.isEmpty)
    }

    func testUpdateNotePersistsRichTextDataAlongsidePlainText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        let attributedText = NSAttributedString(
            string: "Styled note",
            attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        )
        let richTextData = try XCTUnwrap(RichTextContentCodec.encode(attributedText))

        vm.updateNote(
            note,
            title: "Styled",
            content: attributedText.string,
            richTextContentData: richTextData
        )

        XCTAssertEqual(note.title, "Styled")
        XCTAssertEqual(note.content, "Styled note")
        XCTAssertEqual(note.richTextContentData, richTextData)
    }

    func testRichTextCodecFallsBackToPlainTextWhenRichDataMissing() {
        let decoded = RichTextContentCodec.decode(
            richTextData: nil,
            plainText: "Plain body",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        XCTAssertEqual(decoded.string, "Plain body")
    }

    func testRichTextCodecRoundTripPreservesAttributedContent() throws {
        let mutable = NSMutableAttributedString(string: "Bold Italic")
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: fullRange)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        let encoded = try XCTUnwrap(RichTextContentCodec.encode(mutable))

        let decoded = RichTextContentCodec.decode(
            richTextData: encoded,
            plainText: "",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        XCTAssertEqual(decoded.string, "Bold Italic")
        let underlineValue = decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underlineValue, NSUnderlineStyle.single.rawValue)
    }

    func testRichTextCodecRoundTripPreservesConcreteFontSize() throws {
        let mutable = NSMutableAttributedString(string: "Sized")
        mutable.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 24),
            range: NSRange(location: 0, length: mutable.length)
        )
        let encoded = try XCTUnwrap(RichTextContentCodec.encode(mutable))

        let decoded = RichTextContentCodec.decode(
            richTextData: encoded,
            plainText: "",
            baseFont: UIFont.systemFont(ofSize: 17)
        )

        let decodedFont = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(decodedFont.pointSize, 24, accuracy: 0.5)
    }

    func testRichTextCodecRoundTripPreservesForegroundColor() throws {
        let expectedColor = UIColor(red: 0.85, green: 0.18, blue: 0.12, alpha: 1)
        let mutable = NSMutableAttributedString(string: "Color")
        mutable.addAttribute(
            .foregroundColor,
            value: expectedColor,
            range: NSRange(location: 0, length: mutable.length)
        )

        let encoded = try XCTUnwrap(RichTextContentCodec.encode(mutable))
        let decoded = RichTextContentCodec.decode(
            richTextData: encoded,
            plainText: "",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        let decodedColor = try XCTUnwrap(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(decodedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0.85, accuracy: 0.01)
        XCTAssertEqual(green, 0.18, accuracy: 0.01)
        XCTAssertEqual(blue, 0.12, accuracy: 0.01)
        XCTAssertEqual(alpha, 1, accuracy: 0.01)
    }

    func testRichTextDisplayNormalizationPreservesExplicitBlackInDarkMode() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: 1))
        mutable.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            UIColor.black
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemRed
        )
    }

    func testRichTextDisplayNormalizationPaintsAutoTextWithCurrentDefaultColor() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 1, length: 1))
        let defaultTextColor = UIColor.label

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark),
            defaultTextColor: defaultTextColor
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            defaultTextColor
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.black
        )
    }

    func testRichTextDisplayNormalizationPreservesExplicitWhiteInLightMode() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: 1))
        mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .light)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            UIColor.white
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemBlue
        )
    }

    func testRichTextDisplayNormalizationPreservesExplicitDarkGrayInDarkMode() {
        let expectedColor = UIColor(white: 0.2, alpha: 1)
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(
            .foregroundColor,
            value: expectedColor,
            range: NSRange(location: 0, length: 1)
        )
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            expectedColor
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemGreen
        )
    }

    func testNoteEditorOverflowActionPriorityMatchesEditorSpec() {
        XCTAssertEqual(
            NoteEditorOverflowAction.priorityOrder,
            [
                .search,
                .newNote,
                .newFolder,
                .exportNote,
                .attachments,
                .deleteNote
            ]
        )
    }

    func testNoteEditorOverflowActionPriorityIncludesEachActionOnce() {
        XCTAssertEqual(
            Set(NoteEditorOverflowAction.priorityOrder),
            Set(NoteEditorOverflowAction.allCases)
        )
        XCTAssertEqual(
            NoteEditorOverflowAction.priorityOrder.count,
            NoteEditorOverflowAction.allCases.count
        )
    }

    func testBuildNoteExportTextIncludesReadableFieldsForSingleNote() throws {
        let note = Note(title: "Trip Plan", content: "Book flights")
        note.createdAt = Date(timeIntervalSince1970: 1000)
        note.modifiedAt = Date(timeIntervalSince1970: 2000)
        let dateFormatter: (Date) -> String = { date in
            let seconds = Int(date.timeIntervalSince1970)
            return "TS-\(seconds)"
        }

        let exported = NotesViewModel.buildNoteExportText(
            for: note,
            exportedAt: Date(timeIntervalSince1970: 3000),
            dateFormatter: dateFormatter
        )

        XCTAssertTrue(exported.contains("MyRAM Notes Export"))
        XCTAssertTrue(exported.contains("Exported: TS-3000"))
        XCTAssertTrue(exported.contains("Title: Trip Plan"))
        XCTAssertTrue(exported.contains("Created: TS-1000"))
        XCTAssertTrue(exported.contains("Modified: TS-2000"))
        XCTAssertTrue(exported.contains("Pinned:\n(None)"))
        XCTAssertTrue(exported.contains("Body:\nBook flights"))
    }

    func testExportNotesForSharingSingleNoteCreatesStructuredJSONFileAndImageFiles() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        vm.updateNote(note, title: "Daily Log", content: "UTF-8 test ✅")
        note.createdAt = Date(timeIntervalSince1970: 1000)
        note.modifiedAt = Date(timeIntervalSince1970: 2000)
        _ = vm.addPinnedThought(to: note, text: "Review receipt")
        let imageData = try makeJPEGData()
        vm.addPhotoAttachment(to: note, imageData: imageData)
        note.photoAttachments[0].createdAt = Date(timeIntervalSince1970: 3000)

        let exportedAt = Date(timeIntervalSince1970: 4000)
        let exportURLs = try vm.exportNotesForSharing([note], nowProvider: { exportedAt })
        let exportURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "myram" }))
        let textURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "txt" }))
        let imageURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "jpg" }))
        let exportData = try Data(contentsOf: exportURL)
        let manifest = try JSONDecoder().decode(DecodedExportManifest.self, from: exportData)
        let noteRecord = try XCTUnwrap(manifest.notes.first)
        let attachmentRecord = try XCTUnwrap(noteRecord.attachments.first)
        let noteText = try String(contentsOf: textURL, encoding: .utf8)

        XCTAssertEqual(manifest.format, "myram-note-export")
        XCTAssertEqual(manifest.exportedAt, iso8601String(exportedAt))
        XCTAssertEqual(noteRecord.title, "Daily Log")
        XCTAssertEqual(noteRecord.content, "UTF-8 test ✅")
        XCTAssertEqual(noteRecord.createdAt, iso8601String(note.createdAt))
        XCTAssertEqual(noteRecord.modifiedAt, iso8601String(note.modifiedAt))
        XCTAssertEqual(attachmentRecord.mimeType, "image/jpeg")
        XCTAssertEqual(attachmentRecord.filename, imageURL.lastPathComponent)
        XCTAssertEqual(Data(base64Encoded: attachmentRecord.data), imageData)
        XCTAssertEqual(try Data(contentsOf: imageURL), imageData)
        XCTAssertTrue(noteText.contains("Title: Daily Log"))
        XCTAssertTrue(noteText.contains("Pinned:\n- Review receipt"))
        XCTAssertTrue(noteText.contains("Body:\nUTF-8 test ✅"))
    }

    func testExportNotesForSharingMultipleNotesIncludesFolderPathsAndPhotos() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note1 = vm.createNewNote()
        vm.updateNote(note1, title: "First Note", content: "Body A")

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        let note2 = vm.createNewNote()
        vm.updateNote(note2, title: "Second Note", content: "Body B")
        vm.moveNote(note2, to: workFolder)
        let imageData = try makeJPEGData()
        vm.addPhotoAttachment(to: note2, imageData: imageData)

        let exportURLs = try vm.exportNotesForSharing([note1, note2])
        let exportURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "myram" }))
        let jpgURLs = exportURLs.filter { $0.pathExtension.lowercased() == "jpg" }
        let textURLs = exportURLs.filter { $0.pathExtension.lowercased() == "txt" }
        XCTAssertEqual(jpgURLs.count, 1)
        XCTAssertEqual(textURLs.count, 2)
        let exportData = try Data(contentsOf: exportURL)
        let manifest = try JSONDecoder().decode(DecodedExportManifest.self, from: exportData)
        XCTAssertEqual(manifest.notes.count, 2)

        let noteByTitle = Dictionary(uniqueKeysWithValues: manifest.notes.map { ($0.title, $0) })
        XCTAssertEqual(noteByTitle["First Note"]?.content, "Body A")
        XCTAssertEqual(noteByTitle["Second Note"]?.content, "Body B")
        XCTAssertEqual(noteByTitle["Second Note"]?.folderPath, ["Work"])
        XCTAssertEqual(noteByTitle["Second Note"]?.attachments.first?.mimeType, "image/jpeg")
        XCTAssertEqual(noteByTitle["Second Note"]?.attachments.first?.filename, jpgURLs[0].lastPathComponent)
        XCTAssertEqual(Data(base64Encoded: noteByTitle["Second Note"]?.attachments.first?.data ?? ""), imageData)
        XCTAssertEqual(try Data(contentsOf: jpgURLs[0]), imageData)
    }

    func testImportNotesFromMyRAMExportRestoresNotesPinnedThoughtsAndFolders() throws {
        let sourceContainer = try makeContainer(isStoredInMemoryOnly: true)
        let sourceVM = NotesViewModel(context: sourceContainer.mainContext)
        sourceVM.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(sourceVM.folders.first(where: { $0.name == "Work" }))
        let sourceNote = sourceVM.createNewNote()
        sourceVM.updateNote(sourceNote, title: "Imported Plan", content: "Follow up tomorrow")
        sourceVM.moveNote(sourceNote, to: workFolder)
        let pinnedThought = try XCTUnwrap(sourceVM.addPinnedThought(to: sourceNote, text: "Call Sam"))
        pinnedThought.isCollapsed = true
        let imageData = try makeJPEGData()
        sourceVM.addPhotoAttachment(to: sourceNote, imageData: imageData)
        sourceNote.createdAt = Date(timeIntervalSince1970: 1000)
        sourceNote.modifiedAt = Date(timeIntervalSince1970: 2000)

        let exportURLs = try sourceVM.exportNotesForSharing([sourceNote])
        let exportURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "myram" }))
        let importContainer = try makeContainer(isStoredInMemoryOnly: true)
        let importVM = NotesViewModel(context: importContainer.mainContext)

        let importedNotes = try importVM.importNotes(from: exportURL)
        let importedNote = try XCTUnwrap(importedNotes.first)

        XCTAssertEqual(importedNote.title, "Imported Plan")
        XCTAssertEqual(importedNote.content, "Follow up tomorrow")
        XCTAssertEqual(importedNote.folder?.name, "Work")
        XCTAssertEqual(importedNote.pinnedThoughts.first?.text, "Call Sam")
        XCTAssertEqual(importedNote.pinnedThoughts.first?.isCollapsed, true)
        XCTAssertEqual(importedNote.photoAttachments.first?.imageData, imageData)
        XCTAssertEqual(importVM.currentNote?.id, importedNote.id)
    }

    func testSetNotePinnedMovesNoteAheadOfUnpinnedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let older = vm.createNewNote()
        vm.updateNote(older, title: "Older", content: "")
        let newer = vm.createNewNote()
        vm.updateNote(newer, title: "Newer", content: "")

        vm.setNotePinned(older, isPinned: true)

        XCTAssertEqual(vm.notes.first?.id, older.id)
        XCTAssertTrue(vm.notes.contains { $0.id == newer.id })
    }

    func testUndoLastActionRestoresSoftDeletedNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.deleteNote(note)
        XCTAssertNotNil(note.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)

        vm.undoLastAction()

        XCTAssertNil(note.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertTrue(vm.hasRedoableAction)
    }

    func testRedoLastActionReappliesSoftDeletedNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.deleteNote(note)
        vm.undoLastAction()
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()

        XCTAssertNotNil(note.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertFalse(vm.hasRedoableAction)
    }

    func testUndoLastActionRestoresDeletedFolderHierarchyAndNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Parent")
        let parent = try XCTUnwrap(vm.folders.first(where: { $0.name == "Parent" }))
        vm.openFolder(parent)
        vm.createFolder(named: "Child")
        let child = try XCTUnwrap(vm.folders.first(where: { $0.name == "Child" }))
        vm.openFolder(child)
        let nestedNote = vm.createNewNote()

        vm.deleteFolder(parent, preserveNotes: false)
        XCTAssertNotNil(nestedNote.deletedAt)
        XCTAssertNil(nestedNote.folder)

        vm.undoLastAction()

        let restoredFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        let restoredParent = try XCTUnwrap(restoredFolders.first(where: { $0.id == parent.id }))
        let restoredChild = try XCTUnwrap(restoredFolders.first(where: { $0.id == child.id }))
        XCTAssertEqual(restoredChild.parentFolder?.id, restoredParent.id)
        XCTAssertEqual(nestedNote.folder?.id, restoredChild.id)
        XCTAssertNil(nestedNote.deletedAt)
    }

    func testRedoLastActionReappliesDeletedFolderHierarchyAndNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Parent")
        let parent = try XCTUnwrap(vm.folders.first(where: { $0.name == "Parent" }))
        vm.openFolder(parent)
        vm.createFolder(named: "Child")
        let child = try XCTUnwrap(vm.folders.first(where: { $0.name == "Child" }))
        vm.openFolder(child)
        let nestedNote = vm.createNewNote()

        vm.deleteFolder(parent, preserveNotes: false)
        vm.undoLastAction()
        XCTAssertNil(nestedNote.deletedAt)

        vm.redoLastAction()

        let remainingFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertFalse(remainingFolders.contains { $0.id == parent.id })
        XCTAssertFalse(remainingFolders.contains { $0.id == child.id })
        XCTAssertNil(nestedNote.folder)
        XCTAssertNotNil(nestedNote.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertFalse(vm.hasRedoableAction)
    }

    func testRichTextContentCodecRoundTripPreservesFormattingAttributes() throws {
        let baseFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: "MyRAM",
            attributes: [.font: baseFont]
        )

        let boldFont = UIFont.boldSystemFont(ofSize: 17)
        let italicFont = UIFont.italicSystemFont(ofSize: 17)
        mutable.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: 2))
        mutable.addAttribute(.font, value: italicFont, range: NSRange(location: 2, length: 2))
        mutable.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 4, length: 1)
        )
        mutable.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 3, length: 2)
        )

        let data = try XCTUnwrap(RichTextContentCodec.encode(mutable))
        let decoded = RichTextContentCodec.decode(
            richTextData: data,
            plainText: mutable.string,
            baseFont: baseFont
        )

        let boldDecoded = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldDecoded.fontDescriptor.symbolicTraits.contains(.traitBold))

        let italicDecoded = try XCTUnwrap(decoded.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(italicDecoded.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let underline = decoded.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)

        let strikethrough = decoded.attribute(.strikethroughStyle, at: 3, effectiveRange: nil) as? Int
        XCTAssertEqual(strikethrough, NSUnderlineStyle.single.rawValue)
    }

    func testRichTextDisplayNormalizationKeepsFormattingAndExplicitTextColor() {
        let baseFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: "Task",
            attributes: [.font: baseFont]
        )
        mutable.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: 4))
        mutable.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 4)
        )

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        let color = normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, UIColor.black)

        let underline = normalized.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    }

    func testRichTextRoundTripKeepsAutoTextColorAsMissingForegroundAttribute() throws {
        let mutable = NSMutableAttributedString(string: "Task")
        mutable.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 4)
        )

        let data = try XCTUnwrap(RichTextContentCodec.encode(mutable))
        let decoded = RichTextContentCodec.decode(
            richTextData: data,
            plainText: "Task",
            baseFont: UIFont.systemFont(ofSize: 17)
        )

        XCTAssertNil(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        let underline = decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    }

    func testPasteMatcherUsesTypingAttributesOverDefaults() throws {
        let defaultFont = UIFont.systemFont(ofSize: 17)
        let typingFont = UIFont.boldSystemFont(ofSize: 22)
        let attributedPaste = EditorPasteFormatter.attributedString(
            matchingDestinationFormattingFor: "Pasted text",
            typingAttributes: [
                .font: typingFont,
                .foregroundColor: UIColor.systemBlue,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            defaultAttributes: [
                .font: defaultFont,
                .foregroundColor: UIColor.label
            ]
        )

        XCTAssertEqual(attributedPaste.string, "Pasted text")
        let pastedFont = try XCTUnwrap(attributedPaste.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(pastedFont.pointSize, typingFont.pointSize)
        XCTAssertTrue(pastedFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        let pastedColor = try XCTUnwrap(
            attributedPaste.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        ).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(pastedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let expectedColor = UIColor.systemBlue.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var expectedRed: CGFloat = 0
        var expectedGreen: CGFloat = 0
        var expectedBlue: CGFloat = 0
        var expectedAlpha: CGFloat = 0
        XCTAssertTrue(expectedColor.getRed(
            &expectedRed,
            green: &expectedGreen,
            blue: &expectedBlue,
            alpha: &expectedAlpha
        ))
        XCTAssertEqual(red, expectedRed, accuracy: 0.02)
        XCTAssertEqual(green, expectedGreen, accuracy: 0.02)
        XCTAssertEqual(blue, expectedBlue, accuracy: 0.02)
        XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.02)
        XCTAssertEqual(
            attributedPaste.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testChecklistActionCreatesUncheckedItemAtCurrentLine() {
        let mutable = NSMutableAttributedString(string: "Buy milk")

        let updatedSelection = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(mutable.string, "☐\tBuy milk")
        XCTAssertEqual(updatedSelection.location, ChecklistItemEditor.uncheckedPrefix.utf16.count)
        XCTAssertEqual(updatedSelection.length, 0)
    }

    func testChecklistActionTogglesUncheckedAndCheckedState() {
        let mutable = NSMutableAttributedString(string: "☐\tBuy milk")

        _ = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(mutable.string, "☑︎\tBuy milk")

        _ = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(mutable.string, "☐\tBuy milk")
    }

    func testChecklistRenderingAppliesStrikethroughOnlyToCheckedItemText() {
        let mutable = NSMutableAttributedString(string: "☑︎\tDone\n☐\tPending")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let checkedTextStart = ChecklistItemEditor.checkedPrefix.utf16.count
        let checkedStyle = mutable.attribute(.strikethroughStyle, at: checkedTextStart, effectiveRange: nil) as? Int
        XCTAssertEqual(checkedStyle, NSUnderlineStyle.single.rawValue)

        let prefixStyle = mutable.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertNil(prefixStyle)

        let nsText = mutable.string as NSString
        let uncheckedLineLocation = nsText.range(of: "☐\tPending").location
        let uncheckedTextStart = uncheckedLineLocation + ChecklistItemEditor.uncheckedPrefix.utf16.count
        let uncheckedStyle = mutable.attribute(.strikethroughStyle, at: uncheckedTextStart, effectiveRange: nil) as? Int
        XCTAssertNil(uncheckedStyle)
    }

    func testChecklistRenderingIncreasesCheckboxGlyphSize() throws {
        let bodyFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: "☐\tPending",
            attributes: [.font: bodyFont]
        )

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let checkboxFont = try XCTUnwrap(mutable.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let delimiterFont = try XCTUnwrap(
            mutable.attribute(.font, at: ChecklistItemEditor.uncheckedPrefix.utf16.count - 1, effectiveRange: nil) as? UIFont
        )
        let textFont = try XCTUnwrap(
            mutable.attribute(
                .font,
                at: ChecklistItemEditor.uncheckedPrefix.utf16.count,
                effectiveRange: nil
            ) as? UIFont
        )
        XCTAssertGreaterThan(checkboxFont.pointSize, bodyFont.pointSize)
        XCTAssertEqual(delimiterFont.pointSize, bodyFont.pointSize)
        XCTAssertEqual(textFont.pointSize, bodyFont.pointSize)
    }

    func testChecklistRenderingKeepsBlankItemTypingBoundaryAtBodyFont() throws {
        let bodyFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: ChecklistItemEditor.uncheckedPrefix,
            attributes: [.font: bodyFont]
        )

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let typingBoundaryIndex = ChecklistItemEditor.uncheckedPrefix.utf16.count - 1
        let boundaryFont = try XCTUnwrap(mutable.attribute(.font, at: typingBoundaryIndex, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(boundaryFont.pointSize, bodyFont.pointSize)
    }

    func testChecklistRenderingAppliesContinuationIndentToChecklistLines() throws {
        let mutable = NSMutableAttributedString(string: "☐\tThis is a long checklist item")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let paragraphStyle = try XCTUnwrap(
            mutable.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraphStyle.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
        XCTAssertEqual(paragraphStyle.lineSpacing, 0)
        XCTAssertGreaterThan(paragraphStyle.paragraphSpacing, 0)
    }

    func testChecklistRenderingKeepsStableTabStopForLargerCheckboxGlyph() throws {
        let mutable = NSMutableAttributedString(string: "☐\tThis checklist item is long enough to wrap onto another visual line")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let paragraphStyle = try XCTUnwrap(
            mutable.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let checkboxFont = try XCTUnwrap(mutable.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(checkboxFont.pointSize, UIFont.systemFont(ofSize: 17).pointSize)
        XCTAssertEqual(paragraphStyle.headIndent, 30)
        XCTAssertEqual(paragraphStyle.tabStops.first?.location, paragraphStyle.headIndent)
    }

    func testChecklistRenderingKeepsCheckedWrappedLinesSingleSpaced() throws {
        let mutable = NSMutableAttributedString(string: "☑︎\tThis checked checklist item is long enough to wrap onto another visual line")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let paragraphStyle = try XCTUnwrap(
            mutable.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let checkboxFont = try XCTUnwrap(mutable.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(checkboxFont.pointSize, 20)
        XCTAssertEqual(paragraphStyle.lineSpacing, 0)
        XCTAssertEqual(paragraphStyle.tabStops.first?.location, paragraphStyle.headIndent)
    }

    func testChecklistRenderingKeepsPlainNotesCompactWithoutGutters() throws {
        let mutable = NSMutableAttributedString(string: "Regular note without checklist items")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let paragraphStyle = try XCTUnwrap(
            mutable.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraphStyle.firstLineHeadIndent, 0)
        XCTAssertEqual(paragraphStyle.headIndent, 0)
        XCTAssertEqual(paragraphStyle.lineSpacing, 0)
        XCTAssertGreaterThan(paragraphStyle.paragraphSpacing, 0)
        XCTAssertEqual(
            ChecklistItemEditor.textContainerInsets(hasChecklistItems: false).right,
            ChecklistItemEditor.textContainerInsets(hasChecklistItems: false).left
        )
    }

    func testChecklistRenderingIndentsBodyLinesWhenAnyChecklistExists() throws {
        let mutable = NSMutableAttributedString(string: "Regular line\n☐\tChecklist line")

        XCTAssertTrue(ChecklistItemEditor.applyEditorRendering(in: mutable))

        let regularStyle = try XCTUnwrap(
            mutable.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(regularStyle.firstLineHeadIndent, 0)
        XCTAssertEqual(regularStyle.headIndent, regularStyle.firstLineHeadIndent)
        XCTAssertEqual(regularStyle.lineSpacing, 0)
        XCTAssertGreaterThan(regularStyle.paragraphSpacing, 0)

        let compactInsets = ChecklistItemEditor.textContainerInsets(hasChecklistItems: false)
        let checklistInsets = ChecklistItemEditor.textContainerInsets(hasChecklistItems: true)
        XCTAssertEqual(checklistInsets.left, compactInsets.left)
        XCTAssertGreaterThan(checklistInsets.right, compactInsets.right)
        XCTAssertEqual(checklistInsets.right - compactInsets.right, regularStyle.firstLineHeadIndent)
    }

    func testChecklistCheckedItemRemainsEditableAfterRendering() {
        let mutable = NSMutableAttributedString(string: "☑︎\tDone")
        _ = ChecklistItemEditor.applyEditorRendering(in: mutable)

        mutable.replaceCharacters(in: NSRange(location: mutable.length, length: 0), with: " now")
        _ = ChecklistItemEditor.applyEditorRendering(in: mutable)

        XCTAssertEqual(mutable.string, "☑︎\tDone now")
        let lastCharacterIndex = max(mutable.length - 1, 0)
        let style = mutable.attribute(.strikethroughStyle, at: lastCharacterIndex, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func testChecklistRenderingMigratesLegacyMarkersToIcons() {
        let mutable = NSMutableAttributedString(string: "- [x] Done\n- [ ] Pending")

        _ = ChecklistItemEditor.applyEditorRendering(in: mutable)

        XCTAssertEqual(mutable.string, "☑︎\tDone\n☐\tPending")
    }

    func testChecklistIconDetectionMatchesIconPrefixRange() {
        let text = "☐\tBuy milk" as NSString

        XCTAssertTrue(ChecklistItemEditor.isChecklistIcon(at: 0, in: text))
        XCTAssertFalse(ChecklistItemEditor.isChecklistIcon(at: 1, in: text))
        XCTAssertFalse(ChecklistItemEditor.isChecklistIcon(at: 2, in: text))
    }

    func testChecklistIconExactDetectionStaysLimitedToPrefix() {
        let text = "Before\n☐\tBuy milk\nAfter" as NSString
        let textLocation = text.range(of: "Buy").location

        XCTAssertFalse(ChecklistItemEditor.isChecklistIcon(at: textLocation, in: text))
    }

    func testNoteContentPreviewOmitsCompletedChecklistLines() {
        let note = Note(title: "Preview", content: "☑︎\tDone\n☐\tPending\nRegular detail")

        let preview = noteContentPreviewText(for: note)

        XCTAssertEqual(preview, "☐\tPending\nRegular detail")
    }

    func testNoteContentPreviewOmitsLegacyCompletedChecklistLines() {
        let note = Note(title: "Preview", content: "- [x] Done\n[X] Also done\n- [ ] Pending")

        let preview = noteContentPreviewText(for: note)

        XCTAssertEqual(preview, "- [ ] Pending")
    }

    func testNoteSearchMatchesTitleContentAndPinnedText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let note = Note(title: "Trip Ideas", content: "Book the lakeside cabin")
        let thought = PinnedThought(text: "Reserve kayak", order: 0)
        context.insert(note)
        context.insert(thought)
        note.pinnedThoughts.append(thought)
        try context.save()

        XCTAssertTrue(noteMatchesSearch(note, query: "trip"))
        XCTAssertTrue(noteMatchesSearch(note, query: "lakeside"))
        XCTAssertTrue(noteMatchesSearch(note, query: "kayak"))
        XCTAssertTrue(noteMatchesSearch(note, query: "trip kayak"))
        XCTAssertFalse(noteMatchesSearch(note, query: "invoice"))
    }

    func testNoteSearchIgnoresCompletedChecklistLinesHiddenFromPreview() {
        let note = Note(
            title: "Errands",
            content: "\(ChecklistItemEditor.checkedPrefix)Completed receipt\n\(ChecklistItemEditor.uncheckedPrefix)Pending groceries"
        )

        XCTAssertFalse(noteMatchesSearch(note, query: "receipt"))
        XCTAssertTrue(noteMatchesSearch(note, query: "groceries"))
    }

    func testCurrentNoteSearchOrdersPinnedTextBeforeBodyMatches() {
        let firstPinnedID = UUID()
        let secondPinnedID = UUID()

        let matches = NoteSearchMatcher.matches(
            in: "Body alpha detail",
            pinnedTexts: [
                NoteSearchPinnedText(id: firstPinnedID, text: "Pinned beta"),
                NoteSearchPinnedText(id: secondPinnedID, text: "Pinned alpha")
            ],
            query: "alpha"
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].region, .pinnedText(id: secondPinnedID))
        XCTAssertNil(matches[0].nsRangeInRenderedText)
        XCTAssertEqual(matches[1].region, .body)
        XCTAssertEqual(matches[1].nsRangeInRenderedText, NSRange(location: 5, length: 5))
    }

    func testCurrentNoteSearchUsesOriginalStringRangesForDiacriticInsensitiveBodyMatches() {
        let body = "Cafe planning\nCafé receipt"

        let matches = NoteSearchMatcher.matches(
            in: body,
            pinnedTexts: [],
            query: "cafe"
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.nsRangeInRenderedText), [
            NSRange(location: 0, length: 4),
            NSRange(location: 14, length: 4)
        ])
    }

    private func makeContainer(
        isStoredInMemoryOnly: Bool,
        configurationName: String = "MyRAMTests"
    ) throws -> ModelContainer {
        let schema = Schema([Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self])
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )

        return try ModelContainer(
            for: Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self,
            configurations: configuration
        )
    }

    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func temporarySyncQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-pending-changes.json")
    }

    private func temporarySyncConflictFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
    }

    private func makeActiveNoteContentConflictFixture(
        initialContent: String = "Local before conflict",
        remoteText: String = "Version to Sync",
        remoteRichTextContentData: Data? = nil
    ) throws -> (
        container: ModelContainer,
        context: ModelContext,
        conflictFileURL: URL,
        conflictStore: SyncConflictStore,
        recorder: RecordingSyncController,
        vm: NotesViewModel,
        note: Note,
        conflict: SyncConflictVersion
    ) {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: initialContent)
        note.id = UUID()
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: note.id,
            noteID: note.id,
            field: .noteContent,
            localText: initialContent,
            remoteText: remoteText,
            remoteRichTextContentData: remoteRichTextContentData,
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 201),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = conflictStore.preserve(conflict)
        let vm = NotesViewModel(context: context, syncController: recorder, syncConflictStore: conflictStore)

        return (
            container: container,
            context: context,
            conflictFileURL: conflictFileURL,
            conflictStore: conflictStore,
            recorder: recorder,
            vm: vm,
            note: note,
            conflict: conflict
        )
    }

    private func makeConflictRichTextData(text: String) throws -> Data {
        let attributedText = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.foregroundColor, value: UIColor.black, range: fullRange)
        attributedText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        attributedText.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: fullRange)

        let redRange = (text as NSString).range(of: "to")
        attributedText.addAttribute(.foregroundColor, value: UIColor.systemRed, range: redRange)

        return try XCTUnwrap(RichTextContentCodec.encode(attributedText))
    }

    private func decodeRichTextData(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func loadNoteIntelligenceFixtures() throws -> [NoteIntelligenceFixture] {
        let fixturesDirectory = try noteIntelligenceBaseURL()
            .appendingPathComponent("fixtures/v1", isDirectory: true)
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try fixtureURLs.map { url in
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(NoteIntelligenceFixture.self, from: data)
        }
    }

    private func canonicalInput(from fixture: NoteIntelligenceFixture) -> NoteIntelligenceCanonicalInput {
        .init(
            noteID: fixture.input.noteId,
            text: fixture.input.text,
            language: fixture.input.language,
            createdAt: fixture.input.createdAt,
            modifiedAt: fixture.input.modifiedAt,
            features: .init(
                lemmas: fixture.input.features.lemmas,
                tokens: fixture.input.features.tokens,
                posTags: [],
                openCount30d: fixture.input.features.openCount30d,
                editCount7d: fixture.input.features.editCount7d,
                firstPersonRatio: fixture.input.features.firstPersonRatio
            ),
            entities: .init(
                datetimes: fixture.input.entities.datetimes,
                emails: fixture.input.entities.emails,
                phones: fixture.input.entities.phones,
                urls: fixture.input.entities.urls,
                addresses: fixture.input.entities.addresses
            ),
            similarNoteIDs: fixture.input.similarNoteIds
        )
    }

    private func decodeNoteIntelligenceArtifact<T: Decodable>(relativePath: String) throws -> T {
        let artifactURL = try noteIntelligenceBaseURL().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: artifactURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func noteIntelligenceBaseURL() throws -> URL {
        let testBundle = Bundle(for: Self.self)
        if let bundledURL = testBundle.url(forResource: "note-intelligence", withExtension: nil) {
            return bundledURL
        }

        let repositoryPathURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/note-intelligence", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositoryPathURL.path) {
            return repositoryPathURL
        }

        throw NSError(
            domain: "MyRAMTests",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate note-intelligence test artifacts in bundle or repository path."
            ]
        )
    }
}

private func fontSize(in attributedText: NSAttributedString, at location: Int) -> CGFloat {
    (attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont)?.pointSize ?? 0
}

private func contrastRatio(foreground: UIColor, background: UIColor) -> CGFloat {
    let foregroundLuminance = relativeLuminance(for: foreground)
    let backgroundLuminance = relativeLuminance(for: background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(for color: UIColor) -> CGFloat {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    func adjusted(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * adjusted(red) + 0.7152 * adjusted(green) + 0.0722 * adjusted(blue)
}

private extension UIColor {
    var rgbaTestComponents: [CGFloat]? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return [red, green, blue, alpha].map { ($0 * 1_000).rounded() / 1_000 }
    }
}
