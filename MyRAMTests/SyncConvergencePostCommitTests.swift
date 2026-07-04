import XCTest
import SwiftData
import CryptoKit
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergencePostCommitTests: XCTestCase {
    func testThrowingQueueRemovalRemovesExactlyRequestedIDsAndPreservesOrder() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000001"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000002"))
        let third = batch(id: uuid("00000000-0000-0000-0000-000000000003"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)

        try queue.removeBatches(withIDs: [second.id])

        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, third])
    }

    func testThrowingQueueRemovalRestoresExactQueueOnPersistenceFailure() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000011"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000012"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)

        queue.injectPersistenceFailureForNextWrite()

        XCTAssertThrowsError(try queue.removeBatches(withIDs: [first.id])) { error in
            XCTAssertEqual(error as? FileBackedSyncBatchQueue.QueueError, .persistenceFailed)
        }
        XCTAssertEqual(queue.pendingBatches, [first, second])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
    }

    func testNonthrowingQueueRemovalPreservesPriorInMemoryFailureSemantics() throws {
        let fileURL = temporaryQueueURL()
        let first = batch(id: uuid("00000000-0000-0000-0000-000000000021"))
        let second = batch(id: uuid("00000000-0000-0000-0000-000000000022"))
        let queue = FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10)
        queue.enqueue(first)
        queue.enqueue(second)

        queue.injectPersistenceFailureForNextWrite()
        queue.removeAll(withIDs: [first.id])

        XCTAssertEqual(queue.pendingBatches, [second])
        XCTAssertEqual(FileBackedSyncBatchQueue(fileURL: fileURL, limit: 10).pendingBatches, [first, second])
    }

    func testCompletedPostCommitStateDoesNotCallAdaptersOrWrite() async {
        let identity = testIdentity()
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: .none)))
        let queue = FakeQueueCleanupAdapter()
        let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete)
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(legacy.callCount, 0)
        XCTAssertEqual(presentation.requests, [])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testQueueFailureDoesNotBlockPresentationProgress() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let queue = FakeQueueCleanupAdapter()
        queue.shouldThrowOnRemove = true
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup]))
        XCTAssertEqual(store.persistedState?.queueCleanupPending, true)
        XCTAssertEqual(store.persistedState?.presentationRefreshPending, false)
        XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA])
    }

    func testFakeStoreCASPreservesImmutableWorkPayloadAfterPartialClear() throws {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let original = fullRootState(identity: identity, state: state)
        let store = FakePostCommitStore(state: .fullRoot(original))
        let queueOnly = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )

        let loaded = try store.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: original.root),
            expectedPayloadData: original.postCommitStatePayloadData,
            newState: queueOnly
        )

        XCTAssertEqual(loaded.postCommitState, queueOnly)
        XCTAssertEqual(loaded.postCommitWorkPayloadData, original.postCommitWorkPayloadData)
        XCTAssertEqual(loaded.postCommitWorkPayload?.presentationEntries.count, 1)
        XCTAssertEqual(loaded.postCommitWorkPayload?.queueCleanupBatchIDs, [identity.batchID, TestIDs.extraBatch].sorted { $0.uuidString < $1.uuidString })
    }

    func testWorkPayloadAllowsClearedFlagsWithRetainedEvidence() throws {
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.batch],
            legacyCleanupRequired: false,
            presentationEntries: [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        )

        XCTAssertNoThrow(try payload.validateCurrentState(.none))
        XCTAssertNoThrow(try payload.validateCurrentState(SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )))
        XCTAssertThrowsError(try payload.validateCurrentState(SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: true,
            presentationRefreshPending: false
        )))
    }

    func testSwiftDataStoreReloadsAfterPartialAndFullClearWithRetainedWorkPayload() throws {
        let identity = testIdentity()
        let initialState = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let workPayload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [identity.batchID, TestIDs.extraBatch],
            legacyCleanupRequired: false,
            presentationEntries: [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        )
        let workPayloadData = try workPayload.encodedPayloadData()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let contextA = ModelContext(container)
        let committedAt = Date(timeIntervalSince1970: 2)
        let orderingPayload = try CommittedAtOrderingPayload(
            batchID: identity.batchID,
            committedAt: committedAt
        ).encodedEvidenceData()
        contextA.insert(IncorporatedSyncBatch(
            batchID: identity.batchID,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 1),
            batchSequence: 1,
            schemaVersion: 1,
            committedAt: committedAt,
            canonicalPayloadDigest: identity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
            committedResultDigest: identity.committedResultDigest,
            committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
            affectedNotesPayloadData: Data(),
            authoritativeChildCount: 0,
            authoritativeChildBytes: 0,
            authoritativeChildrenDigest: "children",
            postCommitWorkPayloadData: workPayloadData,
            postCommitStatePayloadData: try SyncConvergenceStableEncoding.encode(initialState)
        ))
        try contextA.save()

        let storeA = SwiftDataSyncConvergencePostCommitStore(context: contextA)
        guard case .fullRoot(let loadedA) = try storeA.loadState(matching: identity) else {
            return XCTFail("Expected full root")
        }
        XCTAssertEqual(loadedA.root.committedAtOrderingPayloadData, orderingPayload)
        let queueOnly = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
        let clearedPresentation = try storeA.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loadedA.root),
            expectedPayloadData: loadedA.postCommitStatePayloadData,
            newState: queueOnly
        )
        XCTAssertEqual(clearedPresentation.postCommitWorkPayloadData, workPayloadData)

        let storeB = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedB) = try storeB.loadState(matching: identity) else {
            return XCTFail("Expected partial-clear full root")
        }
        XCTAssertTrue(loadedB.postCommitState.queueCleanupPending)
        XCTAssertFalse(loadedB.postCommitState.presentationRefreshPending)
        XCTAssertEqual(loadedB.postCommitWorkPayload?.queueCleanupBatchIDs, [identity.batchID, TestIDs.extraBatch].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(loadedB.postCommitWorkPayload?.presentationEntries.count, 1)

        _ = try storeB.compareAndSetPostCommitState(
            expectedRoot: SyncConvergencePostCommitRootSnapshot(root: loadedB.root),
            expectedPayloadData: loadedB.postCommitStatePayloadData,
            newState: .none
        )
        let storeC = SwiftDataSyncConvergencePostCommitStore(context: ModelContext(container))
        guard case .fullRoot(let loadedC) = try storeC.loadState(matching: identity) else {
            return XCTFail("Expected completed full root")
        }
        XCTAssertEqual(loadedC.postCommitState, .none)
        XCTAssertEqual(loadedC.postCommitWorkPayloadData, workPayloadData)
    }

    func testLegacyTrueWithoutAdapterRemainsPending() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: true,
            presentationRefreshPending: false
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.legacyCleanup]))
        XCTAssertEqual(store.writeCount, 0)
    }

    func testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects() async {
        struct Case {
            let name: String
            let state: SyncConvergencePostCommitState
            let expectedOutcome: SyncConvergencePostCommitOutcome
            let expectedEvents: [PostCommitInvocationEvent]
            let expectedPersistedState: SyncConvergencePostCommitState?
        }

        let cases = [
            Case(
                name: "none pending",
                state: .none,
                expectedOutcome: .complete,
                expectedEvents: [],
                expectedPersistedState: nil
            ),
            Case(
                name: "queue only",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: false, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch])],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "legacy only",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.legacyCleanup(batchID: TestIDs.batch)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "presentation only",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: false, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "queue legacy",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: false),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch]), .legacyCleanup(batchID: TestIDs.batch)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "queue presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: false, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.queueCleanup([TestIDs.batch, TestIDs.extraBatch]), .presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "legacy presentation",
                state: SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [.legacyCleanup(batchID: TestIDs.batch), .presentation(noteID: TestIDs.noteA)],
                expectedPersistedState: SyncConvergencePostCommitState.none
            ),
            Case(
                name: "all pending",
                state: SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                expectedOutcome: .complete,
                expectedEvents: [
                    .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
                    .legacyCleanup(batchID: TestIDs.batch),
                    .presentation(noteID: TestIDs.noteA)
                ],
                expectedPersistedState: SyncConvergencePostCommitState.none
            )
        ]

        for testCase in cases {
            let identity = testIdentity()
            let persistedEntry = workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)
            let committedNote = note(id: TestIDs.noteA, title: "Matrix", body: "post")
            let store = FakePostCommitStore(
                state: .fullRoot(fullRootState(
                    identity: identity,
                    state: testCase.state,
                    presentationEntries: testCase.state.presentationRefreshPending ? [persistedEntry] : []
                ))
            )
            store.notes[TestIDs.noteA] = committedNote
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                legacyCleanupAdapter: legacy,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: testCase.state))

            XCTAssertEqual(outcome, testCase.expectedOutcome, testCase.name)
            XCTAssertEqual(recorder.events, testCase.expectedEvents, testCase.name)
            XCTAssertEqual(queue.removals, testCase.state.queueCleanupPending ? [[TestIDs.batch, TestIDs.extraBatch]] : [], testCase.name)
            XCTAssertEqual(legacy.requests.map(\.sourceBatchID), testCase.state.legacyCleanupPending ? [TestIDs.batch] : [], testCase.name)
            XCTAssertEqual(
                presentation.requests,
                testCase.state.presentationRefreshPending
                    ? [expectedPresentationRequest(identity: identity, entry: persistedEntry, committedNote: committedNote)]
                    : [],
                testCase.name
            )
            XCTAssertEqual(store.persistedState, testCase.expectedPersistedState, testCase.name)
            XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData, testCase.name)
            XCTAssertEqual(store.writeCount, testCase.expectedPersistedState == nil ? 0 : 1, testCase.name)
        }
    }

    func testEightPendingStateMatrixWithoutLegacyAdapterLeavesLegacyPending() async {
        let states: [(SyncConvergencePostCommitState, SyncConvergencePostCommitState?)] = [
            (
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false),
                nil
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: false),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            ),
            (
                SyncConvergencePostCommitState(queueCleanupPending: true, legacyCleanupPending: true, presentationRefreshPending: true),
                SyncConvergencePostCommitState(queueCleanupPending: false, legacyCleanupPending: true, presentationRefreshPending: false)
            )
        ]

        for (state, expectedPersistedState) in states {
            let identity = testIdentity()
            let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
            let recorder = PostCommitInvocationRecorder()
            let queue = FakeQueueCleanupAdapter(recorder: recorder)
            let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
            let executor = SyncConvergencePostCommitExecutor(
                store: store,
                queueCleanupAdapter: queue,
                presentationAdapter: presentation
            )

            let outcome = await executor.execute(request(identity: identity, state: state))

            XCTAssertEqual(outcome, .pending([.legacyCleanup]))
            var expectedEvents: [PostCommitInvocationEvent] = []
            if state.queueCleanupPending {
                expectedEvents.append(.queueCleanup([TestIDs.batch, TestIDs.extraBatch]))
            }
            if state.presentationRefreshPending {
                expectedEvents.append(.presentation(noteID: TestIDs.noteA))
            }
            XCTAssertEqual(recorder.events, expectedEvents)
            XCTAssertEqual(store.persistedState, expectedPersistedState)
            XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData)
            XCTAssertEqual(store.writeCount, expectedPersistedState == nil ? 0 : 1)
        }
    }

    func testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: true,
            presentationRefreshPending: true
        )
        let committedNote = note(id: TestIDs.noteA, title: "Retry", body: "Body")
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        store.notes[TestIDs.noteA] = committedNote
        store.shouldFailCAS = true
        let recorder = PostCommitInvocationRecorder()
        let queue = FakeQueueCleanupAdapter(recorder: recorder)
        let legacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: recorder)
        let presentation = FakePresentationAdapter(result: .verifiedComplete, recorder: recorder)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            legacyCleanupAdapter: legacy,
            presentationAdapter: presentation
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .pending([.queueCleanup, .legacyCleanup, .presentationRefresh, .postCommitStatePersistence]))
        XCTAssertEqual(recorder.events, [
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
            .legacyCleanup(batchID: TestIDs.batch),
            .presentation(noteID: TestIDs.noteA)
        ])
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.persistedState, nil)
        XCTAssertEqual(store.currentPostCommitState, state)
        XCTAssertEqual(store.currentWorkPayloadData, store.originalWorkPayloadData)

        guard case .fullRoot(let persistedRoot) = store.state else {
            return XCTFail("Expected failed-CAS store to retain full root")
        }
        let persistedStateBytes = Data(persistedRoot.root.postCommitStatePayloadData)
        let persistedWorkBytes = Data(try! XCTUnwrap(persistedRoot.root.postCommitWorkPayloadData))
        let retryStore = try! FakePostCommitStore(
            reloading: persistedRoot.root,
            notes: [TestIDs.noteA: committedNote]
        )
        XCTAssertEqual(retryStore.currentPostCommitState, state)
        XCTAssertEqual(retryStore.currentWorkPayloadData, persistedWorkBytes)
        guard case .fullRoot(let reloadedRoot) = retryStore.state else {
            return XCTFail("Expected reloaded retry store to contain a full root")
        }
        XCTAssertEqual(reloadedRoot.postCommitStatePayloadData, persistedStateBytes)
        XCTAssertEqual(reloadedRoot.postCommitWorkPayloadData, persistedWorkBytes)
        let retryRecorder = PostCommitInvocationRecorder()
        let retryQueue = FakeQueueCleanupAdapter(recorder: retryRecorder)
        let retryLegacy = FakeLegacyCleanupAdapter(result: .verifiedComplete, recorder: retryRecorder)
        let retryPresentation = FakePresentationAdapter(result: .verifiedComplete, recorder: retryRecorder)
        let retryExecutor = SyncConvergencePostCommitExecutor(
            store: retryStore,
            queueCleanupAdapter: retryQueue,
            legacyCleanupAdapter: retryLegacy,
            presentationAdapter: retryPresentation
        )

        let retryOutcome = await retryExecutor.execute(request(identity: identity, state: state))

        XCTAssertEqual(retryOutcome, .complete)
        XCTAssertEqual(retryRecorder.events, [
            .queueCleanup([TestIDs.batch, TestIDs.extraBatch]),
            .legacyCleanup(batchID: TestIDs.batch),
            .presentation(noteID: TestIDs.noteA)
        ])
        XCTAssertEqual(retryStore.persistedState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.currentPostCommitState, Optional(SyncConvergencePostCommitState.none))
        XCTAssertEqual(retryStore.writeCount, 1)
        XCTAssertEqual(retryStore.currentWorkPayloadData, retryStore.originalWorkPayloadData)
    }

    func testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let entries = [
            workEntry(noteID: TestIDs.noteB, routing: .wholeNoteFallback, postHash: SyncBatchContentHash.sha256Hex(for: "body-b")),
            workEntry(noteID: TestIDs.noteA, routing: .incremental, postHash: SyncBatchContentHash.sha256Hex(for: "body-a"))
        ]
        let incrementalEntry = entries[1]
        let fallbackEntry = entries[0]
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, presentationEntries: entries)))
        let noteA = note(id: TestIDs.noteA, title: "A", body: "body-a")
        let noteB = note(id: TestIDs.noteB, title: "B", body: "body-b")
        store.notes[TestIDs.noteA] = noteA
        store.notes[TestIDs.noteB] = noteB
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: presentation
        )

        let plan = SyncConvergencePresentationPlan(noteRoutings: [
            TestIDs.noteB: .wholeNoteFallback,
            TestIDs.noteA: .incremental
        ])
        let outcome = await executor.execute(request(identity: identity, state: state, presentationPlan: plan))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(presentation.requests, [
            expectedPresentationRequest(identity: identity, entry: incrementalEntry, committedNote: noteA),
            expectedPresentationRequest(identity: identity, entry: fallbackEntry, committedNote: noteB)
        ])
    }

    func testCallerPlansCannotSuppressPersistedQueueOrPresentationWork() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let entries = [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)]
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, presentationEntries: entries)))
        let queue = FakeQueueCleanupAdapter()
        let presentation = FakePresentationAdapter(result: .verifiedComplete)
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: presentation
        )

        let emptyCallerRequest = SyncConvergencePostCommitRequest(
            sourceBatchID: identity.batchID,
            affectedNoteIDs: [],
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: [],
                retryQueueCleanup: false,
                retryLegacyCleanup: false,
                retryPresentationRefresh: false
            ),
            presentationPlan: SyncConvergencePresentationPlan(noteRoutings: [:]),
            persistedIncorporationIdentity: identity
        )
        let outcome = await executor.execute(emptyCallerRequest)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [[identity.batchID, TestIDs.extraBatch]])
        XCTAssertEqual(presentation.requests.map(\.noteID), [TestIDs.noteA])
    }

    func testTombstoneCleanupRemovesOnlyVerifiedSourceBatchID() async {
        let identity = testIdentity()
        let store = FakePostCommitStore(state: .tombstone(tombstone(identity: identity)))
        let queue = FakeQueueCleanupAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity))

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(queue.removals, [[identity.batchID]])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testPrePayloadPendingRootFailsClosedBeforeAdapters() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: false
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state, includeWorkPayload: false)))
        let queue = FakeQueueCleanupAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: queue,
            presentationAdapter: FakePresentationAdapter(result: .verifiedComplete)
        )

        let outcome = await executor.execute(request(identity: identity, state: state))

        XCTAssertEqual(outcome, .failedBeforeWork(.missingPostCommitWorkPayload(batchID: identity.batchID)))
        XCTAssertEqual(queue.removals, [])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testSameExecutorInstanceSerializesOverlappingRuns() async {
        let identity = testIdentity()
        let state = SyncConvergencePostCommitState(
            queueCleanupPending: false,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        )
        let store = FakePostCommitStore(state: .fullRoot(fullRootState(identity: identity, state: state)))
        let presentation = TrackingPresentationAdapter()
        let executor = SyncConvergencePostCommitExecutor(
            store: store,
            queueCleanupAdapter: FakeQueueCleanupAdapter(),
            presentationAdapter: presentation
        )

        async let first = executor.execute(request(identity: identity, state: state))
        async let second = executor.execute(request(identity: identity, state: state))
        let outcomes = await [first, second]
        let requestCount = await presentation.requestCount()
        let maximumConcurrentRequests = await presentation.maximumConcurrentRequests()

        XCTAssertEqual(outcomes, [.complete, .complete])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(maximumConcurrentRequests, 1)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testPostCommitPayloadRejectsMalformedOperationIdentity() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "post")
        let operation = incrementalOperation(noteID: TestIDs.noteA, resultHash: postHash)
        let malformedIdentity = OperationIdentityPayload(
            version: OperationIdentityPayload.supportedVersion + 1,
            batchID: TestIDs.batch,
            originDeviceID: TestIDs.device,
            operationIndex: operation.operationIndex,
            operationKind: operation.kind.rawValue,
            canonicalReplayKey: operation.operationIdentity.canonicalReplayKey
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [
                        SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
                            noteID: operation.noteID,
                            operationIndex: operation.operationIndex,
                            kind: operation.kind,
                            utf16Offset: operation.utf16Offset,
                            utf16Length: operation.utf16Length,
                            text: operation.text,
                            expectedText: operation.expectedText,
                            baseContentHash: operation.baseContentHash,
                            resultContentHash: operation.resultContentHash,
                            operationIdentity: malformedIdentity
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsOperationHashChainMismatch() {
        let firstHash = SyncBatchContentHash.sha256Hex(for: "first")
        let finalHash = SyncBatchContentHash.sha256Hex(for: "final")
        let wrongBaseHash = SyncBatchContentHash.sha256Hex(for: "wrong")
        let first = incrementalOperation(noteID: TestIDs.noteA, resultHash: firstHash)
        let secondIdentity = OperationIdentityPayload(
            batchID: TestIDs.batch,
            originDeviceID: TestIDs.device,
            operationIndex: 1,
            operationKind: "insert",
            canonicalReplayKey: CanonicalReplayKeyPayload(
                modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 4)),
                originDeviceIDLowercase: TestIDs.device.uuidString.lowercased(),
                batchOrderKind: .legacy,
                legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 1)),
                sequence: nil,
                batchIDLowercase: TestIDs.batch.uuidString.lowercased(),
                operationIndex: 1
            )
        )
        let second = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: TestIDs.noteA,
            operationIndex: 1,
            kind: .insert,
            utf16Offset: 1,
            utf16Length: nil,
            text: "y",
            expectedText: nil,
            baseContentHash: wrongBaseHash,
            resultContentHash: finalHash,
            operationIdentity: secondIdentity
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: finalHash,
                    incrementalOperations: [first, second]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsMissingFirstBaseHashWhenExpectedPreHashExists() {
        let expectedPreHash = SyncBatchContentHash.sha256Hex(for: "A")
        let postHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let operation = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: nil,
            resultHash: postHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: expectedPreHash,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [operation]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadRejectsMissingIntermediateBaseHash() {
        let firstHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let finalHash = SyncBatchContentHash.sha256Hex(for: "ABC")
        let first = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: SyncBatchContentHash.sha256Hex(for: "A"),
            resultHash: firstHash
        )
        let second = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 1,
            utf16Offset: 2,
            text: "C",
            baseHash: nil,
            resultHash: finalHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "A"),
                    committedPostBodyHash: finalHash,
                    incrementalOperations: [first, second]
                )
            ]
        )

        XCTAssertThrowsError(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadAllowsMissingExpectedPreHashAndMissingFirstBaseHash() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "AB")
        let operation = incrementalOperation(
            noteID: TestIDs.noteA,
            operationIndex: 0,
            utf16Offset: 1,
            text: "B",
            baseHash: nil,
            resultHash: postHash
        )
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [],
            legacyCleanupRequired: false,
            presentationEntries: [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [operation]
                )
            ]
        )

        XCTAssertNoThrow(try payload.encodedPayloadData())
    }

    func testPostCommitPayloadValidationMatrixRejectsContradictoryPresentationEntries() {
        let postHash = SyncBatchContentHash.sha256Hex(for: "post")
        let base = incrementalOperation(noteID: TestIDs.noteA, resultHash: postHash)
        let wrongNote = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: TestIDs.noteB,
            operationIndex: base.operationIndex,
            kind: base.kind,
            utf16Offset: base.utf16Offset,
            utf16Length: base.utf16Length,
            text: base.text,
            expectedText: base.expectedText,
            baseContentHash: base.baseContentHash,
            resultContentHash: base.resultContentHash,
            operationIdentity: base.operationIdentity
        )
        let wrongKindIdentity = SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: base.noteID,
            operationIndex: base.operationIndex,
            kind: .delete,
            utf16Offset: base.utf16Offset,
            utf16Length: 1,
            text: nil,
            expectedText: "x",
            baseContentHash: base.baseContentHash,
            resultContentHash: base.resultContentHash,
            operationIdentity: base.operationIdentity
        )
        let cases: [(String, [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry])] = [
            ("incremental without executable operation", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: []
                )
            ]),
            ("whole note fallback with incremental operation", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .wholeNoteFallback,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [base]
                )
            ]),
            ("operation note differs from entry note", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [wrongNote]
                )
            ]),
            ("operation kind differs from identity kind", [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: nil,
                    committedPostBodyHash: postHash,
                    incrementalOperations: [wrongKindIdentity]
                )
            ]),
            ("duplicate presentation note", [
                workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback),
                workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)
            ])
        ]

        for testCase in cases {
            let payload = SyncConvergencePostCommitWorkPayloadV1(
                queueCleanupBatchIDs: [],
                legacyCleanupRequired: false,
                presentationEntries: testCase.1
            )

            XCTAssertThrowsError(try payload.encodedPayloadData(), testCase.0)
        }
    }

    func testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding() throws {
        let payload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: [TestIDs.extraBatch, TestIDs.batch],
            legacyCleanupRequired: true,
            presentationEntries: [
                workEntry(
                    noteID: TestIDs.noteB,
                    routing: .wholeNoteFallback,
                    postHash: SyncBatchContentHash.sha256Hex(for: "whole-note-final")
                ),
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .incremental,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "A"),
                    committedPostBodyHash: SyncBatchContentHash.sha256Hex(for: "ABC"),
                    incrementalOperations: [
                        incrementalOperation(
                            noteID: TestIDs.noteA,
                            operationIndex: 0,
                            utf16Offset: 1,
                            text: "B",
                            baseHash: SyncBatchContentHash.sha256Hex(for: "A"),
                            resultHash: SyncBatchContentHash.sha256Hex(for: "AB")
                        ),
                        incrementalOperation(
                            noteID: TestIDs.noteA,
                            operationIndex: 1,
                            utf16Offset: 2,
                            text: "C",
                            baseHash: SyncBatchContentHash.sha256Hex(for: "AB"),
                            resultHash: SyncBatchContentHash.sha256Hex(for: "ABC")
                        )
                    ]
                )
            ]
        )

        let data = try payload.encodedPayloadData()
        XCTAssertEqual(sha256Hex(data), "9cd2489d7c1338e54c0db95eabf20e5a98c8fefc872e4b02665ce3a678e1e3e5")
        let decoded = try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData(data)
        XCTAssertEqual(decoded.queueCleanupBatchIDs, [TestIDs.batch, TestIDs.extraBatch])
        XCTAssertEqual(decoded.presentationEntries.map(\.noteID), [TestIDs.noteA, TestIDs.noteB])
        let incrementalEntry = decoded.presentationEntries[0]
        let fallbackEntry = decoded.presentationEntries[1]
        XCTAssertEqual(incrementalEntry.routing, .incremental)
        XCTAssertEqual(incrementalEntry.expectedPreBodyHash, SyncBatchContentHash.sha256Hex(for: "A"))
        XCTAssertEqual(incrementalEntry.committedPostBodyHash, SyncBatchContentHash.sha256Hex(for: "ABC"))
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIndex), [0, 1])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.utf16Offset), [1, 2])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.text), ["B", "C"])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.baseContentHash), [
            SyncBatchContentHash.sha256Hex(for: "A"),
            SyncBatchContentHash.sha256Hex(for: "AB")
        ])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.resultContentHash), [
            SyncBatchContentHash.sha256Hex(for: "AB"),
            SyncBatchContentHash.sha256Hex(for: "ABC")
        ])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIdentity.operationIndex), [0, 1])
        XCTAssertEqual(incrementalEntry.incrementalOperations.map(\.operationIdentity.canonicalReplayKey.operationIndex), [0, 1])
        var replayedBody = "A"
        for operation in incrementalEntry.incrementalOperations {
            let index = String.Index(utf16Offset: operation.utf16Offset, in: replayedBody)
            replayedBody.insert(contentsOf: operation.text ?? "", at: index)
        }
        XCTAssertEqual(replayedBody, "ABC")
        XCTAssertEqual(SyncBatchContentHash.sha256Hex(for: replayedBody), incrementalEntry.committedPostBodyHash)
        XCTAssertEqual(fallbackEntry.routing, .wholeNoteFallback)
        XCTAssertEqual(fallbackEntry.incrementalOperations, [])
    }

    func testBodyHashCapabilityRemainsDisabled() {
        XCTAssertFalse(SyncBatchBodyHashCapability.defaultEnabled)
    }

    private func request(
        identity: SyncConvergencePersistedIncorporationIdentity,
        state: SyncConvergencePostCommitState = SyncConvergencePostCommitState(
            queueCleanupPending: true,
            legacyCleanupPending: false,
            presentationRefreshPending: true
        ),
        presentationPlan: SyncConvergencePresentationPlan = SyncConvergencePresentationPlan(noteRoutings: [
            TestIDs.noteA: .wholeNoteFallback
        ])
    ) -> SyncConvergencePostCommitRequest {
        SyncConvergencePostCommitRequest(
            sourceBatchID: identity.batchID,
            affectedNoteIDs: [TestIDs.noteA],
            cleanupPlan: SyncConvergenceCleanupPlan(
                batchIDs: [identity.batchID, TestIDs.extraBatch],
                retryQueueCleanup: state.queueCleanupPending,
                retryLegacyCleanup: state.legacyCleanupPending,
                retryPresentationRefresh: state.presentationRefreshPending
            ),
            presentationPlan: presentationPlan,
            persistedIncorporationIdentity: identity
        )
    }

    private func testIdentity() -> SyncConvergencePersistedIncorporationIdentity {
        SyncConvergencePersistedIncorporationIdentity(
            batchID: TestIDs.batch,
            canonicalPayloadDigest: "canonical",
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: "committed",
            committedResultDigestFormatVersion: 1
        )
    }

    private func fullRootState(
        identity: SyncConvergencePersistedIncorporationIdentity,
        state: SyncConvergencePostCommitState,
        presentationEntries: [SyncConvergencePostCommitWorkPayloadV1.PresentationEntry]? = nil,
        includeWorkPayload: Bool = true
    ) -> SyncConvergencePostCommitFullRootState {
        let payload = try! SyncConvergenceStableEncoding.encode(state)
        let workPayload = includeWorkPayload ? SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: state.queueCleanupPending ? [identity.batchID, TestIDs.extraBatch] : [],
            legacyCleanupRequired: state.legacyCleanupPending,
            presentationEntries: presentationEntries ?? (state.presentationRefreshPending ? [workEntry(noteID: TestIDs.noteA, routing: .wholeNoteFallback)] : [])
        ) : nil
        let workPayloadData = try! workPayload?.encodedPayloadData()
        return SyncConvergencePostCommitFullRootState(
            root: SyncConvergenceIncorporatedRootProjection(
                batchID: identity.batchID,
                originDeviceID: TestIDs.device,
                createdAt: Date(timeIntervalSince1970: 1),
                batchSequence: 1,
                schemaVersion: 1,
                committedAt: Date(timeIntervalSince1970: 2),
                canonicalPayloadDigest: identity.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
                committedResultDigest: identity.committedResultDigest,
                committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
                committedAtOrderingPayloadData: Data(),
                affectedNotesPayloadData: Data(),
                authoritativeChildCount: 0,
                authoritativeChildBytes: 0,
                authoritativeChildrenDigest: "children",
                postCommitWorkPayloadData: workPayloadData,
                postCommitStatePayloadData: payload
            ),
            postCommitState: state,
            postCommitStatePayloadData: payload,
            postCommitWorkPayload: workPayload,
            postCommitWorkPayloadData: workPayloadData
        )
    }

    private func workEntry(
        noteID: UUID,
        routing: SyncConvergencePostCommitPresentationRoutingPayload,
        postHash: String = SyncBatchContentHash.sha256Hex(for: "post")
    ) -> SyncConvergencePostCommitWorkPayloadV1.PresentationEntry {
        SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
            noteID: noteID,
            routing: routing,
            expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
            committedPostBodyHash: postHash,
            incrementalOperations: routing == .incremental ? [incrementalOperation(noteID: noteID, resultHash: postHash)] : []
        )
    }

    private func expectedPresentationRequest(
        identity: SyncConvergencePersistedIncorporationIdentity,
        entry: SyncConvergencePostCommitWorkPayloadV1.PresentationEntry,
        committedNote: SyncConvergenceMutableNoteRecord
    ) -> SyncConvergencePresentationRequest {
        SyncConvergencePresentationRequest(
            incorporationIdentity: identity,
            noteID: entry.noteID,
            routing: entry.routing.routing,
            expectedPreBodyHash: entry.expectedPreBodyHash,
            committedPostBodyHash: entry.committedPostBodyHash,
            incrementalOperations: entry.incrementalOperations,
            committedNote: committedNote,
            committedBodyHash: SyncBatchContentHash.sha256Hex(for: committedNote.body),
            committedTitle: committedNote.title
        )
    }

    private func incrementalOperation(
        noteID: UUID,
        resultHash: String
    ) -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
        incrementalOperation(
            noteID: noteID,
            operationIndex: 0,
            utf16Offset: 0,
            text: "x",
            baseHash: SyncBatchContentHash.sha256Hex(for: "pre"),
            resultHash: resultHash
        )
    }

    private func incrementalOperation(
        noteID: UUID,
        operationIndex: Int,
        utf16Offset: Int,
        text: String,
        baseHash: String?,
        resultHash: String
    ) -> SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
        SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: noteID,
            operationIndex: operationIndex,
            kind: .insert,
            utf16Offset: utf16Offset,
            utf16Length: nil,
            text: text,
            expectedText: nil,
            baseContentHash: baseHash,
            resultContentHash: resultHash,
            operationIdentity: OperationIdentityPayload(
                batchID: TestIDs.batch,
                originDeviceID: TestIDs.device,
                operationIndex: operationIndex,
                operationKind: "insert",
                canonicalReplayKey: CanonicalReplayKeyPayload(
                    modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 3)),
                    originDeviceIDLowercase: TestIDs.device.uuidString.lowercased(),
                    batchOrderKind: .legacy,
                    legacyCreatedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 1)),
                    sequence: nil,
                    batchIDLowercase: TestIDs.batch.uuidString.lowercased(),
                    operationIndex: operationIndex
                )
            )
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func tombstone(
        identity: SyncConvergencePersistedIncorporationIdentity
    ) -> SyncConvergenceIncorporatedTombstoneProjection {
        SyncConvergenceIncorporatedTombstoneProjection(
            batchID: identity.batchID,
            originDeviceID: TestIDs.device,
            canonicalPayloadDigest: identity.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
            schemaVersion: 1,
            committedResultDigest: identity.committedResultDigest,
            committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: Data(),
            tombstoneFormatVersion: 1
        )
    }

    private func note(id: UUID, title: String, body: String) -> SyncConvergenceMutableNoteRecord {
        SyncConvergenceMutableNoteRecord(
            noteID: id,
            folderID: nil,
            title: title,
            body: body,
            createdAt: Date(timeIntervalSince1970: 3),
            modifiedAt: Date(timeIntervalSince1970: 4)
        )
    }

    private func batch(id: UUID) -> SyncBatch {
        SyncBatch(
            id: id,
            originDeviceID: TestIDs.device,
            createdAt: Date(timeIntervalSince1970: 5),
            batchSequence: nil,
            changes: []
        )
    }

    private func temporaryQueueURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("queue.json")
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private enum TestIDs {
    static let batch = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let extraBatch = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    static let device = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    static let noteA = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    static let noteB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
}

