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

    func testBootstrapMergesSharedDivergentLineageAndCoversSequenceBaseline() throws {
        let source = try makeSeededFixture(body: "AB")
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext
        )

        let sourceSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        )
        let destinationNote = try fetchNote(source.note.id, in: destinationContext)
        let destinationSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: destinationNote,
            in: destinationContext
        )
        let rootID = try XCTUnwrap(sourceSnapshot.state.runs.first?.operationID)
        let left = try SyncTextElementID(operationID: rootID, elementOffset: 0)
        let right = try SyncTextElementID(operationID: rootID, elementOffset: 1)
        let anchor = try SyncOperationAnchor.between(left: left, right: right)
        let sourceState = try sourceSnapshot.state.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
                anchor: anchor
            ),
            insertedText: "S"
        )
        let destinationState = try destinationSnapshot.state.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
                anchor: anchor
            ),
            insertedText: "D"
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: source.note,
            expected: sourceSnapshot,
            newBody: sourceState.visibleText,
            finalState: sourceState,
            in: source.context
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: destinationNote,
            expected: destinationSnapshot,
            newBody: destinationState.visibleText,
            finalState: destinationState,
            in: destinationContext
        )
        try source.context.save()
        try destinationContext.save()
        destinationNote.richTextContentData = Data("stale-rich-text".utf8)
        try destinationContext.save()
        let batchID = UUID()
        let snapshot = withHistoryCoverage(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            batchID: batchID,
            noteIDs: [source.note.id]
        )

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(snapshot, to: destinationContext)
        let mergedRecord = try XCTUnwrap(fetchRecords(in: destinationContext).only)
        let mergedState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: mergedRecord,
            noteID: source.note.id
        )

        XCTAssertEqual(disposition.coveredNoteIDs, [source.note.id])
        XCTAssertTrue(disposition.coveredBatchIDs.isEmpty)
        XCTAssertTrue(disposition.presentationRefreshRequired)
        XCTAssertTrue(mergedState.visibleText.contains("S"))
        XCTAssertTrue(mergedState.visibleText.contains("D"))
        XCTAssertEqual(destinationNote.content, mergedState.visibleText)
        XCTAssertNil(destinationNote.richTextContentData)
        XCTAssertEqual(mergedState.runs.count, 3)
    }

    func testBootstrapPersistsQueuedInsertionOwnershipAfterUnionCommitAndPlannerCleansIt() throws {
        let source = try makeSeededFixture(body: "AB")
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext
        )
        let sourceSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        )
        let destinationNote = try fetchNote(source.note.id, in: destinationContext)
        let destinationSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: destinationNote,
            in: destinationContext
        )
        let rootID = try XCTUnwrap(sourceSnapshot.state.runs.first?.operationID)
        let anchor = try SyncOperationAnchor.between(
            left: SyncTextElementID(operationID: rootID, elementOffset: 0),
            right: SyncTextElementID(operationID: rootID, elementOffset: 1)
        )
        let ownedID = SyncOperationID(deviceID: UUID(), localCounter: 1)
        let queuedChange = try XCTUnwrap({ () -> SyncBatchNoteBodyTextInsertedAnchoredChange? in
            guard case .noteBodyTextInsertedAnchored(let change) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
                noteID: source.note.id,
                utf16Offset: 1,
                text: "S",
                modifiedAt: Date(timeIntervalSince1970: 221),
                baseContentHash: nil,
                operationID: ownedID,
                state: sourceSnapshot.state
            ) else { return nil }
            return change
        }())
        let insertedSourceState = try sourceSnapshot.state.incorporating(
            insert: queuedChange.payload,
            insertedText: queuedChange.text
        )
        guard case .noteBodyTextDeletedAnchored(let queuedDeletion) = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
            noteID: source.note.id,
            utf16Offset: 0,
            utf16Length: 1,
            expectedText: "A",
            modifiedAt: Date(timeIntervalSince1970: 222),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 2),
            state: insertedSourceState
        ) else {
            return XCTFail("Expected anchored deletion")
        }
        let sourceState = try insertedSourceState.incorporating(delete: queuedDeletion.payload)
        let destinationState = try destinationSnapshot.state.incorporating(
            insert: SyncTextInsertOperationPayload(
                operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
                anchor: anchor
            ),
            insertedText: "D"
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: source.note,
            expected: sourceSnapshot,
            newBody: sourceState.visibleText,
            finalState: sourceState,
            in: source.context
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: destinationNote,
            expected: destinationSnapshot,
            newBody: destinationState.visibleText,
            finalState: destinationState,
            in: destinationContext
        )
        try source.context.save()
        try destinationContext.save()

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let queueURL = temporaryDirectory.appendingPathComponent("pending-incoming.json")
        let recoveryURL = temporaryDirectory.appendingPathComponent("anchored-recovery.json")
        let queue = FileBackedSyncBatchQueue(fileURL: queueURL)
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: recoveryURL)
        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 221),
            changes: [
                .noteBodyTextInsertedAnchored(queuedChange),
                .noteBodyTextDeletedAnchored(queuedDeletion)
            ]
        )
        try queue.enqueueIncomingCore(batch, activationEnabled: true)

        let abortedStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("aborted-recovery.json")
        )
        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(
                try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
                to: destinationContext,
                pendingIncomingBatches: queue,
                anchoredRecoveryStore: abortedStore,
                saveContext: {
                    throw NSError(domain: "MYR221InjectedSequenceSaveFailure", code: 1)
                }
            )
        )
        let abortedKey = SyncBatchAnchoredRecoveryRecordKey(
            noteID: source.note.id,
            operationID: queuedChange.payload.operationID
        )
        XCTAssertNil(abortedStore.snapshot().record(for: abortedKey))
        let rolledBackRecord = try XCTUnwrap(fetchRecords(in: destinationContext).only)
        let rolledBackState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: rolledBackRecord,
            noteID: source.note.id
        )
        XCTAssertFalse(rolledBackState.runs.contains { $0.operationID == ownedID })
        let replayPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: .insertion(queuedChange),
            sequenceState: rolledBackState,
            recoverySnapshot: abortedStore.snapshot()
        )
        XCTAssertTrue(replayPlan.didChangeApplicationState)
        XCTAssertTrue(replayPlan.appliedRecords.isEmpty)
        XCTAssertTrue(replayPlan.recoveryStoreTransitions.isEmpty)

        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext,
            pendingIncomingBatches: queue,
            anchoredRecoveryStore: recoveryStore
        )

        let key = SyncBatchAnchoredRecoveryRecordKey(
            noteID: source.note.id,
            operationID: queuedChange.payload.operationID
        )
        let persisted = try XCTUnwrap(recoveryStore.snapshot().record(for: key))
        XCTAssertEqual(persisted.lifecycle, .bootstrapOwned)
        let deletionKey = SyncBatchAnchoredRecoveryRecordKey(
            noteID: source.note.id,
            operationID: queuedDeletion.payload.operationID
        )
        let persistedDeletion = try XCTUnwrap(recoveryStore.snapshot().record(for: deletionKey))
        XCTAssertEqual(persistedDeletion.lifecycle, .bootstrapOwned)
        let finalRecord = try XCTUnwrap(fetchRecords(in: destinationContext).only)
        let finalState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: finalRecord,
            noteID: source.note.id
        )
        let failingStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("failing-recovery.json"),
            atomicWriter: { _, _ in
                throw NSError(domain: "MYR221InjectedRecoveryWriteFailure", code: 1)
            }
        )
        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(
                try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
                to: destinationContext,
                pendingIncomingBatches: queue,
                anchoredRecoveryStore: failingStore
            )
        )
        let stateAfterFailedOwnership = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: try XCTUnwrap(fetchRecords(in: destinationContext).only),
            noteID: source.note.id
        )
        XCTAssertEqual(stateAfterFailedOwnership, finalState)
        XCTAssertNil(failingStore.snapshot().record(for: key))
        XCTAssertFalse(destinationContext.hasChanges)

        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: .insertion(queuedChange),
            sequenceState: finalState,
            recoverySnapshot: recoveryStore.snapshot()
        )
        XCTAssertEqual(plan.appliedRecords, [persisted])
        XCTAssertEqual(plan.recoveryStoreTransitions, [.removeCommitted(expected: persisted)])
        let deletionPlan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: .deletion(queuedDeletion),
            sequenceState: finalState,
            recoverySnapshot: recoveryStore.snapshot()
        )
        XCTAssertEqual(deletionPlan.appliedRecords, [persistedDeletion])
        XCTAssertEqual(
            deletionPlan.recoveryStoreTransitions,
            [.removeCommitted(expected: persistedDeletion)]
        )

        let duplicateRunStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("duplicate-run-recovery.json")
        )
        let duplicateRunRecord = try SyncBatchAnchoredRecoveryRecord(
            change: .insertion(queuedChange),
            lifecycle: .terminalStructuralFailure(
                try SyncBatchAnchoredStructuralFailure(
                    code: .duplicateRun,
                    evidence: .init(operationID: queuedChange.payload.operationID)
                )
            )
        )
        try duplicateRunStore.apply([.insertExpectedAbsent(duplicateRunRecord)])

        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext,
            pendingIncomingBatches: queue,
            anchoredRecoveryStore: duplicateRunStore
        )

        let upgradedOwnership = try XCTUnwrap(
            duplicateRunStore.snapshot().record(for: duplicateRunRecord.key)
        )
        XCTAssertEqual(upgradedOwnership.change, duplicateRunRecord.change)
        XCTAssertEqual(upgradedOwnership.lifecycle, .bootstrapOwned)
    }

    func testBootstrapPersistsManifestedInsertionOwnershipWithoutPendingIncomingBatch() throws {
        let source = try makeSeededFixture(body: "AB")
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext
        )
        let sourceSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        )
        let destinationNote = try fetchNote(source.note.id, in: destinationContext)
        let destinationSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: destinationNote,
            in: destinationContext
        )
        guard case .noteBodyTextInsertedAnchored(let manifestedInsertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: source.note.id,
            utf16Offset: 1,
            text: "S",
            modifiedAt: Date(timeIntervalSince1970: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
            state: sourceSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let sourceState = try sourceSnapshot.state.incorporating(
            insert: manifestedInsertion.payload,
            insertedText: manifestedInsertion.text
        )
        guard case .noteBodyTextInsertedAnchored(let destinationInsertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: destinationNote.id,
            utf16Offset: 1,
            text: "D",
            modifiedAt: Date(timeIntervalSince1970: 222),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
            state: destinationSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let destinationState = try destinationSnapshot.state.incorporating(
            insert: destinationInsertion.payload,
            insertedText: destinationInsertion.text
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: source.note,
            expected: sourceSnapshot,
            newBody: sourceState.visibleText,
            finalState: sourceState,
            in: source.context
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: destinationNote,
            expected: destinationSnapshot,
            newBody: destinationState.visibleText,
            finalState: destinationState,
            in: destinationContext
        )
        try source.context.save()
        try destinationContext.save()

        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 223),
            changes: [
                .noteBodyTextInsertedAnchored(manifestedInsertion),
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: source.note.id,
                        title: "Non-anchored metadata",
                        modifiedAt: Date(timeIntervalSince1970: 224)
                    )
                )
            ]
        )
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
            .attachingHistoryCoverage(for: [batch])
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-manifested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let emptyQueue = FileBackedSyncBatchQueue(
            fileURL: temporaryDirectory.appendingPathComponent("pending-incoming.json")
        )
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("anchored-recovery.json")
        )

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: destinationContext,
            pendingIncomingBatches: emptyQueue,
            anchoredRecoveryStore: recoveryStore
        )
        let committedState = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: try XCTUnwrap(fetchRecords(in: destinationContext).only),
            noteID: source.note.id
        )
        let key = SyncBatchAnchoredRecoveryRecordKey(
            noteID: source.note.id,
            operationID: manifestedInsertion.payload.operationID
        )

        XCTAssertFalse(disposition.coveredBatchIDs.contains(batch.id))
        XCTAssertEqual(snapshot.historyCoverage.only?.anchoredRecoveryChanges, [.insertion(manifestedInsertion)])
        XCTAssertTrue(committedState.runs.contains { $0.operationID == manifestedInsertion.payload.operationID })
        XCTAssertEqual(recoveryStore.snapshot().record(for: key)?.lifecycle, .bootstrapOwned)

        let route = try SyncBatchAnchoredActivationPlanner.planInitialDelivery(
            change: .noteBodyTextInsertedAnchored(manifestedInsertion),
            sequenceState: committedState,
            recoverySnapshot: recoveryStore.snapshot()
        )
        guard case .completedWithoutApplicationChange(let plan, let reason) = route else {
            return XCTFail("Expected applied-equivalent recovery, got \(route)")
        }
        XCTAssertEqual(reason, .appliedEquivalentRecovery)
        XCTAssertTrue(try recoveryStore.apply(plan.recoveryStoreTransitions))
        XCTAssertNil(recoveryStore.snapshot().record(for: key))
    }

    func testBootstrapFullyCoveredManifestedBatchDoesNotCreateOrphanOwnership() throws {
        let source = try makeSeededFixture(body: "AB")
        let sourceSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        )
        guard case .noteBodyTextInsertedAnchored(let insertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: source.note.id,
            utf16Offset: 1,
            text: "S",
            modifiedAt: Date(timeIntervalSince1970: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
            state: sourceSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let insertedState = try sourceSnapshot.state.incorporating(
            insert: insertion.payload,
            insertedText: insertion.text
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: source.note,
            expected: sourceSnapshot,
            newBody: insertedState.visibleText,
            finalState: insertedState,
            in: source.context
        )
        try source.context.save()
        let batch = SyncBatch(
            id: UUID(),
            originDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 222),
            changes: [.noteBodyTextInsertedAnchored(insertion)]
        )
        let snapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
            .attachingHistoryCoverage(for: [batch])
        let destination = try makeContainer()
        let context = ModelContext(destination)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-covered-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("anchored-recovery.json")
        )

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: context,
            anchoredRecoveryStore: recoveryStore
        )

        XCTAssertEqual(disposition.coveredBatchIDs, [batch.id])
        XCTAssertTrue(recoveryStore.snapshot().records.isEmpty)
    }

    func testBootstrapLegacyHistoryCoverageDecodesWithoutEvidenceAndCreatesNoOwnership() throws {
        let source = try makeSeededFixture(body: "AB")
        let batchID = UUID()
        let noteID = source.note.id
        let encoded = try JSONSerialization.data(withJSONObject: [
            "batchID": batchID.uuidString,
            "noteIDs": [noteID.uuidString]
        ])
        let decoded = try JSONDecoder().decode(
            SyncPeerBootstrapHistoryBatchCoverage.self,
            from: encoded
        )

        XCTAssertEqual(decoded.batchID, batchID)
        XCTAssertEqual(decoded.noteIDs, [noteID])
        XCTAssertNil(decoded.anchoredRecoveryChanges)

        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let snapshot = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: original.notes,
            historyCoverage: [decoded]
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryDirectory.appendingPathComponent("anchored-recovery.json")
        )
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            snapshot,
            to: ModelContext(try makeContainer()),
            anchoredRecoveryStore: recoveryStore
        )
        XCTAssertTrue(recoveryStore.snapshot().records.isEmpty)
    }

    func testBootstrapManifestRejectsBootstrapAndUndeclaredNoteRecoveryEvidence() throws {
        let source = try makeSeededFixture(body: "AB")
        let original = try SyncPeerBootstrapSnapshotPersistence.build(from: source.context)
        let bootstrapBatchID = UUID()
        let bootstrap = SyncBatchAnchoredRecoveryChange.bootstrap(
            try SyncBatchAnchoredBootstrapChange(noteID: source.note.id, body: source.note.content)
        )
        let bootstrapSnapshot = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: original.notes,
            historyCoverage: [
                .init(
                    batchID: bootstrapBatchID,
                    noteIDs: [source.note.id],
                    anchoredRecoveryChanges: [bootstrap]
                )
            ]
        )
        let destination = try makeContainer()

        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(
                bootstrapSnapshot,
                to: ModelContext(destination)
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncPeerBootstrapError,
                .historyContainsBootstrapRecoveryChange(bootstrapBatchID)
            )
        }

        let sourceState = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        ).state
        guard case .noteBodyTextInsertedAnchored(let insertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: source.note.id,
            utf16Offset: 1,
            text: "S",
            modifiedAt: Date(timeIntervalSince1970: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
            state: sourceState
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let undeclaredSnapshot = SyncPeerBootstrapSnapshot(
            id: original.id,
            folders: original.folders,
            notes: original.notes,
            historyCoverage: [
                .init(
                    batchID: UUID(),
                    noteIDs: [],
                    anchoredRecoveryChanges: [.insertion(insertion)]
                )
            ]
        )

        XCTAssertThrowsError(
            try SyncPeerBootstrapSnapshotPersistence.apply(
                undeclaredSnapshot,
                to: ModelContext(destination)
            )
        ) {
            XCTAssertEqual(
                $0 as? SyncPeerBootstrapError,
                .historyEvidenceReferencesUndeclaredNote(source.note.id)
            )
        }
    }

    func testBootstrapStructuralOnlyUnionPreservesRichText() throws {
        let source = try makeSeededFixture(body: "AB")
        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext
        )
        let sourceSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: source.note,
            in: source.context
        )
        guard case .noteBodyTextInsertedAnchored(let insertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: source.note.id,
            utf16Offset: 1,
            text: "X",
            modifiedAt: Date(timeIntervalSince1970: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 1),
            state: sourceSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let insertedState = try sourceSnapshot.state.incorporating(
            insert: insertion.payload,
            insertedText: insertion.text
        )
        guard case .noteBodyTextDeletedAnchored(let deletion) = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
            noteID: source.note.id,
            utf16Offset: 1,
            utf16Length: 1,
            expectedText: "X",
            modifiedAt: Date(timeIntervalSince1970: 222),
            baseContentHash: nil,
            operationID: SyncOperationID(deviceID: UUID(), localCounter: 2),
            state: insertedState
        ) else {
            return XCTFail("Expected anchored deletion")
        }
        let tombstonedState = try insertedState.incorporating(delete: deletion.payload)
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: source.note,
            expected: sourceSnapshot,
            newBody: tombstonedState.visibleText,
            finalState: tombstonedState,
            in: source.context
        )
        try source.context.save()
        let destinationNote = try fetchNote(source.note.id, in: destinationContext)
        let richText = Data("preserve-rich-text".utf8)
        destinationNote.richTextContentData = richText
        try destinationContext.save()

        let disposition = try SyncPeerBootstrapSnapshotPersistence.apply(
            try SyncPeerBootstrapSnapshotPersistence.build(from: source.context),
            to: destinationContext
        )

        XCTAssertTrue(disposition.presentationRefreshRequired)
        XCTAssertEqual(destinationNote.content, "AB")
        XCTAssertEqual(destinationNote.richTextContentData, richText)
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
