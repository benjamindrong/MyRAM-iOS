import Foundation
import SwiftData
import XCTest
import NearbySyncCore
import AnchoredSequenceCore
@preconcurrency import MultipeerConnectivity

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

@MainActor
final class NoteSequenceStateBootstrapMigratorTests: XCTestCase {
    func testMigrationCoversActiveDeletedEmptyAndNonemptyNotes() async throws {
        let container = try makeContainer()
        let fixtures = [
            try insertNote(body: "", deleted: false, in: container),
            try insertNote(body: "Active", deleted: false, in: container),
            try insertNote(body: "", deleted: true, in: container),
            try insertNote(body: "Deleted", deleted: true, in: container)
        ]

        try await makeMigrator(container).runToCompletion()

        XCTAssertEqual(Set(try fetchRecords(in: container).map(\.noteID)), Set(fixtures))
    }

    func testMigrationProcessesNoteIDsInDeterministicOrder() async throws {
        let container = try makeContainer()
        let ids = [
            UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        ]
        for id in ids {
            _ = try insertNote(noteID: id, body: id.uuidString, in: container)
        }
        let recorder = IDRecorder()

        try await makeMigrator(container) { recorder.record($0) }.runToCompletion()

        XCTAssertEqual(
            recorder.ids,
            ids.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        )
    }

    func testMigrationRerunIsIdempotentForExactRows() async throws {
        let container = try makeContainer()
        _ = try insertNote(body: "Body", in: container)
        let migrator = await makeMigrator(container)
        try await migrator.runToCompletion()
        let original = try XCTUnwrap(fetchRecords(in: container).first)
        let payload = original.statePayloadData

        try await migrator.runToCompletion()

        let rerun = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(rerun.revision, 0)
        XCTAssertEqual(rerun.statePayloadData, payload)
    }

    func testActivatedMigrationStopsAtValidStaleRowWithoutReplacingLineage() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old", in: container)
        try await makeMigrator(container).runToCompletion()
        let original = try XCTUnwrap(fetchRecords(in: container).first)
        let originalPayload = original.statePayloadData
        try updateNote(noteID: noteID, body: "Current", in: container)

        do {
            try await makeMigrator(container).runToCompletion()
            XCTFail("Expected activated migration to preserve the established lineage and stop")
        } catch {
            XCTAssertEqual(error as? NoteSequenceStateStoreError, .corruptState)
        }

