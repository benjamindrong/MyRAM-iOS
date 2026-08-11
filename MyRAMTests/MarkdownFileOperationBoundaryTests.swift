import Foundation
import SwiftData
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownFileOperationBoundaryTests: XCTestCase {
    func testExpectedNoneWithoutRegistrationReturnsNoActiveEditor() async {
        await assertEqualAsync(
            await NoteEditorFileOperationBridge().flushEditor(expected: .none),
            .noActiveEditor
        )
    }

    func testExpectedNoneWithRegistrationRejectsMismatchWithoutInvokingClosure() async {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        var didFlush = false
        bridge.register(noteID: noteID) {
            didFlush = true
            return .succeeded
        }

        await assertEqualAsync(
            await bridge.flushEditor(expected: .none),
            .editorMismatch(expected: .none, actualNoteID: noteID)
        )
        XCTAssertFalse(didFlush)
    }

    func testMatchingExpectedEditorReturnsBridgeOwnedIdentity() async {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        bridge.register(noteID: noteID) { .succeeded }

        await assertEqualAsync(
            await bridge.flushEditor(expected: .note(noteID)),
            .succeeded(noteID: noteID)
        )
    }

    func testExpectedEditorWithoutRegistrationReturnsUnavailableWithoutFlush() async {
        let noteID = UUID()

        await assertEqualAsync(
            await NoteEditorFileOperationBridge().flushEditor(expected: .note(noteID)),
            .expectedEditorUnavailable(noteID: noteID)
        )
    }

    func testExpectedEditorMismatchDoesNotInvokeWrongClosure() async {
        let bridge = NoteEditorFileOperationBridge()
        let expectedID = UUID()
        let registeredID = UUID()
        var didFlush = false
        bridge.register(noteID: registeredID) {
            didFlush = true
            return .succeeded
        }

        await assertEqualAsync(
            await bridge.flushEditor(expected: .note(expectedID)),
            .editorMismatch(
                expected: .note(expectedID),
                actualNoteID: registeredID
            )
        )
        XCTAssertFalse(didFlush)
    }

    func testBridgeAttachesIdentityToLocalFailure() async {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        bridge.register(noteID: noteID) {
            .failed(message: "Injected failure")
        }

        await assertEqualAsync(
            await bridge.flushEditor(expected: .note(noteID)),
            .failed(noteID: noteID, message: "Injected failure")
        )
    }

    func testStaleUnregisterCannotClearNewerEditor() async {
        let bridge = NoteEditorFileOperationBridge()
        let oldID = UUID()
        let currentID = UUID()
        bridge.register(noteID: oldID) { .succeeded }
        bridge.register(noteID: currentID) { .succeeded }

        bridge.unregister(noteID: oldID)

        await assertEqualAsync(
            await bridge.flushEditor(expected: .note(currentID)),
            .succeeded(noteID: currentID)
        )
    }

    func testFlushFailurePreventsReadAndConsumptionAndPreservesDiagnosticResult() async {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            .failed(message: "Injected failure")
        }
        var didRead = false
        var didConsume = false
        let coordinator = makeMarkdownCoordinator { _ in
            didRead = true
            return Data()
        }

        await assertThrowsErrorAsync(try await coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Blocked.md"),
            expectedEditor: .note(noteID),
            flushBridge: bridge,
            consume: { _ in
                didConsume = true
            }
        )) {
            XCTAssertEqual(
                $0 as? MarkdownImportOperationError,
                .editorPreconditionFailed(
                    .failed(noteID: noteID, message: "Injected failure")
                )
            )
            XCTAssertEqual(
                ($0 as? LocalizedError)?.errorDescription,
                "The current note could not be saved before continuing."
            )
        }
        XCTAssertFalse(didRead)
        XCTAssertFalse(didConsume)
    }

    func testSuccessfulFlushPrecedesReadAndConsumption() async throws {
        var events: [String] = []
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            events.append("flush")
            return .succeeded
        }
        let coordinator = makeMarkdownCoordinator { _ in
            events.append("read")
            return Data("body".utf8)
        }

        let source = try await coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Allowed.md"),
            expectedEditor: .note(noteID),
            flushBridge: bridge,
            consume: { document in
                events.append("consume")
                return document.source
            }
        )

        XCTAssertEqual(source, "body")
        XCTAssertEqual(events, ["flush", "read", "consume"])
    }

    func testProductionRouterMarkdownSuccessOrdersAuthorizationBeforeBodyAndCommitEffects() async throws {
        var events: [String] = []
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            events.append("flush")
            return .succeeded
        }
        let coordinator = makeMarkdownCoordinator { _ in
            events.append("read")
            return Data("body".utf8)
        }
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in
                events.append("classify")
                return MarkdownFileClassifier.markdownContentType
            }
        ))

        let result: ExternalImportRoutingResult<String, Void> = try await router.route(
            url: URL(fileURLWithPath: "/tmp/External.data"),
            expectedEditor: .note(noteID),
            markdownCoordinator: coordinator,
            flushBridge: bridge,
            importMarkdown: { document in
                events.append(contentsOf: [
                    "commit",
                    "publish",
                    "undo",
                    "refresh",
                    "select"
                ])
                return document.source
            },
            importMyRAM: { _ in XCTFail("Unexpected .myram import") }
        )

        guard case .markdown(let source) = result else {
            return XCTFail("Expected Markdown route")
        }
        XCTAssertEqual(source, "body")
        XCTAssertEqual(events, [
            "classify",
            "flush",
            "read",
            "commit",
            "publish",
            "undo",
            "refresh",
            "select"
        ])
    }

    func testProductionRouterMarkdownFlushFailureHasZeroDownstreamEffects() async {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) { .failed(message: "Injected") }
        await assertMarkdownRouteBlocked(
            expectedEditor: .note(noteID),
            bridge: bridge,
            expectedResult: .failed(noteID: noteID, message: "Injected")
        )
    }

    func testProductionRouterMarkdownMismatchDoesNotInvokeWrongEditorOrDownstreamEffects() async {
        let expectedID = UUID()
        let actualID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        var didFlush = false
        bridge.register(noteID: actualID) {
            didFlush = true
            return .succeeded
        }

        await assertMarkdownRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: bridge,
            expectedResult: .editorMismatch(
                expected: .note(expectedID),
                actualNoteID: actualID
            )
        )
        XCTAssertFalse(didFlush)
    }

    func testProductionRouterMarkdownUnavailableHasZeroDownstreamEffects() async {
        let expectedID = UUID()
        await assertMarkdownRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: NoteEditorFileOperationBridge(),
            expectedResult: .expectedEditorUnavailable(noteID: expectedID)
        )
    }

    func testProductionRouterKeepsMyRAMOnExistingImporterPath() async throws {
        var didReadMarkdown = false
        var didImportMarkdown = false
        var importedMyRAMURL: URL?
        let url = URL(fileURLWithPath: "/tmp/Archive.myram")
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in nil }
        ))

        let result: ExternalImportRoutingResult<Void, String> = try await router.route(
            url: url,
            expectedEditor: .none,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                didReadMarkdown = true
                return Data()
            },
            flushBridge: NoteEditorFileOperationBridge(),
            importMarkdown: { _ in didImportMarkdown = true },
            importMyRAM: {
                importedMyRAMURL = $0
                return "myram"
            }
        )

        guard case .myram(let value) = result else {
            return XCTFail("Expected .myram route")
        }
        XCTAssertEqual(value, "myram")
        XCTAssertEqual(importedMyRAMURL, url)
        XCTAssertFalse(didReadMarkdown)
        XCTAssertFalse(didImportMarkdown)
    }

    func testProductionRouterUnsupportedInvokesNeitherImporter() async {
        var didReadMarkdown = false
        var didImportMarkdown = false
        var didImportMyRAM = false
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in nil }
        ))

        await assertThrowsErrorAsync(try await router.route(
            url: URL(fileURLWithPath: "/tmp/Archive.txt"),
            expectedEditor: .none,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                didReadMarkdown = true
                return Data()
            },
            flushBridge: NoteEditorFileOperationBridge(),
            importMarkdown: { _ in didImportMarkdown = true },
            importMyRAM: { _ in didImportMyRAM = true }
        )) {
            XCTAssertEqual(
                $0 as? ExternalImportRoutingError,
                .unsupportedFileType
            )
        }
        XCTAssertFalse(didReadMarkdown)
        XCTAssertFalse(didImportMarkdown)
        XCTAssertFalse(didImportMyRAM)
    }

    func testExportFlushFailurePreventsSourceCapture() async {
        var didCaptureSource = false

        await assertThrowsErrorAsync(
            try await MarkdownExportPreparationCoordinator().prepare(
                flush: {
                    .failed(message: "Injected failure")
                },
                snapshot: {
                    didCaptureSource = true
                    return (title: "Draft", source: "Unsaved")
                }
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownExportPreparationError, .sourceFlushFailed)
        }
        XCTAssertFalse(didCaptureSource)
    }

    func testExportCapturesLatestRawSourceOnlyAfterSuccessfulLocalFlush() async throws {
        var rawSource = "Before"
        var events: [String] = []

        let prepared = try await MarkdownExportPreparationCoordinator().prepare(
            flush: {
                events.append("local-flush")
                rawSource = "Latest\r\n**literal**"
                return .succeeded
            },
            snapshot: {
                events.append("snapshot")
                return (title: "Roadmap.md", source: rawSource)
            }
        )

        XCTAssertEqual(events, ["local-flush", "snapshot"])
        XCTAssertEqual(prepared.filename, "Roadmap.md")
        XCTAssertEqual(prepared.data, Data("Latest\r\n**literal**".utf8))
    }

    func testExportDoesNotConsultAnotherEditorsBridgeRegistration() async throws {
        let bridge = NoteEditorFileOperationBridge()
        var didInvokeBridge = false
        bridge.register(noteID: UUID()) {
            didInvokeBridge = true
            return .failed(message: "Wrong editor")
        }

        let prepared = try await MarkdownExportPreparationCoordinator().prepare(
            flush: { .succeeded },
            snapshot: { (title: "Local", source: "Editor-owned") }
        )

        XCTAssertFalse(didInvokeBridge)
        XCTAssertEqual(prepared.data, Data("Editor-owned".utf8))
    }

    private func assertMarkdownRouteBlocked(
        expectedEditor: ExpectedEditor,
        bridge: NoteEditorFileOperationBridge,
        expectedResult: EditorFlushResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var bodyReadCount = 0
        var persistenceCount = 0
        var publicationCount = 0
        var undoCount = 0
        var refreshCount = 0
        var selectionCount = 0
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in MarkdownFileClassifier.markdownContentType }
        ))

        await assertThrowsErrorAsync(try await router.route(
            url: URL(fileURLWithPath: "/tmp/Blocked.md"),
            expectedEditor: expectedEditor,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                bodyReadCount += 1
                return Data()
            },
            flushBridge: bridge,
            importMarkdown: { _ in
                persistenceCount += 1
                publicationCount += 1
                undoCount += 1
                refreshCount += 1
                selectionCount += 1
            },
            importMyRAM: { _ in XCTFail("Unexpected .myram import", file: file, line: line) }
        )) {
            XCTAssertEqual(
                $0 as? MarkdownImportOperationError,
                .editorPreconditionFailed(expectedResult),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(bodyReadCount, 0, file: file, line: line)
        XCTAssertEqual(persistenceCount, 0, file: file, line: line)
        XCTAssertEqual(publicationCount, 0, file: file, line: line)
        XCTAssertEqual(undoCount, 0, file: file, line: line)
        XCTAssertEqual(refreshCount, 0, file: file, line: line)
        XCTAssertEqual(selectionCount, 0, file: file, line: line)
    }

    private func assertEqualAsync<T: Equatable>(
        _ expression: @autoclosure () async -> T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await expression()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ errorHandler: (Error) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    private func makeMarkdownCoordinator(
        dataLoader: @escaping (URL) throws -> Data
    ) -> MarkdownImportOperationCoordinator {
        MarkdownImportOperationCoordinator(
            classifier: MarkdownFileClassifier(contentTypeProvider: { _ in
                MarkdownFileClassifier.markdownContentType
            }),
            reader: MarkdownFileReader(dataLoader: dataLoader)
        )
    }
}

@MainActor
final class MYR179PostCommitRemediationTests: XCTestCase {
    func testV2RoundTripPreservesAnchoredRecoveryAndDerivesPendingState() throws {
        let transition = try makeInsertTransition(counter: 179_001, dependencyCounter: 179_002)
        let legacy = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.batch],
            legacyCleanupRequired: false,
            presentationEntries: []
        )

        let data = try SyncConvergenceVersionedPostCommitWorkPayload.encodedPayloadData(
            legacyWorkPayload: legacy,
            anchoredRecoveryTransitions: [transition]
        )
        let decoded = try SyncConvergenceVersionedPostCommitWorkPayload.decodePayloadData(data)

        XCTAssertEqual(decoded.legacyWorkPayload, legacy)
        XCTAssertEqual(decoded.anchoredRecoveryTransitions, [transition])
        XCTAssertTrue(decoded.derivedInitialState().anchoredRecoveryPending)
        XCTAssertTrue(decoded.derivedInitialState().queueCleanupPending)
    }

    func testV1PersistedWorkCompatibilityHasNoAnchoredRecovery() throws {
        let legacy = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.batch],
            legacyCleanupRequired: false,
            presentationEntries: []
        )

        let data = try legacy.encodedPayloadData()
        let decoded = try SyncConvergenceVersionedPostCommitWorkPayload.decodePayloadData(data)

        XCTAssertEqual(decoded.legacyWorkPayload, legacy)
        XCTAssertTrue(decoded.anchoredRecoveryTransitions.isEmpty)
        XCTAssertFalse(decoded.derivedInitialState().anchoredRecoveryPending)
        XCTAssertTrue(decoded.derivedInitialState().queueCleanupPending)
    }

    func testRecoveryPersistenceFailureSuppressesPresentationAndQueueCleanup() async throws {
        let fixture = try makeMYR137Fixture()
        let transition = try makeInsertTransition(counter: 179_011, dependencyCounter: 179_012)
        let request = try configurePersistedAnchoredWork(fixture: fixture, transition: transition)
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        struct InjectedWriteFailure: Error {}
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(
            fileURL: temporaryRecoveryURL(),
            atomicWriter: { _, _ in throw InjectedWriteFailure() }
        )
        let stateStore = fixture.store(context: ModelContext(fixture.container))
        let executor = SyncConvergencePostCommitExecutor(
            store: stateStore,
            queueCleanupAdapter: queue,
            anchoredRecoveryAdapter: recoveryStore,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request, activationEnabled: true)

        XCTAssertEqual(
            outcome,
            .pending(
                blocking: .anchoredRecoveryPersistence,
                outstanding: [.anchoredRecoveryPersistence, .queueCleanup, .presentationRefresh]
            )
        )
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(presentation.requests, [])
        guard case .fullRoot(let reloaded) = try stateStore.loadState(
            matching: request.persistedIncorporationIdentity
        ) else {
            return XCTFail("Expected persisted full root")
        }
        XCTAssertTrue(reloaded.postCommitState.anchoredRecoveryPending)
        XCTAssertTrue(reloaded.postCommitState.presentationRefreshPending)
        XCTAssertTrue(reloaded.postCommitState.queueCleanupPending)
    }

    func testRestartCompletesPersistedRecoveryBeforePresentationAndCleanup() async throws {
        let fixture = try makeMYR137Fixture()
        let transition = try makeInsertTransition(counter: 179_021, dependencyCounter: 179_022)
        let request = try configurePersistedAnchoredWork(fixture: fixture, transition: transition)
        let recoveryURL = temporaryRecoveryURL()
        struct InjectedWriteFailure: Error {}
        let firstExecutor = SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            anchoredRecoveryAdapter: FileBackedSyncBatchAnchoredRecoveryStore(
                fileURL: recoveryURL,
                atomicWriter: { _, _ in throw InjectedWriteFailure() }
            ),
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )
        _ = await firstExecutor.execute(request, activationEnabled: true)

        let restartedStore = fixture.store(context: ModelContext(fixture.container))
        let pending = try restartedStore.loadPendingPostCommitRequests()
        let restartedRequest = try XCTUnwrap(pending.first { $0.sourceBatchID == request.sourceBatchID })
        let events = MYR179PostCommitEventRecorder()
        let recovery = MYR179RecordingRecoveryAdapter(
            wrapped: FileBackedSyncBatchAnchoredRecoveryStore(fileURL: recoveryURL),
            events: events
        )
        let presentation = MYR179RecordingPresentationAdapter(events: events)
        let queue = MYR179RecordingQueueCleanupAdapter(events: events)
        let restartedExecutor = SyncConvergencePostCommitExecutor(
            store: restartedStore,
            queueCleanupAdapter: queue,
            anchoredRecoveryAdapter: recovery,
            presentationAdapter: presentation
        )

        let outcome = await restartedExecutor.execute(restartedRequest, activationEnabled: true)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(events.snapshot, ["recovery", "presentation", "queue"])
        XCTAssertEqual(
            FileBackedSyncBatchAnchoredRecoveryStore(fileURL: recoveryURL).snapshot().records,
            [try transitionRecord(transition)]
        )
    }

    func testAlreadyDurableRecoveryTransitionIsIdempotentAndCompletesCleanup() async throws {
        let fixture = try makeMYR137Fixture()
        let transition = try makeInsertTransition(counter: 179_031, dependencyCounter: 179_032)
        let request = try configurePersistedAnchoredWork(fixture: fixture, transition: transition)
        let recoveryURL = temporaryRecoveryURL()
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: recoveryURL)
        XCTAssertTrue(try recoveryStore.apply([transition]))
        let before = recoveryStore.snapshot()
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: queue,
            anchoredRecoveryAdapter: recoveryStore,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request, activationEnabled: true)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(recoveryStore.snapshot(), before)
        XCTAssertEqual(queue.removals, [[request.sourceBatchID]])
        XCTAssertEqual(presentation.requests.map(\.noteID), [fixture.base.noteID])
    }

    func testActivationOffKeepsAnchoredRecoveryPendingAndBlocksLaterGates() async throws {
        let fixture = try makeMYR137Fixture()
        let transition = try makeInsertTransition(counter: 179_041, dependencyCounter: 179_042)
        let request = try configurePersistedAnchoredWork(fixture: fixture, transition: transition)
        let recoveryStore = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: temporaryRecoveryURL())
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: fixture.store(context: ModelContext(fixture.container)),
            queueCleanupAdapter: queue,
            anchoredRecoveryAdapter: recoveryStore,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request, activationEnabled: false)

        XCTAssertEqual(
            outcome,
            .pending(
                blocking: .anchoredRecoveryPersistence,
                outstanding: [.anchoredRecoveryPersistence, .queueCleanup, .presentationRefresh]
            )
        )
        XCTAssertTrue(recoveryStore.snapshot().records.isEmpty)
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(presentation.requests, [])
    }

    func testMalformedV2RecoveryTransitionFixturesFailClosedWithTypedErrors() throws {
        let insert = try makeInsertTransition(counter: 179_051, dependencyCounter: 179_052)
        let expected = try transitionRecord(insert)
        let replacement = try replacementRecord(for: expected, dependencyCounter: 179_053)
        let replace = SyncBatchAnchoredRecoveryStoreTransition.replace(
            expected: expected,
            replacement: replacement
        )
        let remove = SyncBatchAnchoredRecoveryStoreTransition.removeCommitted(expected: expected)
        let other = try makeInsertTransition(counter: 179_054, dependencyCounter: 179_055)

        let malformedCases: [(String, Data, SyncConvergencePostCommitWorkPayloadError)] = [
            (
                "insertExpectedAbsent without replacement",
                try mutatedV2Data(transitions: [insert]) { transition in
                    transition.removeValue(forKey: "replacement")
                },
                .contradictoryAnchoredRecoveryTransition
            ),
            (
                "replace without expected",
                try mutatedV2Data(transitions: [replace]) { transition in
                    transition.removeValue(forKey: "expected")
                },
                .contradictoryAnchoredRecoveryTransition
            ),
            (
                "replace without replacement",
                try mutatedV2Data(transitions: [replace]) { transition in
                    transition.removeValue(forKey: "replacement")
                },
                .contradictoryAnchoredRecoveryTransition
            ),
            (
                "removeCommitted without expected",
                try mutatedV2Data(transitions: [remove]) { transition in
                    transition.removeValue(forKey: "expected")
                },
                .contradictoryAnchoredRecoveryTransition
            ),
            (
                "replace with mismatched replacement key/change",
                try mutatedV2Data(transitions: [replace]) { transition in
                    let otherObject = try recoveryTransitionJSONObject(other)
                    transition["replacement"] = otherObject["replacement"]
                },
                .contradictoryAnchoredRecoveryTransition
            ),
            (
                "duplicate valid keys",
                try duplicatedV2Data(transition: insert),
                .duplicateAnchoredRecoveryTransitionKeys
            )
        ]

        for testCase in malformedCases {
            XCTAssertThrowsError(
                try SyncConvergencePostCommitWorkPayloadV2.decodePayloadData(testCase.1),
                testCase.0
            ) { error in
                XCTAssertEqual(error as? SyncConvergencePostCommitWorkPayloadError, testCase.2, testCase.0)
            }
        }
    }

    private func configurePersistedAnchoredWork(
        fixture: MYR136Fixture,
        transition: SyncBatchAnchoredRecoveryStoreTransition
    ) throws -> SyncConvergencePostCommitRequest {
        let legacy = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [fixture.request.sourceBatchID],
            legacyCleanupRequired: false,
            presentationEntries: [
                workEntry(noteID: fixture.base.noteID, routing: .noteRemoved)
            ]
        )
        let workData = try SyncConvergenceVersionedPostCommitWorkPayload.encodedPayloadData(
            legacyWorkPayload: legacy,
            anchoredRecoveryTransitions: [transition]
        )
        let decoded = try SyncConvergenceVersionedPostCommitWorkPayload.decodePayloadData(workData)
        let state = decoded.derivedInitialState()
        let context = ModelContext(fixture.container)
        let root = try fixture.rawRoot(context: context)
        root.postCommitWorkPayloadData = workData
        root.postCommitStatePayloadData = try SyncConvergenceStableEncoding.encode(state)
        root.hasPendingPostCommitWork = state.hasPendingWork
        try context.save()

        return SyncConvergencePostCommitRequest(
            sourceBatchID: fixture.request.sourceBatchID,
            affectedNoteIDs: [fixture.base.noteID],
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: [fixture.request.sourceBatchID],
                retryQueueCleanup: true,
                retryLegacyCleanup: false,
                retryPresentationRefresh: true
            ),
            presentationPlan: SyncConvergencePresentationPlan(
                noteRoutings: [fixture.base.noteID: .noteRemoved]
            ),
            persistedIncorporationIdentity: fixture.request.persistedIncorporationIdentity
        )
    }

    private func makeInsertTransition(
        counter: UInt64,
        dependencyCounter: UInt64
    ) throws -> SyncBatchAnchoredRecoveryStoreTransition {
        let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
            state: .empty,
            offset: 0,
            text: "A",
            operationID: SyncBatchAnchoredRecoveryTestFactory.operation(counter)
        )
        let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
            change: change,
            dependency: .insertionAnchor(
                try SyncBatchAnchoredRecoveryTestFactory.element(
                    SyncBatchAnchoredRecoveryTestFactory.operation(dependencyCounter),
                    offset: 0
                )
            )
        )
        return .insertExpectedAbsent(record)
    }

    private func transitionRecord(
        _ transition: SyncBatchAnchoredRecoveryStoreTransition
    ) throws -> SyncBatchAnchoredRecoveryRecord {
        guard case .insertExpectedAbsent(let record) = transition else {
            throw MYR179PostCommitTestError.unexpectedTransition
        }
        return record
    }

    private func replacementRecord(
        for expected: SyncBatchAnchoredRecoveryRecord,
        dependencyCounter: UInt64
    ) throws -> SyncBatchAnchoredRecoveryRecord {
        try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
            change: expected.change,
            dependency: .insertionAnchor(
                try SyncBatchAnchoredRecoveryTestFactory.element(
                    SyncBatchAnchoredRecoveryTestFactory.operation(dependencyCounter),
                    offset: 0
                )
            )
        )
    }

    private func mutatedV2Data(
        transitions: [SyncBatchAnchoredRecoveryStoreTransition],
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let data = try validV2Data(transitions: transitions)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var transitionObjects = root["anchoredRecoveryTransitions"] as? [[String: Any]],
              !transitionObjects.isEmpty else {
            throw MYR179PostCommitTestError.invalidFixture
        }
        try mutate(&transitionObjects[0])
        root["anchoredRecoveryTransitions"] = transitionObjects
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func duplicatedV2Data(
        transition: SyncBatchAnchoredRecoveryStoreTransition
    ) throws -> Data {
        let data = try validV2Data(transitions: [transition])
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitionObjects = root["anchoredRecoveryTransitions"] as? [[String: Any]],
              let first = transitionObjects.first else {
            throw MYR179PostCommitTestError.invalidFixture
        }
        root["anchoredRecoveryTransitions"] = [first, first]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func recoveryTransitionJSONObject(
        _ transition: SyncBatchAnchoredRecoveryStoreTransition
    ) throws -> [String: Any] {
        let data = try validV2Data(transitions: [transition])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transitions = root["anchoredRecoveryTransitions"] as? [[String: Any]],
              let first = transitions.first else {
            throw MYR179PostCommitTestError.invalidFixture
        }
        return first
    }

    private func validV2Data(
        transitions: [SyncBatchAnchoredRecoveryStoreTransition]
    ) throws -> Data {
        try SyncConvergencePostCommitWorkPayloadV2(
            legacyWorkPayload: SyncConvergencePostCommitWorkPayloadV1(
                queueCleanupBatchIDs: [],
                legacyCleanupRequired: false,
                presentationEntries: []
            ),
            anchoredRecoveryTransitions: transitions
        ).encodedPayloadData()
    }

    private func temporaryRecoveryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("recovery.json")
    }
}

