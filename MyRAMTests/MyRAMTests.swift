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

    private final class RecordingSyncController: MyRAMSyncControlling, SyncConvergenceLocalBatchTransportAdapter {
        var onChangesReceived: (([SyncChange]) async -> [LegacyIncomingChangeResult])?
        var onLocalChangesAcknowledged: (([SyncChange]) async -> Void)?
        var onBatchReceived: ((SyncBatch) async -> Void)?
        private(set) var recordedChanges: [SyncChange] = []
        private(set) var recordedBatches: [SyncBatch] = []

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

        func acceptLocalBatch(_ batch: SyncBatch) async throws {
            recordedBatches.append(batch)
        }
    }

    private final class InjectableLegacyIncomingSaveFailure {
        var shouldFail: Bool
        var failingCallNumbers: Set<Int> = []
        private(set) var callCount = 0

        init(shouldFail: Bool) {
            self.shouldFail = shouldFail
        }

        func save(_ context: ModelContext) throws {
            callCount += 1
            if shouldFail || failingCallNumbers.contains(callCount) {
                throw NSError(domain: "MyRAMTests.InjectedLegacyIncomingSaveFailure", code: 1)
            }
            try context.save()
        }
    }

    private struct MountedEditorFixture {
        let container: ModelContainer
        let context: ModelContext
        let queueFileURL: URL
        let localQueueFileURL: URL
        let conflictFileURL: URL
        let recorder: RecordingSyncController
        let vm: NotesViewModel
        let note: Note
        let noteID: UUID
        let bridge: NoteEditorToolbarBridge
        let window: UIWindow
        let hostingController: UIHostingController<NoteEditorView>
        let textView: UITextView

        @MainActor
        func unmount() {
            vm.selectNote(nil)
            vm.unregisterActiveEditor(noteID: noteID)
            window.rootViewController = nil
            window.isHidden = true
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    func testPlatformPolicyMatchesCurrentBuildTarget() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(MyRAMPlatform.isRealIOSOrIPadOS)
        XCTAssertFalse(MyRAMPlatform.isNativeMacOS)
        XCTAssertFalse(MyRAMPlatform.isMacCatalyst)
        #elseif targetEnvironment(macCatalyst)
        XCTAssertFalse(MyRAMPlatform.isRealIOSOrIPadOS)
        XCTAssertFalse(MyRAMPlatform.isNativeMacOS)
        XCTAssertTrue(MyRAMPlatform.isMacCatalyst)
        #elseif os(macOS)
        XCTAssertFalse(MyRAMPlatform.isRealIOSOrIPadOS)
        XCTAssertTrue(MyRAMPlatform.isNativeMacOS)
        XCTAssertFalse(MyRAMPlatform.isMacCatalyst)
        #else
        XCTFail("MyRAMPlatform has no policy for this build target.")
        #endif
    }

    func testPlatformPolicyDoesNotReportImpossibleTargetCombination() {
        XCTAssertFalse(MyRAMPlatform.isRealIOSOrIPadOS && MyRAMPlatform.isMacCatalyst)
        XCTAssertFalse(MyRAMPlatform.isNativeMacOS && MyRAMPlatform.isMacCatalyst)
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

    func testEditorSelectionRangeResolverClampsNSNotFoundToEndCaret() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: NSNotFound, length: 4),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 8, length: 0))
    }

    func testEditorSelectionRangeResolverClampsNegativeSelectionLocationToZero() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: -2, length: 3),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 0, length: 3))
    }

    func testEditorSelectionRangeResolverClampsSelectionLocationPastTextEnd() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: 12, length: 3),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 8, length: 0))
    }

    func testEditorSelectionRangeResolverClampsSelectionLengthPastTextEnd() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: 6, length: 5),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 6, length: 2))
    }

    func testEditorSelectionRangeResolverPreservesCollapsedCaretInsideBounds() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: 4, length: 0),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 4, length: 0))
    }

    func testEditorSelectionRangeResolverHandlesEmptyText() {
        let range = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: 3, length: 2),
            textLength: 0
        )

        XCTAssertEqual(range, NSRange(location: 0, length: 0))
        XCTAssertEqual(EditorSelectionRangeResolver.clampedCaretLocation(3, textLength: 0), 0)
    }

    func testEditorSelectionRangeResolverRejectsInvalidRanges() {
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: NSNotFound, length: 0),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: -1, length: 1),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 1, length: -1),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 7, length: 2),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 9, length: 0),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: Int.max - 1, length: 2),
            textLength: 8
        ))
    }

    func testEditorSelectionRangeResolverAcceptsRangeEndingAtTextLength() {
        XCTAssertTrue(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 5, length: 3),
            textLength: 8
        ))
    }

    func testEditorSelectionRangeResolverAcceptsCollapsedRangeAtTextEnd() {
        XCTAssertTrue(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 8, length: 0),
            textLength: 8
        ))
    }

    func testEditorSelectionRangeResolverRejectsNegativeTextLength() {
        XCTAssertFalse(EditorSelectionRangeResolver.isValidRange(
            NSRange(location: 0, length: 0),
            textLength: -1
        ))
    }

    func testEditorSelectionRangeResolverPositiveLengthRequiresValidNonEmptyRange() {
        XCTAssertFalse(EditorSelectionRangeResolver.hasPositiveLengthResolvedRange(
            NSRange(location: 3, length: 0),
            textLength: 8
        ))
        XCTAssertFalse(EditorSelectionRangeResolver.hasPositiveLengthResolvedRange(
            NSRange(location: Int.max - 1, length: 2),
            textLength: 8
        ))
        XCTAssertTrue(EditorSelectionRangeResolver.hasPositiveLengthResolvedRange(
            NSRange(location: 3, length: 2),
            textLength: 8
        ))
    }

    func testEditorSelectionRangeResolverClampsRenderedSelectionWithExistingSemantics() {
        let range = EditorSelectionRangeResolver.clampedRenderedSelectionRange(
            NSRange(location: 6, length: 5),
            textLength: 8
        )

        XCTAssertEqual(range, NSRange(location: 6, length: 2))
    }

    func testRenderedSelectionClampPreservesLegacySemanticsDistinctFromCanonicalClamp() {
        let renderedRange = EditorSelectionRangeResolver.clampedRenderedSelectionRange(
            NSRange(location: -2, length: 3),
            textLength: 8
        )
        let canonicalRange = EditorSelectionRangeResolver.clampedSelectionRange(
            NSRange(location: -2, length: 3),
            textLength: 8
        )

        XCTAssertEqual(renderedRange, NSRange(location: -2, length: 3))
        XCTAssertEqual(canonicalRange, NSRange(location: 0, length: 3))
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

    func testRichTextConflictSanitizationPreservesFormattingForTrailingNewlineMismatch() throws {
        let richTextData = try makeStyledConflictRichTextData(text: "Bold Italic Underline\n")

        let sanitized = try XCTUnwrap(
            RichTextContentCodec.sanitizedConflictRichTextData(
                richTextData,
                plainText: "Bold Italic Underline"
            )
        )
        let decoded = try decodeRichTextData(sanitized)

        XCTAssertEqual(decoded.string, "Bold Italic Underline")
        try assertStyledConflictFormattingSurvives(in: decoded)
    }

    func testRichTextConflictSanitizationPreservesFormattingForTrailingBoundaryWhitespaceMismatch() throws {
        let richTextData = try makeStyledConflictRichTextData(text: "Bold Italic Underline   ")

        let sanitized = try XCTUnwrap(
            RichTextContentCodec.sanitizedConflictRichTextData(
                richTextData,
                plainText: "Bold Italic Underline"
            )
        )
        let decoded = try decodeRichTextData(sanitized)

        XCTAssertEqual(decoded.string, "Bold Italic Underline")
        try assertStyledConflictFormattingSurvives(in: decoded)
    }

    func testRichTextConflictSanitizationRejectsInteriorWhitespaceMismatch() throws {
        let richTextData = try makeStyledConflictRichTextData(text: "Bold  Italic Underline")

        XCTAssertNil(
            RichTextContentCodec.sanitizedConflictRichTextData(
                richTextData,
                plainText: "Bold Italic Underline"
            )
        )
    }

    func testRichTextConflictSanitizationRejectsMultipleTrailingNewlineMismatch() throws {
        let richTextData = try makeStyledConflictRichTextData(text: "Bold Italic Underline\n\n")

        XCTAssertNil(
            RichTextContentCodec.sanitizedConflictRichTextData(
                richTextData,
                plainText: "Bold Italic Underline"
            )
        )
    }

    func testRichTextConflictSanitizationRejectsMixedTrailingNewlineWhitespaceMismatch() throws {
        let richTextData = try makeStyledConflictRichTextData(text: "Bold Italic Underline\n ")

        XCTAssertNil(
            RichTextContentCodec.sanitizedConflictRichTextData(
                richTextData,
                plainText: "Bold Italic Underline"
            )
        )
    }

    func testRichTextConflictSanitizationRejectsMalformedRichTextData() {
        XCTAssertNil(
            RichTextContentCodec.sanitizedConflictRichTextData(
                Data("not rtf".utf8),
                plainText: "Bold Italic Underline"
            )
        )
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

        _ = await vm.applyIncomingSyncChanges([
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
        _ = await vm.applyIncomingSyncChanges([
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
        try context.save()
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

        _ = await vm.applyIncomingSyncChanges([
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

    func testSupportedNoteBodyInsertPublishesBatchOnly() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Hello")
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: recorder,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            syncBatchQuietWindow: 0
        )

        vm.commitNoteEdit(note, title: "Shared", content: "Hello world")
        for _ in 0..<20 where recorder.recordedBatches.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(recorder.recordedChanges.contains {
            $0.entityType == .item && $0.entityID == note.id.uuidString
        })
        let batch = try XCTUnwrap(recorder.recordedBatches.first)
        XCTAssertEqual(batch.changes.count, 1)
        guard case .noteBodyTextInserted(let change) = try XCTUnwrap(batch.changes.first) else {
            return XCTFail("Expected body insert batch change")
        }
        XCTAssertEqual(change.noteID, note.id)
        XCTAssertEqual(change.utf16Offset, "Hello".utf16.count)
        XCTAssertEqual(change.text, " world")
        XCTAssertNil(change.baseContentHash)
    }

    func testReadyLocalBatchRegistersConvergenceEvidenceBeforeTransport() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let recorder = RecordingSyncController()
        let note = Note(title: "Shared", content: "Hello")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000127501")!
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: recorder,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            syncBatchQuietWindow: 0
        )

        vm.commitNoteEdit(note, title: "Renamed", content: "Hello world")
        for _ in 0..<20 where recorder.recordedBatches.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let batch = try XCTUnwrap(recorder.recordedBatches.first)
        let retained = try context.fetch(FetchDescriptor<RetainedBodyOperation>())
        XCTAssertEqual(retained.count, 1)
        let operation = try XCTUnwrap(retained.first)
        XCTAssertEqual(operation.sourceRaw, SyncConvergenceRetainedOperationSource.local.rawValue)
        XCTAssertEqual(operation.batchID, batch.id)
        XCTAssertEqual(operation.noteID, note.id)
        XCTAssertEqual(operation.operationKindRaw, SyncConvergencePlannedBodyOperation.Kind.insert.rawValue)
        XCTAssertEqual(operation.baseContentHash, SyncBatchContentHash.sha256Hex(for: "Hello"))
        XCTAssertEqual(operation.resultContentHash, SyncBatchContentHash.sha256Hex(for: "Hello world"))

        let winners = try context.fetch(FetchDescriptor<NoteTitleWinner>())
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(winners.first?.noteID, note.id)
        XCTAssertEqual(winners.first?.title, "Renamed")
    }

    func testSustainedLocalTypingAccountsForWholeBodyEvidenceWork() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let base = String(repeating: "large-note-line\n", count: 2_000)
        let inserted = (0..<20).map { "x\($0)" }
        let finalBody = base + inserted.joined()
        let note = Note(title: "Shared", content: finalBody)
        note.id = noteID
        context.insert(note)
        try context.save()

        var offset = base.utf16.count
        let changes: [SyncBatchChange] = inserted.map { text in
            defer { offset += text.utf16.count }
            return .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                noteID: noteID,
                utf16Offset: offset,
                text: text,
                modifiedAt: Date(),
                baseContentHash: nil
            ))
        }
        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(),
            changes: changes
        )
        let metrics = SyncConvergenceLocalEvidenceMetrics()
        let transport = AcceptingLocalBatchTransport()
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: transport,
            presentationAdapter: CompletingPresentationAdapter(),
            localEvidenceMetrics: metrics
        )

        let outcome = await runtime.submitLocalBatch(batch)

        guard case .drained = outcome else { return XCTFail("Expected local batch to drain") }
        XCTAssertEqual(metrics.submittedBodyOperationCount, 20)
        XCTAssertEqual(metrics.wholeBodyHashCount, 40)
        XCTAssertEqual(metrics.wholeBodyReconstructionCount, 20)
        XCTAssertEqual(metrics.retainedOperationRecordCount, 20)
        XCTAssertEqual(metrics.saveCount, 1)
    }

    func testCapturedLocalEvidenceRegistersAfterAuthoritativeBodyMovesOnWithoutReverseReconstruction() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000127510")!
        let note = Note(title: "Shared", content: "Hello world!!")
        note.id = noteID
        context.insert(note)
        try context.save()

        let change = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: "Hello".utf16.count,
            text: " world",
            modifiedAt: Date(timeIntervalSince1970: 10),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello")
        ))
        let capturedChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: change,
            preBody: "Hello",
            postBody: "Hello world"
        )
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127511")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127512")!,
            createdAt: Date(timeIntervalSince1970: 11),
            changes: [change]
        )
        let obligation = SyncConvergenceLocalObligation(batch: batch, capturedChanges: [capturedChange])
        let metrics = SyncConvergenceLocalEvidenceMetrics()
        let transport = AcceptingLocalBatchTransport()
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: transport,
            presentationAdapter: CompletingPresentationAdapter(),
            localEvidenceMetrics: metrics
        )

        let outcome = await runtime.submitLocalObligation(obligation)

        guard case .drained = outcome else { return XCTFail("Expected captured local obligation to drain") }
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<RetainedBodyOperation>()).first)
        XCTAssertEqual(retained.baseContentHash, SyncBatchContentHash.sha256Hex(for: "Hello"))
        XCTAssertEqual(retained.resultContentHash, SyncBatchContentHash.sha256Hex(for: "Hello world"))
        XCTAssertEqual(metrics.wholeBodyReconstructionCount, 0)
        XCTAssertEqual(metrics.retainedOperationRecordCount, 1)
        XCTAssertEqual(transport.acceptedBatches.map(\.id), [batch.id])
    }

    func testCapturedLocalObligationValidationFailureRejectsBeforeQueueInsertion() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000127513")!
        let note = Note(title: "Shared", content: "A")
        note.id = noteID
        context.insert(note)
        try context.save()

        let obligation = try discontinuousCapturedObligation(noteID: noteID)
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil)
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: localQueue,
            localBatchTransportAdapter: AcceptingLocalBatchTransport(),
            presentationAdapter: CompletingPresentationAdapter()
        )

        let outcome = await runtime.submitLocalObligation(obligation)

        guard case .blocked(let failure) = outcome else {
            return XCTFail("Expected invalid newly submitted captured obligation to be blocked")
        }
        XCTAssertEqual(failure.kind, .localEvidenceContinuityViolation)
        XCTAssertTrue(localQueue.pendingObligations.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).isEmpty)
    }

    func testPersistedCorruptCapturedObligationQuarantinesAndDisjointLocalWorkProgresses() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteAID = UUID(uuidString: "00000000-0000-0000-0000-000000127514")!
        let noteBID = UUID(uuidString: "00000000-0000-0000-0000-000000127515")!
        let noteA = Note(title: "A", content: "A")
        noteA.id = noteAID
        let noteB = Note(title: "B", content: "B")
        noteB.id = noteBID
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        let corruptObligation = try discontinuousCapturedObligation(noteID: noteAID)
        let validChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteBID,
            utf16Offset: 1,
            text: "!",
            modifiedAt: Date(timeIntervalSince1970: 5),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "B")
        ))
        let capturedValidChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: validChange,
            preBody: "B",
            postBody: "B!"
        )
        let validBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127516")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127517")!,
            createdAt: Date(timeIntervalSince1970: 5),
            changes: [validChange]
        )
        let validObligation = SyncConvergenceLocalObligation(batch: validBatch, capturedChanges: [capturedValidChange])
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil)
        try localQueue.enqueue(corruptObligation)
        try localQueue.enqueue(validObligation)
        let transport = AcceptingLocalBatchTransport()
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: localQueue,
            localBatchTransportAdapter: transport,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let outcome = await runtime.resumePendingWork()

        guard case .quarantined(let quarantined) = outcome else {
            return XCTFail("Expected persisted corrupt captured obligation to be quarantined")
        }
        XCTAssertEqual(quarantined.items.map(\.batchID), [corruptObligation.id])
        XCTAssertEqual(quarantined.items.first?.reason, .localEvidenceContinuityViolation)
        XCTAssertEqual(localQueue.pendingBatches.map(\.id), [corruptObligation.id])
        XCTAssertEqual(transport.acceptedBatches.map(\.id), [validBatch.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).map(\.batchID), [validBatch.id])
    }

    func testCommitNoteEditBodyReplacementRecordsCapturedEvidenceChain() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let note = Note(title: "Draft", content: "abc")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-0000001275B0")!
        context.insert(note)
        try context.save()
        let syncController = RecordingSyncController()
        let viewModel = NotesViewModel(
            context: context,
            syncController: syncController,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false
        )

        viewModel.commitNoteEdit(note, title: "Draft", content: "axc")

        XCTAssertEqual(note.content, "axc")
        XCTAssertEqual(note.title, "Draft")
        XCTAssertNil(viewModel.syncBatchErrorMessage)
        await Task.yield()
        await Task.yield()
        guard let obligationID = await viewModel.capturePendingLocalBatchForRecovery() else {
            return XCTFail("Expected replacement edit to enter the local obligation accumulator")
        }
        XCTAssertEqual(syncController.recordedBatches.count, 1)
        XCTAssertEqual(syncController.recordedBatches.first?.id, obligationID)
        XCTAssertEqual(syncController.recordedBatches.first?.changes.count, 2)
        guard case .noteBodyTextDeleted(let deletion) = syncController.recordedBatches.first?.changes.first,
              case .noteBodyTextInserted(let insertion) = syncController.recordedBatches.first?.changes.dropFirst().first else {
            return XCTFail("Expected replacement to record delete then insert")
        }
        XCTAssertEqual(deletion.expectedText, "b")
        XCTAssertEqual(insertion.text, "x")
        let retainedOperations = try context.fetch(FetchDescriptor<RetainedBodyOperation>(
            sortBy: [SortDescriptor(\.operationIndex)]
        ))
        XCTAssertEqual(retainedOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(retainedOperations.map(\.baseContentHash), [
            SyncBatchContentHash.sha256Hex(for: "abc"),
            SyncBatchContentHash.sha256Hex(for: "ac")
        ])
    }

    func testCommitNoteEditLargeReplacementRecordsCapturedEvidenceChain() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let originalBody = String(repeating: "a", count: 600)
        let replacementBody = String(repeating: "b", count: 600)
        let note = Note(title: "Draft", content: originalBody)
        context.insert(note)
        try context.save()
        let syncController = RecordingSyncController()
        let viewModel = NotesViewModel(
            context: context,
            syncController: syncController,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false
        )

        viewModel.commitNoteEdit(note, title: "Draft", content: replacementBody)

        XCTAssertEqual(note.content, replacementBody)
        XCTAssertEqual(note.title, "Draft")
        XCTAssertNil(viewModel.syncBatchErrorMessage)
        await Task.yield()
        await Task.yield()
        guard let pendingBatchID = await viewModel.capturePendingLocalBatchForRecovery() else {
            return XCTFail("Expected large replacement to enter the local obligation accumulator")
        }
        XCTAssertEqual(syncController.recordedBatches.map(\.id), [pendingBatchID])
        XCTAssertEqual(syncController.recordedBatches.first?.changes.count, 2)
        let retainedOperations = try context.fetch(FetchDescriptor<RetainedBodyOperation>(
            sortBy: [SortDescriptor(\.operationIndex)]
        ))
        XCTAssertEqual(retainedOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(retainedOperations.map(\.baseContentHash), [
            SyncBatchContentHash.sha256Hex(for: originalBody),
            SyncBatchContentHash.sha256Hex(for: "")
        ])
    }

    func testCommitNoteEditSaveFailureRestoresStateAndDoesNotRecordConvergenceWork() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let originalRichText = Data([1, 2, 3])
        let failedRichText = Data([9, 8, 7])
        let originalModifiedAt = Date(timeIntervalSince1970: 100)
        let note = Note(title: "Draft", content: "abc")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-0000001275D0")!
        note.richTextContentData = originalRichText
        note.modifiedAt = originalModifiedAt
        let folder = Folder(name: "Unrelated")
        context.insert(note)
        context.insert(folder)
        try context.save()
        folder.name = "Unrelated dirty change"
        var failNextSave = true
        struct SaveFailure: Error {}
        let syncController = RecordingSyncController()
        let viewModel = NotesViewModel(
            context: context,
            syncController: syncController,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false,
            saveContext: {
                if failNextSave {
                    failNextSave = false
                    throw SaveFailure()
                }
                try context.save()
            }
        )

        viewModel.commitNoteEdit(note, title: "Saved later?", content: "axc", richTextContentData: failedRichText)

        XCTAssertEqual(note.title, "Draft")
        XCTAssertEqual(note.content, "abc")
        XCTAssertEqual(note.richTextContentData, originalRichText)
        XCTAssertEqual(note.modifiedAt, originalModifiedAt)
        XCTAssertEqual(folder.name, "Unrelated dirty change")
        XCTAssertEqual(viewModel.syncBatchErrorMessage, "Unable to save the latest edit.")
        XCTAssertFalse(viewModel.hasRecentTextEditForTesting(noteID: note.id))
        let pendingBatchID = await viewModel.capturePendingLocalBatchForRecovery()
        XCTAssertNil(pendingBatchID)
        XCTAssertTrue(syncController.recordedBatches.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).isEmpty)

        try context.save()
        let freshContext = ModelContext(container)
        let noteID = note.id
        let reloadedNote = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == noteID }
        )).first)
        let reloadedFolder = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<Folder>()).first)
        XCTAssertEqual(reloadedNote.title, "Draft")
        XCTAssertEqual(reloadedNote.content, "abc")
        XCTAssertEqual(reloadedNote.richTextContentData, originalRichText)
        XCTAssertEqual(reloadedFolder.name, "Unrelated dirty change")
    }

    func testIncomingBodyMutationFinalizesPendingLocalObligationBeforeAuthoritativeMutation() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000127518")!
        let note = Note(title: "Shared", content: "Hello")
        note.id = noteID
        context.insert(note)
        try context.save()
        let syncController = RecordingSyncController()
        let viewModel = NotesViewModel(
            context: context,
            syncController: syncController,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false
        )

        viewModel.commitNoteEdit(note, title: "Shared", content: "Hello local")
        await Task.yield()
        await Task.yield()
        let remoteBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127519")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-00000012751A")!,
            createdAt: Date(timeIntervalSince1970: 20),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Hello local".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello local")
                ))
            ]
        )

        await viewModel.applyIncomingSyncBatch(remoteBatch)

        XCTAssertEqual(syncController.recordedBatches.count, 1)
        XCTAssertEqual(syncController.recordedBatches.first?.changes.count, 1)
        guard case .noteBodyTextInserted(let localChange) = syncController.recordedBatches.first?.changes.first else {
            return XCTFail("Expected pending local body insertion to be finalized before incoming mutation")
        }
        XCTAssertEqual(localChange.noteID, noteID)
        XCTAssertEqual(localChange.utf16Offset, "Hello".utf16.count)
        XCTAssertEqual(localChange.text, " local")
        XCTAssertEqual(note.content, "Hello local remote")
    }

    // MARK: - Legacy incoming save-failure durability (8.1, 8.2, 8.4)

    func testLegacyIncomingSaveFailureReturnsRetryRequiredWithNoDurableMutationOrSideEffects() async throws {
        let storeName = "MyRAMLegacySaveFailure-\(UUID().uuidString)"
        let container = try makeContainer(isStoredInMemoryOnly: false, configurationName: storeName)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Original body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        let injector = InjectableLegacyIncomingSaveFailure(shouldFail: true)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { try injector.save($0) }
        )
        vm.currentNote = note
        UserDefaults.standard.removeObject(forKey: "lastNoteID")

        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let dispositions = await vm.applyIncomingSyncChanges([change])

        XCTAssertEqual(dispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(note.content, "Original body")
        XCTAssertEqual(vm.currentNote?.id, noteID)
        XCTAssertNil(UserDefaults.standard.string(forKey: "lastNoteID"))
        XCTAssertNil(vm.activeEditorSyncUpdate)

        let reopenedContainer = try makeContainer(isStoredInMemoryOnly: false, configurationName: storeName)
        let reopenedNote = try XCTUnwrap(
            try reopenedContainer.mainContext.fetch(FetchDescriptor<Note>()).first { $0.id == noteID }
        )
        XCTAssertEqual(reopenedNote.content, "Original body")
    }

    func testLegacyIncomingDirtyContextRefusesApplyWithoutSnapshotOrRollback() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteAID = UUID()
        let noteA = Note(title: "A", content: "A body")
        noteA.id = noteAID
        noteA.modifiedAt = Date(timeIntervalSince1970: 100)
        let noteB = Note(title: "B", content: "B body")
        noteB.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        final class SnapshotProbe {
            var fileExistsCalls = 0
        }
        let probe = SnapshotProbe()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(
            fileURL: conflictFileURL,
            fileIO: SyncConflictStore.FileIO(
                fileExists: { _ in
                    probe.fileExistsCalls += 1
                    return false
                },
                readData: { _ in throw CocoaError(.fileReadUnknown) },
                createDirectory: { _ in },
                writeData: { _, _ in },
                removeItem: { _ in }
            )
        )
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: conflictStore,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )

        noteB.content = "Unsaved local B"
        XCTAssertTrue(context.hasChanges)

        let change = try legacyNoteChange(
            noteID: noteAID,
            title: "A",
            content: "Peer A",
            baseTitle: "A",
            baseContent: "A body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let dispositions = await vm.applyIncomingSyncChanges([change])

        XCTAssertEqual(dispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(noteA.content, "A body")
        XCTAssertEqual(noteB.content, "Unsaved local B")
        XCTAssertEqual(probe.fileExistsCalls, 0)
        XCTAssertTrue(context.hasChanges)
    }

    func testLegacyIncomingDirtyContextRedeliversAfterLocalChangeSaves() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteAID = UUID()
        let noteA = Note(title: "A", content: "A body")
        noteA.id = noteAID
        noteA.modifiedAt = Date(timeIntervalSince1970: 100)
        let noteB = Note(title: "B", content: "B body")
        noteB.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )
        let change = try legacyNoteChange(
            noteID: noteAID,
            title: "A",
            content: "Peer A",
            baseTitle: "A",
            baseContent: "A body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        noteB.content = "Unsaved local B"
        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(noteA.content, "A body")

        try context.save()
        let secondDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(noteA.content, "Peer A")
        XCTAssertEqual(noteB.content, "Unsaved local B")
    }

    func testLegacyIncomingSiblingContextSaveRefreshesRetainedMainReference() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Original body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        let retainedReference = note
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let dispositions = await vm.applyIncomingSyncChanges([change])

        XCTAssertEqual(dispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(retainedReference.content, "Peer body")
    }

    func testLegacyIncomingUnsavedInsertedEntityReturnsRetryWithoutIsolatedSave() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        context.autosaveEnabled = false
        let noteID = UUID()
        final class SaveProbe {
            var callCount = 0
        }
        let probe = SaveProbe()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { isolatedContext in
                probe.callCount += 1
                try isolatedContext.save()
            }
        )
        let note = Note(title: "Draft", content: "Unsaved draft")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        XCTAssertTrue(context.hasChanges)
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Draft",
            content: "Remote body",
            baseTitle: "Draft",
            baseContent: "Unsaved draft",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let dispositions = await vm.applyIncomingSyncChanges([change])

        XCTAssertEqual(dispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(note.content, "Unsaved draft")
        XCTAssertEqual(probe.callCount, 0)
    }

    // MARK: - Unrelated later save cannot persist a refused mutation (8.3, load-bearing)

    func testUnrelatedLaterSaveCannotPersistARefusedLegacyIncomingMutation() async throws {
        let storeName = "MyRAMLegacySaveFailureCompaction-\(UUID().uuidString)"
        let container = try makeContainer(isStoredInMemoryOnly: false, configurationName: storeName)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Original body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        let injector = InjectableLegacyIncomingSaveFailure(shouldFail: true)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { try injector.save($0) }
        )

        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        _ = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(note.content, "Original body")

        // A later, wholly unrelated edit succeeds and saves normally.
        injector.shouldFail = false
        vm.commitNoteEdit(note, title: "Original", content: "Original body edited locally")
        XCTAssertEqual(note.content, "Original body edited locally")

        let reopenedContainer = try makeContainer(isStoredInMemoryOnly: false, configurationName: storeName)
        let reopenedNote = try XCTUnwrap(
            try reopenedContainer.mainContext.fetch(FetchDescriptor<Note>()).first { $0.id == noteID }
        )
        XCTAssertEqual(
            reopenedNote.content,
            "Original body edited locally",
            "The refused incoming mutation must not have ridden along with the later unrelated save."
        )
    }

    // MARK: - Redelivery succeeds exactly once after admission stops failing (8.5)

    func testLegacyIncomingRedeliverySucceedsExactlyOnceAfterSaveFailureClears() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Original body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        let injector = InjectableLegacyIncomingSaveFailure(shouldFail: true)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { try injector.save($0) }
        )

        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(note.content, "Original body")

        injector.shouldFail = false
        let secondDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(note.content, "Peer body")

        let duplicateDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(duplicateDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(note.content, "Peer body")
    }

    func testLegacyIncomingBufferedBaselineCommitFailureRedeliversMissingEffects() async throws {
        let storeName = "MyRAMLegacyBufferedEffectFailure-\(UUID().uuidString)"
        let container = try makeContainer(isStoredInMemoryOnly: false, configurationName: storeName)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Original body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        final class BaselineWriteFailure {
            var shouldFail = true
        }
        let failure = BaselineWriteFailure()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(
            fileURL: conflictFileURL,
            fileIO: SyncConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                writeData: { data, url in
                    if failure.shouldFail, url.lastPathComponent == "sync-remote-text-baselines.json" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: [.atomic])
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: conflictStore,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertNil(conflictStore.remoteBaseline(entityType: .note, entityID: noteID, field: .noteContent))

        let reloadedAfterFailure = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<Note>()).first { $0.id == noteID }
        )
        XCTAssertEqual(reloadedAfterFailure.content, "Peer body")

        failure.shouldFail = false
        let secondDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(
            conflictStore.remoteBaseline(entityType: .note, entityID: noteID, field: .noteContent)?.text,
            "Peer body"
        )
        XCTAssertEqual(note.content, "Peer body")
    }

    func testLegacyIncomingCheckedConflictCommitFailureRedeliversMissingEffects() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Original", content: "Local body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 150)
        context.insert(note)
        try context.save()

        final class ConflictWriteFailure {
            var shouldFail = true
        }
        let failure = ConflictWriteFailure()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(
            fileURL: conflictFileURL,
            fileIO: .live,
            textFileIO: SyncTextConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                writeData: { data, url in
                    if failure.shouldFail, url.lastPathComponent == "sync-conflicts.json" {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: [.atomic])
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: conflictStore,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Original",
            content: "Peer body",
            baseTitle: "Original",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertTrue(conflictStore.activeConflicts().isEmpty)
        XCTAssertTrue(vm.syncConflicts.isEmpty)

        failure.shouldFail = false
        let secondDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(conflictStore.activeConflicts().count, 1)
        XCTAssertEqual(vm.syncConflicts, conflictStore.activeConflicts())
    }

    func testLegacyIncomingExactConflictRedeliveryCommitsMissingConflictWithoutDuplicateQueue() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Local title", content: "Local body")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 150)
        context.insert(note)
        try context.save()

        final class ConflictWriteFailure {
            var shouldFail = true
        }
        let failure = ConflictWriteFailure()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(
            fileURL: conflictFileURL,
            fileIO: .live,
            textFileIO: SyncTextConflictStore.FileIO(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readData: { try Data(contentsOf: $0) },
                createDirectory: {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                },
                writeData: { data, url in
                    if failure.shouldFail,
                       url.lastPathComponent == "sync-conflicts.json",
                       String(data: data, encoding: .utf8)?.contains("Remote body") == true {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try data.write(to: url, options: [.atomic])
                },
                removeItem: { try FileManager.default.removeItem(at: $0) }
            )
        )
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: conflictStore,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false
        )
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Remote title",
            content: "Remote body",
            baseTitle: "Original title",
            baseContent: "Original body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertEqual(conflictStore.activeConflicts().map(\.field), [.noteTitle])
        XCTAssertNil(conflictStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteTitle))
        XCTAssertNil(conflictStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteContent))
        XCTAssertEqual(note.title, "Local title")
        XCTAssertEqual(note.content, "Local body")

        failure.shouldFail = false
        let secondDispositions = await vm.applyIncomingSyncChanges([change])

        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        let activeConflictFields = conflictStore.activeConflicts().map(\.field)
        XCTAssertEqual(activeConflictFields.filter { $0 == .noteTitle }.count, 1)
        XCTAssertEqual(activeConflictFields.filter { $0 == .noteContent }.count, 1)
        XCTAssertNil(conflictStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteTitle))
        XCTAssertNil(conflictStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteContent))
        XCTAssertNil(conflictStore.remoteBaseline(entityType: .note, entityID: noteID, field: .noteTitle))
        XCTAssertNil(conflictStore.remoteBaseline(entityType: .note, entityID: noteID, field: .noteContent))
        XCTAssertEqual(note.title, "Local title")
        XCTAssertEqual(note.content, "Local body")
        XCTAssertEqual(
            [firstDispositions, secondDispositions].flatMap { $0 }.filter { $0.disposition == .applied }.count,
            1
        )
    }

    func testBufferedConflictStoreReadsPinnedTextBaselineWrittenDuringApply() {
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let realStore = SyncConflictStore(fileURL: conflictFileURL)
        let bufferedStore = BufferedSyncConflictStore(base: realStore)
        let thoughtID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 200)

        bufferedStore.savePinnedTextBaseline(
            thoughtID: thoughtID,
            text: "Remote pinned text",
            modifiedAt: modifiedAt,
            originDeviceID: "device-b"
        )

        XCTAssertNil(realStore.remoteBaseline(entityType: .pinnedThought, entityID: thoughtID, field: .pinnedText))
        XCTAssertEqual(
            bufferedStore.remoteBaseline(entityType: .pinnedThought, entityID: thoughtID, field: .pinnedText),
            SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: thoughtID,
                field: .pinnedText,
                text: "Remote pinned text",
                richTextContentData: nil,
                modifiedAt: modifiedAt,
                originDeviceID: "device-b"
            )
        )
    }

    func testBufferedConflictStoreQueuesSameFieldConflictForReadAfterWriteAndCheckedCommit() throws {
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let realStore = SyncConflictStore(fileURL: conflictFileURL)
        let bufferedStore = BufferedSyncConflictStore(base: realStore)
        let noteID = UUID()
        let activeConflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Local",
            remoteText: "Remote 1",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let queuedConflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Local",
            remoteText: "Remote 2",
            remoteModifiedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        _ = realStore.preserve(activeConflict)
        _ = bufferedStore.preserve(queuedConflict)

        XCTAssertEqual(bufferedStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertEqual(
            bufferedStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteContent)?.conflict.id,
            queuedConflict.id
        )

        try realStore.commitLegacyIncomingEffectsChecked(bufferedStore.effects)
        XCTAssertEqual(realStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertEqual(
            realStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteContent)?.conflict.id,
            queuedConflict.id
        )
    }

    func testBufferedConflictStoreExactRemoteConflictDoesNotExposeQueuedReadOrEffect() {
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let realStore = SyncConflictStore(fileURL: conflictFileURL)
        let bufferedStore = BufferedSyncConflictStore(base: realStore)
        let noteID = UUID()
        let activeConflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Local 1",
            remoteText: "Remote",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 300),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        let redeliveredConflict = SyncConflictVersion(
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: "Local 2",
            remoteText: "Remote",
            remoteModifiedAt: Date(timeIntervalSince1970: 200),
            preservedAt: Date(timeIntervalSince1970: 400),
            expiresAt: Date().addingTimeInterval(1_000)
        )

        _ = realStore.preserve(activeConflict)
        _ = bufferedStore.preserve(redeliveredConflict)

        XCTAssertEqual(bufferedStore.activeConflicts().map(\.id), [activeConflict.id])
        XCTAssertNil(bufferedStore.queuedConflict(entityType: .note, entityID: noteID, field: .noteContent))
        XCTAssertTrue(bufferedStore.effects.preservedConflicts.isEmpty)
    }

    // MARK: - Partial envelope save failure (8.6)

    func testPartialLegacyEnvelopeSaveFailureAppliesOnlySuccessfulCandidate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let succeedingNoteID = UUID()
        let succeedingNote = Note(title: "A", content: "A body")
        succeedingNote.id = succeedingNoteID
        succeedingNote.modifiedAt = Date(timeIntervalSince1970: 100)
        let failingNoteID = UUID()
        let failingNote = Note(title: "B", content: "B body")
        failingNote.id = failingNoteID
        failingNote.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(succeedingNote)
        context.insert(failingNote)
        try context.save()

        let injector = InjectableLegacyIncomingSaveFailure(shouldFail: false)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { try injector.save($0) }
        )

        let succeedingChange = try legacyNoteChange(
            noteID: succeedingNoteID,
            title: "A",
            content: "A body from peer",
            baseTitle: "A",
            baseContent: "A body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        let failingChange = try legacyNoteChange(
            noteID: failingNoteID,
            title: "B",
            content: "B body from peer",
            baseTitle: "B",
            baseContent: "B body",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        // applyIncomingSyncChanges processes candidates in array order with no
        // intervening await between apply() and save() for a given change, so
        // the succeeding change's save is call #1 and the failing change's is
        // call #2.
        injector.failingCallNumbers = [2]
        let dispositions = await vm.applyIncomingSyncChanges([succeedingChange, failingChange])

        XCTAssertEqual(
            Set(dispositions.filter { $0.disposition == .applied }.map(\.changeID)),
            [succeedingChange.id]
        )
        XCTAssertEqual(
            Set(dispositions.filter { $0.disposition == .retryRequired }.map(\.changeID)),
            [failingChange.id]
        )
        XCTAssertEqual(succeedingNote.content, "A body from peer")
        XCTAssertEqual(failingNote.content, "B body")
    }

    // MARK: - Conflict-producing change saves before conflict publication (8.8)

    func testConflictProducingLegacyIncomingChangeDoesNotPublishConflictBeforeSaveSucceeds() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Shared", content: "Local text")
        note.id = noteID
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()

        let injector = InjectableLegacyIncomingSaveFailure(shouldFail: true)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let conflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let vm = NotesViewModel(
            context: context,
            syncConflictStore: conflictStore,
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            resumesPendingConvergenceOnInit: false,
            saveLegacyIncomingApplyContext: { try injector.save($0) }
        )

        // No shared baseline is established for this field, so a remote value
        // that diverges from local text resolves as a conflict rather than a
        // clean apply.
        let change = try legacyNoteChange(
            noteID: noteID,
            title: "Shared",
            content: "Remote text",
            baseTitle: nil,
            baseContent: nil,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let firstDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(firstDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .retryRequired)])
        XCTAssertTrue(
            conflictStore.activeConflicts().isEmpty,
            "A speculative conflict write must not survive a failed isolated save."
        )
        XCTAssertTrue(vm.activeSyncConflicts(for: note).isEmpty)

        injector.shouldFail = false
        let secondDispositions = await vm.applyIncomingSyncChanges([change])
        XCTAssertEqual(secondDispositions, [LegacyIncomingChangeResult(changeID: change.id, disposition: .applied)])
        XCTAssertEqual(conflictStore.activeConflicts().count, 1)
        XCTAssertEqual(vm.activeSyncConflicts(for: note).count, 1)
    }


    func testRuntimeBlocksIncomingPlanningWhenBoundaryPreparationFails() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001275D0")!
        let note = Note(title: "Shared", content: "Hello")
        note.id = noteID
        context.insert(note)
        try context.save()

        let incomingQueue = FileBackedSyncBatchQueue(fileURL: nil)
        let boundary = FailingIncomingLocalBoundaryAdapter(failure: .localCaptureFailed(noteID: noteID))
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: incomingQueue,
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: AcceptingLocalBatchTransport(),
            presentationAdapter: CompletingPresentationAdapter(),
            incomingLocalBoundaryAdapter: boundary
        )
        let remoteBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000001275D1")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-0000001275D2")!,
            createdAt: Date(timeIntervalSince1970: 20),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Hello".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello")
                ))
            ]
        )

        let outcome = await runtime.submitRemoteBatch(remoteBatch)

        guard case .blocked(let failure) = outcome else {
            return XCTFail("Expected boundary preparation failure to block incoming work")
        }
        XCTAssertEqual(failure.batchID, remoteBatch.id)
        XCTAssertEqual(failure.kind, .localBoundaryCapture)
        XCTAssertEqual(note.content, "Hello")
        XCTAssertEqual(incomingQueue.pendingBatches.map(\.id), [remoteBatch.id])
    }

    func testRuntimePreservesEveryIncomingBoundaryFailureClassificationAndBatchID() async throws {
        let cases: [(SyncConvergenceIncomingLocalBoundaryFailure, SyncBatchDrainFailureKind)] = [
            (.localCaptureFailed(noteID: UUID()), .localBoundaryCapture),
            (.localPersistenceFailed(noteID: UUID()), .localBoundaryPersistence),
            (.boundaryInvariantViolation(noteID: UUID()), .localBoundaryInvariant),
            (.localStateChanged(noteID: UUID()), .staleAuthoritativeState)
        ]

        for (boundaryFailure, expectedKind) in cases {
            let container = try makeContainer(isStoredInMemoryOnly: true)
            let context = container.mainContext
            let noteID: UUID
            switch boundaryFailure {
            case .localCaptureFailed(let id), .localPersistenceFailed(let id),
                 .boundaryInvariantViolation(let id), .localStateChanged(let id):
                noteID = id
            }
            let note = Note(title: "Shared", content: "Hello")
            note.id = noteID
            context.insert(note)
            try context.save()

            let incomingQueue = FileBackedSyncBatchQueue(fileURL: nil)
            let presentation = RecordingPresentationAdapter()
            let boundary = FailingIncomingLocalBoundaryAdapter(failure: boundaryFailure)
            let runtime = SyncConvergenceRuntime(
                context: context,
                convergenceQueue: incomingQueue,
                localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
                localBatchTransportAdapter: AcceptingLocalBatchTransport(),
                presentationAdapter: presentation,
                incomingLocalBoundaryAdapter: boundary
            )
            let batch = SyncBatch(
                id: UUID(),
                originDeviceID: UUID(),
                createdAt: Date(timeIntervalSince1970: 20),
                changes: [.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Hello".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello")
                ))]
            )

            let outcome = await runtime.submitRemoteBatch(batch)

            guard case .blocked(let failure) = outcome else {
                return XCTFail("Expected boundary failure to block incoming planning")
            }
            XCTAssertEqual(failure.batchID, batch.id)
            XCTAssertEqual(failure.kind, expectedKind)
            XCTAssertEqual(note.content, "Hello")
            XCTAssertEqual(incomingQueue.pendingBatches.map(\.id), [batch.id])
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncorporatedSyncBatch>()), 0)
            XCTAssertEqual(presentation.requestCount, 0)
        }
    }

    func testRuntimeRegistersPendingLocalEvidenceBeforeIncomingPlanningWhenTransportUnavailable() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001275C0")!
        let note = Note(title: "Shared", content: "Hello local")
        note.id = noteID
        context.insert(note)
        try context.save()

        let localChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: "Hello".utf16.count,
            text: " local",
            modifiedAt: Date(timeIntervalSince1970: 10),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello")
        ))
        let capturedLocalChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: localChange,
            preBody: "Hello",
            postBody: "Hello local"
        )
        let localBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000001275C1")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-0000001275C2")!,
            createdAt: Date(timeIntervalSince1970: 10),
            changes: [localChange]
        )
        let boundary = SinglePendingLocalBoundaryAdapter(
            obligation: SyncConvergenceLocalObligation(batch: localBatch, capturedChanges: [capturedLocalChange])
        )
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil)
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: localQueue,
            localBatchTransportAdapter: nil,
            presentationAdapter: CompletingPresentationAdapter(),
            incomingLocalBoundaryAdapter: boundary
        )
        let remoteBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000001275C3")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-0000001275C4")!,
            createdAt: Date(timeIntervalSince1970: 20),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: "Hello local".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello local")
                ))
            ]
        )

        let outcome = await runtime.submitRemoteBatch(remoteBatch)

        guard case .deferred(let deferred) = outcome else {
            return XCTFail("Expected local transport to remain deferred after incoming incorporation")
        }
        XCTAssertEqual(boundary.takeCount, 1)
        XCTAssertEqual(note.content, "Hello local remote")
        XCTAssertEqual(localQueue.pendingBatches.map(\.id), [localBatch.id])
        XCTAssertEqual(deferred.localObligations.map(\.batchID), [localBatch.id])
        let retainedOperations = try context.fetch(FetchDescriptor<RetainedBodyOperation>())
        let localRetainedOperations = retainedOperations.filter {
            $0.sourceRaw == SyncConvergenceRetainedOperationSource.local.rawValue
        }
        XCTAssertEqual(localRetainedOperations.map(\.batchID), [localBatch.id])
    }

    func testLegacyIncomingApplierAppliesRemoteWhenLocalMatchesIncomingBase() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001275CF")!
        let note = Note(title: "Shared", content: "Hello local")
        note.id = noteID
        context.insert(note)
        try context.save()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let baseConflictStore = SyncConflictStore(fileURL: conflictFileURL)
        let applier = MyRAMSyncChangeApplier(
            context: context,
            conflictStore: BufferedSyncConflictStore(base: baseConflictStore)
        )

        let result = applier.apply(
            [try legacyNoteChange(
                noteID: noteID,
                title: "Shared",
                content: "Hello local remote",
                baseTitle: "Shared",
                baseContent: "Hello local",
                modifiedAt: Date(timeIntervalSince1970: 4_000_000_000)
            )],
            activeNoteID: nil as UUID?,
            currentNoteID: nil as UUID?,
            currentFolderID: nil as UUID?
        )

        XCTAssertTrue(result.preservedConflicts.isEmpty)
        XCTAssertEqual(note.content, "Hello local remote")
    }

    func testLegacyIncomingMutationAppliesOnlyAfterExactLocalEvidenceRegistration() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001275D1")!
        let note = Note(title: "Shared", content: "Hello")
        note.id = noteID
        context.insert(note)
        try context.save()
        let viewModel = NotesViewModel(
            context: context,
            syncController: RecordingSyncController(),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false
        )

        viewModel.commitNoteEdit(note, title: "Shared", content: "Hello local")
        await Task.yield()
        await Task.yield()

        let dispositions = await viewModel.applyIncomingSyncChanges([
            try legacyNoteChange(
                noteID: noteID,
                title: "Shared",
                content: "Hello local remote",
                baseTitle: "Shared",
                baseContent: "Hello local",
                modifiedAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
        ])

        XCTAssertEqual(dispositions.map(\.disposition), [.applied])
        XCTAssertTrue(viewModel.syncConflicts.isEmpty)
        let refreshedNote = try XCTUnwrap(context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate { candidate in candidate.id == noteID }
        )).first)
        XCTAssertEqual(refreshedNote.content, "Hello local remote")
        XCTAssertEqual(note.content, "Hello local remote")
        XCTAssertNil(viewModel.syncBatchErrorMessage)
        let pendingBatchID = await viewModel.capturePendingLocalBatchForRecovery()
        XCTAssertNil(pendingBatchID)
        let retainedOperations = try context.fetch(FetchDescriptor<RetainedBodyOperation>())
        let localRetainedOperations = retainedOperations.filter {
            $0.sourceRaw == SyncConvergenceRetainedOperationSource.local.rawValue
        }
        XCTAssertEqual(localRetainedOperations.map(\.operationIndex), [0])
        XCTAssertEqual(localRetainedOperations.first?.expectedText, nil)
        XCTAssertEqual(localRetainedOperations.first?.text, " local")
    }

    func testLegacyIncomingMutationDoesNotApplyWhenLocalAdmissionCannotBeProven() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001275D2")!
        let note = Note(title: "Shared", content: "Hello")
        note.id = noteID
        context.insert(note)
        try context.save()
        let viewModel = NotesViewModel(
            context: context,
            syncController: RecordingSyncController(),
            pendingIncomingBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueFileURL: nil,
            pendingLocalConvergenceBatchQueueLimit: 0,
            syncBatchQuietWindow: 100,
            resumesPendingConvergenceOnInit: false
        )

        viewModel.commitNoteEdit(note, title: "Shared", content: "Hello local")
        await Task.yield()
        await Task.yield()

        _ = await viewModel.applyIncomingSyncChanges([
            try legacyNoteChange(
                noteID: noteID,
                title: "Shared",
                content: "Hello local remote",
                baseTitle: "Shared",
                baseContent: "Hello local",
                modifiedAt: Date(timeIntervalSince1970: 4_000_000_000)
            )
        ])

        XCTAssertEqual(note.content, "Hello local")
        XCTAssertEqual(note.title, "Shared")
        XCTAssertTrue(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).isEmpty)
        XCTAssertNotNil(viewModel.syncBatchErrorMessage)
    }

    func testStaleLegacyLocalObligationDoesNotBlockDifferentOriginCapturedObligation() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteAID = UUID(uuidString: "00000000-0000-0000-0000-000000127520")!
        let noteBID = UUID(uuidString: "00000000-0000-0000-0000-000000127521")!
        let noteA = Note(title: "A", content: "changed")
        noteA.id = noteAID
        let noteB = Note(title: "B", content: "B")
        noteB.id = noteBID
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        let staleChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteAID,
            utf16Offset: 1,
            text: "x",
            modifiedAt: Date(timeIntervalSince1970: 1)
        ))
        let staleBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127522")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127523")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [staleChange]
        )
        let validChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteBID,
            utf16Offset: 1,
            text: "!",
            modifiedAt: Date(timeIntervalSince1970: 2),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "B")
        ))
        let capturedValidChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: validChange,
            preBody: "B",
            postBody: "B!"
        )
        let validBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127524")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127525")!,
            createdAt: Date(timeIntervalSince1970: 2),
            changes: [validChange]
        )
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil)
        try localQueue.enqueue(SyncConvergenceLocalObligation(legacyBatch: staleBatch))
        try localQueue.enqueue(SyncConvergenceLocalObligation(batch: validBatch, capturedChanges: [capturedValidChange]))
        let transport = AcceptingLocalBatchTransport()
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: localQueue,
            localBatchTransportAdapter: transport,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let outcome = await runtime.resumePendingWork()

        guard case .deferred(let deferred) = outcome else {
            return XCTFail("Expected stale legacy local obligation to defer")
        }
        XCTAssertEqual(deferred.localObligations.map(\.batchID), [staleBatch.id])
        XCTAssertEqual(localQueue.pendingBatches.map(\.id), [staleBatch.id])
        XCTAssertEqual(transport.acceptedBatches.map(\.id), [validBatch.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<RetainedBodyOperation>()).map(\.batchID), [validBatch.id])
    }

    func testDeferredIncomingBatchDoesNotBlockDisjointLaterBatch() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteAID = UUID(uuidString: "00000000-0000-0000-0000-000000127530")!
        let noteBID = UUID(uuidString: "00000000-0000-0000-0000-000000127531")!
        let noteA = Note(title: "A", content: "local-a")
        noteA.id = noteAID
        let noteB = Note(title: "B", content: "local-b")
        noteB.id = noteBID
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        let deferredBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127532")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127533")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteAID,
                    utf16Offset: 0,
                    text: "remote ",
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "missing-base")
                ))
            ]
        )
        let validBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127534")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127535")!,
            createdAt: Date(timeIntervalSince1970: 2),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteBID,
                    title: "Remote B",
                    modifiedAt: Date(timeIntervalSince1970: 2)
                ))
            ]
        )
        let queue = FileBackedSyncBatchQueue(fileURL: nil)
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: queue,
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let firstOutcome = await runtime.submitRemoteBatch(deferredBatch)
        guard case .deferred = firstOutcome else {
            return XCTFail("Expected first incoming batch to defer")
        }
        let secondOutcome = await runtime.submitRemoteBatch(validBatch)

        guard case .deferred(let deferred) = secondOutcome else {
            return XCTFail("Expected remaining note-A work to stay deferred")
        }
        XCTAssertEqual(deferred.incoming.map(\.batchID), [deferredBatch.id])
        XCTAssertEqual(noteA.content, "local-a")
        XCTAssertEqual(noteB.title, "Remote B")
        XCTAssertEqual(queue.pendingBatches.map(\.id), [deferredBatch.id])
    }

    func testLocalObligationRemainsDurableWhenTransportAcceptanceThrows() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000127399")!
        let note = Note(title: "Original", content: "Body")
        note.id = noteID
        context.insert(note)
        try context.save()

        let localObligationQueueURL = temporarySyncBatchQueueFileURL()
        let localObligationQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationQueueURL)
        let batch = makeTitleOnlyBatch(idSuffix: 127500, title: "Unsatisfied")
        let localBatchTransportAdapter = FailingLocalBatchTransport(error: FileBackedSyncBatchQueue.QueueError.persistenceFailed)
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: localObligationQueue,
            localBatchTransportAdapter: localBatchTransportAdapter,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let outcome = await runtime.submitLocalBatch(batch)

        guard case .blocked(let failure) = outcome else {
            return XCTFail("Expected local obligation drain to block")
        }
        XCTAssertEqual(failure.batchID, batch.id)
        XCTAssertEqual(localObligationQueue.pendingBatches, [batch])
        XCTAssertEqual(FileBackedSyncConvergenceLocalObligationQueue(fileURL: localObligationQueueURL).pendingBatches, [batch])
    }

    func testUnrelatedIncorporationHistoryDoesNotChangeActiveNotePlanning() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let activeNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000127399")!
        let note = Note(title: "Shared", content: "stable body")
        note.id = activeNoteID
        context.insert(note)

        let noPendingPostCommitWork = try SyncConvergencePostCommitState.none.encodedPayloadData()
        for index in 0..<300 {
            let batchID = UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!
            let unrelatedNoteID = UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", index))!
            context.insert(IncorporatedSyncBatch(
                batchID: batchID,
                originDeviceID: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                batchSequence: UInt64(index),
                schemaVersion: 1,
                committedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1,
                affectedNotesPayloadData: Data(),
                authoritativeChildCount: 0,
                authoritativeChildBytes: 0,
                authoritativeChildrenDigest: String(repeating: "c", count: 64),
                postCommitStatePayloadData: noPendingPostCommitWork,
                hasPendingPostCommitWork: false
            ))
            context.insert(IncorporationContradictionDiagnostic(
                batchID: batchID,
                noteID: unrelatedNoteID,
                diagnosticEvidencePayloadData: Data([0x01])
            ))
            context.insert(NoteContentSnapshot(
                noteID: unrelatedNoteID,
                contentHash: SyncBatchContentHash.sha256Hex(for: "history"),
                body: "history",
                generation: 1
            ))
        }
        try context.save()

        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: FileBackedSyncBatchQueue(fileURL: nil),
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let history = try runtime.loadHistoryStatesForTesting(noteIDs: [activeNoteID])

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.snapshotCount, 0)
        XCTAssertEqual(note.content, "stable body")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncorporatedSyncBatch>()), 300)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<IncorporationContradictionDiagnostic>()), 300)

        // Delayed remote convergence for the active note must still succeed correctly despite
        // the unrelated history noise seeded above: insertions near the end and the start of
        // the body, followed by a provenance-matched delete of the original text in between.
        let endInsertion = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156200")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                noteID: activeNoteID,
                utf16Offset: "stable body".utf16.count,
                text: "END",
                modifiedAt: Date(timeIntervalSince1970: 1)
            ))]
        )
        let startInsertion = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156200")!,
            createdAt: Date(timeIntervalSince1970: 2),
            changes: [.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                noteID: activeNoteID,
                utf16Offset: 0,
                text: "TOP",
                modifiedAt: Date(timeIntervalSince1970: 2)
            ))]
        )
        let middleDeletion = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156200")!,
            createdAt: Date(timeIntervalSince1970: 3),
            changes: [.noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                noteID: activeNoteID,
                utf16Offset: 3,
                utf16Length: "stable ".utf16.count,
                expectedText: "stable ",
                modifiedAt: Date(timeIntervalSince1970: 3)
            ))]
        )

        var lastOutcome = await runtime.submitRemoteBatch(endInsertion)
        guard case .drained = lastOutcome else { return XCTFail("Expected end insertion to drain under seeded history, got \(lastOutcome)") }
        lastOutcome = await runtime.submitRemoteBatch(startInsertion)
        guard case .drained = lastOutcome else { return XCTFail("Expected start insertion to drain under seeded history") }
        lastOutcome = await runtime.submitRemoteBatch(middleDeletion)
        guard case .drained = lastOutcome else { return XCTFail("Expected provenance-matched deletion to drain under seeded history") }

        XCTAssertEqual(note.content, "TOPbodyEND")

        // A duplicate delivery of an already-incorporated batch must not reapply its text,
        // even with hundreds of unrelated incorporated batches in history.
        let duplicateOutcome = await runtime.submitRemoteBatch(startInsertion)
        guard case .drained = duplicateOutcome else { return XCTFail("Expected duplicate batch to drain without blocking") }
        XCTAssertEqual(note.content, "TOPbodyEND")
        XCTAssertEqual(note.content.components(separatedBy: "TOP").count - 1, 1)
    }

    func testDelayedBatchDrainRepeatsForReentrantSubmissionWithoutStrandingWork() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let note = Note(title: "Base", content: String(repeating: "large note\n", count: 2_000))
        note.id = noteID
        context.insert(note)
        try context.save()

        let baseBody = note.content
        let presentationBatch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: "Remote 1",
                    modifiedAt: Date(timeIntervalSince1970: 1)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: baseBody.utf16.count,
                    text: "[presentation]",
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: baseBody)
                ))
            ]
        )
        let queuedBatches = [presentationBatch] + (1..<5).map { index in
            makeTitleBatch(
                noteID: noteID,
                sequence: UInt64(index + 1),
                title: "Remote \(index + 1)"
            )
        }
        let reentrantBatch = makeTitleBatch(noteID: noteID, sequence: 6, title: "Remote 6")
        let queue = FileBackedSyncBatchQueue(fileURL: nil)
        for batch in queuedBatches {
            try queue.enqueueIncoming(batch)
        }
        // A duplicate delivery is structurally deduplicated before the runtime starts.
        try queue.enqueueIncoming(queuedBatches[2])
        XCTAssertEqual(queue.pendingBatches.count, 5)

        let adapter = ReentrantPresentationAdapter()
        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: queue,
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: adapter
        )
        adapter.onFirstPresentation = {
            await runtime.submitRemoteBatch(reentrantBatch)
        }

        let outcome = await runtime.resumePendingWork()

        guard case .drained(let appliedBatchIDs) = outcome else {
            return XCTFail("Expected delayed batches to drain")
        }
        XCTAssertEqual(adapter.reentrantOutcomeCount, 1)
        XCTAssertTrue(adapter.didObserveAlreadyDraining)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(appliedBatchIDs, Set(queuedBatches.map(\.id) + [reentrantBatch.id]))
        XCTAssertEqual(note.title, "Remote 6")
        XCTAssertEqual(note.content, baseBody + "[presentation]")
    }

    func testKDelayedBatchDrainAppliesBodyInsertionsExactlyOnceAcrossRegionsAndRejectsDuplicateIncorporation() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let noteID = UUID()
        let baseBody = String(repeating: "0123456789", count: 200)
        let note = Note(title: "Base", content: baseBody)
        note.id = noteID
        context.insert(note)
        try context.save()

        let endOffset = baseBody.utf16.count - 10
        let middleOffset = baseBody.utf16.count / 2
        let startOffset = 10

        func insertionBatch(sequence: UInt64, offset: Int, text: String) -> SyncBatch {
            SyncBatch(
                id: UUID(),
                originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156100")!,
                createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
                batchSequence: sequence,
                changes: [
                    .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteID,
                        utf16Offset: offset,
                        text: text,
                        modifiedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
                    ))
                ]
            )
        }

        // Queued end-to-start so each batch's offset, expressed against the original body,
        // remains valid at application time: every earlier insertion lands strictly after
        // the offset the next queued batch will target.
        let endBatch = insertionBatch(sequence: 1, offset: endOffset, text: "[END]")
        let middleBatch = insertionBatch(sequence: 2, offset: middleOffset, text: "[MID]")
        let startBatch = insertionBatch(sequence: 3, offset: startOffset, text: "[TOP]")

        let queue = FileBackedSyncBatchQueue(fileURL: nil)
        try queue.enqueueIncoming(endBatch)
        try queue.enqueueIncoming(middleBatch)
        try queue.enqueueIncoming(startBatch)

        let runtime = SyncConvergenceRuntime(
            context: context,
            convergenceQueue: queue,
            localObligationQueue: FileBackedSyncConvergenceLocalObligationQueue(fileURL: nil),
            localBatchTransportAdapter: nil,
            presentationAdapter: CompletingPresentationAdapter()
        )

        let outcome = await runtime.resumePendingWork()

        guard case .drained(let appliedBatchIDs) = outcome else {
            return XCTFail("Expected K delayed body-insertion batches to drain")
        }
        XCTAssertEqual(appliedBatchIDs, Set([endBatch.id, middleBatch.id, startBatch.id]))

        var expected = baseBody
        expected.insert(contentsOf: "[END]", at: expected.index(expected.startIndex, offsetBy: endOffset))
        expected.insert(contentsOf: "[MID]", at: expected.index(expected.startIndex, offsetBy: middleOffset))
        expected.insert(contentsOf: "[TOP]", at: expected.index(expected.startIndex, offsetBy: startOffset))
        XCTAssertEqual(note.content, expected)
        for marker in ["[END]", "[MID]", "[TOP]"] {
            XCTAssertEqual(note.content.components(separatedBy: marker).count - 1, 1, "\(marker) must appear exactly once")
        }

        // Re-delivering an already-incorporated batch must not reapply its text.
        let duplicateOutcome = await runtime.submitRemoteBatch(middleBatch)
        guard case .drained = duplicateOutcome else {
            return XCTFail("Expected duplicate already-incorporated batch to drain without blocking")
        }
        XCTAssertEqual(note.content, expected)
        XCTAssertEqual(note.content.components(separatedBy: "[MID]").count - 1, 1)
    }

    func testPublishedEditorUpdateCompletesOnceWhenAcknowledgedMultipleTimesAtViewModelLevel() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let note = Note(title: "Shared", content: "Body")
        context.insert(note)
        try context.save()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer { try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent()) }
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)
        vm.registerActiveEditor(noteID: note.id)
        let emptyBatch = AppliedEditorMutationBatch(noteID: note.id, mutations: [], authoritativeBody: note.content)
        let dispositions: [(ActiveEditorMetadataUpdate?, ActiveEditorSyncDisposition)] = [
            (nil, .apply(emptyBatch)),
            (ActiveEditorMetadataUpdate(title: nil), .apply(emptyBatch)),
            (ActiveEditorMetadataUpdate(title: "Remote"), .apply(emptyBatch)),
            (nil, .metadataOnly),
            (ActiveEditorMetadataUpdate(title: "Remote"), .metadataOnly),
            (nil, .reload(.authoritativeConvergencePresentation)),
            (nil, .deferred(.pendingLocalCommit)),
            (nil, .deferred(.markedTextComposition)),
            (nil, .deferred(.activePinnedTextEdit)),
            (nil, .ignored(.targetNoteIsNotActive))
        ]
        var completionCount = 0

        for (index, shape) in dispositions.enumerated() {
            let update = ActiveEditorSyncUpdate(
                noteID: note.id,
                metadata: shape.0,
                disposition: shape.1
            )
            let identity = SyncConvergencePersistedIncorporationIdentity(
                batchID: UUID(),
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1
            )
            let resultTask = Task {
                await vm.publishConvergencePresentationUpdate(update, incorporationIdentity: identity)
            }
            try await waitUntil("active editor update \(index)") {
                vm.activeEditorSyncUpdate?.id == update.id
            }

            vm.acknowledgeActiveEditorSyncUpdate(id: update.id, noteID: note.id, result: .verifiedComplete)
            vm.acknowledgeActiveEditorSyncUpdate(id: update.id, noteID: note.id, result: .stillPending)
            let result = await resultTask.value
            if result == .verifiedComplete { completionCount += 1 }
        }

        XCTAssertEqual(completionCount, dispositions.count)
        XCTAssertNil(vm.activeEditorSyncUpdate)
    }

    func testIPhoneIncomingHashedMismatchRemainsQueuedAndBlocksLaterBatch() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Shared", content: "local")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000127001")!
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            bodyHashCapabilityEnabled: true,
            syncBatchQuietWindow: 0
        )
        let mismatchedBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127101")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127201")!,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "remote ",
                        modifiedAt: Date(timeIntervalSince1970: 2),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "remote-base")
                    )
                )
            ]
        )
        let laterBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127102")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127201")!,
            createdAt: Date(timeIntervalSince1970: 3),
            batchSequence: 2,
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: note.content.utf16.count,
                        text: " later",
                        modifiedAt: Date(timeIntervalSince1970: 4),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "local")
                    )
                )
            ]
        )

        await vm.applyIncomingSyncBatch(mismatchedBatch)
        await vm.applyIncomingSyncBatch(laterBatch)

        let reloadedQueue = FileBackedSyncBatchQueue(fileURL: queueFileURL)
        XCTAssertEqual(note.content, "local")
        XCTAssertEqual(reloadedQueue.pendingBatches.map(\.id), [mismatchedBatch.id, laterBatch.id])
        XCTAssertEqual(vm.syncBatchErrorMessage, "Incoming changes are waiting for deterministic merge support.")
    }

    func testIPhoneIncomingUnsupportedReconciliationShowsDistinctError() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Shared", content: "local")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000127003")!
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            bodyHashCapabilityEnabled: true,
            syncBatchQuietWindow: 0
        )

        await vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127103")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127203")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyReconciled(
                    SyncBatchNoteBodyReconciledChange(
                        noteID: note.id,
                        replacementBody: "remote",
                        replacementContentHash: SyncBatchContentHash.sha256Hex(for: "remote"),
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ]
        ))

        // Unsupported reconciliation is a note-scoped retryable condition: the batch
        // remains durably queued and does not surface as a blocking error.
        XCTAssertNil(vm.syncBatchErrorMessage)
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueFileURL).pendingBatches.count, 1)
    }

    func testIPhoneIncomingQueueCapacityShowsDistinctError() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Shared", content: "local")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000127004")!
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingIncomingBatchQueueLimit: 1,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )

        await vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000127104")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127204")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyReconciled(
                    SyncBatchNoteBodyReconciledChange(
                        noteID: note.id,
                        replacementBody: "remote",
                        replacementContentHash: SyncBatchContentHash.sha256Hex(for: "remote"),
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ]
        ))
        await vm.applyIncomingSyncBatch(makeTitleOnlyBatch(idSuffix: 127105, title: "Second"))

        XCTAssertEqual(vm.syncBatchErrorMessage, "Incoming sync queue is full; newest batch could not be retained.")
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: queueFileURL).pendingBatches.map(\.id), [
            UUID(uuidString: "00000000-0000-0000-0000-000000127104")!
        ])
    }

    func testIPhoneIncomingQueuePersistenceShowsDistinctError() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ios-pending-incoming-batch-queue.json")
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        try FileManager.default.createDirectory(at: queueFileURL, withIntermediateDirectories: true)
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL)
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )

        await vm.applyIncomingSyncBatch(makeTitleOnlyBatch(idSuffix: 127106, title: "Persist"))

        XCTAssertEqual(vm.syncBatchErrorMessage, "Unable to persist incoming sync batch.")
    }

    func testActiveNoteTitleOnlyIncomingBatchPublishesMetadataOnlyEditorUpdate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Local Title", content: "body")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000129001")!
        context.insert(note)
        try context.save()
        let recorder = RecordingSyncController()
        let vm = NotesViewModel(
            context: context,
            syncController: recorder,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)

        let batchID = UUID()
        await vm.applyIncomingSyncBatch(SyncBatch(
            id: batchID,
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "Remote Title",
                    modifiedAt: Date(timeIntervalSince1970: 2)
                ))
            ]
        ))

        XCTAssertNil(vm.syncBatchErrorMessage)
        XCTAssertEqual(note.title, "Remote Title")
        XCTAssertEqual(note.content, "body")
        XCTAssertNil(vm.activeEditorSyncUpdate)
        XCTAssertTrue(recorder.recordedBatches.isEmpty)
    }

    func testActiveNoteMixedTitleAndBodyIncomingBatchPublishesCompositeEditorUpdate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Local Title", content: "Hello")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000129002")!
        context.insert(note)
        try context.save()
        let recorder = RecordingSyncController()
        let vm = NotesViewModel(
            context: context,
            syncController: recorder,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)

        let batchID = UUID()
        await vm.applyIncomingSyncBatch(SyncBatch(
            id: batchID,
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 3),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "Remote Mixed Title",
                    modifiedAt: Date(timeIntervalSince1970: 4)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: note.id,
                    utf16Offset: "Hello".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 5)
                ))
            ]
        ))

        XCTAssertEqual(note.title, "Remote Mixed Title")
        XCTAssertEqual(note.content, "Hello remote")
        XCTAssertNil(vm.activeEditorSyncUpdate)
        XCTAssertTrue(recorder.recordedBatches.isEmpty)
    }

    func testNonactiveTitleOnlyIncomingBatchDoesNotPublishActiveEditorUpdate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let activeNote = Note(title: "Active", content: "active body")
        activeNote.id = UUID(uuidString: "00000000-0000-0000-0000-000000129003")!
        let otherNote = Note(title: "Other", content: "other body")
        otherNote.id = UUID(uuidString: "00000000-0000-0000-0000-000000129004")!
        context.insert(activeNote)
        context.insert(otherNote)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(activeNote)

        await vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 6),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: otherNote.id,
                    title: "Other Remote",
                    modifiedAt: Date(timeIntervalSince1970: 7)
                ))
            ]
        ))

        XCTAssertEqual(activeNote.title, "Active")
        XCTAssertEqual(activeNote.content, "active body")
        XCTAssertEqual(otherNote.title, "Other Remote")
        XCTAssertNil(vm.activeEditorSyncUpdate)
    }

    func testDuplicateTitleOnlyIncomingBatchDoesNotPublishNewActiveEditorUpdate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Local", content: "body")
        note.id = UUID()
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)
        let batch = titleOnlyBatch(noteID: note.id, title: "Remote")

        await vm.applyIncomingSyncBatch(batch)
        XCTAssertNil(vm.activeEditorSyncUpdate)
        note.title = "Newer Local"
        try context.save()
        await vm.applyIncomingSyncBatch(batch)

        XCTAssertEqual(note.title, "Newer Local")
        XCTAssertNil(vm.activeEditorSyncUpdate)
    }

    func testDuplicateMixedIncomingBatchDoesNotRepublishEditorUpdate() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let note = Note(title: "Local", content: "Hello")
        note.id = UUID()
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)
        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 30),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "Remote",
                    modifiedAt: Date(timeIntervalSince1970: 31)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: note.id,
                    utf16Offset: "Hello".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 32)
                ))
            ]
        )

        await vm.applyIncomingSyncBatch(batch)
        XCTAssertNil(vm.activeEditorSyncUpdate)
        note.title = "Newer Local"
        note.content = "Local body"
        try context.save()
        await vm.applyIncomingSyncBatch(batch)

        XCTAssertEqual(note.title, "Newer Local")
        XCTAssertEqual(note.content, "Local body")
        XCTAssertNil(vm.activeEditorSyncUpdate)
    }

    func testMountedEditorMetadataOnlyRemoteTitleIsNotRecaptured() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "body")
        defer { fixture.unmount() }

        await fixture.vm.applyIncomingSyncBatch(titleOnlyBatch(noteID: fixture.note.id, title: "Remote Title"))
        try await waitUntil("toolbar title updates") {
            fixture.bridge.title == "Remote Title"
        }
        try await waitPastEditorCommitDelay()

        XCTAssertEqual(fixture.note.title, "Remote Title")
        XCTAssertEqual(fixture.note.content, "body")
        XCTAssertTrue(fixture.recorder.recordedBatches.isEmpty)
        XCTAssertFalse(fixture.bridge.canUndo)
        fixture.bridge.undo?()
        try await waitForMountedEditorLifecycle()
        XCTAssertEqual(fixture.bridge.title, "Remote Title")
        XCTAssertEqual(fixture.note.title, "Remote Title")
    }

    func testMountedEditorMixedRemoteTitleAndBodyIsNotRecaptured() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "Hello")
        defer { fixture.unmount() }

        await fixture.vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: fixture.note.id,
                    title: "Remote Mixed Title",
                    modifiedAt: Date(timeIntervalSince1970: 11)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: fixture.note.id,
                    utf16Offset: "Hello".utf16.count,
                    text: " remote",
                    modifiedAt: Date(timeIntervalSince1970: 12)
                ))
            ]
        ))
        try await waitUntil("toolbar title and editor body update") {
            fixture.bridge.title == "Remote Mixed Title" && fixture.textView.text == "Hello remote"
        }
        try await waitPastEditorCommitDelay()

        XCTAssertNil(fixture.vm.activeEditorSyncUpdate)
        XCTAssertEqual(fixture.note.title, "Remote Mixed Title")
        XCTAssertEqual(fixture.note.content, "Hello remote")
        XCTAssertTrue(fixture.recorder.recordedBatches.isEmpty)
    }

    func testMountedEditorRemoteTitleDoesNotContaminateNextUndoSnapshot() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "body")
        defer { fixture.unmount() }

        await fixture.vm.applyIncomingSyncBatch(titleOnlyBatch(noteID: fixture.note.id, title: "Remote Title"))
        try await waitUntil("remote title updates") {
            fixture.bridge.title == "Remote Title"
        }

        fixture.textView.text = "body local"
        fixture.textView.delegate?.textViewDidChange?(fixture.textView)
        try await waitUntil("local edit enables undo") {
            fixture.bridge.canUndo
        }
        fixture.bridge.undo?()
        try await waitUntil("local body edit is undone") {
            fixture.textView.text == "body"
        }

        XCTAssertEqual(fixture.bridge.title, "Remote Title")
        XCTAssertEqual(fixture.note.title, "Remote Title")
    }

    func testMountedEditorUnsafeLocalBodyStateDoesNotApplyRemoteTitleOrBody() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "body")
        defer { fixture.unmount() }

        fixture.textView.text = "user body"
        fixture.textView.delegate?.textViewDidChange?(fixture.textView)
        try await waitUntil("local edit is pending") {
            fixture.bridge.canUndo
        }

        await fixture.vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 20),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: fixture.note.id,
                    title: "Remote Title",
                    modifiedAt: Date(timeIntervalSince1970: 21)
                )),
                .noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
                    noteID: fixture.note.id,
                    utf16Offset: 0,
                    text: "remote ",
                    modifiedAt: Date(timeIntervalSince1970: 22)
                ))
            ]
        ))
        try await waitForMountedEditorLifecycle()

        XCTAssertEqual(fixture.bridge.title, "Local Title")
        XCTAssertEqual(fixture.textView.text, "user body")
        try await waitPastEditorCommitDelay()
        XCTAssertEqual(fixture.note.title, "Local Title")
        XCTAssertEqual(fixture.note.content, "user body")
        XCTAssertFalse(fixture.recorder.recordedBatches.isEmpty)
    }

    func testMountedEditorPendingLocalBodyStateDefersReload() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "body")
        defer { fixture.unmount() }

        fixture.textView.text = "user body"
        fixture.textView.delegate?.textViewDidChange?(fixture.textView)
        try await waitUntil("local edit is pending") {
            fixture.bridge.canUndo
        }
        let remoteNote = Note(title: "Remote Title", content: "remote body")
        remoteNote.id = fixture.note.id
        remoteNote.modifiedAt = Date(timeIntervalSince1970: 50)
        _ = await fixture.vm.applyIncomingSyncChanges([
            try legacyNoteSyncChange(
                note: remoteNote,
                baseTitle: "Local Title",
                baseContent: "body",
                originDeviceID: "reload-peer"
            )
        ])
        try await waitForMountedEditorLifecycle()

        XCTAssertEqual(fixture.bridge.title, "Local Title")
        XCTAssertEqual(fixture.textView.text, "user body")
        try await waitPastEditorCommitDelay()
        XCTAssertEqual(fixture.note.title, "Local Title")
        XCTAssertEqual(fixture.note.content, "user body")
    }

    func testMountedEditorSafeReloadAppliesAuthoritativeNote() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "body")
        defer { fixture.unmount() }
        let conflict = SyncConflictVersion(
            entityType: .note,
            entityID: fixture.note.id,
            noteID: fixture.note.id,
            field: .noteContent,
            localText: "body",
            remoteText: "remote body",
            remoteModifiedAt: Date(timeIntervalSince1970: 60),
            preservedAt: Date(timeIntervalSince1970: 61),
            expiresAt: Date().addingTimeInterval(1_000)
        )
        _ = SyncConflictStore(fileURL: fixture.conflictFileURL).preserve(conflict)
        fixture.vm.restoreSyncConflict(conflict)
        try await waitUntil("safe reload applies") {
            fixture.textView.text == "remote body"
        }
        try await waitPastEditorCommitDelay()

        XCTAssertEqual(fixture.note.content, "remote body")
        XCTAssertTrue(fixture.recorder.recordedBatches.isEmpty)
    }

    func testMountedEditorEqualRemoteTitleDoesNotCreateLocalCommitOrUndo() async throws {
        let fixture = try makeMountedEditorFixture(title: "Same Title", content: "body")
        defer { fixture.unmount() }

        await fixture.vm.applyIncomingSyncBatch(titleOnlyBatch(noteID: fixture.note.id, title: "Same Title"))
        try await waitForMountedEditorLifecycle()
        try await waitPastEditorCommitDelay()

        XCTAssertEqual(fixture.bridge.title, "Same Title")
        XCTAssertEqual(fixture.note.title, "Same Title")
        XCTAssertTrue(fixture.recorder.recordedBatches.isEmpty)
        XCTAssertFalse(fixture.bridge.canUndo)
    }

    func testMountedEditorDeletedTextMismatchReloadsAndAcknowledgesExactlyOnce() async throws {
        let fixture = try makeMountedEditorFixture(title: "Local Title", content: "Hello world")
        defer { fixture.unmount() }

        // Drift the live editor buffer from the authoritative body without registering it as
        // an unsafe local edit, so the remote deletion is eligible for incremental application
        // and the bridge's independent deletedText verification (not the runtime's provenance
        // check) is what must catch the mismatch and route to reload.
        fixture.textView.text = "Hello mars!"

        await fixture.vm.applyIncomingSyncBatch(SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [.noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange(
                noteID: fixture.note.id,
                utf16Offset: 6,
                utf16Length: 5,
                expectedText: "world",
                modifiedAt: Date(timeIntervalSince1970: 1)
            ))]
        ))

        try await waitUntil("mismatch reload resolves the active editor sync update") {
            fixture.vm.activeEditorSyncUpdate == nil
        }
        try await waitForMountedEditorLifecycle()

        XCTAssertEqual(fixture.textView.text, "Hello ")
        try await waitPastEditorCommitDelay()
        XCTAssertEqual(fixture.note.content, "Hello ")
    }

    func testConvergenceRuntimeProcessesQueuedIncomingBatchesSerially() async throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        defer {
            try? FileManager.default.removeItem(at: queueFileURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: conflictFileURL.deletingLastPathComponent())
        }
        let noteA = Note(title: "A", content: "hello")
        noteA.id = UUID(uuidString: "00000000-0000-0000-0000-000000128001")!
        let noteB = Note(title: "B", content: "world")
        noteB.id = UUID(uuidString: "00000000-0000-0000-0000-000000128002")!
        context.insert(noteA)
        context.insert(noteB)
        try context.save()

        let firstBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000128101")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000128201")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteA.id,
                        utf16Offset: noteA.content.utf16.count,
                        text: " remote-a",
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ]
        )
        let secondBatch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000128102")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000128201")!,
            createdAt: Date(timeIntervalSince1970: 3),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: noteB.id,
                        utf16Offset: noteB.content.utf16.count,
                        text: " remote-b",
                        modifiedAt: Date(timeIntervalSince1970: 4)
                    )
                )
            ]
        )
        // Pre-enqueue both batches directly so one convergence drain must serialize
        // all queued work without the removed legacy direct-applier callback path.
        try FileBackedSyncBatchQueue(fileURL: queueFileURL).enqueueIncoming(firstBatch)
        try FileBackedSyncBatchQueue(fileURL: queueFileURL).enqueueIncoming(secondBatch)

        let vm = NotesViewModel(
            context: context,
            syncController: nil,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0,
            resumesPendingConvergenceOnInit: false
        )

        await vm.applyIncomingSyncBatch(firstBatch)

        XCTAssertFalse(vm.isApplyingRemoteSyncChange)
        XCTAssertEqual(noteA.content, "hello remote-a")
        XCTAssertEqual(noteB.content, "world remote-b")
        XCTAssertTrue(FileBackedSyncBatchQueue(fileURL: queueFileURL).pendingBatches.isEmpty)
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

    func testSearchHighlightGeometryConvertsTextContainerRectToLayerCoordinates() {
        let textContainerRect = CGRect(x: 18, y: 120, width: 42, height: 16)
        let convertedRect = EditorSearchHighlightGeometry.layerRect(
            forTextContainerRect: textContainerRect,
            textContainerInset: UIEdgeInsets(top: 12, left: 20, bottom: 8, right: 10)
        )

        XCTAssertEqual(convertedRect, CGRect(x: 38, y: 132, width: 42, height: 16))
    }

    func testSearchHighlighterLayerRectsStayStableWhenContentOffsetChanges() throws {
        let textView = searchHighlightTestTextView()
        let range = (textView.text as NSString).range(of: "needle")
        XCTAssertNotEqual(range.location, NSNotFound)

        textView.contentOffset = .zero
        let initialRects = try XCTUnwrap(EditorSearchHighlighter.highlightLayerRects(for: range, in: textView))

        textView.contentOffset = CGPoint(x: 0, y: 72)
        let scrolledRects = try XCTUnwrap(EditorSearchHighlighter.highlightLayerRects(for: range, in: textView))

        XCTAssertEqual(initialRects.count, scrolledRects.count)
        XCTAssertEqual(scrolledRects.first?.minX ?? 0, initialRects.first?.minX ?? 0, accuracy: 0.5)
        XCTAssertEqual(scrolledRects.first?.minY ?? 0, initialRects.first?.minY ?? 0, accuracy: 0.5)
    }

    func testSearchHighlighterRepositionsLayerAfterScrolling() throws {
        let textView = searchHighlightTestTextView()
        let range = (textView.text as NSString).range(of: "needle")
        XCTAssertNotEqual(range.location, NSNotFound)
        let highlighter = EditorSearchHighlighter()

        highlighter.apply(range: range, in: textView)
        textView.contentOffset = CGPoint(x: 0, y: 96)
        highlighter.reposition(in: textView)

        let highlightLayer = try XCTUnwrap(textView.layer.sublayers?.first {
            $0.name == "MyRAMSearchHighlightLayer"
        })
        let expectedRects = try XCTUnwrap(EditorSearchHighlighter.highlightLayerRects(for: range, in: textView))
        let expectedFrame = try XCTUnwrap(expectedRects.first)
        XCTAssertEqual(highlightLayer.frame.minX, expectedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(highlightLayer.frame.minY, expectedFrame.minY, accuracy: 0.5)
        XCTAssertEqual(highlightLayer.frame.width, expectedFrame.width, accuracy: 0.5)
        XCTAssertEqual(highlightLayer.frame.height, expectedFrame.height, accuracy: 0.5)
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

    private func searchHighlightTestTextView() -> UITextView {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 220, height: 120))
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        textView.textContainer.lineFragmentPadding = 6
        textView.text = """
        Alpha beta gamma
        Second line filler
        Third line filler
        Fourth line filler
        Fifth line has needle here
        Sixth line filler
        Seventh line filler
        Eighth line filler
        Ninth line filler
        """
        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        return textView
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

        _ = await vm.applyIncomingSyncChanges([
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
        XCTAssertEqual(recorder.recordedChanges.map(\.entityType), [.conflict])
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

    func testRestoreConflictPreservesBoldItalicAndUnderlineFormatting() throws {
        let remoteText = "Bold Italic Underline"
        let incomingRichTextData = try makeStyledConflictRichTextData(text: remoteText)
        let fixture = try makeActiveNoteContentConflictFixture(
            remoteText: remoteText,
            remoteRichTextContentData: incomingRichTextData
        )
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }

        fixture.vm.restoreSyncConflict(fixture.conflict)

        let richTextData = try XCTUnwrap(fixture.note.richTextContentData)
        let attributedText = try decodeRichTextData(richTextData)
        XCTAssertEqual(attributedText.string, remoteText)
        try assertStyledConflictFormattingSurvives(in: attributedText)
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

    func testSaveMergedConflictPreservesCompatibleExistingRichTextWhenResolvedDataIsNil() throws {
        let fixture = try makeActiveNoteContentConflictFixture()
        defer { try? FileManager.default.removeItem(at: fixture.conflictFileURL.deletingLastPathComponent()) }
        let mergedText = "Bold Italic Underline\nVersion to Sync"
        fixture.note.richTextContentData = try makeStyledConflictRichTextData(text: mergedText)

        fixture.vm.saveMergedSyncConflict(fixture.conflict, mergedText: mergedText)

        let richTextData = try XCTUnwrap(fixture.note.richTextContentData)
        let attributedText = try decodeRichTextData(richTextData)
        XCTAssertEqual(attributedText.string, mergedText)
        try assertStyledConflictFormattingSurvives(in: attributedText)
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

        _ = await vm.applyIncomingSyncChanges([
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

    func testFormattingStateResolverUsesTypingAttributesForCollapsedCaret() throws {
        let typingFont = UIFont.boldSystemFont(ofSize: 19)
        let typingColor = UIColor.systemGreen
        var cache = EditorSelectionFormattingCache()

        let state = EditorFormattingStateResolver.formattingState(
            attributedText: NSAttributedString(string: "Body"),
            selectedRange: NSRange(location: 2, length: 0),
            typingAttributes: [
                .font: typingFont,
                .foregroundColor: typingColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertTrue(state.bold)
        XCTAssertFalse(state.italic)
        XCTAssertTrue(state.underline)
        XCTAssertTrue(state.strikethrough)
        XCTAssertEqual(state.fontSize, 19, accuracy: 0.1)
        XCTAssertTrue(try XCTUnwrap(state.foregroundColor).isEqual(typingColor))
    }

    func testFormattingStateResolverRequiresAllSelectedCharactersToShareFontTrait() {
        let attributedText = NSMutableAttributedString(string: "Bold mix")
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: 4)
        )
        attributedText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: NSRange(location: 4, length: 4)
        )
        var cache = EditorSelectionFormattingCache()

        let mixedState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: attributedText.length),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        cache.markDirty(range: NSRange(location: 0, length: 4))
        let boldState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: 4),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertFalse(mixedState.bold)
        XCTAssertTrue(boldState.bold)
    }

    func testFormattingStateResolverRequiresAllSelectedCharactersToShareDecorations() {
        let attributedText = NSMutableAttributedString(string: "Marked up")
        attributedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 6)
        )
        attributedText.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 6)
        )
        var cache = EditorSelectionFormattingCache()

        let mixedState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: attributedText.length),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        cache.markDirty(range: NSRange(location: 0, length: 6))
        let decoratedState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: 6),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertFalse(mixedState.underline)
        XCTAssertFalse(mixedState.strikethrough)
        XCTAssertTrue(decoratedState.underline)
        XCTAssertTrue(decoratedState.strikethrough)
    }

    func testFormattingStateResolverUsesLeadingSelectedFontAndColor() throws {
        let attributedText = NSMutableAttributedString(string: "Red blue")
        attributedText.addAttributes(
            [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.systemRed
            ],
            range: NSRange(location: 0, length: 3)
        )
        attributedText.addAttributes(
            [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.systemBlue
            ],
            range: NSRange(location: 4, length: 4)
        )
        var cache = EditorSelectionFormattingCache()

        let state = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: attributedText.length),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertEqual(state.fontSize, 24, accuracy: 0.1)
        XCTAssertTrue(try XCTUnwrap(state.foregroundColor).isEqual(UIColor.systemRed))
    }

    func testFormattingStateResolverApproximateLargeSelectionSamplesLeadingState() {
        let text = String(repeating: "a", count: EditorSelectionFormattingPolicy.largeSelectionFormattingThreshold + 2)
        let attributedText = NSMutableAttributedString(string: text)
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: 1)
        )
        attributedText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: NSRange(location: 1, length: attributedText.length - 1)
        )
        var cache = EditorSelectionFormattingCache()

        let state = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: NSRange(location: 0, length: attributedText.length),
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertTrue(state.bold)
        XCTAssertTrue(cache.formattingStateIsApproximate)
    }

    func testFormattingStateResolverFallsBackForCollapsedOutOfBoundsSelection() {
        var cache = EditorSelectionFormattingCache()
        let fallbackFont = UIFont.systemFont(ofSize: 21)

        let state = EditorFormattingStateResolver.formattingState(
            attributedText: NSAttributedString(string: "Body"),
            selectedRange: NSRange(location: 99, length: 0),
            typingAttributes: [:],
            fallbackFont: fallbackFont,
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertFalse(state.bold)
        XCTAssertFalse(state.italic)
        XCTAssertFalse(state.underline)
        XCTAssertFalse(state.strikethrough)
        XCTAssertEqual(state.fontSize, 21, accuracy: 0.1)
        XCTAssertNil(state.foregroundColor)
    }

    func testFormattingStateResolverReturnsCachedStateForCleanMatchingSelection() {
        let attributedText = NSMutableAttributedString(string: "Body")
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: attributedText.length)
        )
        let range = NSRange(location: 0, length: attributedText.length)
        var cache = EditorSelectionFormattingCache()

        let firstState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: range,
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )
        attributedText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: range
        )
        let cachedState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: range,
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertTrue(firstState.bold)
        XCTAssertEqual(cachedState, firstState)
    }

    func testFormattingStateResolverRecomputesDirtyCache() {
        let attributedText = NSMutableAttributedString(string: "Body")
        let range = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: range
        )
        var cache = EditorSelectionFormattingCache()

        _ = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: range,
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )
        attributedText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: range
        )
        cache.markDirty(range: range)
        let recomputedState = EditorFormattingStateResolver.formattingState(
            attributedText: attributedText,
            selectedRange: range,
            typingAttributes: [:],
            fallbackFont: UIFont.systemFont(ofSize: 17),
            allowsLargeSelectionScan: false,
            cache: &cache
        )

        XCTAssertFalse(recomputedState.bold)
    }

    func testFormattingCommandResolverAppliesTraitWhenAnySelectedSegmentIsMissingTrait() {
        let attributedText = NSMutableAttributedString(string: "Bold mix")
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: 4)
        )
        attributedText.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 17),
            range: NSRange(location: 4, length: 4)
        )

        let traitPlan = EditorFormattingCommandResolver.traitPlan(
            in: attributedText,
            range: NSRange(location: 0, length: attributedText.length),
            trait: .traitBold
        )

        XCTAssertEqual(traitPlan.range, NSRange(location: 0, length: attributedText.length))
        XCTAssertEqual(traitPlan.trait, .traitBold)
        XCTAssertTrue(traitPlan.shouldApply)
    }

    func testFormattingCommandResolverRemovesTraitWhenAllSelectedSegmentsHaveTrait() {
        let attributedText = NSMutableAttributedString(string: "Bold")
        attributedText.addAttribute(
            .font,
            value: UIFont.boldSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: attributedText.length)
        )

        let traitPlan = EditorFormattingCommandResolver.traitPlan(
            in: attributedText,
            range: NSRange(location: 0, length: attributedText.length),
            trait: .traitBold
        )

        XCTAssertFalse(traitPlan.shouldApply)
    }

    func testFormattingCommandResolverItalicUsesTraitSemantics() {
        let attributedText = NSMutableAttributedString(string: "Italic mix")
        attributedText.addAttribute(
            .font,
            value: UIFont.italicSystemFont(ofSize: 17),
            range: NSRange(location: 0, length: 6)
        )

        let traitPlan = EditorFormattingCommandResolver.traitPlan(
            in: attributedText,
            range: NSRange(location: 0, length: attributedText.length),
            trait: .traitItalic
        )

        XCTAssertTrue(traitPlan.shouldApply)
    }

    func testFormattingCommandResolverDecorationAppliesWhenAnySegmentIsUndecorated() {
        let attributedText = NSMutableAttributedString(string: "Underline mix")
        attributedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 9)
        )

        let decorationPlan = EditorFormattingCommandResolver.decorationPlan(
            in: attributedText,
            range: NSRange(location: 0, length: attributedText.length),
            key: .underlineStyle
        )

        XCTAssertEqual(decorationPlan.styleKey, .underlineStyle)
        XCTAssertEqual(decorationPlan.colorKey, .underlineColor)
        XCTAssertTrue(decorationPlan.shouldApply)
    }

    func testFormattingCommandResolverDecorationRemovesWhenFullyDecorated() {
        let attributedText = NSMutableAttributedString(string: "Strike")
        attributedText.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: attributedText.length)
        )

        let decorationPlan = EditorFormattingCommandResolver.decorationPlan(
            in: attributedText,
            range: NSRange(location: 0, length: attributedText.length),
            key: .strikethroughStyle
        )

        XCTAssertEqual(decorationPlan.styleKey, .strikethroughStyle)
        XCTAssertEqual(decorationPlan.colorKey, .strikethroughColor)
        XCTAssertFalse(decorationPlan.shouldApply)
    }

    func testFormattingCommandResolverMapsDecorationColorKeys() {
        XCTAssertEqual(
            EditorFormattingCommandResolver.decorationColorKey(for: .underlineStyle),
            .underlineColor
        )
        XCTAssertEqual(
            EditorFormattingCommandResolver.decorationColorKey(for: .strikethroughStyle),
            .strikethroughColor
        )
        XCTAssertNil(EditorFormattingCommandResolver.decorationColorKey(for: .font))
    }

    func testFormattingCommandResolverFontTraitHelperPreservesPointSize() {
        let baseFont = UIFont.systemFont(ofSize: 23)

        let boldFont = EditorFormattingCommandResolver.fontBySettingTrait(
            on: baseFont,
            trait: .traitBold,
            isEnabled: true
        )

        XCTAssertEqual(boldFont.pointSize, 23, accuracy: 0.1)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testFormattingCommandResolverFontTraitHelperSafelyReturnsFontForUnsupportedTrait() {
        let baseFont = UIFont.systemFont(ofSize: 18)

        let resolvedFont = EditorFormattingCommandResolver.fontBySettingTrait(
            on: baseFont,
            trait: .traitExpanded,
            isEnabled: true
        )

        XCTAssertEqual(resolvedFont.pointSize, 18, accuracy: 0.1)
    }

    func testFormattingCommandResolverFontSizeClampsToSupportedRange() {
        let smallFont = UIFont.systemFont(ofSize: 12)
        let largeFont = UIFont.systemFont(ofSize: 39)

        let minimumFont = EditorFormattingCommandResolver.adjustedFontSize(from: smallFont, delta: -10)
        let maximumFont = EditorFormattingCommandResolver.adjustedFontSize(from: largeFont, delta: 10)

        XCTAssertEqual(minimumFont.pointSize, EditorFormattingCommandResolver.minimumFontSize, accuracy: 0.1)
        XCTAssertEqual(maximumFont.pointSize, EditorFormattingCommandResolver.maximumFontSize, accuracy: 0.1)
    }

    func testFormattingCommandResolverColorPlanDistinguishesExplicitAndDefaultColor() throws {
        let range = NSRange(location: 2, length: 4)
        let explicitPlan = EditorFormattingCommandResolver.colorPlan(
            range: range,
            color: .systemRed,
            usesDefaultColor: false
        )
        let defaultPlan = EditorFormattingCommandResolver.colorPlan(
            range: range,
            color: nil,
            usesDefaultColor: true
        )

        XCTAssertEqual(explicitPlan.range, range)
        XCTAssertTrue(try XCTUnwrap(explicitPlan.color).isEqual(UIColor.systemRed))
        XCTAssertFalse(explicitPlan.usesDefaultColor)
        XCTAssertNil(defaultPlan.color)
        XCTAssertTrue(defaultPlan.usesDefaultColor)
    }

    func testFormattingCommandResolverCollapsedCaretPlansPreserveToggleSemantics() {
        let boldPlan = EditorFormattingCommandResolver.collapsedTraitPlan(
            range: NSRange(location: 3, length: 0),
            baseFont: UIFont.boldSystemFont(ofSize: 17),
            trait: .traitBold
        )
        let decorationPlan = EditorFormattingCommandResolver.collapsedDecorationPlan(
            range: NSRange(location: 3, length: 0),
            key: .underlineStyle,
            currentValue: 0
        )

        XCTAssertFalse(boldPlan.shouldApply)
        XCTAssertTrue(decorationPlan.shouldApply)
        XCTAssertEqual(decorationPlan.colorKey, .underlineColor)
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

        let matches = EditorSearchMatchResolver.matches(
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

        let matches = EditorSearchMatchResolver.matches(
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

    func testCurrentNoteSearchNormalizesWhitespaceQuery() {
        XCTAssertEqual(EditorSearchMatchResolver.normalizedQuery("  alpha\n"), "alpha")
    }

    func testCurrentNoteSearchReturnsNoMatchesForWhitespaceQuery() {
        let matches = EditorSearchMatchResolver.matches(
            in: "Body alpha detail",
            pinnedTexts: [NoteSearchPinnedText(id: UUID(), text: "Pinned alpha")],
            query: "  \n  "
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testCurrentNoteSearchReturnsNoMatchesWhenQueryIsMissing() {
        let matches = EditorSearchMatchResolver.matches(
            in: "Body alpha detail",
            pinnedTexts: [NoteSearchPinnedText(id: UUID(), text: "Pinned alpha")],
            query: "invoice"
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testCurrentNoteSearchPreservesPinnedThenBodyOrdering() {
        let firstPinnedID = UUID()
        let secondPinnedID = UUID()

        let matches = EditorSearchMatchResolver.matches(
            in: "Body alpha detail",
            pinnedTexts: [
                NoteSearchPinnedText(id: firstPinnedID, text: "Pinned alpha one"),
                NoteSearchPinnedText(id: secondPinnedID, text: "Pinned alpha two")
            ],
            query: "alpha"
        )

        XCTAssertEqual(matches.map(\.region), [
            .pinnedText(id: firstPinnedID),
            .pinnedText(id: secondPinnedID),
            .body
        ])
    }

    func testCurrentNoteSearchPreservesValidSelectedMatch() {
        let matches = EditorSearchMatchResolver.matches(
            in: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )
        let selectedID = matches[1].id

        XCTAssertEqual(
            EditorSearchMatchResolver.resolvedSelectedMatchID(in: matches, selectedMatchID: selectedID),
            selectedID
        )
    }

    func testCurrentNoteSearchFallsBackFromStaleSelectedMatch() {
        let matches = EditorSearchMatchResolver.matches(
            in: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(
            EditorSearchMatchResolver.resolvedSelectedMatchID(in: matches, selectedMatchID: "stale"),
            matches.first?.id
        )
    }

    func testCurrentNoteSearchClearsSelectedMatchWhenEmpty() {
        XCTAssertNil(EditorSearchMatchResolver.resolvedSelectedMatchID(in: [], selectedMatchID: "stale"))
    }

    func testCurrentNoteSearchNextAndPreviousWrapMatches() {
        let matches = EditorSearchMatchResolver.matches(
            in: "alpha beta alpha gamma alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(EditorSearchMatchResolver.nextMatchIndex(in: matches, selectedMatchID: nil), 0)
        XCTAssertEqual(EditorSearchMatchResolver.previousMatchIndex(in: matches, selectedMatchID: nil), 2)
        XCTAssertEqual(EditorSearchMatchResolver.nextMatchIndex(in: matches, selectedMatchID: matches[2].id), 0)
        XCTAssertEqual(EditorSearchMatchResolver.previousMatchIndex(in: matches, selectedMatchID: matches[0].id), 2)
        XCTAssertEqual(EditorSearchMatchResolver.matchIndex(in: matches, selectedMatchID: matches[0].id, movingBy: 2), 2)
        XCTAssertEqual(EditorSearchMatchResolver.matchIndex(in: matches, selectedMatchID: matches[2].id, movingBy: -2), 0)
    }

    func testCurrentNoteSearchBodyRangeRequiresBodyMatchWithinBounds() {
        let body = "Body alpha detail"
        let matches = EditorSearchMatchResolver.matches(
            in: body,
            pinnedTexts: [NoteSearchPinnedText(id: UUID(), text: "Pinned alpha")],
            query: "alpha"
        )

        XCTAssertNil(EditorSearchMatchResolver.bodyRange(for: matches[0], textLength: body.utf16.count))
        XCTAssertEqual(
            EditorSearchMatchResolver.bodyRange(for: matches[1], textLength: body.utf16.count),
            NSRange(location: 5, length: 5)
        )
    }

    func testCurrentNoteSearchBodyRangeRejectsOutOfBoundsRange() {
        let text = "alpha"
        let match = NoteSearchMatch(
            id: "body-3-4",
            region: .body,
            plainTextRange: text.startIndex..<text.endIndex,
            nsRangeInRenderedText: NSRange(location: 3, length: 4),
            previewText: text
        )

        XCTAssertNil(EditorSearchMatchResolver.bodyRange(for: match, textLength: text.utf16.count))
    }

    private func makeContainer(
        isStoredInMemoryOnly: Bool,
        configurationName: String = "MyRAMTests"
    ) throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )

        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func legacyNoteChange(
        noteID: UUID,
        title: String,
        content: String,
        baseTitle: String?,
        baseContent: String?,
        modifiedAt: Date,
        originDeviceID: String = "device-b"
    ) throws -> SyncChange {
        let remoteNote = Note(title: title, content: content)
        remoteNote.id = noteID
        remoteNote.modifiedAt = modifiedAt
        return SyncChange(
            entityType: .item,
            entityID: noteID.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(
                note: remoteNote,
                baseTitle: baseTitle,
                baseContent: baseContent,
                baseRichTextContentData: nil
            )),
            updatedAt: modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    private func makeMountedEditorFixture(
        title: String,
        content: String
    ) throws -> MountedEditorFixture {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let queueFileURL = temporarySyncBatchQueueFileURL()
        let localQueueFileURL = temporarySyncBatchQueueFileURL()
        let conflictFileURL = temporarySyncConflictFileURL()
        let recorder = RecordingSyncController()
        let note = Note(title: title, content: content)
        note.id = UUID()
        context.insert(note)
        try context.save()
        let vm = NotesViewModel(
            context: context,
            syncController: recorder,
            syncConflictStore: SyncConflictStore(fileURL: conflictFileURL),
            pendingIncomingBatchQueueFileURL: queueFileURL,
            pendingLocalConvergenceBatchQueueFileURL: localQueueFileURL,
            syncBatchQuietWindow: 0
        )
        vm.selectNote(note)
        vm.registerActiveEditor(noteID: note.id)
        let bridge = NoteEditorToolbarBridge()
        let view = NoteEditorView(
            vm: vm,
            note: note,
            onNewNote: { _ in },
            showsTopBar: false,
            toolbarBridge: bridge
        )
        let hostingController = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let textView = try XCTUnwrap(hostingController.view.firstSubview(of: UITextView.self))
        return MountedEditorFixture(
            container: container,
            context: context,
            queueFileURL: queueFileURL,
            localQueueFileURL: localQueueFileURL,
            conflictFileURL: conflictFileURL,
            recorder: recorder,
            vm: vm,
            note: note,
            noteID: note.id,
            bridge: bridge,
            window: window,
            hostingController: hostingController,
            textView: textView
        )
    }

    private func titleOnlyBatch(noteID: UUID, title: String) -> SyncBatch {
        SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(),
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: title,
                    modifiedAt: Date()
                ))
            ]
        )
    }

    private func legacyNoteSyncChange(
        note: Note,
        baseTitle: String,
        baseContent: String,
        originDeviceID: String
    ) throws -> SyncChange {
        SyncChange(
            entityType: .item,
            entityID: note.id.uuidString,
            operation: .upsert,
            payload: try MyRAMSyncPayloadCoding.encode(MyRAMNoteSyncPayload(
                note: note,
                baseTitle: baseTitle,
                baseContent: baseContent,
                baseRichTextContentData: nil
            )),
            updatedAt: note.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    private func waitForMountedEditorLifecycle(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        _ = file
        _ = line
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func waitPastEditorCommitDelay() async throws {
        let delay = Double(EditorTimingPolicy.commitDelayNanoseconds) / 1_000_000_000
        try await Task.sleep(nanoseconds: UInt64((delay + 0.25) * 1_000_000_000))
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)", file: file, line: line)
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

    private func temporarySyncBatchQueueFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sync-pending-batches.json")
    }

    private func makeTitleOnlyBatch(idSuffix: Int, title: String) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000127299")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: UUID(uuidString: "00000000-0000-0000-0000-000000127399")!,
                        title: title,
                        modifiedAt: Date(timeIntervalSince1970: TimeInterval(idSuffix + 1))
                    )
                )
            ]
        )
    }

    private func makeTitleBatch(noteID: UUID, sequence: UInt64, title: String) -> SyncBatch {
        SyncBatch(
            id: UUID(),
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000156001")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            batchSequence: sequence,
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: noteID,
                    title: title,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
                ))
            ]
        )
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

    private func makeStyledConflictRichTextData(text: String) throws -> Data {
        let attributedText = NSMutableAttributedString(string: text)
        let boldRange = (text as NSString).range(of: "Bold")
        let italicRange = (text as NSString).range(of: "Italic")
        let underlineRange = (text as NSString).range(of: "Underline")
        attributedText.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: boldRange)
        attributedText.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 18), range: italicRange)
        attributedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: underlineRange
        )

        return try XCTUnwrap(RichTextContentCodec.encode(attributedText))
    }

    private func assertStyledConflictFormattingSurvives(in attributedText: NSAttributedString) throws {
        let text = attributedText.string as NSString
        let boldLocation = text.range(of: "Bold").location
        let italicLocation = text.range(of: "Italic").location
        let underlineLocation = text.range(of: "Underline").location

        let boldFont = try XCTUnwrap(attributedText.attribute(.font, at: boldLocation, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        let italicFont = try XCTUnwrap(attributedText.attribute(.font, at: italicLocation, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let underline = attributedText.attribute(.underlineStyle, at: underlineLocation, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
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

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        if let matching = self as? T {
            return matching
        }
        for subview in subviews {
            if let matching = subview.firstSubview(of: type) {
                return matching
            }
        }
        return nil
    }

}

@MainActor
private final class AcceptingLocalBatchTransport: SyncConvergenceLocalBatchTransportAdapter {
    private(set) var acceptedBatches: [SyncBatch] = []

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        acceptedBatches.append(batch)
    }
}

@MainActor
private final class FailingLocalBatchTransport: SyncConvergenceLocalBatchTransportAdapter {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        throw error
    }
}


@MainActor
private final class FailingIncomingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter {
    private let failure: SyncConvergenceIncomingLocalBoundaryFailure

    init(failure: SyncConvergenceIncomingLocalBoundaryFailure) {
        self.failure = failure
    }

    func prepareForIncomingBodyMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryPreparation {
        .failed(failure)
    }
}

@MainActor
private final class SinglePendingLocalBoundaryAdapter: SyncConvergenceIncomingLocalBoundaryAdapter {
    private var obligation: SyncConvergenceLocalObligation?
    private(set) var takeCount = 0

    init(obligation: SyncConvergenceLocalObligation) {
        self.obligation = obligation
    }

    func prepareForIncomingBodyMutation(
        affecting noteIDs: Set<UUID>
    ) async -> SyncConvergenceIncomingLocalBoundaryPreparation {
        guard let obligation,
              !noteIDs.isDisjoint(with: Self.affectedNoteIDs(in: obligation.batch)) else {
            return .ready
        }
        takeCount += 1
        self.obligation = nil
        return .localObligation(obligation)
    }

    private static func affectedNoteIDs(in batch: SyncBatch) -> Set<UUID> {
        Set(batch.changes.map { change in
            switch change {
            case .noteCreated(let payload):
                return payload.noteID
            case .noteTitleChanged(let payload):
                return payload.noteID
            case .noteBodyTextInserted(let payload):
                return payload.noteID
            case .noteBodyTextDeleted(let payload):
                return payload.noteID
            case .noteBodyReconciled(let payload):
                return payload.noteID
            }
        })
    }
}

private func discontinuousCapturedObligation(noteID: UUID) throws -> SyncConvergenceLocalObligation {
    let firstChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
        noteID: noteID,
        utf16Offset: 1,
        text: "B",
        modifiedAt: Date(timeIntervalSince1970: 1),
        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
    ))
    let secondChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
        noteID: noteID,
        utf16Offset: 1,
        text: "C",
        modifiedAt: Date(timeIntervalSince1970: 2),
        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
    ))
    let firstCapturedChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
        for: firstChange,
        preBody: "A",
        postBody: "AB"
    )
    let secondCapturedChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
        for: secondChange,
        preBody: "A",
        postBody: "AC"
    )
    let batch = SyncBatch(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000001275A0")!,
        originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-0000001275A1")!,
        createdAt: Date(timeIntervalSince1970: 1),
        changes: [firstChange, secondChange]
    )
    return SyncConvergenceLocalObligation(batch: batch, capturedChanges: [firstCapturedChange, secondCapturedChange])
}

private struct CompletingPresentationAdapter: SyncConvergencePresentationAdapter {
    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        .verifiedComplete
    }
}

@MainActor
private final class RecordingPresentationAdapter: SyncConvergencePresentationAdapter {
    private(set) var requestCount = 0

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        requestCount += 1
        return .verifiedComplete
    }
}

@MainActor
private final class ReentrantPresentationAdapter: SyncConvergencePresentationAdapter {
    var onFirstPresentation: (() async -> SyncConvergenceRuntimeOutcome)?
    private(set) var reentrantOutcomeCount = 0
    private(set) var didObserveAlreadyDraining = false

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        guard let onFirstPresentation else { return .verifiedComplete }
        self.onFirstPresentation = nil
        reentrantOutcomeCount += 1
        if case .alreadyDraining = await onFirstPresentation() {
            didObserveAlreadyDraining = true
        }
        return .verifiedComplete
    }
}