private enum PostCommitInvocationEvent: Equatable {
    case queueCleanup([UUID])
    case legacyCleanup(batchID: UUID)
    case presentation(noteID: UUID)
}

private final class PostCommitInvocationRecorder {
    private let lock = NSLock()
    private var recordedEvents: [PostCommitInvocationEvent] = []

    var events: [PostCommitInvocationEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: PostCommitInvocationEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}

private final class FakePostCommitStore: SyncConvergencePostCommitStateStore {
    var state: SyncConvergencePostCommitLoadedState
    var notes: [UUID: SyncConvergenceMutableNoteRecord] = [:]
    var persistedState: SyncConvergencePostCommitState?
    var writeCount = 0
    var shouldFailCAS = false
    let originalWorkPayloadData: Data?

    init(state: SyncConvergencePostCommitLoadedState) {
        self.state = state
        if case .fullRoot(let root) = state {
            originalWorkPayloadData = root.postCommitWorkPayloadData
        } else {
            originalWorkPayloadData = nil
        }
        notes[TestIDs.noteA] = SyncConvergenceMutableNoteRecord(
            noteID: TestIDs.noteA,
            folderID: nil,
            title: "Title",
            body: "Body",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
    }

    convenience init(
        reloading root: SyncConvergenceIncorporatedRootProjection,
        notes: [UUID: SyncConvergenceMutableNoteRecord]
    ) throws {
        let statePayloadData = Data(root.postCommitStatePayloadData)
        let workPayloadData = root.postCommitWorkPayloadData.map { Data($0) }
        let state = try SyncConvergenceStableEncoding.decode(
            SyncConvergencePostCommitState.self,
            from: statePayloadData
        )
        let work = try workPayloadData.map {
            try SyncConvergencePostCommitWorkPayloadV1.decodePayloadData($0)
        }
        let loaded = SyncConvergencePostCommitFullRootState(
            root: root,
            postCommitState: state,
            postCommitStatePayloadData: statePayloadData,
            postCommitWorkPayload: work,
            postCommitWorkPayloadData: workPayloadData
        )

        self.init(state: .fullRoot(loaded))
        self.notes = notes
    }

    func loadState(
        matching identity: SyncConvergencePersistedIncorporationIdentity
    ) throws -> SyncConvergencePostCommitLoadedState {
        state
    }

    func loadCommittedNote(id: UUID) throws -> SyncConvergenceMutableNoteRecord? {
        notes[id]
    }

    func compareAndSetPostCommitState(
        expectedRoot: SyncConvergencePostCommitRootSnapshot,
        expectedPayloadData: Data,
        newState: SyncConvergencePostCommitState
    ) throws -> SyncConvergencePostCommitFullRootState {
        writeCount += 1
        if shouldFailCAS {
            throw SyncConvergencePostCommitFailure.persistence
        }
        guard case .fullRoot(let current) = state,
              current.root == expectedRoot.root,
              current.postCommitStatePayloadData == expectedPayloadData else {
            throw SyncConvergencePostCommitFailure.inconsistentIncorporationIdentity(batchID: expectedRoot.root.batchID)
        }
        persistedState = newState
        let payload = try SyncConvergenceStableEncoding.encode(newState)
        let root = SyncConvergenceIncorporatedRootProjection(
            batchID: current.root.batchID,
            originDeviceID: current.root.originDeviceID,
            createdAt: current.root.createdAt,
            batchSequence: current.root.batchSequence,
            schemaVersion: current.root.schemaVersion,
            committedAt: current.root.committedAt,
            canonicalPayloadDigest: current.root.canonicalPayloadDigest,
            canonicalPayloadDigestFormatVersion: current.root.canonicalPayloadDigestFormatVersion,
            committedResultDigest: current.root.committedResultDigest,
            committedResultDigestFormatVersion: current.root.committedResultDigestFormatVersion,
            committedAtOrderingPayloadData: current.root.committedAtOrderingPayloadData,
            affectedNotesPayloadData: current.root.affectedNotesPayloadData,
            authoritativeChildCount: current.root.authoritativeChildCount,
            authoritativeChildBytes: current.root.authoritativeChildBytes,
            authoritativeChildrenDigest: current.root.authoritativeChildrenDigest,
            postCommitWorkPayloadData: current.root.postCommitWorkPayloadData,
            postCommitStatePayloadData: payload
        )
        let loaded = SyncConvergencePostCommitFullRootState(
            root: root,
            postCommitState: newState,
            postCommitStatePayloadData: payload,
            postCommitWorkPayload: current.postCommitWorkPayload,
            postCommitWorkPayloadData: current.postCommitWorkPayloadData
        )
        state = .fullRoot(loaded)
        return loaded
    }

    var currentPostCommitState: SyncConvergencePostCommitState? {
        guard case .fullRoot(let current) = state else { return nil }
        return current.postCommitState
    }

    var currentWorkPayloadData: Data? {
        guard case .fullRoot(let current) = state else { return nil }
        return current.postCommitWorkPayloadData
    }

    private func makeFullRootState(
        identity: SyncConvergencePersistedIncorporationIdentity,
        state: SyncConvergencePostCommitState
    ) -> SyncConvergencePostCommitFullRootState {
        let payload = try! SyncConvergenceStableEncoding.encode(state)
        let workPayload = SyncConvergencePostCommitWorkPayloadV1(
            queueCleanupBatchIDs: state.queueCleanupPending ? [identity.batchID, TestIDs.extraBatch] : [],
            legacyCleanupRequired: state.legacyCleanupPending,
            presentationEntries: state.presentationRefreshPending ? [
                SyncConvergencePostCommitWorkPayloadV1.PresentationEntry(
                    noteID: TestIDs.noteA,
                    routing: .wholeNoteFallback,
                    expectedPreBodyHash: SyncBatchContentHash.sha256Hex(for: "pre"),
                    committedPostBodyHash: SyncBatchContentHash.sha256Hex(for: "post"),
                    incrementalOperations: []
                )
            ] : []
        )
        let workPayloadData = try! workPayload.encodedPayloadData()
        return SyncConvergencePostCommitFullRootState(
            root: SyncConvergenceIncorporatedRootProjection(
                batchID: identity.batchID,
                originDeviceID: TestIDs.device,
                createdAt: Date(timeIntervalSince1970: 1),
                batchSequence: 1,
                schemaVersion: 1,
                committedAt: Date(timeIntervalSince1970: 2),
                canonicalPayloadDigest: identity.canonicalPayloadDigest,
                canonicalPayloadDigestFormatVersion: identity.canonicalPayloadDigestFormatVersion,
                committedResultDigest: identity.committedResultDigest,
                committedResultDigestFormatVersion: identity.committedResultDigestFormatVersion,
                committedAtOrderingPayloadData: Data(),
                affectedNotesPayloadData: Data(),
                authoritativeChildCount: 0,
                authoritativeChildBytes: 0,
                authoritativeChildrenDigest: "children",
                postCommitWorkPayloadData: workPayloadData,
                postCommitStatePayloadData: payload
            ),
            postCommitState: state,
            postCommitStatePayloadData: payload,
            postCommitWorkPayload: workPayload,
            postCommitWorkPayloadData: workPayloadData
        )
    }
}

private final class FakeQueueCleanupAdapter: SyncConvergenceQueueCleanupAdapter {
    var removals: [Set<SyncBatchID>] = []
    var remaining: Set<SyncBatchID> = []
    var shouldThrowOnRemove = false
    private let recorder: PostCommitInvocationRecorder?

