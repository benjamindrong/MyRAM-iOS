import AppKit
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncBatchApplierTests: XCTestCase {
    func testDuplicateCreateNotePayloadsCreateDistinctNotesWhenIDsDiffer() throws {
        let container = try makeInMemoryContainer()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000002001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000002002")!

        _ = try apply(batchID: "00000000-0000-0000-0000-000000002101", changes: [createChange(noteID: firstID)], in: container)
        _ = try apply(batchID: "00000000-0000-0000-0000-000000002102", changes: [createChange(noteID: secondID)], in: container)

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
                    AppliedEditorBodyInsertion(
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
                    AppliedEditorBodyInsertion(
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
                    AppliedEditorBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 3,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                )
            ]
        )
    }

    func testMatchingBaseHashUsesExistingPositionalInsertionPath() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000211A")!, content: "A😀B", in: container)

        let appliedBatch = try apply(
            changes: [
                .noteBodyTextInserted(
                    MacSyncNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 11),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A😀B")
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
        XCTAssertEqual(
            appliedBatch.changes,
            [
                .bodyInserted(
                    AppliedEditorBodyInsertion(
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
                    AppliedEditorBodyDeletion(
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
                    AppliedEditorBodyInsertion(
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
                    AppliedEditorBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 1,
                        text: "X",
                        modifiedAt: Date(timeIntervalSince1970: 11)
                    )
                ),
                .bodyDeleted(
                    AppliedEditorBodyDeletion(
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

        _ = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "x", baseBody: "abc"))],
            in: container
        )

        XCTAssertEqual(note.content, "axbc")
        XCTAssertNil(note.richTextContentData)
    }

    func testStoredRichTextInsertionInheritsPreviousCharacterAttributes() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000210A")!, content: "abc", in: container)
        note.richTextContentData = richTextData([
            ("a", [.foregroundColor: NSColor.systemRed]),
            ("b", [.foregroundColor: NSColor.systemBlue]),
            ("c", [.foregroundColor: NSColor.systemGreen])
        ])
        try container.mainContext.save()

        _ = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 2, text: "x"))],
            in: container
        )

        let attributedText = try XCTUnwrap(decodedRichText(for: note))
        XCTAssertEqual(attributedText.string, "abxc")
        XCTAssertEqual(
            attributedText.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor,
            NSColor.systemBlue
        )
    }

    func testStoredRichTextInsertionAtZeroUsesFirstCharacterAttributes() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000210B")!, content: "abc", in: container)
        note.richTextContentData = richTextData([
            ("a", [.foregroundColor: NSColor.systemRed]),
            ("b", [.foregroundColor: NSColor.systemBlue]),
            ("c", [.foregroundColor: NSColor.systemGreen])
        ])
        try container.mainContext.save()

        _ = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "x"))],
            in: container
        )

        let attributedText = try XCTUnwrap(decodedRichText(for: note))
        XCTAssertEqual(attributedText.string, "xabc")
        XCTAssertEqual(
            attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            NSColor.systemRed
        )
    }

    func testStoredRichTextAndBridgeInsertionUseMatchingAttributes() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000000210C")!
        let note = try insertNote(id: noteID, content: "abc", in: container)
        let styledText = NSMutableAttributedString()
        styledText.append(NSAttributedString(string: "a", attributes: [.foregroundColor: NSColor.systemRed]))
        styledText.append(NSAttributedString(string: "b", attributes: [.foregroundColor: NSColor.systemBlue]))
        styledText.append(NSAttributedString(string: "c", attributes: [.foregroundColor: NSColor.systemGreen]))
        note.richTextContentData = RTFCoding.encode(styledText)
        try container.mainContext.save()

        _ = try apply(
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 2, text: "x"))],
            in: container
        )
        let storedText = try XCTUnwrap(decodedRichText(for: note))

        let textView = NSTextView()
        textView.textStorage?.setAttributedString(styledText)
        let bridge = MacEditorSyncBridge()
        bridge.textView = textView
        _ = bridge.applyBatch(
            [.applyBodyInsertion(AppliedEditorBodyInsertion(noteID: noteID, utf16Offset: 2, text: "x", modifiedAt: Date()))],
            selectedNoteID: noteID,
            authoritativeBody: "abxcd"
        )

        XCTAssertEqual(storedText.string, textView.string)
        XCTAssertEqual(
            storedText.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor,
            textView.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        )
    }

    func testSaveFailureRollsBackContentAndDoesNotMarkBatchSeen() throws {
        struct SaveFailure: Error {}

        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000210D")!, content: "abc", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000000220D")!
        let seenBatchStore = MacSyncSeenBatchStore(defaults: defaults)
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            performSave: { throw SaveFailure() }
        )

        XCTAssertThrowsError(try applier.apply(batch(id: batchID, changes: [
            .noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "x", baseBody: "abc"))
        ])))

        XCTAssertEqual(note.content, "abc")
        XCTAssertFalse(seenBatchStore.hasSeen(batchID))
    }

    func testSaveFailureThenRetryAppliesInsertionExactlyOnce() throws {
        struct SaveFailure: Error {}

        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000210E")!, content: "abc", in: container)
        let batch = batch(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000220E")!,
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 1, text: "x", baseBody: "abc"))]
        )
        var saveAttempts = 0
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: MacSyncSeenBatchStore(defaults: defaults),
            performSave: {
                saveAttempts += 1
                if saveAttempts == 1 {
                    throw SaveFailure()
                }
                try container.mainContext.save()
            }
        )

        XCTAssertThrowsError(try applier.apply(batch))
        _ = try applier.apply(batch)

        XCTAssertEqual(note.content, "axbc")
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
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "Once", baseBody: ""))]
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

    func testHashlessInsertionRejectsBeforeMutationSaveOrSeenMarking() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000204F")!, content: "local", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000000214F")!
        let seenStore = MacSyncSeenBatchStore(defaults: defaults)
        var saveCount = 0
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenStore,
            performSave: { saveCount += 1; try container.mainContext.save() }
        )
        XCTAssertThrowsError(try applier.apply(MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [.noteBodyTextInserted(insertChange(noteID: note.id, offset: 0, text: "remote "))]
        ))) { error in
            XCTAssertEqual(
                error as? SyncBatchApplyPreflightError,
                .unavailableAnchorlessBaseEvidence(noteID: note.id)
            )
        }
        XCTAssertEqual(note.content, "local")
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(seenStore.hasSeen(batchID))
    }

    func testHashlessDeletionRejectsBeforeMutationSaveOrSeenMarking() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000002050")!, content: "local", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000002150")!
        let seenStore = MacSyncSeenBatchStore(defaults: defaults)
        var saveCount = 0
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenStore,
            performSave: { saveCount += 1; try container.mainContext.save() }
        )
        let change = SyncBatchNoteBodyTextDeletedChange(
            noteID: note.id,
            utf16Offset: 0,
            utf16Length: 1,
            expectedText: "l",
            modifiedAt: Date(timeIntervalSince1970: 12)
        )
        XCTAssertThrowsError(try applier.apply(MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [.noteBodyTextDeleted(change)]
        ))) { error in
            XCTAssertEqual(
                error as? SyncBatchApplyPreflightError,
                .unavailableAnchorlessBaseEvidence(noteID: note.id)
            )
        }
        XCTAssertEqual(note.content, "local")
        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(seenStore.hasSeen(batchID))
    }

    func testMismatchedHashedInsertionDoesNotApplyOrMarkSeen() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000200F")!, content: "local", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000000210F")!
        let seenBatchStore = MacSyncSeenBatchStore(defaults: defaults)
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    MacSyncNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "remote ",
                        modifiedAt: Date(timeIntervalSince1970: 14),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "remote-base")
                    )
                )
            ]
        ))) { error in
            XCTAssertEqual(
                error as? SyncBatchApplyPreflightError,
                .mismatchedBaseContentHash(
                    noteID: note.id,
                    expected: SyncBatchContentHash.sha256Hex(for: "remote-base"),
                    actual: SyncBatchContentHash.sha256Hex(for: "local")
                )
            )
        }

        XCTAssertEqual(note.content, "local")
        XCTAssertFalse(seenBatchStore.hasSeen(batchID))
    }

    func testTitleBeforeMismatchedBodyDoesNotPartiallyApply() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000201F")!, content: "local", in: container)
        note.title = "Original"
        try container.mainContext.save()
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000000211F")!
        let seenBatchStore = MacSyncSeenBatchStore(defaults: defaults)
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteTitleChanged(
                    MacSyncNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Remote",
                        modifiedAt: Date(timeIntervalSince1970: 15)
                    )
                ),
                .noteBodyTextInserted(
                    MacSyncNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "remote ",
                        modifiedAt: Date(timeIntervalSince1970: 16),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "remote-base")
                    )
                )
            ]
        )))

        XCTAssertEqual(note.title, "Original")
        XCTAssertEqual(note.content, "local")
        XCTAssertFalse(seenBatchStore.hasSeen(batchID))
    }

    func testEarlierValidNoteChangeDoesNotApplyWhenLaterNoteMismatches() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let first = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000202F")!, content: "A", in: container)
        let second = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000203F")!, content: "B", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000000212F")!
        let seenBatchStore = MacSyncSeenBatchStore(defaults: defaults)
        let applier = MacSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(MacSyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    MacSyncNoteBodyTextInsertedChange(
                        noteID: first.id,
                        utf16Offset: 1,
                        text: "1",
                        modifiedAt: Date(timeIntervalSince1970: 17),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextInserted(
                    MacSyncNoteBodyTextInsertedChange(
                        noteID: second.id,
                        utf16Offset: 1,
                        text: "2",
                        modifiedAt: Date(timeIntervalSince1970: 18),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "wrong")
                    )
                )
            ]
        )))

        XCTAssertEqual(first.content, "A")
        XCTAssertEqual(second.content, "B")
        XCTAssertFalse(seenBatchStore.hasSeen(batchID))
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
                changes: try changesWithMatchingBaseEvidence(changes, in: container)
            )
        )
    }

    private func changesWithMatchingBaseEvidence(
        _ changes: [MacSyncChange],
        in container: ModelContainer
    ) throws -> [MacSyncChange] {
        var bodies: [UUID: String] = [:]
        var loaded: Set<UUID> = []
        func body(for noteID: UUID) throws -> String? {
            if loaded.contains(noteID) { return bodies[noteID] }
            loaded.insert(noteID)
            if let current = try fetchNote(id: noteID, in: container)?.content {
                bodies[noteID] = current
                return current
            }
            return nil
        }
        var result: [MacSyncChange] = []
        for change in changes {
            switch change {
            case .noteCreated(let created):
                if try body(for: created.noteID) == nil { bodies[created.noteID] = created.body }
                result.append(change)
            case .noteBodyTextInserted(let insert):
                guard var current = try body(for: insert.noteID) else { result.append(change); continue }
                result.append(.noteBodyTextInserted(.init(
                    noteID: insert.noteID, utf16Offset: insert.utf16Offset, text: insert.text,
                    modifiedAt: insert.modifiedAt,
                    baseContentHash: insert.baseContentHash ?? SyncBatchContentHash.sha256Hex(for: current)
                )))
                if !insert.text.isEmpty {
                    let offset = current.syncBatchSafeInsertionOffset(fallingForwardFrom: insert.utf16Offset)
                    current = current.syncBatchInserting(insert.text, atUTF16Offset: offset)
                    bodies[insert.noteID] = current
                }
            case .noteBodyTextDeleted(let delete):
                guard var current = try body(for: delete.noteID) else { result.append(change); continue }
                result.append(.noteBodyTextDeleted(.init(
                    noteID: delete.noteID, utf16Offset: delete.utf16Offset, utf16Length: delete.utf16Length,
                    expectedText: delete.expectedText, modifiedAt: delete.modifiedAt,
                    baseContentHash: delete.baseContentHash ?? SyncBatchContentHash.sha256Hex(for: current)
                )))
                if delete.utf16Length > 0,
                   let range = current.syncBatchSafeUTF16Range(location: delete.utf16Offset, length: delete.utf16Length),
                   let swiftRange = Range(range, in: current) {
                    let actual = String(current[swiftRange])
                    if delete.expectedText == nil || delete.expectedText == actual {
                        current.removeSubrange(swiftRange)
                        bodies[delete.noteID] = current
                    }
                }
            default:
                result.append(change)
            }
        }
        return result
    }

    private func batch(id: UUID, changes: [MacSyncChange]) -> MacSyncBatch {
        MacSyncBatch(
            id: id,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: changes
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

    private func insertChange(
        noteID: UUID,
        offset: Int,
        text: String,
        baseBody: String? = nil
    ) -> MacSyncNoteBodyTextInsertedChange {
        MacSyncNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: Date(timeIntervalSince1970: 11),
            baseContentHash: baseBody.map { SyncBatchContentHash.sha256Hex(for: $0) }
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

    private func richTextData(_ runs: [(String, [NSAttributedString.Key: Any])]) -> Data? {
        let attributedText = NSMutableAttributedString()
        for run in runs {
            attributedText.append(NSAttributedString(string: run.0, attributes: run.1))
        }
        return RTFCoding.encode(attributedText)
    }

    private func decodedRichText(for note: Note) throws -> NSAttributedString? {
        guard let richTextContentData = note.richTextContentData else { return nil }
        return try NSMutableAttributedString(
            data: richTextContentData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
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