        let persisted = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(persisted.revision, 0)
        XCTAssertEqual(persisted.statePayloadData, originalPayload)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: persisted, noteID: noteID)
        XCTAssertEqual(state.visibleText, "Old")

        let verificationContext = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            verificationContext.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedID })
            ).first
        )
        XCTAssertEqual(note.content, "Current")
    }

    func testMigrationReestablishesValidStaleRowsWhenExplicitlyAllowed() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old", in: container)
        try await makeMigrator(container).runToCompletion()
        try updateNote(noteID: noteID, body: "Current", in: container)

        try await makeMigrator(
            container,
            allowsExistingStateReplacement: true
        ).runToCompletion()

        let record = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(record.revision, 1)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        XCTAssertEqual(state.visibleText, "Current")
    }

    func testMYR238PreservesValidDivergenceWhilePreparingOtherNotes() async throws {
        let container = try makeContainer()
        let divergentNoteID = try insertNote(body: "Prior sequence body", in: container)
        let healthyNoteID = try insertNote(body: "Healthy body", in: container)
        try await makeMigrator(
            container, allowsExistingStateReplacement: false
        ).runToCompletion()
        let originalRecords = try fetchRecords(in: container)
        let divergentRecord = try XCTUnwrap(
            originalRecords.first { $0.noteID == divergentNoteID }
        )
        let originalPayload = divergentRecord.statePayloadData
        let originalRevision = divergentRecord.revision
        try updateNote(noteID: divergentNoteID, body: "Saved note body", in: container)

        let quarantined = try await makeMigrator(
            container, allowsExistingStateReplacement: false
        ).runPreservingDivergentStates()

        XCTAssertEqual(quarantined, Set([divergentNoteID]))
        let records = try fetchRecords(in: container)
        let retained = try XCTUnwrap(records.first { $0.noteID == divergentNoteID })
        XCTAssertEqual(retained.revision, originalRevision)
        XCTAssertEqual(retained.statePayloadData, originalPayload)
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: retained, noteID: divergentNoteID)
        XCTAssertEqual(sequence.visibleText, "Prior sequence body")
        let context = ModelContext(container)
        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(
            notes.first { $0.id == divergentNoteID }?.content,
            "Saved note body"
        )
        XCTAssertEqual(
            notes.first { $0.id == healthyNoteID }?.content,
            "Healthy body"
        )
        let rerun = try await makeMigrator(
            container, allowsExistingStateReplacement: false
        ).runPreservingDivergentStates()
        XCTAssertEqual(rerun, quarantined)
        // Preservation mode must not inherit the destructive legacy replacement
        // behavior if an older runtime config ever enables that switch.
        let legacyConfigured = try await makeMigrator(
            container, allowsExistingStateReplacement: true
        ).runPreservingDivergentStates()
        XCTAssertEqual(legacyConfigured, quarantined)
        XCTAssertEqual(
            try XCTUnwrap(fetchRecords(in: container).first {
                $0.noteID == divergentNoteID
            }).statePayloadData,
            originalPayload
        )
    }

    func testMYR238DivergenceSnapshotPreservesBothAuthoritiesAndRejectsStaleState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old anchored body", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        let originalRecord = try XCTUnwrap(fetchRecords(in: container).first)
        try updateNote(noteID: noteID, body: "Current saved body", in: container)

        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        XCTAssertEqual(snapshot.savedBody, "Current saved body")
        XCTAssertEqual(snapshot.sequenceVisibleText, "Old anchored body")
        XCTAssertEqual(snapshot.sequencePayloadData, originalRecord.statePayloadData)
        XCTAssertEqual(snapshot.markStatePayloadData, originalRecord.markStatePayloadData)
        XCTAssertEqual(snapshot.sequenceRevision, originalRecord.revision)
        XCTAssertEqual(snapshot.markRevision, originalRecord.markRevision)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(NoteLocalDivergenceSnapshot.self, from: encoded), snapshot)
        let current = try await migrator.revalidateDivergenceSnapshot(snapshot)
        XCTAssertTrue(current)

        try updateNote(noteID: noteID, body: "Another saved body", in: container)
        let currentAfterChange = try await migrator.revalidateDivergenceSnapshot(snapshot)
        XCTAssertFalse(currentAfterChange)
        XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                       originalRecord.statePayloadData)
    }

    func testMYR238OwnerResolutionPlansPreserveHistoryAndDoNotMutateAuthorities() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored original", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        let recordBefore = try XCTUnwrap(fetchRecords(in: container).first)
        let originalPayload = recordBefore.statePayloadData
        let originalRevision = recordBefore.revision
        try updateNote(noteID: noteID, body: "Saved local text", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)

        let keepHistory = try await migrator.makeOwnerResolutionPlan(
            for: snapshot, choice: .keepAnchoredHistory
        )
        XCTAssertEqual(keepHistory.finalBody, "Anchored original")
        XCTAssertEqual(keepHistory.finalState.visibleText, "Anchored original")
        XCTAssertTrue(keepHistory.capturedChanges.isEmpty)

        let keepSaved = try await migrator.makeOwnerResolutionPlan(
            for: snapshot, choice: .keepSavedBody
        )
        XCTAssertEqual(keepSaved.finalBody, "Saved local text")
        XCTAssertEqual(keepSaved.finalState.visibleText, "Saved local text")
        XCTAssertFalse(keepSaved.capturedChanges.isEmpty)
        XCTAssertNotEqual(keepSaved.finalState, keepHistory.finalState)

        // Proposals alone must not stage a new note, sequence, or queue owner.
        let unchanged = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(unchanged.statePayloadData, originalPayload)
        XCTAssertEqual(unchanged.revision, originalRevision)
        let unchangedSnapshot = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        XCTAssertEqual(try XCTUnwrap(unchangedSnapshot), snapshot)

        try updateNote(noteID: noteID, body: "Edited after review", in: container)
        do {
            _ = try await migrator.makeOwnerResolutionPlan(
                for: snapshot, choice: .keepSavedBody
            )
            XCTFail("Stale authority must invalidate an earlier owner decision")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .staleSnapshot)
        }
    }

    func testMYR238DivergenceSnapshotRejectsNondivergentRow() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Matching body", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        let snapshot = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        XCTAssertNil(snapshot)
    }

    func testMYR238DurableLocalEvidencePreservesBothGenerationsAndRestarts() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored original", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        let originalRecord = try XCTUnwrap(fetchRecords(in: container).first)
        try updateNote(noteID: noteID, body: "Saved first", in: container)
        let firstCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let first = try XCTUnwrap(firstCapture)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("local-divergence-evidence-v1.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: archiveURL)
        let created = try await store.preserve(first, checkedBy: migrator)
        XCTAssertTrue(created)
        let duplicate = try await store.preserve(first, checkedBy: migrator)
        XCTAssertFalse(duplicate)

        try updateNote(noteID: noteID, body: "Saved second", in: container)
        let secondCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let second = try XCTUnwrap(secondCapture)
        let secondCreated = try await store.preserve(second, checkedBy: migrator)
        XCTAssertTrue(secondCreated)

        let reopened = await NoteLocalDivergenceEvidenceStore(fileURL: archiveURL)
        let restored = try await reopened.snapshots(for: noteID)
        XCTAssertEqual(restored, [first, second])
        XCTAssertEqual(restored.first?.sequencePayloadData, originalRecord.statePayloadData)
        XCTAssertEqual(restored.first?.markStatePayloadData, originalRecord.markStatePayloadData)
        XCTAssertEqual(restored.map(\.savedBody), ["Saved first", "Saved second"])
        XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                       originalRecord.statePayloadData)
    }

    func testMYR238DurableLocalEvidenceRejectsStaleAndCorruptArchive() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored original", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved first", in: container)
        let snapshotCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(snapshotCapture)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("archive.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: archiveURL)

        try updateNote(noteID: noteID, body: "Saved later", in: container)
        do {
            _ = try await store.preserve(snapshot, checkedBy: migrator)
            XCTFail("Stale local note authority must not be certified")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .staleSnapshot)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: archiveURL)
        do {
            _ = try await store.snapshots(for: noteID)
            XCTFail("Corrupt evidence must be retained and reported, never replaced")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .corruptArchive)
        }
        XCTAssertEqual(try Data(contentsOf: archiveURL), corrupt)
    }

    func testMYR238DurableLocalEvidenceFailedWriteCannotReportPreserved() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored original", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved text", in: container)
        let snapshotCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(snapshotCapture)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appendingPathComponent("archive.json")
        var failingIO = NoteLocalDivergenceEvidenceFileIO.live
        failingIO.writeData = { _, _ in
            throw NSError(domain: "MYR238.simulatedWriteFailure", code: 1)
        }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: archiveURL,
            fileIO: failingIO
        )
        do {
            _ = try await store.preserve(snapshot, checkedBy: migrator)
            XCTFail("A failed evidence write must never permit authority change")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        let retained = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(retained.statePayloadData, snapshot.sequencePayloadData)
    }

    func testMYR238OwnerSelectedResolutionIntentPersistsAcrossRestartWithoutMutatingNotes() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Original anchored history", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved owner text", in: container)
        let snapshotCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(snapshotCapture)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-owner-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let initiallyUnfinished = try await store.hasUnfinishedResolutionIntents()
        XCTAssertFalse(initiallyUnfinished)
        let preserved = try await store.preserve(snapshot, checkedBy: migrator)
        XCTAssertTrue(preserved)
        let prepared = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot,
            choice: .keepSavedBody,
            checkedBy: migrator
        )
        XCTAssertTrue(prepared)
        let repeated = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot,
            choice: .keepSavedBody,
            checkedBy: migrator
        )
        XCTAssertFalse(repeated)
        let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let stillUnfinished = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertTrue(stillUnfinished)
        let intent = try await restarted.preparedResolution(for: noteID)
        XCTAssertEqual(intent?.noteID, noteID)
        XCTAssertEqual(intent?.evidenceIndex, 0)
        XCTAssertEqual(intent?.choice, .keepSavedBody)
        let restoredSnapshots = try await restarted.snapshots(for: noteID)
        XCTAssertEqual(restoredSnapshots, [snapshot])
        let record = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(record.statePayloadData, snapshot.sequencePayloadData)
        XCTAssertEqual(record.markStatePayloadData, snapshot.markStatePayloadData)
        let notes = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.first { $0.id == noteID }?.content, snapshot.savedBody)
    }

    func testMYR238OwnerResolutionIntentRejectsMissingEvidenceAndConflictingChoice() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let snapshotCapture = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(snapshotCapture)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-owner-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: directory.appendingPathComponent("archive.json")
        )
        do {
            _ = try await store.prepareOwnerSelectedResolution(
                snapshot: snapshot,
                choice: .keepAnchoredHistory,
                checkedBy: migrator
            )
            XCTFail("Cannot record a choice without verified durable evidence")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .snapshotNotPreserved)
        }
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        let firstPrepared = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot,
            choice: .keepAnchoredHistory,
            checkedBy: migrator
        )
        XCTAssertTrue(firstPrepared)
        do {
            _ = try await store.prepareOwnerSelectedResolution(
                snapshot: snapshot,
                choice: .keepSavedBody,
                checkedBy: migrator
            )
            XCTFail("A second choice must not replace the immutable first intent")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .conflictingResolution)
        }
        try updateNote(noteID: noteID, body: "Saved updated again", in: container)
        do {
            _ = try await store.prepareOwnerSelectedResolution(
                snapshot: snapshot,
                choice: .keepAnchoredHistory,
                checkedBy: migrator
            )
            XCTFail("Do not accept stale owner choices")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .staleSnapshot)
        }
        let retained = try await store.preparedResolution(for: noteID)
        XCTAssertEqual(retained?.choice, .keepAnchoredHistory)
    }

    func testMYR238OwnerResolutionIntentDecodesEarlierV1AndRejectsInvalidReferences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-owner-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("archive.json")
        // Existing v1 snapshot archives contain no resolutionIntents key.
        let legacyArchive = Data(#"{"formatVersion":1,"snapshots":[]}"#.utf8)
        try legacyArchive.write(to: url)
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let missing = try await store.preparedResolution(for: UUID())
        XCTAssertNil(missing)
        // Invalid intent indices must fail closed, preserving original bytes.
        let corrupted = Data(
            #"{"formatVersion":1,"snapshots":[],"resolutionIntents":[{"noteID":"00000000-0000-0000-0000-000000000001","evidenceIndex":0,"choice":"keepSavedBody"}]}"#.utf8
        )
        try corrupted.write(to: url)
        do {
            _ = try await store.preparedResolution(for: UUID())
            XCTFail("An orphaned resolution intent must never be trusted")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .corruptArchive)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
        do {
            _ = try await store.hasUnfinishedResolutionIntents()
            XCTFail("Corrupt intent ledger cannot be treated as empty")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .corruptArchive)
        }
    }

    func testMYR238PreparedQueueOwnershipSurvivesRestartAndRejectsChangedPreimage() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-queue-preimage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let ownership = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(pendingChanges: []),
            unsent: [],
            incoming: [],
            localObligations: []
        )
        do {
            _ = try await store.prepareQueueOwnership(
                for: snapshot, ownership: ownership, checkedBy: migrator
            )
            XCTFail("Queue preimage requires explicit preserved user intent")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .unresolvedResolutionIntent)
        }
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        let prepared = try await store.prepareQueueOwnership(
            for: snapshot, ownership: ownership, checkedBy: migrator
        )
        XCTAssertTrue(prepared)
        let repeated = try await store.prepareQueueOwnership(
            for: snapshot, ownership: ownership, checkedBy: migrator
        )
        XCTAssertFalse(repeated)
        let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let restored = try await restarted.preparedQueueOwnership(for: noteID)
        XCTAssertEqual(restored?.ownership, ownership)
        XCTAssertEqual(restored?.intent.choice, .keepSavedBody)

        let changed = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: ownership.legacy,
            unsent: [],
            incoming: [SyncBatch(
                id: UUID(), originDeviceID: UUID(), createdAt: .now,
                changes: []
            )],
            localObligations: []
        )
        do {
            _ = try await restarted.prepareQueueOwnership(
                for: snapshot, ownership: changed, checkedBy: migrator
            )
            XCTFail("Cannot silently replace captured pending queue work")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .conflictingQueueOwnership)
        }
        let unchanged = try await restarted.preparedQueueOwnership(for: noteID)
        XCTAssertEqual(unchanged?.ownership, ownership)
        let authoritative = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(authoritative.statePayloadData, snapshot.sequencePayloadData)
        let notes = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.first { $0.id == noteID }?.content, "Saved")
    }

    func testMYR238CommitPreparationRequiresOwnerIntentAndQueuePreimage() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-commit-preimage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: directory.appendingPathComponent("archive.json")
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)

        do {
            _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
            XCTFail("No automatic resolution without explicit intent")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .conflictingQueueOwnership)
        }
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        do {
            _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
            XCTFail("An owner choice alone cannot bypass durable queue ownership")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .conflictingQueueOwnership)
        }
        let unprepared = try await store.preparedCommit(for: noteID)
        XCTAssertNil(unprepared)
    }

    func testMYR238CommitPreparationSurvivesRestartWithoutChangingAuthority() async throws {
        for choice in [NoteLocalDivergenceResolutionChoice.keepSavedBody, .keepAnchoredHistory] {
            let container = try makeContainer()
            let noteID = try insertNote(body: "Anchored original", in: container)
            let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
            try await migrator.runToCompletion()
            try updateNote(noteID: noteID, body: "Saved local work", in: container)
            let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
            let snapshot = try XCTUnwrap(captured)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MYR238-commit-durable-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("archive.json")
            let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
            let queue = NoteLocalDivergenceQueueOwnershipEvidence(
                legacy: SyncQueueSnapshot(pendingChanges: []),
                unsent: [], incoming: [], localObligations: []
            )
            _ = try await store.preserve(snapshot, checkedBy: migrator)
            _ = try await store.prepareOwnerSelectedResolution(
                snapshot: snapshot, choice: choice, checkedBy: migrator
            )
            _ = try await store.prepareQueueOwnership(
                for: snapshot, ownership: queue, checkedBy: migrator
            )
            let prepared = try await store.prepareCommit(
                for: snapshot, checkedBy: migrator
            )
            XCTAssertEqual(prepared.intent.choice, choice)
            XCTAssertEqual(prepared.finalBody, choice == .keepSavedBody
                ? "Saved local work" : "Anchored original")
            XCTAssertEqual(prepared.finalMarkStatePayloadData, snapshot.markStatePayloadData)
            if choice == .keepAnchoredHistory {
                XCTAssertEqual(prepared.finalSequencePayloadData, snapshot.sequencePayloadData)
                XCTAssertTrue(prepared.capturedChanges.isEmpty)
            } else {
                XCTAssertFalse(prepared.capturedChanges.isEmpty)
            }
            let bytes = try Data(contentsOf: url)
            let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: url)
            let recovered = try await restarted.preparedCommit(for: noteID)
            XCTAssertEqual(recovered, prepared)
            let repeated = try await restarted.prepareCommit(
                for: snapshot, checkedBy: migrator
            )
            XCTAssertEqual(repeated, prepared)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            let pending = try await restarted.hasUnfinishedResolutionIntents()
            XCTAssertTrue(pending)

            let record = try XCTUnwrap(fetchRecords(in: container).first)
            XCTAssertEqual(record.statePayloadData, snapshot.sequencePayloadData)
            XCTAssertEqual(record.markStatePayloadData, snapshot.markStatePayloadData)
            let notes = try ModelContext(container).fetch(FetchDescriptor<Note>())
            XCTAssertEqual(notes.first { $0.id == noteID }?.content, snapshot.savedBody)
            try updateNote(noteID: noteID, body: "Newer unsaved reconciliation", in: container)
            do {
                _ = try await restarted.prepareCommit(for: snapshot, checkedBy: migrator)
                XCTFail("A stale plan cannot be reported valid after a note edit")
            } catch let error as NoteLocalDivergenceEvidenceStoreError {
                XCTAssertEqual(error, .staleSnapshot)
            }
        }
    }

    func testMYR238CommitPreparationWriteFailurePreservesExistingLedger() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-commit-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot,
            ownership: NoteLocalDivergenceQueueOwnershipEvidence(
                legacy: SyncQueueSnapshot(pendingChanges: []),
                unsent: [], incoming: [], localObligations: []
            ),
            checkedBy: migrator
        )
        let original = try Data(contentsOf: url)
        var failedIO = NoteLocalDivergenceEvidenceFileIO.live
        failedIO.writeData = { _, _ in
            throw NSError(domain: "MYR238.injectedWriteFailure", code: 1)
        }
        let failingStore = await NoteLocalDivergenceEvidenceStore(fileURL: url, fileIO: failedIO)
        do {
            _ = try await failingStore.prepareCommit(for: snapshot, checkedBy: migrator)
            XCTFail("A failed write-ahead plan must not certify durability")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let missing = try await store.preparedCommit(for: noteID)
        XCTAssertNil(missing)
        let pending = try await store.hasUnfinishedResolutionIntents()
        XCTAssertTrue(pending)
    }

    func testMYR238OwnerNoteCommitIsAtomicAndIdempotentWithoutQueueMutation() async throws {
        for choice in [NoteLocalDivergenceResolutionChoice.keepSavedBody, .keepAnchoredHistory] {
            let container = try makeContainer()
            let noteID = try insertNote(body: "Old anchored history", in: container)
            let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
            try await migrator.runToCompletion()
            try updateNote(noteID: noteID, body: "Saved owner edits", in: container)
            let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
            let snapshot = try XCTUnwrap(captured)
            let archive = FileManager.default.temporaryDirectory
                .appendingPathComponent("MYR238-note-commit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: archive) }
            let store = await NoteLocalDivergenceEvidenceStore(
                fileURL: archive.appendingPathComponent("ledger.json")
            )
            let originalQueues = NoteLocalDivergenceQueueOwnershipEvidence(
                legacy: SyncQueueSnapshot(pendingChanges: []),
                unsent: [], incoming: [], localObligations: []
            )
            _ = try await store.preserve(snapshot, checkedBy: migrator)
            _ = try await store.prepareOwnerSelectedResolution(
                snapshot: snapshot, choice: choice, checkedBy: migrator
            )
            _ = try await store.prepareQueueOwnership(
                for: snapshot, ownership: originalQueues, checkedBy: migrator
            )
            let frozen = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
            let beforePhase = try await store.noteCommitPhase(for: noteID)
            XCTAssertNil(beforePhase)
            let first = try await store.commitPreparedNote(
                for: snapshot, checkedBy: migrator,
                recaptureQueueOwnership: { originalQueues }
            )
            XCTAssertTrue(first)
            let receipt = try await store.noteCommitPhase(for: noteID)
            XCTAssertEqual(receipt, .noteSaved)
            let savedNote = try XCTUnwrap(ModelContext(container).fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
            ).first)
            XCTAssertEqual(savedNote.content, frozen.finalBody)
            XCTAssertEqual(savedNote.title, snapshot.savedTitle)
            XCTAssertEqual(savedNote.modifiedAt, snapshot.savedModifiedAt)
            let record = try XCTUnwrap(fetchRecords(in: container).first)
            XCTAssertEqual(record.statePayloadData, frozen.finalSequencePayloadData)
            XCTAssertEqual(record.markStatePayloadData, snapshot.markStatePayloadData)
            XCTAssertEqual(record.markRevision, snapshot.markRevision)

            let restarted = await NoteLocalDivergenceEvidenceStore(
                fileURL: archive.appendingPathComponent("ledger.json")
            )
            let replayed = try await restarted.commitPreparedNote(
                for: snapshot, checkedBy: migrator,
                recaptureQueueOwnership: { originalQueues }
            )
            XCTAssertFalse(replayed)
            let pending = try await restarted.hasUnfinishedResolutionIntents()
            XCTAssertTrue(pending, "A note receipt is not permission to resume sync")
            XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                           frozen.finalSequencePayloadData)
            let retainedEvidence = try await restarted.snapshots(for: noteID)
            XCTAssertEqual(retainedEvidence, [snapshot])
        }
    }

    func testMYR238CleanQueueResolutionCompletionSurvivesRestartWithoutDiscardingEvidence() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored history", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved divergent text", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-clean-queue-complete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let queues = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(), unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepAnchoredHistory, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: queues, checkedBy: migrator
        )
        _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        _ = try await store.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { queues }
        )
        let before = try await store.hasUnfinishedResolutionIntents()
        XCTAssertTrue(before, "Note saved is not a completion receipt")
        do {
            _ = try await store.finalizePreparedCleanQueueResolution(
                for: snapshot, checkedBy: migrator,
                verifyQueueOwnership: {
                    throw PendingSyncRecoveryCoordinator.RecoveryError.staleLocalResolutionQueueOwnership
                }
            )
            XCTFail("A failed queue recapture cannot complete resolution")
        } catch let error as PendingSyncRecoveryCoordinator.RecoveryError {
            XCTAssertEqual(error, .staleLocalResolutionQueueOwnership)
        }
        let blocked = try await store.hasUnfinishedResolutionIntents()
        XCTAssertTrue(blocked)
        let finalized = try await store.finalizePreparedCleanQueueResolution(
            for: snapshot, checkedBy: migrator,
            verifyQueueOwnership: {}
        )
        XCTAssertTrue(finalized)
        let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let unfinished = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertFalse(unfinished)
        let repeated = try await restarted.finalizePreparedCleanQueueResolution(
            for: snapshot, checkedBy: migrator,
            verifyQueueOwnership: {}
        )
        XCTAssertFalse(repeated)
        let archived = try await restarted.snapshots(for: noteID)
        XCTAssertEqual(archived, [snapshot], "Both original representations remain archived")
        let note = try XCTUnwrap(ModelContext(container).fetch(
            FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
        ).first)
        XCTAssertEqual(note.content, "Anchored history")
    }

    func testMYR238SavedTextResolutionCannotCompleteWithoutPublishingCapturedWork() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored history", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Owner saved text", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-captured-block-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        let queues = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(), unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: queues, checkedBy: migrator
        )
        let prepared = try await store.prepareCommit(
            for: snapshot, checkedBy: migrator
        )
        XCTAssertFalse(prepared.capturedChanges.isEmpty)
        _ = try await store.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { queues }
        )
        do {
            _ = try await store.finalizePreparedCleanQueueResolution(
                for: snapshot, checkedBy: migrator,
                verifyQueueOwnership: {}
            )
            XCTFail("An unpublished edit cannot be treated as converged")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .unresolvedCapturedResolutionChanges)
        }
        let pending = try await store.hasUnfinishedResolutionIntents()
        XCTAssertTrue(pending)
        let retained = try await store.preparedCommit(for: noteID)
        XCTAssertEqual(retained, prepared)
    }

    func testMYR238CompletionReceiptWriteFailureLeavesIntentUnfinished() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored history", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved owner edits", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-receipt-write-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("ledger.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: archive)
        let queues = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(), unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepAnchoredHistory, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: queues, checkedBy: migrator
        )
        _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        _ = try await store.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { queues }
        )
        let before = try Data(contentsOf: archive)
        var failedIO = NoteLocalDivergenceEvidenceFileIO.live
        failedIO.writeData = { _, _ in
            throw NSError(domain: "MYR238.receiptWriteFailure", code: 1)
        }
        let failing = await NoteLocalDivergenceEvidenceStore(
            fileURL: archive, fileIO: failedIO
        )
        do {
            _ = try await failing.finalizePreparedCleanQueueResolution(
                for: snapshot, checkedBy: migrator,
                verifyQueueOwnership: {}
            )
            XCTFail("A failed completion receipt cannot release the note")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: archive), before)
        let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: archive)
        let unfinished = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertTrue(unfinished)
        let phase = try await restarted.noteCommitPhase(for: noteID)
        XCTAssertEqual(phase, .noteSaved)
        let repaired = try await restarted.finalizePreparedCleanQueueResolution(
            for: snapshot, checkedBy: migrator,
            verifyQueueOwnership: {}
        )
        XCTAssertTrue(repaired)
        let complete = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertFalse(complete)
    }

    func testMYR238PreparedResolutionUsesFullArchiveIndexNotFilteredNoteIndex() async throws {
        let container = try makeContainer()
        let firstID = try insertNote(body: "First anchored history", in: container)
        let selectedID = try insertNote(body: "Selected anchored history", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: firstID, body: "First saved body", in: container)
        try updateNote(noteID: selectedID, body: "Selected saved body", in: container)
        let firstCaptured = try await migrator.validatedDivergenceSnapshot(noteID: firstID)
        let selectedCaptured = try await migrator.validatedDivergenceSnapshot(noteID: selectedID)
        let first = try XCTUnwrap(firstCaptured)
        let selected = try XCTUnwrap(selectedCaptured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-choice-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        _ = try await store.preserve(first, checkedBy: migrator)
        _ = try await store.preserve(selected, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: selected, choice: .keepAnchoredHistory, checkedBy: migrator
        )
        let recovered = try await store.snapshotForPreparedResolution(noteID: selectedID)
        XCTAssertEqual(recovered, selected)
        let other = try await store.snapshotForPreparedResolution(noteID: firstID)
        XCTAssertNil(other, "Other archived notes must not borrow this choice")
    }

    func testMYR238OwnerNoteCommitRejectsStaleQueuesBeforeWritingJournal() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-stale-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: archive.appendingPathComponent("ledger.json")
        )
        let queued = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(pendingChanges: []),
            unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: queued, checkedBy: migrator
        )
        _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        let oldBytes = try Data(contentsOf: archive.appendingPathComponent("ledger.json"))
        do {
            _ = try await store.commitPreparedNote(
                for: snapshot, checkedBy: migrator,
                recaptureQueueOwnership: {
                    NoteLocalDivergenceQueueOwnershipEvidence(
                        legacy: SyncQueueSnapshot(
                            pendingChanges: [], pendingAcknowledgementIDs: [UUID()]
                        ),
                        unsent: [], incoming: [], localObligations: []
                    )
                }
            )
            XCTFail("Never mutate a note after pending queue ownership changes")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .conflictingQueueOwnership)
        }
        let phase = try await store.noteCommitPhase(for: noteID)
        XCTAssertNil(phase)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("ledger.json")), oldBytes)
        XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                       snapshot.sequencePayloadData)
    }

    func testMYR238FailedSaveCanRestartFromDurableNoteCommitIntent() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-failed-commit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: archive.appendingPathComponent("ledger.json")
        )
        let ownership = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(pendingChanges: []),
            unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: ownership, checkedBy: migrator
        )
        _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        let failingMigrator = await makeMigrator(
            container, allowsExistingStateReplacement: false,
            saveOperation: { _ in throw NSError(domain: "MYR238.injectedSaveFailure", code: 1) }
        )
        do {
            _ = try await store.commitPreparedNote(
                for: snapshot, checkedBy: failingMigrator,
                recaptureQueueOwnership: { ownership }
            )
            XCTFail("SwiftData save failure must be surfaced")
        } catch {}
        let pendingPhase = try await store.noteCommitPhase(for: noteID)
        XCTAssertEqual(pendingPhase, .started)
        XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                       snapshot.sequencePayloadData)
        let notesBeforeRetry = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notesBeforeRetry.first { $0.id == noteID }?.content, snapshot.savedBody)

        let restarted = await NoteLocalDivergenceEvidenceStore(
            fileURL: archive.appendingPathComponent("ledger.json")
        )
        let changed = try await restarted.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { ownership }
        )
        XCTAssertTrue(changed)
        let finalPhase = try await restarted.noteCommitPhase(for: noteID)
        XCTAssertEqual(finalPhase, .noteSaved)
        let stillBlocked = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertTrue(stillBlocked)
    }

    func testMYR238CrashAfterNoteSaveBeforeReceiptRecoversWithoutRewriting() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-crash-after-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        let store = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let ownership = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(pendingChanges: []),
            unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepSavedBody, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: ownership, checkedBy: migrator
        )
        let prepared = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        var failedReceiptIO = NoteLocalDivergenceEvidenceFileIO.live
        failedReceiptIO.writeData = { bytes, url in
            if bytes.range(of: Data(#""noteSaved""#.utf8)) != nil {
                throw NSError(domain: "MYR238.injectedReceiptFailure", code: 1)
            }
            try bytes.write(to: url, options: [.atomic])
        }
        let interruptedStore = await NoteLocalDivergenceEvidenceStore(
            fileURL: url, fileIO: failedReceiptIO
        )
        do {
            _ = try await interruptedStore.commitPreparedNote(
                for: snapshot, checkedBy: migrator,
                recaptureQueueOwnership: { ownership }
            )
            XCTFail("Receipt failure must not be reported as a finished resolution")
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            XCTAssertEqual(error, .persistenceFailed)
        }
        let pendingPhase = try await store.noteCommitPhase(for: noteID)
        XCTAssertEqual(pendingPhase, .started)
        let committedBytes = try XCTUnwrap(fetchRecords(in: container).first).statePayloadData
        XCTAssertEqual(committedBytes, prepared.finalSequencePayloadData)

        let restarted = await NoteLocalDivergenceEvidenceStore(fileURL: url)
        let replayed = try await restarted.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { ownership }
        )
        XCTAssertFalse(replayed, "The previously committed note must not be staged again")
        let savedPhase = try await restarted.noteCommitPhase(for: noteID)
        XCTAssertEqual(savedPhase, .noteSaved)
        XCTAssertEqual(try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
                       committedBytes)
        let stillUnfinished = try await restarted.hasUnfinishedResolutionIntents()
        XCTAssertTrue(stillUnfinished)
    }

    func testMYR238StartupSkipsNotesWithIncompleteResolutionEvenAfterBodiesMatch() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Anchored history", in: container)
        let otherID = try insertNote(body: "Healthy", in: container)
        let migrator = await makeMigrator(container, allowsExistingStateReplacement: false)
        try await migrator.runToCompletion()

        // Older valid empty-mark rows need migration when healthy, but must
        // remain byte-for-byte untouched once owner resolution is in progress.
        let context = ModelContext(container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
            .first { $0.noteID == noteID })
        record.markFormatVersion = 0
        record.markRevision = 0
        record.markStatePayloadData = Data()
        try context.save()
        try updateNote(noteID: noteID, body: "Owner's saved text", in: container)
        let captured = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        let snapshot = try XCTUnwrap(captured)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR238-boot-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = await NoteLocalDivergenceEvidenceStore(
            fileURL: directory.appendingPathComponent("ledger.json")
        )
        let ownership = NoteLocalDivergenceQueueOwnershipEvidence(
            legacy: SyncQueueSnapshot(pendingChanges: []),
            unsent: [], incoming: [], localObligations: []
        )
        _ = try await store.preserve(snapshot, checkedBy: migrator)
        _ = try await store.prepareOwnerSelectedResolution(
            snapshot: snapshot, choice: .keepAnchoredHistory, checkedBy: migrator
        )
        _ = try await store.prepareQueueOwnership(
            for: snapshot, ownership: ownership, checkedBy: migrator
        )
        _ = try await store.prepareCommit(for: snapshot, checkedBy: migrator)
        _ = try await store.commitPreparedNote(
            for: snapshot, checkedBy: migrator,
            recaptureQueueOwnership: { ownership }
        )

        let protectedIDs = try await store.unfinishedResolutionNoteIDs()
        XCTAssertEqual(protectedIDs, Set([noteID]))
        let before = try XCTUnwrap(fetchRecords(in: container).first { $0.noteID == noteID })
        XCTAssertEqual(before.markFormatVersion, 0)
        XCTAssertEqual(before.markStatePayloadData, Data())
        let migrated = try await makeMigrator(
            container, allowsExistingStateReplacement: false
        ).runPreservingDivergentStates(protectedNoteIDs: protectedIDs)
        XCTAssertEqual(migrated, Set([noteID]))
        let after = try XCTUnwrap(fetchRecords(in: container).first { $0.noteID == noteID })
        XCTAssertEqual(after.statePayloadData, before.statePayloadData)
        XCTAssertEqual(after.markFormatVersion, 0)
        XCTAssertEqual(after.markStatePayloadData, Data())
        let notes = try ModelContext(container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.first { $0.id == noteID }?.content, "Anchored history")
        XCTAssertEqual(notes.first { $0.id == otherID }?.content, "Healthy")
        let stillPending = try await store.hasUnfinishedResolutionIntents()
        XCTAssertTrue(stillPending)
    }

    func testMYR238InvalidMarkCannotBeQuarantinedAsTextDivergence() async throws {
        for invalidMark in ["malformed", "unsupported", "inconsistentLegacy"] {
            let container = try makeContainer()
            let noteID = try insertNote(body: "Sequence body", in: container)
            let migrator = await makeMigrator(
                container, allowsExistingStateReplacement: false
            )
            try await migrator.runToCompletion()
            try updateNote(noteID: noteID, body: "Saved divergent body", in: container)
            let context = ModelContext(container)
            let record = try XCTUnwrap(
                context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
            )
            let sequenceBytes = record.statePayloadData
            let errorExpected: NoteSequenceStateStoreError
            switch invalidMark {
            case "malformed":
                record.markStatePayloadData = Data("invalid".utf8)
                errorExpected = .corruptMarkState
            case "unsupported":
                record.markFormatVersion = 99
                errorExpected = .unsupportedMarkVersion(99)
            default:
                record.markFormatVersion = 0
                record.markRevision = 1
                record.markStatePayloadData = Data()
                errorExpected = .corruptMarkState
            }
            try context.save()
            let markBytes = record.markStatePayloadData
            do {
                _ = try await migrator.runPreservingDivergentStates()
                XCTFail("Malformed structural marks must not enter text divergence quarantine")
            } catch let error as NoteSequenceStateStoreError {
                XCTAssertEqual(error, errorExpected)
            }
            let retained = try XCTUnwrap(fetchRecords(in: container).first)
            XCTAssertEqual(retained.statePayloadData, sequenceBytes)
            XCTAssertEqual(retained.markStatePayloadData, markBytes)
            let notes = try ModelContext(container).fetch(FetchDescriptor<Note>())
            XCTAssertEqual(
                notes.first { $0.id == noteID }?.content,
                "Saved divergent body"
            )
        }
    }

    func testMYR238ValidLegacyEmptyMarksCanBePreservedAsDivergence() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Sequence body", in: container)
        let migrator = await makeMigrator(
            container, allowsExistingStateReplacement: false
        )
        try await migrator.runToCompletion()
        try updateNote(noteID: noteID, body: "Saved divergent body", in: container)
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        record.markFormatVersion = 0
        record.markRevision = 0
        record.markStatePayloadData = Data()
        try context.save()

        let divergentIDs = try await migrator.runPreservingDivergentStates()
        XCTAssertEqual(divergentIDs, Set([noteID]))
        let evidence = try await migrator.validatedDivergenceSnapshot(noteID: noteID)
        XCTAssertEqual(evidence?.markFormatVersion, 0)
        XCTAssertEqual(evidence?.markRevision, 0)
        XCTAssertEqual(evidence?.markStatePayloadData, Data())
        XCTAssertEqual(evidence?.savedBody, "Saved divergent body")
    }

    func testMYR238MalformedSequenceCannotBeQuarantinedAsTextDivergence() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Authoritative body", in: container)
        try await makeMigrator(
            container, allowsExistingStateReplacement: false
        ).runToCompletion()
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        record.statePayloadData = Data("corrupt".utf8)
        record.payloadByteCount = record.statePayloadData.count
        try context.save()
        let malformedPayload = record.statePayloadData

        do {
            _ = try await makeMigrator(
                container, allowsExistingStateReplacement: false
            ).runPreservingDivergentStates()
            XCTFail("Malformed sequence must not be mistaken for a safe divergence")
        } catch let error as NoteSequenceStateStoreError {
            XCTAssertEqual(error, .corruptState)
        }

        XCTAssertEqual(
            try XCTUnwrap(fetchRecords(in: container).first).statePayloadData,
            malformedPayload
        )
        let requestedID = noteID
        XCTAssertEqual(
            try XCTUnwrap(ModelContext(container).fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedID })
            ).first).content,
            "Authoritative body"
        )
    }

    func testMigrationStopsAtCorruptRowWithoutOverwritingIt() async throws {
        try await assertMigrationStopsWithoutOverwriting { record in
            record.statePayloadData = Data("corrupt".utf8)
            record.payloadByteCount = record.statePayloadData.count
        }
    }

    func testMigrationStopsAtUnsupportedRowWithoutOverwritingIt() async throws {
        try await assertMigrationStopsWithoutOverwriting { $0.formatVersion = 2 }
    }

    func testMigrationPersistsEarlierNotesBeforeInjectedInterruption() async throws {
        let container = try makeContainer()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try insertNote(noteID: first, body: "First", in: container)
        _ = try insertNote(noteID: second, body: "Second", in: container)

        do {
            try await makeMigrator(container) { id in
                if id == second {
                    throw MigratorTestFailure.interrupted
                }
            }.runToCompletion()
            XCTFail("Expected interruption")
        } catch MigratorTestFailure.interrupted {
        }

        XCTAssertEqual(try fetchRecords(in: container).map(\.noteID), [first])
    }

    func testMigrationResumesRemainingNotesAfterInterruption() async throws {
        let container = try makeContainer()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        _ = try insertNote(noteID: first, body: "First", in: container)
        _ = try insertNote(noteID: second, body: "Second", in: container)

        do {
            try await makeMigrator(container) { id in
                if id == second {
                    throw MigratorTestFailure.interrupted
                }
            }.runToCompletion()
        } catch MigratorTestFailure.interrupted {
        }
        try await makeMigrator(container).runToCompletion()

        let records = try fetchRecords(in: container)
        XCTAssertEqual(Set(records.map(\.noteID)), Set([first, second]))
        XCTAssertTrue(records.allSatisfy { $0.revision == 0 })
    }

    func testLegacyFormattingMigrationPromotesSupportedMarksInReplacementModeAndIsIdempotent() async throws {
        let container = try makeContainer()
        let legacyData = Data("legacy-rtf".utf8)
        let rebuiltCache = Data("canonical-cache".utf8)
        let noteID = try insertNote(
            body: "AB",
            legacyRichTextData: legacyData,
            in: container
        )
        let reserver = MigratorOperationIDReserver()

        let migrator = await makeMigrator(
            container,
            allowsExistingStateReplacement: true,
            operationIDReserver: reserver,
            legacyFormattingProjection: { _, body in
                fullProjection(
                    body: body,
                    bold: .enabled
                )
            },
            renderDerivedFormattingCache: { _, _ in rebuiltCache }
        )
        try await migrator.runToCompletion()

        let first = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(
            first.markFormatVersion,
            NoteStructuralFormattingPersistence.schemaVersion
        )
        XCTAssertEqual(first.markRevision, 1)
        let firstPayload = first.markStatePayloadData
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: first,
                noteID: noteID
            )
        let marks = try NoteStructuralFormattingPersistence.decode(
            record: first,
            pairedWith: sequence
        )
        let projection = try marks.visibleProjection(in: sequence)
        XCTAssertEqual(projection.count, 1)
        XCTAssertEqual(projection[0].assignments[.bold], .enabled)

        let verificationContext = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            verificationContext.fetch(
                FetchDescriptor<Note>(
                    predicate: #Predicate { $0.id == requestedID }
                )
            ).first
        )
        XCTAssertEqual(note.content, "AB")
        XCTAssertEqual(note.richTextContentData, rebuiltCache)

        try await migrator.runToCompletion()

        let rerun = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(rerun.markRevision, 1)
        XCTAssertEqual(rerun.markStatePayloadData, firstPayload)
        let reservationCount1 = await reserver.reservationCount
        XCTAssertEqual(reservationCount1, 1)
    }

    func testLegacyFormattingMigrationMismatchCreatesEmptyMarksWithoutChangingBody() async throws {
        let container = try makeContainer()
        let legacyData = Data("mismatched-rtf".utf8)
        let rebuiltCache = Data("empty-cache".utf8)
        let noteID = try insertNote(
            body: "Authoritative",
            legacyRichTextData: legacyData,
            in: container
        )

        try await makeMigrator(
            container,
            operationIDReserver: MigratorOperationIDReserver(),
            legacyFormattingProjection: { _, _ in
                fullProjection(
                    body: "Different",
                    italic: .enabled
                )
            },
            renderDerivedFormattingCache: { _, marks in
                XCTAssertEqual(marks, .empty)
                return rebuiltCache
            }
        ).runToCompletion()

        let record = try XCTUnwrap(fetchRecords(in: container).first)
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: noteID
            )
        XCTAssertEqual(
            try NoteStructuralFormattingPersistence.decode(
                record: record,
                pairedWith: sequence
            ),
            .empty
        )
        let context = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<Note>(
                    predicate: #Predicate { $0.id == requestedID }
                )
            ).first
        )
        XCTAssertEqual(note.content, "Authoritative")
        XCTAssertEqual(note.richTextContentData, rebuiltCache)
    }

    func testLegacyFormattingMigrationSaveFailureLeavesSchemaZeroAndLegacyCacheRetryable() async throws {
        let container = try makeContainer()
        let legacyData = Data("legacy-cache".utf8)
        let noteID = try insertNote(
            body: "AB",
            legacyRichTextData: legacyData,
            in: container
        )

        do {
            try await makeMigrator(
                container,
                operationIDReserver: MigratorOperationIDReserver(),
                legacyFormattingProjection: { _, body in
                    fullProjection(
                        body: body,
                        underline: .enabled
                    )
                },
                renderDerivedFormattingCache: { _, _ in
                    Data("rebuilt".utf8)
                },
                saveOperation: { _ in
                    throw MigratorTestFailure.interrupted
                }
            ).runToCompletion()
            XCTFail("Expected migration persistence failure")
        } catch {
            XCTAssertEqual(
                error as? NoteSequenceStateStoreError,
                .persistenceFailure
            )
        }

        let record = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(record.markFormatVersion, 0)
        XCTAssertEqual(record.markRevision, 0)
        XCTAssertTrue(record.markStatePayloadData.isEmpty)

        let context = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<Note>(
                    predicate: #Predicate { $0.id == requestedID }
                )
            ).first
        )
        XCTAssertEqual(note.content, "AB")
        XCTAssertEqual(note.richTextContentData, legacyData)
    }

    func testMYR238DiskBackedMigrationResumesAfterInterruptionWithoutLosingNotes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-238-Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("MyRAM.store")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000238001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000238002")!

        do {
            let container = try makeDiskContainer(url: storeURL)
            try insertNote(noteID: firstID, body: "First preserved note", in: container)
            try insertNote(noteID: secondID, body: "Second preserved note", in: container)

            do {
                try await makeMigrator(container) { noteID in
                    if noteID == secondID { throw MigratorTestFailure.interrupted }
                }.runToCompletion()
                XCTFail("Expected migration interruption")
            } catch MigratorTestFailure.interrupted {
                // First note was durably migrated; the second remains pending.
            }
            XCTAssertEqual(Set(try fetchRecords(in: container).map(\.noteID)), [firstID])
        }

        do {
            let reopened = try makeDiskContainer(url: storeURL)
            let originalNotes = try ModelContext(reopened).fetch(FetchDescriptor<Note>())
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: originalNotes.map { ($0.id, $0.content) }),
                [firstID: "First preserved note", secondID: "Second preserved note"]
            )
            XCTAssertEqual(Set(try fetchRecords(in: reopened).map(\.noteID)), [firstID])

            try await makeMigrator(reopened).runToCompletion()
            XCTAssertEqual(Set(try fetchRecords(in: reopened).map(\.noteID)), [firstID, secondID])
        }

        let afterSecondRestart = try makeDiskContainer(url: storeURL)
        try await makeMigrator(afterSecondRestart).runToCompletion()
        XCTAssertEqual(Set(try fetchRecords(in: afterSecondRestart).map(\.noteID)), [firstID, secondID])
        let preservedNotes = try ModelContext(afterSecondRestart).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: preservedNotes.map { ($0.id, $0.content) }),
            [firstID: "First preserved note", secondID: "Second preserved note"]
        )
    }

    func testMYR238DiskBackedCorruptMarkStateFailsClosedAcrossRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-238-Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("MyRAM.store")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000238011")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000238012")!
        let malformedMarks = Data([0xff, 0x00, 0x80])
        let preservedFirstPayload: Data

        do {
            let container = try makeDiskContainer(url: storeURL)
            try insertNote(noteID: firstID, body: "Untouched note", in: container)
            try insertNote(noteID: secondID, body: "Keep this note", in: container)
            try await makeMigrator(container).runToCompletion()

            let context = ModelContext(container)
            let records = try context.fetch(FetchDescriptor<NoteSequenceStateRecord>())
            let firstRecord = try XCTUnwrap(records.first { $0.noteID == firstID })
            let secondRecord = try XCTUnwrap(records.first { $0.noteID == secondID })
            preservedFirstPayload = firstRecord.statePayloadData
            secondRecord.markFormatVersion = NoteStructuralFormattingPersistence.schemaVersion
            secondRecord.markStatePayloadData = malformedMarks
            try context.save()
        }

        for _ in 0..<2 {
            let reopened = try makeDiskContainer(url: storeURL)
            do {
                try await makeMigrator(reopened).runToCompletion()
                XCTFail("A malformed formatting record must not be silently rewritten")
            } catch {
                XCTAssertEqual(error as? NoteSequenceStateStoreError, .corruptMarkState)
            }

            let notes = try ModelContext(reopened).fetch(FetchDescriptor<Note>())
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.content) }),
                [firstID: "Untouched note", secondID: "Keep this note"]
            )
            let records = try fetchRecords(in: reopened)
            XCTAssertEqual(Set(records.map(\.noteID)), [firstID, secondID])
            XCTAssertEqual(records.first { $0.noteID == firstID }?.statePayloadData,
                           preservedFirstPayload)
            XCTAssertEqual(records.first { $0.noteID == secondID }?.markStatePayloadData,
                           malformedMarks)
        }
    }

    private func makeDiskContainer(url: URL) throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-238-Migration-Restart",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-170-Migration-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeMigrator(
        _ container: ModelContainer,
        allowsExistingStateReplacement: Bool = !SyncBatchAnchoredPayloadCapability.isEnabled,
        operationIDReserver: any SyncOperationIDReserving = MigratorOperationIDReserver(),
        legacyFormattingProjection: @escaping NoteLegacyFormattingProjectionOperation = { _, _ in nil },
        renderDerivedFormattingCache: @escaping NoteStructuralFormattingCacheRenderOperation = { _, _ in nil },
        saveOperation: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) async -> NoteSequenceStateBootstrapMigrator {
        await NoteSequenceStateBootstrapMigrator(
            container: container,
            allowsExistingStateReplacement: allowsExistingStateReplacement,
            operationIDReserver: operationIDReserver,
            legacyFormattingProjection: legacyFormattingProjection,
            renderDerivedFormattingCache: renderDerivedFormattingCache,
            saveOperation: saveOperation,
            beforeEachNote: beforeEachNote
        )
    }

    @discardableResult
    private func insertNote(
        noteID: UUID = UUID(),
        body: String,
        deleted: Bool = false,
        legacyRichTextData: Data? = nil,
        in container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        let note = Note(content: body)
        note.id = noteID
        note.deletedAt = deleted ? .now : nil
        note.richTextContentData = legacyRichTextData
        context.insert(note)
        try context.save()
        return noteID
    }

    private func updateNote(
        noteID: UUID,
        body: String,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let requestedID = noteID
        let note = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedID })
            ).first
        )
        note.content = body
        try context.save()
    }

    private func fetchRecords(
        in container: ModelContainer
    ) throws -> [NoteSequenceStateRecord] {
        try ModelContext(container).fetch(
            FetchDescriptor<NoteSequenceStateRecord>(
                sortBy: [SortDescriptor(\.noteID)]
            )
        )
    }

    private func assertMigrationStopsWithoutOverwriting(
        mutation: (NoteSequenceStateRecord) -> Void
    ) async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        try await makeMigrator(container).runToCompletion()
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).first
        )
        mutation(record)
        try context.save()
        let originalPayload = record.statePayloadData
        let originalVersion = record.formatVersion

        do {
            try await makeMigrator(container).runToCompletion()
            XCTFail("Expected migration to stop")
        } catch {
        }

        let persisted = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(persisted.noteID, noteID)
        XCTAssertEqual(persisted.statePayloadData, originalPayload)
        XCTAssertEqual(persisted.formatVersion, originalVersion)
    }
}