private enum MYR179PostCommitTestError: Error {
    case invalidFixture
    case unexpectedTransition
}

private final class MYR179PostCommitEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}

private final class MYR179RecordingRecoveryAdapter: SyncConvergenceAnchoredRecoveryAdapter {
    private let wrapped: FileBackedSyncBatchAnchoredRecoveryStore
    private let events: MYR179PostCommitEventRecorder

    init(
        wrapped: FileBackedSyncBatchAnchoredRecoveryStore,
        events: MYR179PostCommitEventRecorder
    ) {
        self.wrapped = wrapped
        self.events = events
    }

    func applyAnchoredRecoveryTransitions(
        _ transitions: [SyncBatchAnchoredRecoveryStoreTransition]
    ) -> SyncConvergencePostCommitAdapterResult {
        events.append("recovery")
        return wrapped.applyAnchoredRecoveryTransitions(transitions)
    }
}

private final class MYR179RecordingPresentationAdapter: SyncConvergencePresentationAdapter {
    private let events: MYR179PostCommitEventRecorder

    init(events: MYR179PostCommitEventRecorder) {
        self.events = events
    }

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        events.append("presentation")
        return .verifiedComplete
    }
}

private final class MYR179RecordingQueueCleanupAdapter: SyncConvergenceQueueCleanupAdapter {
    private let events: MYR179PostCommitEventRecorder

    init(events: MYR179PostCommitEventRecorder) {
        self.events = events
    }

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        events.append("queue")
    }

    func containsBatch(withID id: SyncBatchID) throws -> Bool {
        false
    }
}
