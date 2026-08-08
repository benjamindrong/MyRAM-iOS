import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class IPhoneSyncBatchApplierTests: XCTestCase {
    func testIncomingNoteCreatedPayloadCreatesNote() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000125001")!

        try apply(changes: [createChange(noteID: noteID)], in: container)

        let note = try XCTUnwrap(try fetchNote(id: noteID, in: container))
        XCTAssertEqual(note.title, "Shared")
        XCTAssertEqual(note.content, "Body")
    }

    func testSameTitleAndBodyWithDifferentIDsCreateDistinctNotes() throws {
        let container = try makeInMemoryContainer()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000125002")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000125003")!

        try apply(batchID: "00000000-0000-0000-0000-000000125102", changes: [createChange(noteID: firstID)], in: container)
        try apply(batchID: "00000000-0000-0000-0000-000000125103", changes: [createChange(noteID: secondID)], in: container)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(Set(notes.map(\.id)), [firstID, secondID])
        XCTAssertEqual(notes.map(\.title).filter { $0 == "Shared" }.count, 2)
    }

    func testIncomingTitleChangeUpdatesByNoteID() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125004")!, content: "", in: container)

        let result = try apply(
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Remote Title",
                        modifiedAt: Date(timeIntervalSince1970: 3)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.title, "Remote Title")
        XCTAssertEqual(result.disposition, .applied)
        XCTAssertEqual(result.appliedTitleChanges, [AppliedSyncBatchTitleChange(noteID: note.id, title: "Remote Title")])
    }

    func testIncomingInsertionFallsForwardAtUnsafeUTF16Boundary() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125005")!, content: "A😀B", in: container)

        let result = try apply(
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 4)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
        XCTAssertEqual(result.editorMutationBatches, [
            AppliedEditorMutationBatch(
                noteID: note.id,
                mutations: [
                    .bodyInsertion(AppliedEditorBodyInsertion(
                        noteID: note.id,
                        utf16Offset: 3,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 4)
                    ))
                ],
                authoritativeBody: "A😀xB"
            )
        ])
    }

    func testMatchingBaseHashUsesExistingPositionalInsertionPath() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125105")!, content: "A😀B", in: container)

        try apply(
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 4),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A😀B")
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "A😀xB")
    }

    func testReplacementSkippedThenDefaultGateInsertAppliesHashless() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125106")!, content: "remote", in: container)

        XCTAssertNil(SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: note.id,
            oldBody: "local",
            newBody: "remote",
            modifiedAt: Date(timeIntervalSince1970: 3)
        ))
        guard case .noteBodyTextInserted(let change) = SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: note.id,
            oldBody: "remote",
            newBody: "remote!",
            modifiedAt: Date(timeIntervalSince1970: 4)
        ) else {
            return XCTFail("Expected follow-up insert")
        }

        XCTAssertNil(change.baseContentHash)
        try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: makeDefaults())
        ).apply(SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000125206")!,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000125306")!,
            createdAt: Date(timeIntervalSince1970: 5),
            changes: [.noteBodyTextInserted(change)]
        ))

        XCTAssertEqual(note.content, "remote!")
    }

    func testDeleteAppliesOnlyWhenSafeAndExpectedTextMatches() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125006")!, content: "abcdef", in: container)

        let result = try apply(
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "cd",
                        modifiedAt: Date(timeIntervalSince1970: 5)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abef")
        XCTAssertEqual(result.editorMutationBatches, [
            AppliedEditorMutationBatch(
                noteID: note.id,
                mutations: [
                    .bodyDeletion(AppliedEditorBodyDeletion(
                        noteID: note.id,
                        range: NSRange(location: 2, length: 2),
                        deletedText: "cd",
                        modifiedAt: Date(timeIntervalSince1970: 5)
                    ))
                ],
                authoritativeBody: "abef"
            )
        ])
    }

    func testUnsafeDeleteDoesNotRemoveUnrelatedLocalText() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125007")!, content: "abcdef", in: container)

        try apply(
            changes: [
                .noteBodyTextDeleted(
                    SyncBatchNoteBodyTextDeletedChange(
                        noteID: note.id,
                        utf16Offset: 2,
                        utf16Length: 2,
                        expectedText: "xy",
                        modifiedAt: Date(timeIntervalSince1970: 6)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "abcdef")
    }

    func testMissingFolderFallsBackToRoot() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000125008")!

        try apply(
            changes: [
                .noteCreated(
                    SyncBatchNoteCreatedChange(
                        noteID: noteID,
                        title: "Remote",
                        body: "Body",
                        folderID: UUID(uuidString: "00000000-0000-0000-0000-000000125009")!,
                        createdAt: Date(timeIntervalSince1970: 1),
                        modifiedAt: Date(timeIntervalSince1970: 2)
                    )
                )
            ],
            in: container
        )

        let note = try XCTUnwrap(try fetchNote(id: noteID, in: container))
        XCTAssertNil(note.folder)
    }

    func testDuplicateBatchIDIsIgnoredAndPersistsAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500A")!, content: "", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000012510A")!
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000125201")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "Once",
                        modifiedAt: Date(timeIntervalSince1970: 7)
                    )
                )
            ]
        )

        let firstResult = try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: defaults)
        ).apply(batch)
        XCTAssertTrue(SyncBatchSeenBatchStore(defaults: defaults).hasSeen(batchID))
        let secondResult = try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: defaults)
        ).apply(batch)

        XCTAssertEqual(note.content, "Once")
        XCTAssertEqual(firstResult.disposition, .applied)
        XCTAssertEqual(secondResult.disposition, .alreadySeen)
        XCTAssertTrue(secondResult.editorMutationBatches.isEmpty)
        XCTAssertTrue(secondResult.appliedTitleChanges.isEmpty)
    }

    func testAnchoredBatchRejectsBeforeMutationSaveOrSeenMarking() throws {
        let container = try makeInMemoryContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-0000001252AA")!
        let note = try insertNote(id: noteID, content: "", in: container)
        let batch = try makeAnchoredInsertBatchForTest(noteID: noteID)
        let defaults = makeDefaults()
        let seenStore = SyncBatchSeenBatchStore(defaults: defaults)

        XCTAssertThrowsError(try IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenStore
        ).apply(batch)) {
            XCTAssertEqual(
                $0 as? SyncBatchAnchoredPayloadPolicyError,
                .anchoredPayloadDisabled(boundary: .apply, noteID: noteID)
            )
        }

        XCTAssertEqual(note.content, "")
        XCTAssertFalse(seenStore.hasSeen(batch.id))
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testMissingNoteTitleChangeProducesNoAppliedTitleEvidence() throws {
        let container = try makeInMemoryContainer()
        let missingNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000125210")!

        let result = try apply(
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: missingNoteID,
                    title: "Missing",
                    modifiedAt: Date(timeIntervalSince1970: 14)
                ))
            ],
            in: container
        )

        XCTAssertEqual(result.disposition, .applied)
        XCTAssertTrue(result.appliedTitleChanges.isEmpty)
        XCTAssertTrue(result.editorMutationBatches.isEmpty)
    }

    func testMultipleTitleChangesForOneNoteProduceFinalAppliedTitleEvidence() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000125211")!, content: "", in: container)

        let result = try apply(
            changes: [
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "First",
                    modifiedAt: Date(timeIntervalSince1970: 15)
                )),
                .noteTitleChanged(SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "Final",
                    modifiedAt: Date(timeIntervalSince1970: 16)
                ))
            ],
            in: container
        )

        XCTAssertEqual(note.title, "Final")
        XCTAssertEqual(result.appliedTitleChanges, [AppliedSyncBatchTitleChange(noteID: note.id, title: "Final")])
    }

    func testPlainTextMutationClearsRichTextData() throws {
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500B")!, content: "abc", in: container)
        note.richTextContentData = Data("stale rtf".utf8)
        try container.mainContext.save()

        try apply(
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 1,
                        text: "x",
                        modifiedAt: Date(timeIntervalSince1970: 8)
                    )
                )
            ],
            in: container
        )

        XCTAssertEqual(note.content, "axbc")
        XCTAssertNil(note.richTextContentData)
    }

    func testMismatchedHashedInsertionDoesNotApplyOrMarkSeen() throws {
        let defaults = makeDefaults()
        let container = try makeInMemoryContainer()
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500C")!, content: "local", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000012510C")!
        let seenBatchStore = SyncBatchSeenBatchStore(defaults: defaults)
        let applier = IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(SyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-00000012520C")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "remote ",
                        modifiedAt: Date(timeIntervalSince1970: 9),
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
        let note = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500D")!, content: "local", in: container)
        note.title = "Original"
        try container.mainContext.save()
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000012510D")!
        let seenBatchStore = SyncBatchSeenBatchStore(defaults: defaults)
        let applier = IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(SyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-00000012520D")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Remote",
                        modifiedAt: Date(timeIntervalSince1970: 10)
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: note.id,
                        utf16Offset: 0,
                        text: "remote ",
                        modifiedAt: Date(timeIntervalSince1970: 11),
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
        let first = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500E")!, content: "A", in: container)
        let second = try insertNote(id: UUID(uuidString: "00000000-0000-0000-0000-00000012500F")!, content: "B", in: container)
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-00000012510E")!
        let seenBatchStore = SyncBatchSeenBatchStore(defaults: defaults)
        let applier = IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: seenBatchStore,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertThrowsError(try applier.apply(SyncBatch(
            id: batchID,
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-00000012520E")!,
            createdAt: Date(timeIntervalSince1970: 1),
            changes: [
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: first.id,
                        utf16Offset: 1,
                        text: "1",
                        modifiedAt: Date(timeIntervalSince1970: 12),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
                    )
                ),
                .noteBodyTextInserted(
                    SyncBatchNoteBodyTextInsertedChange(
                        noteID: second.id,
                        utf16Offset: 1,
                        text: "2",
                        modifiedAt: Date(timeIntervalSince1970: 13),
                        baseContentHash: SyncBatchContentHash.sha256Hex(for: "wrong")
                    )
                )
            ]
        )))

        XCTAssertEqual(first.content, "A")
        XCTAssertEqual(second.content, "B")
        XCTAssertFalse(seenBatchStore.hasSeen(batchID))
    }

    @discardableResult
    private func apply(
        batchID: String = "00000000-0000-0000-0000-000000125100",
        changes: [SyncBatchChange],
        in container: ModelContainer
    ) throws -> IPhoneSyncBatchApplyResult {
        let applier = IPhoneSyncBatchApplier(
            context: container.mainContext,
            seenBatchStore: SyncBatchSeenBatchStore(defaults: makeDefaults()),
            bodyHashCapabilityEnabled: true
        )
        return try applier.apply(
            SyncBatch(
                id: UUID(uuidString: batchID)!,
                originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000125200")!,
                createdAt: Date(timeIntervalSince1970: 1),
                changes: changes
            )
        )
    }

    private func createChange(noteID: UUID) -> SyncBatchChange {
        .noteCreated(
            SyncBatchNoteCreatedChange(
                noteID: noteID,
                title: "Shared",
                body: "Body",
                folderID: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
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
            "IPhoneSyncBatchApplierTests-\(UUID().uuidString)",
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
        let suiteName = "IPhoneSyncBatchApplierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

// MYR-178 Slice 1 shared iPhone compatibility semantics
extension IPhoneSyncBatchApplierTests {
    func testMYR178IPhoneConsumerUsesSharedMatchingBaseDecisionSemantics() {
        let noteID = UUID(uuidString: "17800000-0000-0000-0000-000000000002")!
        let body = "iPhone authoritative body"
        let matching: SyncBatchChange = .noteBodyTextInserted(.init(
            noteID: noteID,
            utf16Offset: 0,
            text: "x",
            modifiedAt: Date(timeIntervalSince1970: 1_780),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: body)
        ))
        let hashless: SyncBatchChange = .noteBodyTextDeleted(.init(
            noteID: noteID,
            utf16Offset: 0,
            utf16Length: 6,
            expectedText: "iPhone",
            modifiedAt: Date(timeIntervalSince1970: 1_780)
        ))

        guard case .eligible = SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
            change: matching,
            authoritativeBody: body
        ) else {
            return XCTFail("Expected matching hash to be eligible on iPhone")
        }
        XCTAssertEqual(
            SyncBatchAnchorlessCompatibilityEvaluator.evaluate(
                change: hashless,
                authoritativeBody: body
            ),
            .unavailableEvidence(noteID: noteID)
        )
    }
}