private actor MigratorOperationIDReserver: SyncOperationIDReserving {
    private var nextCounter: UInt64 = 1
    private(set) var reservationCount = 0

    func reserveOperationID() async throws -> SyncOperationID {
        defer {
            nextCounter += 1
            reservationCount += 1
        }
        return SyncOperationID(
            deviceID: UUID(
                uuidString: "00000000-0000-0000-0000-000000002227"
            )!,
            localCounter: nextCounter
        )
    }
}

private func fullProjection(
    body: String,
    bold: SyncTextMarkAssignment = .clear,
    italic: SyncTextMarkAssignment = .clear,
    underline: SyncTextMarkAssignment = .clear,
    strikethrough: SyncTextMarkAssignment = .clear,
    fontSize: SyncTextMarkAssignment = .clear,
    textColor: SyncTextMarkAssignment = .clear
) -> NoteStructuralFormattingProjection {
    guard !body.isEmpty else {
        return NoteStructuralFormattingProjection(
            plainText: body,
            runs: []
        )
    }
    return NoteStructuralFormattingProjection(
        plainText: body,
        runs: [
            NoteStructuralFormattingProjectionRun(
                startUTF16Offset: 0,
                utf16Length: body.utf16.count,
                assignments: [
                    .bold: bold,
                    .italic: italic,
                    .underline: underline,
                    .strikethrough: strikethrough,
                    .fontSize: fontSize,
                    .textColor: textColor
                ]
            )
        ]
    )
}

