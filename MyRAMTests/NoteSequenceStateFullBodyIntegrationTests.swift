import Foundation
import SwiftData
import XCTest
import AnchoredSequenceCore

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

@MainActor
final class NoteSequenceStateFullBodyIntegrationTests: XCTestCase {
    func testMYR179SuppliedStructuralStateMutatesBodyAndRevisionTogether() throws {
        let fixture = try makeSeededFixture(body: "AB", revision: 7)
        let snapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: fixture.note,
            in: fixture.context
        )
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: fixture.note.id,
            utf16Offset: 1,
            text: "x",
            modifiedAt: .now,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB"),
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 179),
            state: snapshot.state
        )
        guard case .noteBodyTextInsertedAnchored(let inserted) = change else {
            return XCTFail("Expected anchored insertion")
        }
        let finalState = try SyncBatchAnchoredInsertReplay.applying(
            inserted,
            to: snapshot.state
        ).sequenceState

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
                of: fixture.note,
                expected: snapshot,
                newBody: "AxB",
                finalState: finalState,
                in: fixture.context
            ),
            .replaced(previousRevision: 7, revision: 8)
        )
        try fixture.context.save()
        try assertCommittedState(noteID: fixture.note.id, body: "AxB", revision: 8, in: fixture.container)
    }

    func testMYR179SuppliedStructuralStateRejectsIdenticalTextRevisionDrift() throws {
        let fixture = try makeSeededFixture(body: "AB", revision: 7)
        let snapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: fixture.note,
            in: fixture.context
        )
        fixture.record.revision = 8
        try fixture.context.save()

        XCTAssertThrowsError(try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: fixture.note,
            expected: snapshot,
            newBody: "AB",
            finalState: snapshot.state,
            in: fixture.context
        )) { error in
            XCTAssertEqual(error as? NoteSequenceStateStoreError, .staleRevision(expected: 7, actual: 8))
        }
        XCTAssertEqual(fixture.note.content, "AB")
    }
    func testInsertNewNoteCommitsDetachedNoteAndRevisionZeroStateTogether() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = Note(content: "Body")
        let prepared = try prepare(note)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            ),
            .inserted(revision: 0)
        )
        try context.save()

        XCTAssertEqual(try fetchNotes(in: container).map(\.content), ["Body"])
        XCTAssertEqual(try fetchRecords(in: container).only?.revision, 0)
    }

    func testInsertNewNoteRejectsPreparedNoteIDMismatchBeforeInsertion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = Note(content: "Body")
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: UUID(),
            body: note.content
        )

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
        )
        assertNoPendingModels(context)
    }

    func testInsertNewNoteRejectsExactBodyMismatchBeforeInsertion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = Note(content: "e\u{301}")
        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: "\u{E9}"
        )

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
        )
        assertNoPendingModels(context)
    }

    func testInsertNewNoteRejectsExistingNoteCollisionBeforeInsertion() throws {
        let container = try makeContainer()
        let noteID = UUID()
        try insertCommittedNote(noteID: noteID, body: "Existing", in: container)
        let context = ModelContext(container)
        let note = Note(content: "Replacement")
        note.id = noteID

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: try prepare(note),
                in: context
            )
        )
        XCTAssertFalse(context.hasChanges)
    }

    func testInsertNewNoteRejectsExistingStateCollisionBeforeInsertion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let note = Note(content: "Body")
        context.insert(try prepare(note).makeRevisionZeroRecord())
        try context.save()

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: try prepare(note),
                in: context
            )
        )
        XCTAssertFalse(context.hasChanges)
    }

    func testEnsureCurrentBodyStateCreatesMissingRevisionZeroState() throws {
        let container = try makeContainer()
        let noteID = UUID()
        try insertCommittedNote(noteID: noteID, body: "Body", in: container)
        let context = ModelContext(container)
        let note = try fetchNote(noteID, in: context)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            ),
            .inserted(revision: 0)
        )
        try context.save()
        try assertCommittedState(noteID: noteID, body: "Body", revision: 0, in: container)
    }

    func testEnsureCurrentBodyStatePreservesExactExistingStateWithoutRewrite() throws {
        let fixture = try makeSeededFixture(body: "Body", revision: 7)
        let originalPayload = fixture.record.statePayloadData

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: fixture.note,
                in: fixture.context
            ),
            .unchanged(revision: 7)
        )
        XCTAssertFalse(fixture.context.hasChanges)
        XCTAssertEqual(fixture.record.statePayloadData, originalPayload)
    }

    func testEnsureCurrentBodyStateReplacesValidStaleStateAtNextRevision() throws {
        let fixture = try makeSeededFixture(body: "Old", revision: 4)
        fixture.note.content = "Current"
        try fixture.context.save()
        let context = ModelContext(fixture.container)
        let note = try fetchNote(fixture.note.id, in: context)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            ),
            .replaced(previousRevision: 4, revision: 5)
        )
        try context.save()
        try assertCommittedState(
            noteID: note.id,
            body: "Current",
            revision: 5,
            in: fixture.container
        )
    }

    func testEnsureCurrentBodyStateRejectsCorruptStateWithoutMutation() throws {
        let fixture = try makeSeededFixture(body: "Body")
        fixture.record.statePayloadData = Data("corrupt".utf8)
        fixture.record.payloadByteCount = fixture.record.statePayloadData.count
        try fixture.context.save()
        let context = ModelContext(fixture.container)
        let note = try fetchNote(fixture.note.id, in: context)

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
        )
        XCTAssertFalse(context.hasChanges)
    }

    func testEnsureCurrentBodyStateRejectsUnsupportedStateWithoutMutation() throws {
        try assertEnsureFailureWithoutMutation { $0.formatVersion = 2 }
    }

    func testEnsureCurrentBodyStateRejectsRevisionExhaustionWithoutMutation() throws {
        let fixture = try makeSeededFixture(body: "Old", revision: .max)
        fixture.note.content = "Current"
        try fixture.context.save()
        let context = ModelContext(fixture.container)
        let note = try fetchNote(fixture.note.id, in: context)

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
        )
        XCTAssertFalse(context.hasChanges)
    }

    func testReplaceBodyCreatesRevisionZeroStateWhenStateIsMissing() throws {
        let container = try makeContainer()
        let noteID = UUID()
        try insertCommittedNote(noteID: noteID, body: "Old", in: container)
        let context = ModelContext(container)
        let note = try fetchNote(noteID, in: context)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: note,
                with: "New",
                in: context
            ),
            .inserted(revision: 0)
        )
        try context.save()
        try assertCommittedState(noteID: noteID, body: "New", revision: 0, in: container)
    }

    func testReplaceBodyPreservesStateWhenItAlreadyMatchesFinalBodyExactly() throws {
        let fixture = try makeSeededFixture(body: "Final", revision: 3)
        fixture.note.content = "Old"
        let originalPayload = fixture.record.statePayloadData

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: fixture.note,
                with: "Final",
                in: fixture.context
            ),
            .unchanged(revision: 3)
        )
        XCTAssertEqual(fixture.note.content, "Final")
        XCTAssertEqual(fixture.record.statePayloadData, originalPayload)
    }

    func testReplaceBodyReplacesValidStaleStateAndBodyAtOneNextRevision() throws {
        let fixture = try makeSeededFixture(body: "Old", revision: 9)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: fixture.note,
                with: "New",
                in: fixture.context
            ),
            .replaced(previousRevision: 9, revision: 10)
        )
        try fixture.context.save()
        try assertCommittedState(
            noteID: fixture.note.id,
            body: "New",
            revision: 10,
            in: fixture.container
        )
    }

    func testReplaceBodyUsesExactUTF16RatherThanCanonicalStringEquality() throws {
        let fixture = try makeSeededFixture(body: "\u{E9}", revision: 2)

        XCTAssertEqual(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: fixture.note,
                with: "e\u{301}",
                in: fixture.context
            ),
            .replaced(previousRevision: 2, revision: 3)
        )
    }

    func testReplaceBodyPersistsExactUTF16AcrossFreshContextWithoutSecondRewrite() throws {
        let fixture = try makeSeededFixture(body: "\u{E9}", revision: 2)

        _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
            of: fixture.note,
            with: "e\u{301}",
            in: fixture.context
        )
        try fixture.context.save()

        var freshContext: ModelContext? = ModelContext(fixture.container)
        var freshNote: Note? = try fetchNote(fixture.note.id, in: freshContext!)
        let firstRecord = try XCTUnwrap(fetchRecords(in: freshContext!).only)
        let firstPayload = firstRecord.statePayloadData
        XCTAssertTrue(freshNote!.content.utf16.elementsEqual("e\u{301}".utf16))
        let firstState = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: firstRecord, noteID: freshNote!.id)
        XCTAssertTrue(firstState.visibleText.utf16.elementsEqual("e\u{301}".utf16))
        XCTAssertEqual(firstRecord.revision, 3)

        _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
            of: freshNote!,
            with: "e\u{301}",
            in: freshContext!
        )
        if freshContext!.hasChanges {
            try freshContext!.save()
        }
        freshNote = nil
        freshContext = nil

        let reopened = ModelContext(fixture.container)
        let finalRecord = try XCTUnwrap(fetchRecords(in: reopened).only)
        XCTAssertEqual(finalRecord.revision, 3)
        XCTAssertEqual(finalRecord.statePayloadData, firstPayload)
    }

    func testReplaceBodyRejectsCorruptStateBeforeChangingBody() throws {
        try assertReplaceFailureWithoutMutation { record in
            record.statePayloadData = Data("corrupt".utf8)
            record.payloadByteCount = record.statePayloadData.count
        }
    }

    func testReplaceBodyRejectsUnsupportedStateBeforeChangingBody() throws {
        try assertReplaceFailureWithoutMutation { $0.formatVersion = 2 }
    }

    func testReplaceBodyRejectsRevisionExhaustionBeforeChangingBody() throws {
        let fixture = try makeSeededFixture(body: "Old", revision: .max)

        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: fixture.note,
                with: "New",
                in: fixture.context
            )
        )
        XCTAssertEqual(fixture.note.content, "Old")
        XCTAssertFalse(fixture.context.hasChanges)
    }

    func testBootstrapSnapshotRoundTripsExactSequencePayloadAndMetadata() throws {
        let source = try makeSeededFixture(body: "Authoritative", revision: 9)
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.notes.only?.statePayloadData, source.record.statePayloadData)
        XCTAssertEqual(decoded.notes.only?.revision, source.record.revision)
        XCTAssertEqual(decoded.notes.only?.payloadByteCount, source.record.payloadByteCount)
    }

    func testBootstrapMissingNoteInstallsNoteAndExactSequenceStateAtomically() throws {
        let source = try makeSeededFixture(body: "Authoritative", revision: 4)
        let batchID = UUID()
        let snapshot = withHistoryCoverage(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            batchID: batchID,
            noteIDs: [source.note.id]
        )
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: destinationContext
        )

        XCTAssertEqual(disposition.coveredBatchIDs, [batchID])
        XCTAssertEqual(disposition.insertedNoteIDs, Set([source.note.id]))
        XCTAssertTrue(disposition.presentationRefreshRequired)
        XCTAssertEqual(try fetchNotes(in: destination).only?.content, source.note.content)
        let record = try XCTUnwrap(fetchRecords(in: destination).only)
        XCTAssertEqual(record.statePayloadData, source.record.statePayloadData)
        XCTAssertEqual(record.revision, source.record.revision)
    }

    func testBootstrapBodyStateMismatchRejectsWholeSnapshotWithoutMutation() throws {
        let source = try makeSeededFixture(body: "Authoritative")
        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let note = try XCTUnwrap(original.notes.only)
        let mismatched = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: [copy(note, body: "Different")]
        )
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)

        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(mismatched, to: destinationContext)
        ) { error in
            XCTAssertEqual(error as? SyncPeerBootstrapError, .noteBodyStateMismatch(note.id))
        }
        XCTAssertTrue(try fetchNotes(in: destination).isEmpty)
        XCTAssertTrue(try fetchRecords(in: destination).isEmpty)
    }

    func testBootstrapBuilderRejectsCanonicallyEquivalentUTF16Mismatch() throws {
        let fixture = try makeSeededFixture(body: "\u{00E9}")
        fixture.note.content = "e\u{0301}"
        try fixture.context.save()

        XCTAssertThrowsError(try SyncPeerBootstrapSnapshotPersistence.build(from: fixture.context)) {
            XCTAssertEqual($0 as? SyncPeerBootstrapError, .noteBodyStateMismatch(fixture.note.id))
        }
    }

    func testBootstrapReceiverRejectsCanonicallyEquivalentUTF16Mismatch() throws {
        let source = try makeSeededFixture(body: "\u{00E9}")
        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let note = try XCTUnwrap(original.notes.only)
        let mismatched = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: [copy(note, body: "e\u{0301}")]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)

        XCTAssertThrowsError(try SyncPeerBootstrapSnapshotPersistence.apply(mismatched, to: context)) {
            XCTAssertEqual($0 as? SyncPeerBootstrapError, .noteBodyStateMismatch(note.id))
        }
        XCTAssertTrue(try fetchNotes(in: destination).isEmpty)
    }

    func testBootstrapExistingCanonicalEquivalentUTF16BodyDoesNotCoverHistory() throws {
        let source = try makeSeededFixture(body: "\u{00E9}")
        let batchID = UUID()
        let snapshot = withHistoryCoverage(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            batchID: batchID,
            noteIDs: [source.note.id]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)
        let existing = Note(title: source.note.title, content: "e\u{0301}")
        existing.id = source.note.id
        existing.createdAt = source.note.createdAt
        existing.modifiedAt = source.note.modifiedAt
        context.insert(existing)
        context.insert(try prepare(existing).makeRevisionZeroRecord())
        try context.save()

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        XCTAssertTrue(disposition.coveredBatchIDs.isEmpty)
        XCTAssertTrue(try fetchNote(existing.id, in: context).content.utf16.elementsEqual("e\u{0301}".utf16))
    }

    func testBootstrapSameNoteIDDifferentCreatedAtFailsClosed() throws {
        let source = try makeSeededFixture(body: "Authoritative")
        let batchID = UUID()
        let snapshot = withHistoryCoverage(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            batchID: batchID,
            noteIDs: [source.note.id]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)
        let existing = Note(content: "Local")
        existing.id = source.note.id
        existing.createdAt = source.note.createdAt.addingTimeInterval(1)
        context.insert(existing)
        let prepared = try prepare(existing)
        context.insert(prepared.makeRevisionZeroRecord())
        try context.save()

        XCTAssertThrowsError(try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)) { error in
            XCTAssertEqual(error as? SyncPeerBootstrapError, .conflictingNoteIdentity(existing.id))
        }
        XCTAssertEqual(try fetchNotes(in: destination).only?.content, "Local")
    }

    func testBootstrapExistingDivergentValidNoteIsPreservedAndDoesNotCoverHistory() throws {
        let source = try makeSeededFixture(body: "Authoritative")
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let destination = try makeContainer()
        let context = ModelContext(destination)
        let existing = Note(content: "Newer local state")
        existing.id = source.note.id
        existing.createdAt = source.note.createdAt
        context.insert(existing)
        context.insert(try prepare(existing).makeRevisionZeroRecord())
        try context.save()

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        XCTAssertTrue(disposition.coveredBatchIDs.isEmpty)
        XCTAssertEqual(try fetchNotes(in: destination).only?.content, "Newer local state")
    }

    func testBootstrapCoversOnlyExactNoteBatchAndRejectsMixedDivergentBatch() throws {
        let source = try makeSeededFixture(body: "Exact authoritative")
        let divergentSourceNote = Note(content: "Divergent authoritative")
        let divergentPrepared = try prepare(divergentSourceNote)
        source.context.insert(divergentSourceNote)
        source.context.insert(divergentPrepared.makeRevisionZeroRecord())
        try source.context.save()
        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let exactBatchID = UUID()
        let divergentBatchID = UUID()
        let mixedBatchID = UUID()
        let snapshot = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: original.notes,
            historyCoverage: [
                .init(batchID: exactBatchID, noteIDs: [source.note.id]),
                .init(batchID: divergentBatchID, noteIDs: [divergentSourceNote.id]),
                .init(batchID: mixedBatchID, noteIDs: [source.note.id, divergentSourceNote.id])
            ]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)
        let divergentLocalNote = Note(content: "Newer divergent local")
        divergentLocalNote.id = divergentSourceNote.id
        divergentLocalNote.createdAt = divergentSourceNote.createdAt
        context.insert(divergentLocalNote)
        context.insert(try prepare(divergentLocalNote).makeRevisionZeroRecord())
        try context.save()

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        XCTAssertEqual(disposition.coveredBatchIDs, [exactBatchID])
        XCTAssertEqual(try fetchNote(divergentSourceNote.id, in: context).content, "Newer divergent local")
        XCTAssertEqual(try fetchNote(source.note.id, in: context).content, "Exact authoritative")
    }

    func testBootstrapExactRepeatedSnapshotIsIdempotentAndCoversHistory() throws {
        let source = try makeSeededFixture(body: "Authoritative", revision: 3)
        let batchID = UUID()
        let snapshot = withHistoryCoverage(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            batchID: batchID,
            noteIDs: [source.note.id]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        let repeated = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)

        XCTAssertEqual(repeated.coveredBatchIDs, [batchID])
        XCTAssertTrue(repeated.insertedNoteIDs.isEmpty)
        XCTAssertFalse(repeated.presentationRefreshRequired)
        XCTAssertEqual(try fetchNotes(in: destination).count, 1)
        XCTAssertEqual(try fetchRecords(in: destination).count, 1)
    }

    func testBootstrapManifestRejectsMissingNoteBeforeMutation() throws {
        let source = try makeSeededFixture(body: "Authoritative")
        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let missingNoteID = UUID()
        let snapshot = withHistoryCoverage(
            original,
            batchID: UUID(),
            noteIDs: [missingNoteID]
        )
        let destination = try makeContainer()
        let context = ModelContext(destination)

        XCTAssertThrowsError(try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)) {
            XCTAssertEqual(
                $0 as? SyncPeerBootstrapError,
                .historyReferencesMissingNote(missingNoteID)
            )
        }
        XCTAssertTrue(try fetchNotes(in: destination).isEmpty)
        XCTAssertFalse(context.hasChanges)
    }

    func testBootstrapSnapshotAndExactSequenceStateSurviveFileBackedRestart() throws {
        let source = try makeSeededFixture(body: "Durable authoritative state", revision: 7)
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-216-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("bootstrap.store")

        do {
            let destination = try makeDiskContainer(url: storeURL)
            let context = ModelContext(destination)
            _ = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: context)
        }

        let reopened = try makeDiskContainer(url: storeURL)
        let reopenedContext = ModelContext(reopened)
        let note = try fetchNote(source.note.id, in: reopenedContext)
        let record = try XCTUnwrap(fetchRecords(in: reopenedContext).only)

        XCTAssertEqual(note.title, source.note.title)
        XCTAssertEqual(note.content, source.note.content)
        XCTAssertEqual(note.createdAt, source.note.createdAt)
        XCTAssertEqual(note.modifiedAt, source.note.modifiedAt)
        XCTAssertEqual(record.noteID, source.record.noteID)
        XCTAssertEqual(record.formatVersion, source.record.formatVersion)
        XCTAssertEqual(record.revision, source.record.revision)
        XCTAssertEqual(record.visibleUTF16Count, source.record.visibleUTF16Count)
        XCTAssertEqual(record.tombstonedUTF16Count, source.record.tombstonedUTF16Count)
        XCTAssertEqual(record.payloadByteCount, source.record.payloadByteCount)
        XCTAssertEqual(record.statePayloadData, source.record.statePayloadData)
    }

    private func copy(
        _ note: SyncPeerBootstrapNoteSnapshot,
        body: String
    ) -> SyncPeerBootstrapNoteSnapshot {
        SyncPeerBootstrapNoteSnapshot(
            id: note.id,
            title: note.title,
            body: body,
            isPinned: note.isPinned,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            deletedAt: note.deletedAt,
            folderID: note.folderID,
            formatVersion: note.formatVersion,
            revision: note.revision,
            visibleUTF16Count: note.visibleUTF16Count,
            tombstonedUTF16Count: note.tombstonedUTF16Count,
            payloadByteCount: note.payloadByteCount,
            statePayloadData: note.statePayloadData
        )
    }

    private func withHistoryCoverage(
        _ snapshot: SyncPeerBootstrapSnapshot,
        batchID: SyncBatchID,
        noteIDs: Set<SyncBatchNoteID>
    ) -> SyncPeerBootstrapSnapshot {
        SyncPeerBootstrapSnapshot(
            id: snapshot.id,
            folders: snapshot.folders,
            notes: snapshot.notes,
            historyCoverage: [
                SyncPeerBootstrapHistoryBatchCoverage(
                    batchID: batchID,
                    noteIDs: noteIDs
                )
            ]
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-170-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeDiskContainer(url: URL) throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-216-Restart",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func prepare(_ note: Note) throws -> PreparedInitialNoteSequenceState {
        try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: note.id,
            body: note.content
        )
    }

    private func makeSeededFixture(
        body: String,
        revision: UInt64 = 0
    ) throws -> (
        container: ModelContainer,
        context: ModelContext,
        note: Note,
        record: NoteSequenceStateRecord
    ) {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let note = Note(content: body)
        let prepared = try prepare(note)
        context.insert(note)
        let record = prepared.makeRevisionZeroRecord()
        prepared.apply(to: record, revision: revision)
        context.insert(record)
        try context.save()
        return (container, context, note, record)
    }

    private func insertCommittedNote(
        noteID: UUID,
        body: String,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let note = Note(content: body)
        note.id = noteID
        context.insert(note)
        try context.save()
    }

    private func fetchNote(_ noteID: UUID, in context: ModelContext) throws -> Note {
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try XCTUnwrap(context.fetch(descriptor).first)
    }

    private func fetchNotes(in container: ModelContainer) throws -> [Note] {
        try ModelContext(container).fetch(FetchDescriptor<Note>())
    }

    private func fetchRecords(in container: ModelContainer) throws -> [NoteSequenceStateRecord] {
        try fetchRecords(in: ModelContext(container))
    }

    private func fetchRecords(in context: ModelContext) throws -> [NoteSequenceStateRecord] {
        try context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
    }

    private func assertCommittedState(
        noteID: UUID,
        body: String,
        revision: UInt64,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let note = try fetchNote(noteID, in: context)
        let record = try XCTUnwrap(fetchRecords(in: context).only)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        XCTAssertTrue(note.content.utf16.elementsEqual(body.utf16))
        XCTAssertTrue(state.visibleText.utf16.elementsEqual(body.utf16))
        XCTAssertEqual(record.revision, revision)
        XCTAssertEqual(record.payloadByteCount, record.statePayloadData.count)
    }

    private func assertNoPendingModels(_ context: ModelContext) {
        XCTAssertFalse(context.hasChanges)
    }

    private func assertEnsureFailureWithoutMutation(
        mutation: (NoteSequenceStateRecord) -> Void
    ) throws {
        let fixture = try makeSeededFixture(body: "Body")
        mutation(fixture.record)
        try fixture.context.save()
        let context = ModelContext(fixture.container)
        let note = try fetchNote(fixture.note.id, in: context)
        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
                for: note,
                in: context
            )
        )
        XCTAssertFalse(context.hasChanges)
    }

    private func assertReplaceFailureWithoutMutation(
        mutation: (NoteSequenceStateRecord) -> Void
    ) throws {
        let fixture = try makeSeededFixture(body: "Old")
        mutation(fixture.record)
        try fixture.context.save()
        let context = ModelContext(fixture.container)
        let note = try fetchNote(fixture.note.id, in: context)
        XCTAssertThrowsError(
            try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: note,
                with: "New",
                in: context
            )
        )
        XCTAssertEqual(note.content, "Old")
        XCTAssertFalse(context.hasChanges)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
