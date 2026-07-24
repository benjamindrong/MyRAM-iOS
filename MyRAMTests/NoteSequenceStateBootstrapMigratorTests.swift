import Foundation
import SwiftData
import XCTest

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

    func testMigrationReestablishesValidStaleRows() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Old", in: container)
        try await makeMigrator(container).runToCompletion()
        try updateNote(noteID: noteID, body: "Current", in: container)

        try await makeMigrator(container).runToCompletion()

        let record = try XCTUnwrap(fetchRecords(in: container).first)
        XCTAssertEqual(record.revision, 1)
        let state = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        XCTAssertEqual(state.visibleText, "Current")
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
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) async -> NoteSequenceStateBootstrapMigrator {
        await NoteSequenceStateBootstrapMigrator(
            container: container,
            beforeEachNote: beforeEachNote
        )
    }

    @discardableResult
    private func insertNote(
        noteID: UUID = UUID(),
        body: String,
        deleted: Bool = false,
        in container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        let note = Note(content: body)
        note.id = noteID
        note.deletedAt = deleted ? .now : nil
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