@MainActor
final class MYR221BootstrapOwnershipMonotonicityTests: XCTestCase {
    func testRepeatedBootstrapDoesNotRecreateOwnershipAfterFullIncorporation() throws {
        try assertRepeatedBootstrapDoesNotRecreateOwnership(after: .fullIncorporation)
    }

    func testRepeatedBootstrapDoesNotRecreateOwnershipAfterTombstone() throws {
        try assertRepeatedBootstrapDoesNotRecreateOwnership(after: .tombstone)
    }

    private func assertRepeatedBootstrapDoesNotRecreateOwnership(
        after durableProof: DurableProof
    ) throws {
        let source = try makeContainer()
        let sourceContext = ModelContext(source)
        sourceContext.autosaveEnabled = false
        let note = Note(title: "Peer title", content: "AB")
        sourceContext.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: sourceContext
        )
        try sourceContext.save()

        let mutationSnapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: sourceContext
        )
        guard case .noteBodyTextInsertedAnchored(let insertion) = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: note.id,
            utf16Offset: 1,
            text: "S",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 221),
            baseContentHash: nil,
            operationID: SyncOperationID(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000221001")!,
                localCounter: 1
            ),
            state: mutationSnapshot.state
        ) else {
            return XCTFail("Expected anchored insertion")
        }
        let peerState = try mutationSnapshot.state.incorporating(
            insert: insertion.payload,
            insertedText: insertion.text
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: mutationSnapshot,
            newBody: peerState.visibleText,
            finalState: peerState,
            in: sourceContext
        )
        try sourceContext.save()

        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000221002")!
        let originDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000221003")!
        let batch = SyncBatch(
            id: batchID,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 222),
            changes: [
                .noteBodyTextInsertedAnchored(insertion),
                .noteTitleChanged(
                    SyncBatchNoteTitleChangedChange(
                        noteID: note.id,
                        title: "Peer title",
                        modifiedAt: Date(timeIntervalSinceReferenceDate: 223)
                    )
                )
            ]
        )
        let baseSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: sourceContext)
        let staleSnapshot = baseSnapshot.attachingHistoryCoverage(for: [batch])

        let destination = try makeContainer()
        let destinationContext = ModelContext(destination)
        destinationContext.autosaveEnabled = false
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            baseSnapshot,
            to: destinationContext
        )
        let requestedNoteID = note.id
        let destinationNote = try XCTUnwrap(
            destinationContext.fetch(
                FetchDescriptor<Note>(predicate: #Predicate { $0.id == requestedNoteID })
            ).first
        )
        destinationNote.title = "Local title"
        try destinationContext.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-221-stale-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("anchored-recovery.json")
        )
        let firstApply = try SyncPeerBootstrapSnapshotPersistence.apply(
            staleSnapshot,
            to: destinationContext,
            anchoredRecoveryStore: recoveryStore
        )
        XCTAssertFalse(firstApply.coveredBatchIDs.contains(batchID))

        let recoveryChange = SyncBatchAnchoredRecoveryChange.insertion(insertion)
        let owned = try XCTUnwrap(
            recoveryStore.snapshot().record(for: recoveryChange.recordKey)
        )
        XCTAssertEqual(owned.lifecycle, .bootstrapOwned)
        XCTAssertTrue(try recoveryStore.apply([.removeCommitted(expected: owned)]))
        XCTAssertNil(recoveryStore.snapshot().record(for: recoveryChange.recordKey))

        let committedAt = Date(timeIntervalSinceReferenceDate: 224)
        switch durableProof {
        case .fullIncorporation:
            destinationContext.insert(IncorporatedSyncBatch(
                batchID: batchID,
                originDeviceID: originDeviceID,
                createdAt: batch.createdAt,
                batchSequence: batch.batchSequence,
                schemaVersion: 1,
                committedAt: committedAt,
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1,
                affectedNotesPayloadData: Data(),
                authoritativeChildCount: 0,
                authoritativeChildBytes: 0,
                authoritativeChildrenDigest: String(repeating: "c", count: 64),
                postCommitStatePayloadData: Data(),
                hasPendingPostCommitWork: false
            ))
        case .tombstone:
            destinationContext.insert(try IncorporatedBatchTombstone.makeValidated(
                batchID: batchID,
                originDeviceID: originDeviceID,
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                schemaVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1,
                committedAtOrderingPayloadData: try CommittedAtOrderingPayload(
                    batchID: batchID,
                    committedAt: committedAt
                ).encodedEvidenceData()
            ))
        }
        try destinationContext.save()

        _ = try SyncPeerBootstrapSnapshotPersistence.apply(
            staleSnapshot,
            to: destinationContext,
            anchoredRecoveryStore: recoveryStore
        )

        XCTAssertNil(
            recoveryStore.snapshot().record(for: recoveryChange.recordKey),
            "A stale bootstrap retry must not recreate ownership after durable incorporation."
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-221-BootstrapOwnership-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private enum DurableProof {
        case fullIncorporation
        case tombstone
    }
}

