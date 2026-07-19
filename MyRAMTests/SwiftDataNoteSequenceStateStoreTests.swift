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
final class SwiftDataNoteSequenceStateStoreTests: XCTestCase {
    func testMissingLoadDoesNotCreateAStateRow() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let result = try await store.load(noteID: noteID)

        XCTAssertEqual(
            result,
            .missing(note: NoteSequenceStateNoteSnapshot(noteID: noteID, body: "Body"))
        )
        XCTAssertEqual(try fetchRecords(in: container).count, 0)
    }

    func testMissingNoteFailsWithoutCreatingState() async throws {
        let container = try makeContainer()
        let noteID = UUID()
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        await assertStoreError(.missingNote(noteID)) {
            _ = try await store.load(noteID: noteID)
        }
        XCTAssertEqual(try fetchRecords(in: container).count, 0)
    }

    func testFirstWriteUsesRevisionZeroAndCanonicalEmptyBytes() async throws {
        let container = try makeContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try insertNote(noteID: noteID, body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: "",
            newState: .empty
        )

        XCTAssertEqual(loaded.revision, 0)
        let record = try XCTUnwrap(fetchRecords(in: container).only)
        XCTAssertEqual(
            record.statePayloadData,
            Data(
                "{\"formatVersion\":1,\"fragments\":[],\"noteID\":\"00000000-0000-0000-0000-000000000001\",\"runs\":[]}"
                    .utf8
            )
        )
        XCTAssertEqual(record.payloadByteCount, record.statePayloadData.count)
    }

    func testRestartLoadsBothOriginsAndAdvancesRevision() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "", in: container)
        let firstStore = await SwiftDataNoteSequenceStateStore(container: container)
        let firstState = try originState()
        _ = try await firstStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: firstState.visibleText,
            newState: firstState
        )

        let restartedStore = await SwiftDataNoteSequenceStateStore(container: container)
        let restarted = try await restartedStore.load(noteID: noteID)
        XCTAssertEqual(
            restarted,
            .present(LoadedNoteSequenceState(
                note: NoteSequenceStateNoteSnapshot(
                    noteID: noteID,
                    body: firstState.visibleText
                ),
                revision: 0,
                state: firstState
            ))
        )

        let nextState = try rootState(text: "Next")
        let advanced = try await restartedStore.compareAndSet(
            noteID: noteID,
            expected: .present(
                expectedRevision: 0,
                expectedBody: firstState.visibleText
            ),
            newBody: "Next",
            newState: nextState
        )
        XCTAssertEqual(advanced.revision, 1)
    }

    func testCompareAndSetChangesOnlyBodyAndSequenceRecord() async throws {
        let container = try makeContainer()
        let noteID = UUID()
        let richText = Data([0x01, 0x02, 0x03])
        let modifiedAt = Date(timeIntervalSinceReferenceDate: 123_456)
        let context = ModelContext(container)
        let note = Note(title: "Title", content: "Before")
        note.id = noteID
        note.richTextContentData = richText
        note.modifiedAt = modifiedAt
        context.insert(note)
        try context.save()
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let state = try rootState(text: "After")
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Before"),
            newBody: "After",
            newState: state
        )
        let freshNote = try XCTUnwrap(fetchNote(noteID: noteID, in: container))
        XCTAssertEqual(freshNote.content, "After")
        XCTAssertEqual(freshNote.title, "Title")
        XCTAssertEqual(freshNote.richTextContentData, richText)
        XCTAssertEqual(freshNote.modifiedAt, modifiedAt)
    }

    func testBodyStateMismatchAndExpectationsFailClosed() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Before", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let state = try rootState(text: "After")

        await assertStoreError(.newStateBodyMismatch) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .missing(expectedBody: "Before"),
                newBody: "Different",
                newState: state
            )
        }
        await assertStoreError(.visibleBodyChanged(expected: "Wrong", actual: "Before")) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .missing(expectedBody: "Wrong"),
                newBody: "After",
                newState: state
            )
        }
        await assertStoreError(.expectedRowButRowIsMissing) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .present(expectedRevision: 0, expectedBody: "Before"),
                newBody: "After",
                newState: state
            )
        }

        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Before"),
            newBody: "After",
            newState: state
        )
        await assertStoreError(.expectedMissingButRowExists) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .missing(expectedBody: "After"),
                newBody: "After",
                newState: state
            )
        }
        await assertStoreError(.staleRevision(expected: 9, actual: 0)) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .present(expectedRevision: 9, expectedBody: "After"),
                newBody: "After",
                newState: state
            )
        }
    }

    func testMaximumRevisionFailsWithoutChangingCommittedState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Before", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let beforeState = try rootState(text: "Before")
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Before"),
            newBody: "Before",
            newState: beforeState
        )
        try updateRecord(in: container) { $0.revision = UInt64.max }

        await assertStoreError(.revisionExhaustion) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .present(
                    expectedRevision: UInt64.max,
                    expectedBody: "Before"
                ),
                newBody: "After",
                newState: try self.rootState(text: "After")
            )
        }

        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Before")
        XCTAssertEqual(try fetchRecords(in: container).only?.revision, UInt64.max)
    }

    func testFailureBeforeSaveRollsBackBodyAndState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Before", in: container)
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                if stage == .beforeSave {
                    throw InjectedFailure.expected
                }
            }
        )

        await assertStoreError(.persistenceFailure) {
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .missing(expectedBody: "Before"),
                newBody: "After",
                newState: try self.rootState(text: "After")
            )
        }

        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Before")
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
    }

    func testLexicalJSONDifferencesLoadWithoutRewriting() async throws {
        let container = try makeContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try insertNote(noteID: noteID, body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: "",
            newState: .empty
        )
        let lexicalPayload = Data(
            "{ \"runs\" : [ ], \"noteID\" : \"00000000-0000-0000-0000-000000000001\", \"fragments\" : [ ], \"formatVersion\" : 1 }"
                .utf8
        )
        try updateRecord(in: container) { record in
            record.statePayloadData = lexicalPayload
            record.payloadByteCount = lexicalPayload.count
        }

        _ = try await store.load(noteID: noteID)

        XCTAssertEqual(try fetchRecords(in: container).only?.statePayloadData, lexicalPayload)
    }

    func testSemanticRunAndFragmentOrderAreRejectedWithoutNormalization() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let state = try siblingRootState()
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: state.visibleText,
            newState: state
        )
        let canonicalPayload = try XCTUnwrap(
            fetchRecords(in: container).only?.statePayloadData
        )

        try mutateJSONPayload(in: container) { object in
            object["runs"] = Array(
                (object["runs"] as! [[String: Any]]).reversed()
            )
        }
        let unsortedBytes = try XCTUnwrap(fetchRecords(in: container).only?.statePayloadData)
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }
        XCTAssertEqual(try fetchRecords(in: container).only?.statePayloadData, unsortedBytes)

        try restorePayload(
            canonicalPayload,
            state: state,
            in: container
        )
        try mutateJSONPayload(in: container) { object in
            object["fragments"] = Array(
                (object["fragments"] as! [[String: Any]]).reversed()
            )
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }
    }

    func testMergeablePersistedFragmentsAreRejected() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let state = try rootState(text: "ab")
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: "ab",
            newState: state
        )

        try mutateJSONPayload(in: container) { object in
            var first = (object["fragments"] as! [[String: Any]])[0]
            first["utf16Length"] = 1
            var second = first
            second["startOffset"] = 1
            object["fragments"] = [first, second]
        }

        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }
    }

    func testMalformedUnsupportedAndMetadataMismatchesAreDistinct() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: "",
            newState: .empty
        )
        let canonicalPayload = try XCTUnwrap(
            fetchRecords(in: container).only?.statePayloadData
        )

        try updateRecord(in: container) { $0.formatVersion = 2 }
        await assertStoreError(.unsupportedVersion(2)) {
            _ = try await store.load(noteID: noteID)
        }

        try restorePayload(
            canonicalPayload,
            state: .empty,
            in: container
        )
        try mutateJSONPayload(in: container) { $0["formatVersion"] = 2 }
        await assertStoreError(.unsupportedVersion(2)) {
            _ = try await store.load(noteID: noteID)
        }

        try updateRecord(in: container) { record in
            record.formatVersion = 1
            record.statePayloadData = Data("not-json".utf8)
            record.payloadByteCount = record.statePayloadData.count
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }

        try restorePayload(
            canonicalPayload,
            state: .empty,
            in: container
        )
        try updateRecord(in: container) { $0.visibleUTF16Count = 1 }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }
    }

    func testPersistedInvalidOriginUUIDAndOverflowRangeAreCorrupt() async throws {
        let container = try makeContainer()
        let noteID = UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!
        try insertNote(noteID: noteID, body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let state = try originState()
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: ""),
            newBody: state.visibleText,
            newState: state
        )
        let canonicalPayload = try XCTUnwrap(
            fetchRecords(in: container).only?.statePayloadData
        )

        try mutateJSONPayload(in: container) { object in
            var runs = object["runs"] as! [[String: Any]]
            var child = runs[1]
            var leftOrigin = child["leftOrigin"] as! [String: Any]
            leftOrigin["elementOffset"] = Int.max
            child["leftOrigin"] = leftOrigin
            runs[1] = child
            object["runs"] = runs
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }

        try restorePayload(canonicalPayload, state: state, in: container)
        try mutateJSONPayload(in: container) { object in
            var fragments = object["fragments"] as! [[String: Any]]
            fragments[0]["startOffset"] = Int.max - 1
            fragments[0]["utf16Length"] = 2
            object["fragments"] = fragments
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }

        try restorePayload(canonicalPayload, state: state, in: container)
        try mutateJSONPayload(in: container) { object in
            var fragments = object["fragments"] as! [[String: Any]]
            fragments[0]["visibility"] = "VISIBLE"
            object["fragments"] = fragments
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }

        try restorePayload(canonicalPayload, state: state, in: container)
        try mutateJSONPayload(in: container) { object in
            object["noteID"] = noteID.uuidString.uppercased()
        }
        await assertStoreError(.corruptState) {
            _ = try await store.load(noteID: noteID)
        }
    }

    func testSeparateStoresCannotBothPassPreflight() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Before", in: container)
        let bootstrapStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await bootstrapStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Before"),
            newBody: "Before",
            newState: rootState(text: "Before")
        )
        let pause = StorePause()
        let secondEntered = DispatchSemaphore(value: 0)
        let storeA = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                if stage == .afterExpectationValidation {
                    pause.block()
                }
            }
        )
        let storeB = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                if stage == .afterExpectationValidation {
                    secondEntered.signal()
                }
            }
        )
        let stateA = try rootState(text: "A")
        let stateB = try rootState(text: "B")

        let writerA = Task.detached(priority: .userInitiated) {
            try await storeA.compareAndSet(
                noteID: noteID,
                expected: .present(expectedRevision: 0, expectedBody: "Before"),
                newBody: "A",
                newState: stateA
            )
        }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 2), .success)

        let writerB = Task.detached(priority: .userInitiated) {
            try await storeB.compareAndSet(
                noteID: noteID,
                expected: .present(expectedRevision: 0, expectedBody: "Before"),
                newBody: "B",
                newState: stateB
            )
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)

        pause.release.signal()
        let writerAResult = try await writerA.value
        XCTAssertEqual(writerAResult.revision, 1)
        do {
            _ = try await writerB.value
            XCTFail("The stale writer should fail")
        } catch {
            XCTAssertEqual(
                error as? NoteSequenceStateStoreError,
                .staleRevision(expected: 0, actual: 1)
            )
        }
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "A")
        XCTAssertEqual(try fetchRecords(in: container).only?.revision, 1)
    }

    func testOnDiskStoreMigratesWithoutCreatingStateRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-169-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("MyRAM.store")
        let noteID = UUID()
        let legacyModels = MyRAMModelRegistry.models.filter {
            ObjectIdentifier($0) != ObjectIdentifier(NoteSequenceStateRecord.self)
        }

        do {
            let legacyContainer = try makeDiskContainer(
                models: legacyModels,
                url: storeURL
            )
            try insertNote(noteID: noteID, body: "Legacy", in: legacyContainer)
        }

        do {
            let migratedContainer = try makeDiskContainer(
                models: MyRAMModelRegistry.models,
                url: storeURL
            )
            XCTAssertEqual(
                try fetchNote(noteID: noteID, in: migratedContainer)?.content,
                "Legacy"
            )
            XCTAssertTrue(try fetchRecords(in: migratedContainer).isEmpty)

            let store = await SwiftDataNoteSequenceStateStore(container: migratedContainer)
            let state = try rootState(text: "Attached")
            _ = try await store.compareAndSet(
                noteID: noteID,
                expected: .missing(expectedBody: "Legacy"),
                newBody: "Attached",
                newState: state
            )
        }

        let reopened = try makeDiskContainer(
            models: MyRAMModelRegistry.models,
            url: storeURL
        )
        let restartedStore = await SwiftDataNoteSequenceStateStore(container: reopened)
        let loaded = try await restartedStore.load(noteID: noteID)
        guard case .present(let present) = loaded else {
            return XCTFail("Expected migrated state to survive reopening")
        }
        XCTAssertEqual(present.note.body, "Attached")
        XCTAssertEqual(present.revision, 0)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-169-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func makeDiskContainer(
        models: [any PersistentModel.Type],
        url: URL
    ) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(
            "MYR-169-Migration",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    @discardableResult
    private func insertNote(
        noteID: UUID = UUID(),
        body: String,
        in container: ModelContainer
    ) throws -> UUID {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let note = Note(content: body)
        note.id = noteID
        context.insert(note)
        try context.save()
        return noteID
    }

    private func fetchNote(
        noteID: UUID,
        in container: ModelContainer
    ) throws -> Note? {
        let context = ModelContext(container)
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchRecords(
        in container: ModelContainer
    ) throws -> [NoteSequenceStateRecord] {
        try ModelContext(container).fetch(FetchDescriptor<NoteSequenceStateRecord>())
    }

    private func updateRecord(
        in container: ModelContainer,
        mutation: (NoteSequenceStateRecord) throws -> Void
    ) throws {
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<NoteSequenceStateRecord>()).only
        )
        try mutation(record)
        try context.save()
    }

    private func mutateJSONPayload(
        in container: ModelContainer,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        try updateRecord(in: container) { record in
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: record.statePayloadData)
                    as? [String: Any]
            )
            try mutation(&object)
            let payload = try JSONSerialization.data(withJSONObject: object)
            record.statePayloadData = payload
            record.payloadByteCount = payload.count
        }
    }

    private func restorePayload(
        _ payload: Data,
        state: SyncTextSequenceState,
        in container: ModelContainer
    ) throws {
        try updateRecord(in: container) { record in
            record.formatVersion = 1
            record.visibleUTF16Count = state.visibleUTF16Count
            record.tombstonedUTF16Count = state.tombstonedUTF16Count
            record.statePayloadData = payload
            record.payloadByteCount = payload.count
        }
    }

    private func rootState(text: String) throws -> SyncTextSequenceState {
        let operationID = operation(0)
        let run = try SyncTextSequenceRun(
            operationID: operationID,
            origin: SyncTextInsertionOrigin(leftElementID: nil, rightElementID: nil),
            text: text
        )
        let fragment = try SyncTextSequenceFragment(
            operationID: operationID,
            startOffset: 0,
            utf16Length: text.utf16.count,
            visibility: .visible
        )
        return try SyncTextSequenceState(runs: [run], fragments: [fragment])
    }

    private func siblingRootState() throws -> SyncTextSequenceState {
        let first = operation(0)
        let second = operation(1)
        return try SyncTextSequenceState(
            runs: [
                SyncTextSequenceRun(
                    operationID: first,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: nil,
                        rightElementID: nil
                    ),
                    text: "a"
                ),
                SyncTextSequenceRun(
                    operationID: second,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: nil,
                        rightElementID: nil
                    ),
                    text: "b"
                )
            ],
            fragments: [
                SyncTextSequenceFragment(
                    operationID: first,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                SyncTextSequenceFragment(
                    operationID: second,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                )
            ]
        )
    }

    private func originState() throws -> SyncTextSequenceState {
        let parentID = operation(0)
        let childID = operation(1)
        let left = try SyncTextElementID(operationID: parentID, elementOffset: 0)
        let right = try SyncTextElementID(operationID: parentID, elementOffset: 1)
        return try SyncTextSequenceState(
            runs: [
                SyncTextSequenceRun(
                    operationID: parentID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: nil,
                        rightElementID: nil
                    ),
                    text: "ab"
                ),
                SyncTextSequenceRun(
                    operationID: childID,
                    origin: SyncTextInsertionOrigin(
                        leftElementID: left,
                        rightElementID: right
                    ),
                    text: "X"
                )
            ],
            fragments: [
                SyncTextSequenceFragment(
                    operationID: parentID,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                SyncTextSequenceFragment(
                    operationID: childID,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                SyncTextSequenceFragment(
                    operationID: parentID,
                    startOffset: 1,
                    utf16Length: 1,
                    visibility: .visible
                )
            ]
        )
    }

    private func operation(_ counter: UInt64) -> SyncOperationID {
        SyncOperationID(
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            localCounter: counter
        )
    }

    private func assertStoreError(
        _ expected: NoteSequenceStateStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? NoteSequenceStateStoreError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private enum InjectedFailure: Error {
    case expected
}

private final class StorePause: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        release.wait()
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
