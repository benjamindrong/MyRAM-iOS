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
    func testBootstrapAdapterMatchesExplicitCoreV1() throws {
        let noteID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let body = "A\u{1F600}Z"

        XCTAssertEqual(
            try NoteSequenceStateBootstrapAdapter.makeInitialState(
                noteID: noteID,
                body: body
            ),
            try SyncTextLegacyBootstrap.makeState(
                noteID: noteID,
                body: body,
                formatVersion: .v1
            )
        )
    }

    func testBootstrapAdapterPreservesExactUTF16Body() throws {
        let body = "\u{1F600}e\u{301}\n"

        let state = try NoteSequenceStateBootstrapAdapter.makeInitialState(
            noteID: UUID(),
            body: body
        )

        XCTAssertTrue(state.visibleText.utf16.elementsEqual(body.utf16))
    }

    func testBootstrapAdapterMapsEmptyBodyToCanonicalEmptyState() throws {
        XCTAssertEqual(
            try NoteSequenceStateBootstrapAdapter.makeInitialState(
                noteID: UUID(),
                body: ""
            ),
            .empty
        )
    }

    func testExactTextComparisonRejectsCanonicallyEquivalentDifferentUTF16() {
        let precomposed = "\u{E9}"
        let decomposed = "e\u{301}"

        XCTAssertEqual(precomposed, decomposed)
        XCTAssertFalse(NoteSequenceStateExactText.matches(precomposed, decomposed))
    }

    func testPreparedBootstrapExactMismatchUsesNewStateBodyMismatch() throws {
        let state = try rootState(text: "\u{E9}")

        XCTAssertThrowsError(
            try NoteSequenceStateBootstrapPersistence.requireExactBody(
                state: state,
                body: "e\u{301}"
            )
        ) { error in
            XCTAssertEqual(
                error as? NoteSequenceStateStoreError,
                .newStateBodyMismatch
            )
        }
    }

    func testPreparedBootstrapContainsCanonicalPayloadAndRevisionZeroMetadata() throws {
        let noteID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let body = "Prepared \u{1F680}"

        let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
            noteID: noteID,
            body: body
        )
        let expectedPayload = try NoteSequenceStatePersistenceCodec.encode(
            state: prepared.state,
            noteID: noteID
        )
        let record = prepared.makeRevisionZeroRecord()

        XCTAssertEqual(prepared.payload, expectedPayload)
        XCTAssertEqual(prepared.visibleUTF16Count, prepared.state.visibleUTF16Count)
        XCTAssertEqual(
            prepared.tombstonedUTF16Count,
            prepared.state.tombstonedUTF16Count
        )
        XCTAssertEqual(record.noteID, noteID)
        XCTAssertEqual(record.formatVersion, 1)
        XCTAssertEqual(record.revision, 0)
        XCTAssertEqual(record.visibleUTF16Count, prepared.visibleUTF16Count)
        XCTAssertEqual(
            record.tombstonedUTF16Count,
            prepared.tombstonedUTF16Count
        )
        XCTAssertEqual(record.payloadByteCount, prepared.payload.count)
        XCTAssertEqual(record.statePayloadData, prepared.payload)
    }

    func testLoadOrBootstrapCreatesRevisionZeroStateForAuthoritativeNonemptyBody() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Authoritative \u{1F600}", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.loadOrBootstrap(noteID: noteID)
        let expectedState = try NoteSequenceStateBootstrapAdapter.makeInitialState(
            noteID: noteID,
            body: "Authoritative \u{1F600}"
        )

        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(loaded.note.body, "Authoritative \u{1F600}")
        XCTAssertEqual(loaded.state, expectedState)
        XCTAssertEqual(loaded.state.runs.count, 1)
        XCTAssertEqual(loaded.state.fragments.count, 1)
        XCTAssertTrue(
            loaded.state.visibleText.utf16.elementsEqual(
                "Authoritative \u{1F600}".utf16
            )
        )
        XCTAssertEqual(loaded.state.tombstonedUTF16Count, 0)
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
    }

    func testLoadOrBootstrapPersistsRevisionZeroCanonicalEmptyState() async throws {
        let container = try makeContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try insertNote(noteID: noteID, body: "", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.loadOrBootstrap(noteID: noteID)
        let record = try XCTUnwrap(fetchRecords(in: container).only)

        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(loaded.state, .empty)
        XCTAssertEqual(
            record.statePayloadData,
            Data(
                "{\"formatVersion\":1,\"fragments\":[],\"noteID\":\"00000000-0000-0000-0000-000000000001\",\"runs\":[]}"
                    .utf8
            )
        )
    }

    func testLoadOrBootstrapUsesBodyPersistedAtInvocation() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Original", in: container)
        try updateNote(noteID: noteID, in: container) { note in
            note.content = "Current \u{1F680}"
        }
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.loadOrBootstrap(noteID: noteID)

        XCTAssertEqual(loaded.note.body, "Current \u{1F680}")
        XCTAssertTrue(
            loaded.state.visibleText.utf16.elementsEqual("Current \u{1F680}".utf16)
        )
    }

    func testLoadOrBootstrapChangesOnlyTheMissingSequenceStateRow() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let folder = Folder(name: "Folder")
        let note = Note(title: "Title", content: "Body", folder: folder)
        note.id = UUID()
        note.richTextContentData = Data([0x01, 0x02, 0x03])
        note.isPinned = true
        note.createdAt = Date(timeIntervalSinceReferenceDate: 111)
        note.modifiedAt = Date(timeIntervalSinceReferenceDate: 222)
        note.deletedAt = Date(timeIntervalSinceReferenceDate: 333)
        let photo = NotePhotoAttachment(imageData: Data([0x04]), note: note)
        let pinnedText = PinnedThought(text: "Pinned", order: 7, note: note)
        note.photoAttachments = [photo]
        note.pinnedThoughts = [pinnedText]
        context.insert(folder)
        context.insert(note)
        context.insert(photo)
        context.insert(pinnedText)
        try context.save()
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        _ = try await store.loadOrBootstrap(noteID: note.id)
        let persisted = try XCTUnwrap(fetchNote(noteID: note.id, in: container))

        XCTAssertEqual(persisted.title, "Title")
        XCTAssertEqual(persisted.content, "Body")
        XCTAssertEqual(persisted.richTextContentData, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(persisted.isPinned, true)
        XCTAssertEqual(persisted.createdAt, Date(timeIntervalSinceReferenceDate: 111))
        XCTAssertEqual(persisted.modifiedAt, Date(timeIntervalSinceReferenceDate: 222))
        XCTAssertEqual(persisted.deletedAt, Date(timeIntervalSinceReferenceDate: 333))
        XCTAssertEqual(persisted.folder?.id, folder.id)
        XCTAssertEqual(persisted.photoAttachments.map(\.id), [photo.id])
        XCTAssertEqual(persisted.pinnedThoughts.map(\.id), [pinnedText.id])
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
    }

    func testLoadOrBootstrapReturnsExistingStateWithoutSaveRevisionAdvanceOrPayloadRewrite() async throws {
        let container = try makeContainer()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try insertNote(noteID: noteID, body: "", in: container)
        let initialStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await initialStore.compareAndSet(
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
            record.revision = 8
            record.statePayloadData = lexicalPayload
            record.payloadByteCount = lexicalPayload.count
        }
        let saveCalls = InvocationRecorder()
        let hookCalls = InvocationRecorder()
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            bootstrapSaveOperation: { _ in saveCalls.record() },
            testHook: { _ in hookCalls.record() }
        )

        let loaded = try await store.loadOrBootstrap(noteID: noteID)

        XCTAssertEqual(loaded.revision, 8)
        XCTAssertEqual(loaded.state, .empty)
        XCTAssertEqual(saveCalls.count, 0)
        XCTAssertEqual(hookCalls.count, 0)
        let record = try XCTUnwrap(fetchRecords(in: container).only)
        XCTAssertEqual(record.revision, 8)
        XCTAssertEqual(record.statePayloadData, lexicalPayload)
    }

    func testLoadOrBootstrapRejectsExistingStateWhoseVisibleTextIsNotExactUTF16() async throws {
        let container = try makeContainer()
        let decomposed = "e\u{301}"
        let precomposed = "\u{E9}"
        let noteID = try insertNote(body: decomposed, in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: decomposed),
            newBody: decomposed,
            newState: rootState(text: precomposed)
        )
        let originalPayload = try XCTUnwrap(
            fetchRecords(in: container).only?.statePayloadData
        )

        guard case .present = try await seedStore.load(noteID: noteID) else {
            return XCTFail("Existing load should retain canonical String equality")
        }
        await assertStoreError(.corruptState) {
            _ = try await seedStore.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertEqual(
            try fetchRecords(in: container).only?.statePayloadData,
            originalPayload
        )
    }

    func testLoadOrBootstrapDoesNotReplaceCorruptExistingState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Body"),
            newBody: "Body",
            newState: rootState(text: "Body")
        )
        let corruptPayload = Data("not-json".utf8)
        try updateRecord(in: container) { record in
            record.statePayloadData = corruptPayload
            record.payloadByteCount = corruptPayload.count
        }

        await assertStoreError(.corruptState) {
            _ = try await seedStore.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
        XCTAssertEqual(
            try fetchRecords(in: container).only?.statePayloadData,
            corruptPayload
        )
    }

    func testLoadOrBootstrapDoesNotReplaceUnsupportedExistingState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Body"),
            newBody: "Body",
            newState: rootState(text: "Body")
        )
        try updateRecord(in: container) { $0.formatVersion = 2 }

        await assertStoreError(.unsupportedVersion(2)) {
            _ = try await seedStore.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertEqual(try fetchRecords(in: container).only?.formatVersion, 2)
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
    }

    func testLoadOrBootstrapMissingNoteFailsWithoutCreatingState() async throws {
        let container = try makeContainer()
        let noteID = UUID()
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        await assertStoreError(.missingNote(noteID)) {
            _ = try await store.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
    }

    func testLoadOrBootstrapInjectedBeforeSaveFailureRollsBackPendingRow() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                if stage == .beforeSave {
                    throw InjectedFailure.expected
                }
            }
        )

        await assertStoreError(.persistenceFailure) {
            _ = try await store.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Body")
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
    }

    func testLoadOrBootstrapThrownSaveOperationLeavesNoteAndStateUnchanged() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let hookStages = StageRecorder()
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            bootstrapSaveOperation: { _ in
                throw InjectedFailure.expected
            },
            testHook: { hookStages.record($0) }
        )

        await assertStoreError(.persistenceFailure) {
            _ = try await store.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertEqual(hookStages.stages, [.beforeSave])
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Body")
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
    }

    func testLoadOrBootstrapPostSaveCommittedMismatchReturnsVerificationFailure() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                guard stage == .afterSave else { return }
                let mutationContext = ModelContext(container)
                let records = try mutationContext.fetch(
                    FetchDescriptor<NoteSequenceStateRecord>()
                )
                guard let record = records.first else {
                    throw InjectedFailure.expected
                }
                mutationContext.delete(record)
                try mutationContext.save()
            }
        )

        await assertStoreError(.verificationFailure) {
            _ = try await store.loadOrBootstrap(noteID: noteID)
        }
        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Body")
    }

    func testLoadOrBootstrapStateSurvivesStoreRestart() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Restart \u{1F680}", in: container)
        let firstStore = await SwiftDataNoteSequenceStateStore(container: container)
        let first = try await firstStore.loadOrBootstrap(noteID: noteID)

        let restartedStore = await SwiftDataNoteSequenceStateStore(container: container)
        let restarted = try await restartedStore.loadOrBootstrap(noteID: noteID)

        XCTAssertEqual(restarted, first)
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
    }

    func testEnsureBootstrapStateForCurrentBodyReturnsExactExistingStateWithoutSave() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Exact", in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.loadOrBootstrap(noteID: noteID)
        let originalRecord = try XCTUnwrap(fetchRecords(in: container).only)
        let originalPayload = originalRecord.statePayloadData
        let saveCalls = InvocationRecorder()
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            bootstrapSaveOperation: { _ in saveCalls.record() }
        )

        let loaded = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)

        XCTAssertEqual(loaded.revision, 0)
        XCTAssertTrue(NoteSequenceStateExactText.matches(loaded.state.visibleText, "Exact"))
        XCTAssertEqual(saveCalls.count, 0)
        XCTAssertEqual(try fetchRecords(in: container).only?.statePayloadData, originalPayload)
    }

    func testEnsureBootstrapStateForCurrentBodyCreatesMissingState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Missing \u{1F680}", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)

        XCTAssertEqual(loaded.revision, 0)
        XCTAssertTrue(
            NoteSequenceStateExactText.matches(
                loaded.state.visibleText,
                "Missing \u{1F680}"
            )
        )
        XCTAssertEqual(try fetchRecords(in: container).count, 1)
    }

    func testEnsureBootstrapStateForCurrentBodyRepairsValidStaleState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Current", in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Current"),
            newBody: "Stale",
            newState: rootState(text: "Stale")
        )
        try updateNote(noteID: noteID, in: container) { $0.content = "Current" }
        let store = await SwiftDataNoteSequenceStateStore(container: container)

        let loaded = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)

        XCTAssertEqual(loaded.revision, 1)
        XCTAssertTrue(NoteSequenceStateExactText.matches(loaded.state.visibleText, "Current"))
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Current")
    }

    func testEnsureBootstrapStateForCurrentBodyPreservesNonBootstrapStateWhenExact() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let nonBootstrapState = try rootState(text: "Body")
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Body"),
            newBody: "Body",
            newState: nonBootstrapState
        )
        let originalPayload = try XCTUnwrap(fetchRecords(in: container).only?.statePayloadData)

        let loaded = try await seedStore.ensureBootstrapStateForCurrentBody(noteID: noteID)

        XCTAssertEqual(loaded.state, nonBootstrapState)
        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(try fetchRecords(in: container).only?.statePayloadData, originalPayload)
    }

    func testEnsureBootstrapStateForCurrentBodyRejectsCorruptState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.loadOrBootstrap(noteID: noteID)
        let corruptPayload = Data("not-json".utf8)
        try updateRecord(in: container) { record in
            record.statePayloadData = corruptPayload
            record.payloadByteCount = corruptPayload.count
        }

        await assertStoreError(.corruptState) {
            _ = try await seedStore.ensureBootstrapStateForCurrentBody(noteID: noteID)
        }

        XCTAssertEqual(try fetchRecords(in: container).only?.statePayloadData, corruptPayload)
    }

    func testEnsureBootstrapStateForCurrentBodyRejectsUnsupportedState() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await store.loadOrBootstrap(noteID: noteID)
        try updateRecord(in: container) { $0.formatVersion = 2 }

        await assertStoreError(.unsupportedVersion(2)) {
            _ = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
        }

        XCTAssertEqual(try fetchRecords(in: container).only?.formatVersion, 2)
    }

    func testEnsureBootstrapStateForCurrentBodyRejectsRevisionExhaustion() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Current", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Current"),
            newBody: "Stale",
            newState: rootState(text: "Stale")
        )
        try updateNote(noteID: noteID, in: container) { $0.content = "Current" }
        try updateRecord(in: container) { $0.revision = .max }
        let originalPayload = try XCTUnwrap(fetchRecords(in: container).only?.statePayloadData)

        await assertStoreError(.revisionExhaustion) {
            _ = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
        }

        let record = try XCTUnwrap(fetchRecords(in: container).only)
        XCTAssertEqual(record.revision, .max)
        XCTAssertEqual(record.statePayloadData, originalPayload)
    }

    func testEnsureBootstrapStateForCurrentBodySaveFailureRollsBack() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            bootstrapSaveOperation: { _ in throw InjectedFailure.expected }
        )

        await assertStoreError(.persistenceFailure) {
            _ = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
        }

        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
        XCTAssertEqual(try fetchNote(noteID: noteID, in: container)?.content, "Body")
    }

    func testEnsureBootstrapStateForCurrentBodyVerificationFailureIsSurfaced() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let store = await SwiftDataNoteSequenceStateStore(
            container: container,
            testHook: { stage in
                guard stage == .afterSave else { return }
                let mutationContext = ModelContext(container)
                for record in try mutationContext.fetch(
                    FetchDescriptor<NoteSequenceStateRecord>()
                ) {
                    mutationContext.delete(record)
                }
                try mutationContext.save()
            }
        )

        await assertStoreError(.verificationFailure) {
            _ = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
        }

        XCTAssertTrue(try fetchRecords(in: container).isEmpty)
    }

    func testLoadOrBootstrapRejectsMismatchWhileEnsureCurrentBodyRepairsIt() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Current", in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Current"),
            newBody: "Stale",
            newState: rootState(text: "Stale")
        )
        try updateNote(noteID: noteID, in: container) { $0.content = "Current" }

        await assertStoreError(.corruptState) {
            _ = try await store.loadOrBootstrap(noteID: noteID)
        }

        let repaired = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
        XCTAssertEqual(repaired.revision, 1)
        XCTAssertTrue(NoteSequenceStateExactText.matches(repaired.state.visibleText, "Current"))
    }

    func testConcurrentLoadOrBootstrapAcrossStoreInstancesCreatesOneRevisionZeroRow() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Concurrent", in: container)
        let storeA = await SwiftDataNoteSequenceStateStore(container: container)
        let storeB = await SwiftDataNoteSequenceStateStore(container: container)

        let firstTask = Task.detached {
            try await storeA.loadOrBootstrap(noteID: noteID)
        }
        let secondTask = Task.detached {
            try await storeB.loadOrBootstrap(noteID: noteID)
        }
        let first = try await firstTask.value
        let second = try await secondTask.value

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.revision, 0)
        let records = try fetchRecords(in: container)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.only?.revision, 0)
        XCTAssertEqual(
            records.only?.statePayloadData,
            try NoteSequenceStatePersistenceCodec.encode(
                state: first.state,
                noteID: noteID
            )
        )
    }

    func testLoadOrBootstrapReturnsExistingNonBootstrapStateWithoutReplacement() async throws {
        let container = try makeContainer()
        let noteID = try insertNote(body: "Body", in: container)
        let state = try rootState(text: "Body")
        let seedStore = await SwiftDataNoteSequenceStateStore(container: container)
        _ = try await seedStore.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: "Body"),
            newBody: "Body",
            newState: state
        )
        let originalPayload = try XCTUnwrap(
            fetchRecords(in: container).only?.statePayloadData
        )

        let loaded = try await seedStore.loadOrBootstrap(noteID: noteID)

        XCTAssertEqual(loaded.state, state)
        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(
            try fetchRecords(in: container).only?.statePayloadData,
            originalPayload
        )
    }

    func testExistingLoadValidationRetainsCanonicalStringEqualityBehavior() async throws {
        let container = try makeContainer()
        let decomposed = "e\u{301}"
        let noteID = try insertNote(body: decomposed, in: container)
        let store = await SwiftDataNoteSequenceStateStore(container: container)
        let precomposedState = try rootState(text: "\u{E9}")
        _ = try await store.compareAndSet(
            noteID: noteID,
            expected: .missing(expectedBody: decomposed),
            newBody: decomposed,
            newState: precomposedState
        )

        let loaded = try await store.load(noteID: noteID)
        XCTAssertEqual(
            loaded,
            .present(LoadedNoteSequenceState(
                note: NoteSequenceStateNoteSnapshot(noteID: noteID, body: decomposed),
                revision: 0,
                state: precomposedState
            ))
        )
    }

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

    private func updateNote(
        noteID: UUID,
        in container: ModelContainer,
        mutation: (Note) throws -> Void
    ) throws {
        let context = ModelContext(container)
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        let note = try XCTUnwrap(context.fetch(descriptor).first)
        try mutation(note)
        try context.save()
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
                    operationID: second,
                    startOffset: 0,
                    utf16Length: 1,
                    visibility: .visible
                ),
                SyncTextSequenceFragment(
                    operationID: first,
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

private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStages: [NoteSequenceStateStoreTestStage] = []

    var stages: [NoteSequenceStateStoreTestStage] {
        lock.withLock { storedStages }
    }

    func record(_ stage: NoteSequenceStateStoreTestStage) {
        lock.withLock { storedStages.append(stage) }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