@MainActor
final class MYR222DisconnectedConcurrentEditTests: XCTestCase {
    func testMergeableDisconnectedEditsRemainStructuralThroughBootstrapReplayAndAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-mergeable-union-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000101")!
        let lhs = try await makeMergeableReplica(
            noteID: noteID,
            editedBody: "AxB",
            deviceID: UUID(uuidString: "22200000-0000-0000-0000-000000000102")!,
            batchID: UUID(uuidString: "22200000-0000-0000-0000-000000000103")!,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2_221)
        )
        let rhs = try await makeMergeableReplica(
            noteID: noteID,
            editedBody: "ABy",
            deviceID: UUID(uuidString: "22200000-0000-0000-0000-000000000104")!,
            batchID: UUID(uuidString: "22200000-0000-0000-0000-000000000105")!,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2_222)
        )

        XCTAssertEqual(lhs.baselineState, rhs.baselineState)
        XCTAssertEqual(lhs.note.content, lhs.editedState.visibleText)
        XCTAssertEqual(rhs.note.content, rhs.editedState.visibleText)
        XCTAssertTrue(lhs.editedState.runs.contains { $0.operationID == lhs.operationID })
        XCTAssertFalse(lhs.editedState.runs.contains { $0.operationID == rhs.operationID })
        XCTAssertTrue(rhs.editedState.runs.contains { $0.operationID == rhs.operationID })
        XCTAssertFalse(rhs.editedState.runs.contains { $0.operationID == lhs.operationID })
        XCTAssertNotEqual(lhs.operationID, rhs.operationID)
        XCTAssertTrue(Set(lhs.baselineState.runs.map(\.operationID)).isSubset(of: Set(lhs.editedState.runs.map(\.operationID))))
        XCTAssertTrue(Set(rhs.baselineState.runs.map(\.operationID)).isSubset(of: Set(rhs.editedState.runs.map(\.operationID))))

        let expected = try lhs.editedState.mergingRetainedLineage(with: rhs.editedState)
        XCTAssertEqual(expected, try rhs.editedState.mergingRetainedLineage(with: lhs.editedState))

        let lhsQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: directory.appendingPathComponent("lhs-local.json")
        )
        let rhsQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: directory.appendingPathComponent("rhs-local.json")
        )
        try lhsQueue.enqueue(lhs.obligation)
        try rhsQueue.enqueue(rhs.obligation)
        XCTAssertEqual(lhsQueue.pendingBatches.map(\.id), [lhs.obligation.batch.id])
        XCTAssertEqual(rhsQueue.pendingBatches.map(\.id), [rhs.obligation.batch.id])

        let lhsSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: lhs.context)
            .attachingHistoryCoverage(for: [lhs.obligation.batch])
        let rhsSnapshot = try SyncPeerBootstrapSnapshotPersistence.build(from: rhs.context)
            .attachingHistoryCoverage(for: [rhs.obligation.batch])
        let lhsRecovery = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("lhs-recovery.json")
        )
        let rhsRecovery = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("rhs-recovery.json")
        )

        let lhsBootstrap = try SyncPeerBootstrapSnapshotPersistence.apply(
            rhsSnapshot,
            to: lhs.context,
            anchoredRecoveryStore: lhsRecovery
        )
        let rhsBootstrap = try SyncPeerBootstrapSnapshotPersistence.apply(
            lhsSnapshot,
            to: rhs.context,
            anchoredRecoveryStore: rhsRecovery
        )
        XCTAssertTrue(lhsBootstrap.coveredNoteIDs.contains(noteID))
        XCTAssertTrue(rhsBootstrap.coveredNoteIDs.contains(noteID))
        try assertReplica(lhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])
        try assertReplica(rhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])

        let lhsTransport = MYR222AcceptingBatchTransport()
        let rhsTransport = MYR222AcceptingBatchTransport()
        let lhsIncoming = FileBackedSyncBatchQueue(fileURL: directory.appendingPathComponent("lhs-incoming.json"))
        let rhsIncoming = FileBackedSyncBatchQueue(fileURL: directory.appendingPathComponent("rhs-incoming.json"))
        let lhsRuntime = makeRuntime(
            for: lhs,
            incomingQueue: lhsIncoming,
            localQueue: lhsQueue,
            transport: lhsTransport,
            recoveryStore: lhsRecovery,
            conflictURL: directory.appendingPathComponent("lhs-conflicts.json")
        )
        let rhsRuntime = makeRuntime(
            for: rhs,
            incomingQueue: rhsIncoming,
            localQueue: rhsQueue,
            transport: rhsTransport,
            recoveryStore: rhsRecovery,
            conflictURL: directory.appendingPathComponent("rhs-conflicts.json")
        )

        try assertDrained(await lhsRuntime.resumePendingWork(), expectedBatchIDs: [])
        try assertDrained(await rhsRuntime.resumePendingWork(), expectedBatchIDs: [])
        XCTAssertEqual(lhsTransport.acceptedBatches.map(\.id), [lhs.obligation.batch.id])
        XCTAssertEqual(rhsTransport.acceptedBatches.map(\.id), [rhs.obligation.batch.id])
        XCTAssertTrue(lhsQueue.pendingBatches.isEmpty)
        XCTAssertTrue(rhsQueue.pendingBatches.isEmpty)

        try assertDrained(
            await lhsRuntime.submitRemoteBatch(rhs.obligation.batch),
            expectedBatchIDs: [rhs.obligation.batch.id]
        )
        try assertDrained(
            await rhsRuntime.submitRemoteBatch(lhs.obligation.batch),
            expectedBatchIDs: [lhs.obligation.batch.id]
        )
        XCTAssertTrue(lhsIncoming.pendingBatches.isEmpty)
        XCTAssertTrue(rhsIncoming.pendingBatches.isEmpty)
        try assertReplica(lhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])
        try assertReplica(rhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])

        _ = try SyncPeerBootstrapSnapshotPersistence.apply(rhsSnapshot, to: lhs.context, anchoredRecoveryStore: lhsRecovery)
        _ = try SyncPeerBootstrapSnapshotPersistence.apply(lhsSnapshot, to: rhs.context, anchoredRecoveryStore: rhsRecovery)
        try assertDrained(
            await lhsRuntime.submitRemoteBatch(rhs.obligation.batch),
            expectedBatchIDs: [rhs.obligation.batch.id]
        )
        try assertDrained(
            await rhsRuntime.submitRemoteBatch(lhs.obligation.batch),
            expectedBatchIDs: [lhs.obligation.batch.id]
        )
        try assertReplica(lhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])
        try assertReplica(rhs, equals: expected, operationIDs: [lhs.operationID, rhs.operationID])
    }