    init(recorder: PostCommitInvocationRecorder? = nil) {
        self.recorder = recorder
    }

    func removeBatches(withIDs ids: Set<SyncBatchID>) throws {
        if shouldThrowOnRemove {
            throw FileBackedSyncBatchQueue.QueueError.persistenceFailed
        }
        removals.append(ids)
        recorder?.record(.queueCleanup(ids.sorted { $0.uuidString < $1.uuidString }))
        remaining.subtract(ids)
    }

    func containsBatch(withID id: SyncBatchID) throws -> Bool {
        remaining.contains(id)
    }
}

private final class FakeLegacyCleanupAdapter: SyncConvergenceLegacyCleanupAdapter {
    let result: SyncConvergencePostCommitAdapterResult
    var requests: [SyncConvergencePostCommitRequest] = []
    private let recorder: PostCommitInvocationRecorder?

    var callCount: Int {
        requests.count
    }

    init(result: SyncConvergencePostCommitAdapterResult, recorder: PostCommitInvocationRecorder? = nil) {
        self.result = result
        self.recorder = recorder
    }

    func performLegacyCleanup(
        for request: SyncConvergencePostCommitRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        requests.append(request)
        recorder?.record(.legacyCleanup(batchID: request.sourceBatchID))
        return result
    }
}

private final class FakePresentationAdapter: SyncConvergencePresentationAdapter {
    let result: SyncConvergencePostCommitAdapterResult
    var requests: [SyncConvergencePresentationRequest] = []
    private let recorder: PostCommitInvocationRecorder?

    init(result: SyncConvergencePostCommitAdapterResult, recorder: PostCommitInvocationRecorder? = nil) {
        self.result = result
        self.recorder = recorder
    }

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        requests.append(request)
        recorder?.record(.presentation(noteID: request.noteID))
        return result
    }
}

private actor TrackingPresentationAdapter: SyncConvergencePresentationAdapter {
    private var requests: [SyncConvergencePresentationRequest] = []
    private var activeCount = 0
    private var maxActiveCount = 0

    func refreshPresentation(
        for request: SyncConvergencePresentationRequest
    ) async -> SyncConvergencePostCommitAdapterResult {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
        requests.append(request)
        try? await Task.sleep(nanoseconds: 50_000_000)
        activeCount -= 1
        return .verifiedComplete
    }

    func requestCount() -> Int {
        requests.count
    }

    func maximumConcurrentRequests() -> Int {
        maxActiveCount
    }
}