#if os(macOS)
    func testReconnectBootstrapIncludesDurablePendingLocalObligationHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-222-failure-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeDisconnectedEditFixture()
        let localQueueURL = directory.appendingPathComponent("local-obligations.json")
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localQueueURL)
        try localQueue.enqueue(fixture.obligation)
        XCTAssertEqual(localQueue.pendingBatches.map(\.id), [fixture.obligation.batch.id])

        let conflictStore = SyncConflictStore(
            fileURL: directory.appendingPathComponent("conflicts.json")
        )
        let remotePeer = MCPeerID(displayName: "remote|myr222-peer")
        var sentMessages: [Data] = []
        let controller = MacSyncBatchController(
            context: fixture.context,
            conflictStore: conflictStore,
            unsentBatchQueueFileURL: nil,
            unsentBatchQueue: FileBackedSyncBatchQueue(fileURL: nil),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "22200000-0000-0000-0000-000000000010")!,
                    displayName: "MYR222"
                )
            },
            startAdvertisingOperation: {},
            startBrowsingOperation: {},
            connectedPeersProvider: { [remotePeer] },
            sendBatchDataOperation: { data, peers, _ in
                if !peers.isEmpty {
                    sentMessages.append(data)
                }
            }
        )
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: directory.appendingPathComponent("anchored-recovery.json")
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: fixture.context,
            syncController: controller,
            conflictStore: conflictStore,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in fatalError("Not used by bootstrap coverage regression") },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: nil,
            localObligationQueueFileURL: localQueueURL,
            anchoredRecoveryStore: recoveryStore
        )
        _ = coordinator

        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr222-peer"
        )
        await controller.beginReconnectBootstrapForTesting(to: remotePeer)

        let wireData = try XCTUnwrap(sentMessages.first)
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: wireData)
        XCTAssertEqual(message.kind, .bootstrapSnapshot)
        let snapshot = try JSONDecoder().decode(
            SyncPeerBootstrapSnapshot.self,
            from: message.payload
        )

        XCTAssertEqual(
            Set(snapshot.historyCoverage.map(\.batchID)),
            [fixture.obligation.batch.id],
            "Reconnect bootstrap must carry durable local-obligation ownership before ordinary sync can resume."
        )
    }
#else
    func testReconnectBootstrapIncludesDurablePendingLocalObligationHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-ios-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeDisconnectedEditFixture()
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: directory.appendingPathComponent("local-obligations.json")
        )
        try localQueue.enqueue(fixture.obligation)

        let remotePeer = MCPeerID(displayName: "remote|myr233-ios-peer")
        let transport = MYR222BootstrapRecordingTransport(connectedPeers: [remotePeer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: directory.appendingPathComponent("legacy.json"),
            startsNetworking: false,
            transport: transport
        )
        controller.onPrepareLocalOwnershipForBootstrap = {}
        controller.localBootstrapOwnershipSnapshotProvider = {
            localQueue.snapshot()
        }
        controller.removeLocalBootstrapOwnership = { batchIDs in
            try localQueue.removeObligationsForBootstrapAcknowledgement(withIDs: batchIDs)
        }
        controller.buildBootstrapSnapshot = {
            try SyncPeerBootstrapSnapshotPersistence.build(from: fixture.context)
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr233-ios-peer"
        )
        controller.setBootstrapRetryDelayNanosecondsForTesting([1_000_000_000])

        await controller.beginBootstrapForTesting(to: remotePeer)

        XCTAssertEqual(localQueue.pendingCount, 1)
        let snapshot = try XCTUnwrap(transport.sentBootstrapSnapshots.first)
        XCTAssertEqual(
            Set(snapshot.historyCoverage.map(\.batchID)),
            [fixture.obligation.batch.id],
            "iPhone reconnect bootstrap must own durable local obligations directly without transport promotion."
        )
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr233-ios-peer")
    }

    func testReconnectBootstrapRecoversWithFullUnsentQueueAndDurableLocalObligations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-ios-full-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsentURL = directory.appendingPathComponent("unsent-batches.json")
        let localURL = directory.appendingPathComponent("local-obligations.json")
        let unsentQueue = FileBackedSyncBatchQueue(fileURL: unsentURL)
        for index in 0..<100 {
            try unsentQueue.enqueueDurably(makeMYR233Batch(idSuffix: 233_000 + index))
        }
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(fileURL: localURL)
        for index in 0..<36 {
            try localQueue.enqueue(
                SyncConvergenceLocalObligation(
                    legacyBatch: makeMYR233Batch(idSuffix: 234_000 + index)
                )
            )
        }

        let remotePeer = MCPeerID(displayName: "remote|myr233-ios-full")
        let transport = MYR222BootstrapRecordingTransport(connectedPeers: [remotePeer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: unsentURL,
            pendingChangesFileURL: directory.appendingPathComponent("legacy.json"),
            startsNetworking: false,
            transport: transport
        )
        controller.onPrepareLocalOwnershipForBootstrap = {}
        controller.localBootstrapOwnershipSnapshotProvider = {
            localQueue.snapshot()
        }
        controller.removeLocalBootstrapOwnership = { batchIDs in
            try localQueue.removeObligationsForBootstrapAcknowledgement(withIDs: batchIDs)
        }
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr233-ios-full"
        )
        controller.setBootstrapRetryDelayNanosecondsForTesting([1_000_000_000])

        await controller.beginBootstrapForTesting(to: remotePeer)

        XCTAssertEqual(controller.unsentBatchQueueSnapshot().pendingBatches.count, 100)
        XCTAssertEqual(localQueue.pendingCount, 36)
        let snapshot = try XCTUnwrap(transport.sentBootstrapSnapshots.first)
        XCTAssertEqual(snapshot.historyCoverage.count, 136)
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr233-ios-full")
    }

    func testBootstrapLocalCleanupFailureRemainsRetryableOnAckReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-233-ios-local-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let batch = makeMYR233Batch(idSuffix: 235_100)
        let localQueue = FileBackedSyncConvergenceLocalObligationQueue(
            fileURL: directory.appendingPathComponent("local-obligations.json")
        )
        try localQueue.enqueue(SyncConvergenceLocalObligation(legacyBatch: batch))

        let remotePeer = MCPeerID(displayName: "remote|myr233-ios-replay")
        let transport = MYR222BootstrapRecordingTransport(connectedPeers: [remotePeer])
        let controller = MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: directory.appendingPathComponent("legacy.json"),
            startsNetworking: false,
            transport: transport
        )
        controller.onPrepareLocalOwnershipForBootstrap = {}
        controller.localBootstrapOwnershipSnapshotProvider = {
            localQueue.snapshot()
        }
        controller.removeLocalBootstrapOwnership = { batchIDs in
            try localQueue.removeObligationsForBootstrapAcknowledgement(withIDs: batchIDs)
        }
        controller.buildBootstrapSnapshot = {
            SyncPeerBootstrapSnapshot(id: UUID(), folders: [], notes: [])
        }
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "myr233-ios-replay"
        )
        controller.setBootstrapRetryDelayNanosecondsForTesting([1_000_000_000])

        await controller.beginBootstrapForTesting(to: remotePeer)
        let snapshot = try XCTUnwrap(transport.sentBootstrapSnapshots.first)
        localQueue.injectPersistenceFailureForNextWrite()
        let acknowledgement = SyncPeerBootstrapAcknowledgement(
            snapshotID: snapshot.id,
            coveredBatchIDs: [batch.id]
        )

        await controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: remotePeer
        )
        XCTAssertEqual(localQueue.pendingCount, 1)
        XCTAssertFalse(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "myr233-ios-replay"))

        await controller.handleBootstrapAcknowledgementForTesting(
            acknowledgement,
            from: remotePeer
        )
        XCTAssertEqual(localQueue.pendingCount, 0)
        XCTAssertTrue(controller.isOrdinarySyncReadyForTesting(peerDeviceID: "myr233-ios-replay"))
        controller.handlePeerDisconnectForTesting(peerDeviceID: "myr233-ios-replay")
    }
#endif

    private func makeMergeableReplica(
        noteID: UUID,
        editedBody: String,
        deviceID: UUID,
        batchID: UUID,
        modifiedAt: Date
    ) async throws -> MYR222MergeableReplica {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-MergeableReplica-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let note = Note(title: "", content: "AB")
        note.id = noteID
        note.createdAt = Date(timeIntervalSinceReferenceDate: 2_220)
        note.modifiedAt = Date(timeIntervalSinceReferenceDate: 2_220)
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(for: note, in: context)
        try context.save()

        let baseline = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        let capture = try await SyncBatchAnchoredLocalCapture.capture(
            noteID: noteID,
            oldBody: baseline.body,
            newBody: editedBody,
            modifiedAt: modifiedAt,
            initialState: baseline.state,
            operationIDReserver: MYR222OperationIDReserver(deviceID: deviceID, nextCounter: 1)
        )
        let operationIDs = Set(capture.finalState.runs.map(\.operationID))
            .subtracting(baseline.state.runs.map(\.operationID))
        XCTAssertEqual(operationIDs.count, 1)
        let operationID = try XCTUnwrap(operationIDs.first)
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: baseline,
            newBody: capture.finalState.visibleText,
            finalState: capture.finalState,
            in: context
        )
        note.modifiedAt = modifiedAt
        try context.save()
        let persisted = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        XCTAssertEqual(persisted.state, capture.finalState)
        XCTAssertEqual(persisted.body, capture.finalState.visibleText)

        let batch = SyncBatch(
            id: batchID,
            originDeviceID: deviceID,
            createdAt: modifiedAt,
            batchSequence: 1,
            changes: capture.capturedChanges.map(\.change)
        )
        return MYR222MergeableReplica(
            container: container,
            context: context,
            note: note,
            baselineState: baseline.state,
            editedState: persisted.state,
            operationID: operationID,
            obligation: SyncConvergenceLocalObligation(batch: batch, capturedChanges: capture.capturedChanges)
        )
    }

    private func makeRuntime(
        for replica: MYR222MergeableReplica,
        incomingQueue: FileBackedSyncBatchQueue,
        localQueue: FileBackedSyncConvergenceLocalObligationQueue,
        transport: MYR222AcceptingBatchTransport,
        recoveryStore: FileBackedSyncBatchAnchoredRecoveryStore,
        conflictURL: URL
    ) -> SyncConvergenceRuntime {
        SyncConvergenceRuntime(
            context: replica.context,
            convergenceQueue: incomingQueue,
            localObligationQueue: localQueue,
            localBatchTransportAdapter: transport,
            presentationAdapter: MYR222CompletingPresentationAdapter(),
            conflictStore: SyncConflictStore(fileURL: conflictURL),
            anchoredRecoveryStore: recoveryStore
        )
    }

    private func assertReplica(
        _ replica: MYR222MergeableReplica,
        equals expected: SyncTextSequenceState,
        operationIDs: Set<SyncOperationID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let persisted = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: replica.note,
            in: replica.context
        )
        XCTAssertEqual(replica.note.content, expected.visibleText, file: file, line: line)
        XCTAssertEqual(replica.note.content, persisted.state.visibleText, file: file, line: line)
        XCTAssertEqual(persisted.state, expected, file: file, line: line)
        XCTAssertTrue(operationIDs.isSubset(of: Set(persisted.state.runs.map(\.operationID))), file: file, line: line)
    }

    private func assertDrained(
        _ outcome: SyncConvergenceRuntimeOutcome,
        expectedBatchIDs: Set<UUID>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .drained(let appliedBatchIDs) = outcome else {
            return XCTFail("Expected convergence to drain, got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(appliedBatchIDs, expectedBatchIDs, file: file, line: line)
    }

    private func makeMYR233Batch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "23300000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "23300000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func makeDisconnectedEditFixture() async throws -> (
        container: ModelContainer,
        context: ModelContext,
        obligation: SyncConvergenceLocalObligation
    ) {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-222-DisconnectedEdit-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        context.autosaveEnabled = false
        let noteID = UUID(uuidString: "22200000-0000-0000-0000-000000000001")!
        let note = Note(title: "", content: "AB")
        note.id = noteID
        context.insert(note)
        _ = try NoteSequenceStateFullBodyIntegration.ensureCurrentBodyState(
            for: note,
            in: context
        )
        try context.save()

        let initial = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        let originDeviceID = UUID(uuidString: "22200000-0000-0000-0000-000000000002")!
        let capture = try await SyncBatchAnchoredLocalCapture.capture(
            noteID: noteID,
            oldBody: "AB",
            newBody: "AxB",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 222),
            initialState: initial.state,
            operationIDReserver: MYR222OperationIDReserver(
                deviceID: originDeviceID,
                nextCounter: 1
            )
        )
        _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
            of: note,
            expected: initial,
            newBody: capture.finalState.visibleText,
            finalState: capture.finalState,
            in: context
        )
        note.modifiedAt = Date(timeIntervalSinceReferenceDate: 222)
        try context.save()

        let persisted = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(
            for: note,
            in: context
        )
        XCTAssertEqual(note.content, persisted.state.visibleText)
        XCTAssertEqual(note.content, "AxB")

        let batch = SyncBatch(
            id: UUID(uuidString: "22200000-0000-0000-0000-000000000003")!,
            originDeviceID: originDeviceID,
            createdAt: Date(timeIntervalSinceReferenceDate: 222),
            batchSequence: 1,
            changes: capture.capturedChanges.map(\.change)
        )
        return (
            container,
            context,
            SyncConvergenceLocalObligation(
                batch: batch,
                capturedChanges: capture.capturedChanges
            )
        )
    }
}

@MainActor
private struct MYR222MergeableReplica {
    let container: ModelContainer
    let context: ModelContext
    let note: Note
    let baselineState: SyncTextSequenceState
    let editedState: SyncTextSequenceState
    let operationID: SyncOperationID
    let obligation: SyncConvergenceLocalObligation
}

@MainActor
private final class MYR222AcceptingBatchTransport: SyncConvergenceLocalBatchTransportAdapter {
    private(set) var acceptedBatches: [SyncBatch] = []

    func acceptLocalBatch(_ batch: SyncBatch) async throws {
        acceptedBatches.append(batch)
    }
}

private struct MYR222CompletingPresentationAdapter: SyncConvergencePresentationAdapter {
    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        .verifiedComplete
    }
}

#if !os(macOS)
private final class MYR222BootstrapRecordingTransport: MyRAMSyncTransporting {
    private let connectedPeerValues: [MCPeerID]
    private(set) var sentBootstrapSnapshots: [SyncPeerBootstrapSnapshot] = []

    init(connectedPeers: [MCPeerID]) {
        connectedPeerValues = connectedPeers
    }

    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        connectedPeerValues
    }

    func hasConnectedPeer(_ peerID: MCPeerID) -> Bool {
        connectedPeerValues.contains(peerID)
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {
        let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
        guard message.kind == .bootstrapSnapshot else { return }
        sentBootstrapSnapshots.append(
            try JSONDecoder().decode(SyncPeerBootstrapSnapshot.self, from: message.payload)
        )
    }
}
#endif

private actor MYR222OperationIDReserver: SyncOperationIDReserving {
    private let deviceID: UUID
    private var nextCounter: UInt64

    init(deviceID: UUID, nextCounter: UInt64) {
        self.deviceID = deviceID
        self.nextCounter = nextCounter
    }

    func reserveOperationID() async throws -> SyncOperationID {
        let operationID = SyncOperationID(deviceID: deviceID, localCounter: nextCounter)
        nextCounter &+= 1
        return operationID
    }
}

private enum MigratorTestFailure: Error {
    case interrupted
}

private final class IDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }
}
